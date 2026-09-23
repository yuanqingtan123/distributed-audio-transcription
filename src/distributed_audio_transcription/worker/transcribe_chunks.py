#!/usr/bin/env python3

"""
Transcribe a single audio chunk using Faster Whisper.

This module:
    1. Loads the configured Whisper model from the local cache when available.
    2. Downloads the model from Hugging Face if the local cache is unavailable.
    3. Transcribes the specified audio chunk.
    4. Writes the transcription segments to a CSV file.

The script is invoked by worker.sh for each WAV chunk assigned to a worker.

Command-line usage:
    python -m distributed_audio_transcription.worker.transcribe_chunks \
        -i <input_audio_file> \
        -o <output_csv_file>
"""

from typing import Iterable

from faster_whisper import WhisperModel
from faster_whisper.transcribe import Segment
from pathlib import Path
import logging
import click

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
)


def transcribe_chunks(
    model_size: str,
    compute_type: str,
    input_file_path: str
) -> Iterable[Segment]:
    """
    Load the Whisper model and transcribe an audio file.

    The function first attempts to load the model from the local cache.
    If the model is unavailable or the cache is corrupted, it falls back
    to downloading the model from Hugging Face.

    Args:
        model_size: Whisper model to load.
        compute_type: Compute type used by Faster Whisper.
        input_file_path: Path to the audio file to transcribe.

    Returns:
        An iterable of transcription segments produced by Faster Whisper.
    """
    try:
        # Try the local model cache first to avoid downloading the model.
        logging.info("Loading model from local cache...")
        model = WhisperModel(
            model_size,
            device="cpu",
            compute_type=compute_type,
            local_files_only=True
        )
    except Exception:
        # Fall back to downloading the model if the local cache is unavailable.
        logging.warning(
            "Cache missing or corrupted! Downloading model from Hugging Face...")
        model = WhisperModel(
            model_size,
            device="cpu",
            compute_type=compute_type,
            local_files_only=False
        )

    logging.info(f"Transcribing <{input_file_path}>")
    segments, _ = model.transcribe(
        input_file_path,
        beam_size=5,
        log_progress=True
    )

    return segments


@click.command()
@click.option(
    "--input-file",
    "-i",
    required=True,
    type=click.Path(exists=True),
    help="Path to the audio chunk to transcribe.",
)
@click.option(
    "--output-file",
    "-o",
    required=True,
    type=click.Path(exists=False),
    help="Path for the output transcription CSV file.",
)
def main(input_file, output_file):
    """
    Transcribe an audio file and write the segments to a CSV file.

    Args:
        input_file: Path to the audio chunk.
        output_file: Path where the transcription CSV will be written.
    """
    logging.info(f"Script started for <{input_file}>")

    segments: Iterable[Segment] = transcribe_chunks(
        "large-v3-turbo", "int8",
        input_file
    )

    logging.info(f"Writing output to <{output_file}>")
    with open(output_file, "w") as outfile:
        outfile.write("startTime,endTime,text\n")
        for segment in segments:
            formatted_line: str = f'"{segment.start}","{segment.end}","{segment.text}"\n'
            outfile.write(formatted_line)

    logging.info(f"Scripted ended for <{input_file}>")


if __name__ == "__main__":
    main()
