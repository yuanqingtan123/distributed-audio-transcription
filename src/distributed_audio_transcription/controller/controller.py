#!/usr/bin/python3
import subprocess
from faster_whisper import WhisperModel
import logging
from pathlib import Path
from datetime import datetime
import shutil
import click
from fabric import Connection
from paramiko.ssh_exception import BadAuthenticationType
from distributed_audio_transcription.utils.params import Config, SSHConfig
from concurrent.futures import ThreadPoolExecutor, as_completed

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
)

UBUNTU_ROOT = "/data/data/com.termux/files/usr/var/lib/proot-distro/containers/ubuntu/rootfs/root/"


def split_audio(input_file: Path, chunks_dir: Path, chunk_length: int) -> None:
    """
    Split an audio file into fixed-length .wav chunks using ffmpeg.

    Args:
        input_file (Path): Path to the input audio file.
        chunks_dir (Path): Directory where chunk files will be stored.
        chunk_length (int): Length of each chunk in seconds.

    Raises:
        subprocess.CalledProcessError: If ffmpeg fails to process the file.
    """
    subprocess.run([
        "ffmpeg", "-i", input_file,
        "-f", "segment", "-segment_time", str(chunk_length),
        "-c", "pcm_s16le",  # force raw WAV encoding
        "-hide_banner",
        "-loglevel", "error",
        f"{chunks_dir}/chunk_%03d.wav"
    ], check=True)


def get_worker_workload(configs: list[SSHConfig]) -> dict[str, float]:
    workloads: list[int] = [config.workload_weight for config in configs]
    total_workload: int = sum(workloads)

    normalised_workload_by_alias: dict[str, float] = {
        config.alias: config.workload_weight/total_workload
        for config in configs
        if config.workload_weight != 0
    }

    return normalised_workload_by_alias


def distribute_files(workload_config: dict[str, float], main_chunks_dir: Path) -> list[tuple[str, list[Path]]]:
    all_chunks: list[Path] = sorted(
        [
            path
            for path in main_chunks_dir.iterdir()
            if path.is_file and path.name.endswith(".wav")
        ]
    )

    num_of_chunks: int = len(all_chunks)

    num_of_chunks_by_worker: list[tuple[str, int]] = [
        (worker, round(workload*num_of_chunks))
        for worker, workload in workload_config.items()
    ]

    total_distributed_chunks: int = sum(
        [
            num_of_chunks
            for _, num_of_chunks in num_of_chunks_by_worker
        ]
    )

    diff: int = num_of_chunks-total_distributed_chunks

    if diff != 0:
        num_of_chunks_by_worker[-1] = (num_of_chunks_by_worker[-1]
                                       [0], num_of_chunks_by_worker[-1][1]+diff)

    assigned_chunks: int = 0
    list_of_chunks_by_worker: list[tuple[str, list[Path]]] = list()
    for worker, num_of_chunks in num_of_chunks_by_worker:
        if num_of_chunks == 0:
            continue
        list_of_chunks_by_worker.append(
            (worker, all_chunks[assigned_chunks:assigned_chunks+num_of_chunks])
        )
        assigned_chunks += num_of_chunks

    return list_of_chunks_by_worker


def move_chunks_to_sub_chunks(file_paths_to_send: list[Path], worker: str) -> list[Path]:
    if not file_paths_to_send:
        logging.info(f"No files to be sent to {worker}")
        return None
    main_chunks_dir: Path = file_paths_to_send[0].parent

    sub_chunks_dir: Path = main_chunks_dir.joinpath(worker)
    sub_chunks_dir.mkdir(parents=True, exist_ok=True)

    logging.info(f"Using sub-chunks folder at {sub_chunks_dir}")
    for path in file_paths_to_send:
        filename = path.name
        path.rename(sub_chunks_dir.joinpath(filename))

    logging.info(f"Moved files into {sub_chunks_dir}")

    updated_file_paths_to_send: list[Path] = list(sub_chunks_dir.iterdir())

    return updated_file_paths_to_send


def process_chunk_at_worker(file_paths: list[Path], ssh_target: SSHConfig) -> str:
    try:
        connection: Connection = Connection(
            host=ssh_target.host,
            user=ssh_target.user,
            port=ssh_target.port,
            connect_kwargs={
                "password": ssh_target.password,
                "look_for_keys": False
            }
        )
        connection.open()
    except BadAuthenticationType:
        connection: Connection = Connection(ssh_target.alias)

    test_user = connection.run("whoami", hide=True).stdout.strip()
    if test_user == ssh_target.user:
        logging.info(f"Connected to {ssh_target.alias}")

    files = []
    for file in file_paths:
        connection.put(file, remote=f"{UBUNTU_ROOT}/staging/")
        ress = connection.run(
            f"proot-distro login ubuntu -- bash -c 'ls staging'", hide=True).stdout.strip()
        files.append(ress)

    connection.close()
    return f"{ssh_target.alias}-{files[-1]}"


