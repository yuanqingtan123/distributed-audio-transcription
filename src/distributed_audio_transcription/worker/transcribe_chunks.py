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


def transcribe_chunks(model_size: str, compute_type: str, input_file_path: str) -> Iterable[Segment]:
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

    logging.info(f"Transcribing <{input_file_path}>")
    segments, _ = model.transcribe(
        input_file_path,
        beam_size=5,
        log_progress=True
    )

    return segments


@click.command()
@click.option("--input-file", "-i", required=True, type=click.Path(exists=True), help="Path to the audio chunk to be transcribed")
@click.option("--output-file", "-o", required=True, type=click.Path(exists=False), help="Path to output the transcription csv file")
def main(input_file, output_file):
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
