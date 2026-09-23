#!/usr/bin/python3

"""
Consolidate worker transcription CSV files into a single SRT subtitle file.

The script runs on the controller after all workers have completed
transcription. It:

    1. Finds transcription CSV files produced by the workers.
    2. Processes the chunks in filename order.
    3. Applies cumulative time offsets to the transcription timestamps.
    4. Assigns sequential SRT subtitle numbers.
    5. Writes the resulting subtitles to a single SRT file.
"""

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


def consolidate_srt(
    start_time: float,
    start_srt_seq: int,
    transcription_segments: list[dict[str, Any]],
) -> tuple[float, int, list[str]]:
    """
    Convert transcription segments into formatted SRT entries.

    Each segment's timestamps are offset by the supplied start time.
    Subtitle sequence numbers continue from the supplied starting sequence.

    Args:
        start_time (float): Cumulative time offset to apply to the segments.
        start_srt_seq (int): Starting SRT sequence number.
        transcription_segments (list[dict[str, Any]]): Transcription segments read from a worker CSV file.

    Returns:
        A tuple containing:
            - Updated cumulative time.
            - Next SRT sequence number.
            - Formatted SRT subtitle entries.
    """
    cumulative_time: float = 0
    srt_seq: int = start_srt_seq
    formatted_lines = []
    for transcription_segment in transcription_segments:
        line_start_time: float = float(transcription_segment["startTime"])
        line_end_time: float = float(transcription_segment["endTime"])
        text: str = transcription_segment["text"]

        start_ts = get_timestamp(line_start_time + start_time)
        end_ts = get_timestamp(line_end_time + start_time)
        formatted_line = f"{srt_seq}\n{start_ts} --> {end_ts}\n{text}\n\n"
        formatted_lines.append(formatted_line)
        srt_seq += 1
        cumulative_time += line_end_time - line_start_time

    updated_cumulative_time = start_time + cumulative_time

    return (updated_cumulative_time, srt_seq, formatted_lines)


@click.command()
@click.option(
    "--srt-chunks-dir",
    required=True,
    type=click.Path(exists=True),
    help="Directory containing worker transcription CSV files.",
)
@click.option(
    "--output-file-path",
    required=True,
    type=click.Path(exists=False),
    help="Path for the consolidated SRT file.",
)
def main(srt_chunks_dir, output_file_path):
    script_name: str = Path(__file__).name
    logging.info(f"Script {script_name} started for <{srt_chunks_dir}>")
    logging.info(f"Consolidating output to <{output_file_path}>")

    with open(output_file_path, "w") as outfile:
        # Track the timestamp offset and next subtitle sequence across all chunks.
        cumulative_time = 0.0
        srt_seq = 1
        # Process all worker chunk results in chunk filename order.
        for srt_chunk in tqdm(
            sorted(glob.glob(f"{srt_chunks_dir}/*/chunk_*.csv")),
            desc="Consolidating file",
        ):
            with open(srt_chunk, "r") as infile:
                transcription_segments: list[dict[str:Any]] = list(
                    csv.DictReader(infile))
                cumulative_time, srt_seq, formatted_lines = consolidate_srt(
                    cumulative_time, srt_seq, transcription_segments
                )
                if not formatted_lines:
                    continue
                for formatted_line in formatted_lines:
                    outfile.write(formatted_line)

    logging.info(f"Finish consolidating SRT to <{output_file_path}>")
    logging.info(f"Script {script_name} ended for <{srt_chunks_dir}>")


if __name__ == "__main__":
    main()
