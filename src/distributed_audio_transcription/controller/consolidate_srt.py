#!/usr/bin/python3
import click
import logging
import glob
from pathlib import Path
import re
import csv
from typing import Any
from tqdm import tqdm

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s: %(message)s',
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


def consolidate_srt(start_time: float, start_srt_seq: int, srt_lines: list[dict[str:Any]]) -> tuple[float, int, list[str]]:
    cumulative_time: float = 0
    srt_seq: int = start_srt_seq
    formatted_lines = []
    for srt_line in srt_lines:
        line_start_time: float = float(srt_line["startTime"])
        line_end_time: float = float(srt_line["endTime"])
        text: str = srt_line["text"]

        start_ts = get_timestamp(line_start_time + start_time)
        end_ts = get_timestamp(line_end_time + start_time)
        formatted_line = f"{srt_seq}\n{start_ts} --> {end_ts}\n{text}\n\n"
        formatted_lines.append(formatted_line)
        srt_seq += 1
        cumulative_time += line_end_time - line_start_time

    updated_cumulative_time = start_time + cumulative_time

    return (updated_cumulative_time, srt_seq, formatted_lines)


@click.command()
@click.option("--srt-chunks-dir", required=True, type=click.Path(exists=False), help="Path to the folder containing srt chunks")
def main(srt_chunks_dir):
    script_name: str = Path(__file__).name
    logging.info(f"Script {script_name} started for <{srt_chunks_dir}>")

    pattern = r".*/\d{8}_\d{6}-(.*)/audioChunks"
    filename_with_extension: str = re.search(pattern, srt_chunks_dir).group(1)

    filename_no_extension: str = ".".join(
        filename_with_extension.split(".")[:-1]
    )

    current_file_staging_dir: Path = Path(srt_chunks_dir).parent

    output_srt_file: str = current_file_staging_dir\
        .joinpath(f"{filename_no_extension}.SRT")

    logging.info(f"Consolidating output to <{output_srt_file}>")

    with open(output_srt_file, "w") as outfile:
        cumulative_time = 0.0
        srt_seq = 1
        for srt_chunk in tqdm(sorted(glob.glob(f"{srt_chunks_dir}/*/chunk_*.csv")), desc="Consolidating file"):
            with open(srt_chunk, "r") as infile:
                srt_lines: list[dict[str:Any]] = list(csv.DictReader(infile))
                cumulative_time, srt_seq, formatted_lines = consolidate_srt(
                    cumulative_time, srt_seq, srt_lines
                )
                if not formatted_lines:
                    continue
                for formatted_line in formatted_lines:
                    outfile.write(formatted_line)

    logging.info(f"Finish consolidating SRT to <{output_srt_file}>")
    logging.info(f"Script {script_name} ended for <{srt_chunks_dir}>")


if __name__ == "__main__":
    main()
