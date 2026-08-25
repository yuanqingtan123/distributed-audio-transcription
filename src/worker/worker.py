#!/usr/bin/python3
"""
Audio-to-SRT transcription script using Faster-Whisper.

This script automates the conversion of audio files into subtitle files (.SRT)
by splitting audio into fixed-length chunks, transcribing each chunk, and
writing the results in proper SRT format.

Workflow:
    1. Read all audio files from the input folder.
    2. For each file:
        - Split into 5-minute chunks using ffmpeg.
        - Load a Faster-Whisper model (CPU-only, quantized).
        - Transcribe each chunk sequentially.
        - Write subtitles with timestamps into an .SRT file.
        - Clean up temporary chunk directories.
    3. Save all output .SRT files into the specified output folder.

Inputs:
    --input-folder   Path to the folder containing audio files to transcribe.
    --output-folder  Path to the folder where output SRT files will be written.

Outputs:
    One .SRT file per audio input, saved in the output folder.
    Logs are written to stdout/stderr with timestamps and severity levels.

Error Handling:
    - Invalid/missing input files are logged and skipped.
    - ffmpeg failures are logged with the filename.
    - Chunk directories are automatically removed after processing.

Examples:
    Transcribe all audio files in the "inputAudio" folder and save results to "outputSRT":
        uv run transcribe.py --input-folder ./inputAudio --output-folder ./outputSRT

    Transcribe files from an absolute path:
        uv run transcribe.py --input-folder /home/yuan/audio --output-folder /home/yuan/subtitles

    Run with logging output visible:
        uv run transcribe.py --input-folder ./samples --output-folder ./subs
"""


import glob
import subprocess
from faster_whisper import WhisperModel
import logging
from pathlib import Path
from datetime import datetime
import shutil
import click

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
)


def get_timestamp(seconds: float) -> str:
    """
    Convert a time offset in seconds into SRT timestamp format.

    Args:
        seconds (float): Time offset in seconds.

    Returns:
        str: Timestamp string in the format HH:MM:SS,mmm.
    """
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    return f"{int(hours):02}:{int(minutes):02}:{secs:06.3f}".replace(".", ",")


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


def transcribe_chunks(chunks_dir: Path, output_file: Path, model_size: str, compute_type: str) -> None:
    """
    Transcribe audio chunks into an SRT subtitle file.

    Args:
        chunks_dir (Path): Directory containing audio chunks.
        output_file (Path): Path to the output SRT file.
        model_size (str): Whisper model size (e.g., "small", "large-v3-turbo").
        compute_type (str): Compute type for inference (e.g., "int8").

    Notes:
        - Attempts to load the model from local cache first.
        - Falls back to online download if cache is missing.
        - Writes subtitles with sequential numbering and timestamps.
    """
    try:
        # 1. Try to load instantly from local cache without checking the internet
        logging.info("Loading model from local cache...")
        model = WhisperModel(model_size, device="cpu",
                             compute_type=compute_type, local_files_only=True)
    except Exception:
        # 2. If files are missing/deleted, fall back to online download
        logging.warning(
            "Cache missing or corrupted! Downloading model from Hugging Face...")
        model = WhisperModel(model_size, device="cpu",
                             compute_type=compute_type, local_files_only=False)

    cumulative_time = 0.0
    srt_seq = 1

    with open(output_file, "w", encoding="utf-8") as f:
        for file in sorted(glob.glob(f"{chunks_dir}/chunk_*.wav")):
            segments, _ = model.transcribe(
                file, beam_size=5, log_progress=True)

            for seg in segments:
                start_ts = get_timestamp(seg.start + cumulative_time)
                end_ts = get_timestamp(seg.end + cumulative_time)
                line = f"{srt_seq}\n{start_ts} --> {end_ts}\n{seg.text}\n\n"
                f.write(line)
                srt_seq += 1

            cumulative_time += seg.end - seg.start

    logging.info(f"✅ Transcription complete. See {output_file}")


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
            chunks_dir: Path = input_folder_path.joinpath(
                f"{datetime.now().strftime("%Y%m%dT%H%M%S")}-{audio_file}_chunks")
            chunks_dir.mkdir(parents=True, exist_ok=True)
            if chunks_dir.exists() and len(list(chunks_dir.iterdir())) != 0:
                raise FileExistsError(
                    f"Chunk directory {chunks_dir} exists and is not empty. Please rename or remove it.")

            logging.info(f"Using chunks folder at {chunks_dir}")
            split_audio(input_file, chunks_dir, chunk_length=5 * 60)

            transcribe_chunks(chunks_dir, output_file,
                              model_size="large-v3-turbo", compute_type="int8")

        except FileExistsError as e:
            logging.error(f"❌ {e}")
            break
        except subprocess.CalledProcessError:
            logging.error(f"❌ ffmpeg failed to process {audio_file}")
            failure_files.append(audio_file)

        shutil.rmtree(chunks_dir)
        logging.info(f"Cleared chunks folder {chunks_dir}")

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