def temp():
    configs: list[SSHConfig] = Config.from_yaml().configs
    termux_phone_config: SSHConfig = [
        config for config in configs if config.alias == "termux-tablet"][0]
    process_chunk_at_worker([Path("123")], termux_phone_config)


@click.command()
@click.option("--input-folder", required=True, type=click.Path(exists=True),
              help="Path to the folder containing audio files to transcribe.")
@click.option("--output-folder", required=True, type=click.Path(exists=False),
              help="Path to the folder where output SRT files will be written.")
def main(input_folder, output_folder):
    """
    Main entry point for batch transcription.

    Iterates over all audio files in the input folder, processes each file,
    and writes the corresponding SRT file to the output folder.

    Args:
        input_folder (str): Path to the input folder.
        output_folder (str): Path to the output folder.

    Logs:
        - Start/end of script execution.
        - Number of files found and processed.
        - Success/failure per file.
        - Cleanup of temporary chunk directories.
    """
    logging.info("Script started")
    input_folder_path: Path = Path(input_folder)
    input_files: list[Path] = []
    configs: list[SSHConfig] = Config.from_yaml().configs
    configs_by_alias: dict[str, SSHConfig] = {
        config.alias: config
        for config in configs
    }

    for path in input_folder_path.iterdir():
        if path.is_file():
            if not path.name.endswith(":Zone.Identifier"):
                input_files.append(path)
            else:
                path.unlink(missing_ok=True)

    num_of_input_files: int = len(input_files)

    if num_of_input_files == 0:
        logging.info("No files to transcribe")
        logging.info("Script ended")
        return

    logging.info(f"Found {num_of_input_files} files in {input_folder_path}")

    failure_files = []
    for num, input_file in enumerate(input_files, 1):
        logging.info(
            f"Processing file {num} of {num_of_input_files}: {input_file}")

        audio_file: str = input_file.name
        base_name: str = ".".join(audio_file.split(".")[:-1])
        output_name: str = f"{base_name}.SRT"
        output_file: Path = Path(output_folder).joinpath(output_name)

        try:
            main_chunks_dir: Path = input_folder_path.joinpath(
                f"{datetime.now().strftime("%Y%m%dT%H%M%S")}-{audio_file}_chunks")
            main_chunks_dir.mkdir(parents=True, exist_ok=True)
            if main_chunks_dir.exists() and len(list(main_chunks_dir.iterdir())) != 0:
                raise FileExistsError(
                    f"Main chunk directory {main_chunks_dir} exists and is not empty. Please rename or remove it.")
            main_chunks_dir = Path(
                "inputAudioFiles/20260911T175429-6 May, 22.35​.m4a_chunks")
            logging.info(f"Using main chunks folder at {main_chunks_dir}")
            # split_audio(input_file, main_chunks_dir, chunk_length=5 * 60)

            worker_workload: dict[str, float] = get_worker_workload(configs)

            chunks_by_worker: list[tuple[str, list[Path]]] = distribute_files(
                worker_workload,
                main_chunks_dir
            )

            with ThreadPoolExecutor(max_workers=len(chunks_by_worker)) as executor:
                futures = [
                    executor.submit(
                        process_chunk_at_worker,
                        files,
                        configs_by_alias[alias]
                    )
                    for alias, files in chunks_by_worker
                ]
                for future in as_completed(futures):
                    print(future.result())

        except FileExistsError as e:
            logging.error(f"❌ {e}")
            break
        except subprocess.CalledProcessError:
            logging.error(f"❌ ffmpeg failed to process {audio_file}")
            failure_files.append(audio_file)

        # shutil.rmtree(main_chunks_dir)
        # logging.info(f"Cleared chunks folder {main_chunks_dir}")

    num_of_failure_files: int = len(failure_files)
    if num_of_failure_files == 0:
        logging.info(f"Successfully processed all {num_of_input_files} files")
    else:
        logging.error(
            f"Successfully processed {num_of_input_files-num_of_failure_files} of {num_of_input_files}")
        logging.error(
            f"Failed to process {num_of_failure_files}: {", ".join(failure_files)}")

    logging.info("Script ended")


if __name__ == "__main__":
    main()
    # temp()
