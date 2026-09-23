# Distributed Audio Transcription

## Overview

This project distributes audio transcription workloads across multiple worker devices.

The controller device coordinates the transcription process by:

* Finding and preparing input audio files.
* Splitting audio files into fixed-length WAV chunks.
* Allocating chunks to workers according to their workload weights.
* Transferring chunks to workers.
* Starting the transcription process on workers.
* Waiting for all workers to complete.
* Consolidating the transcription results into a single SRT file.

Worker devices process their assigned audio chunks, generate transcription CSV files, and return the results to the controller.

Android devices can be used as workers through Termux.

---

## Architecture

The system consists of a **controller** and one or more **workers**.

### Controller

The controller:

1. Finds audio files in the input directory.
2. Renames input files to remove unsupported characters and normalize spaces.
3. Splits each audio file into fixed-length WAV chunks.
4. Calculates how many chunks each worker should process based on `workload_weight`.
5. Moves the assigned chunks into worker-specific directories.
6. Starts the worker processes remotely.
7. Transfers the assigned chunks to the workers.
8. Signals each worker when all of its chunks have been transferred.
9. Waits for completion signals from all workers.
10. Consolidates the returned transcription CSV files into a final SRT file.

### Workers

Each worker:

1. Waits for WAV chunks to become available.
2. Transcribes each assigned chunk.
3. Archives each processed WAV chunk.
4. Waits until all assigned chunks have been transferred and processed.
5. Transfers the transcription CSV files back to the controller.
6. Signals the controller after the result transfer succeeds.

Workers can process chunks while the controller is still transferring additional chunks.

---

## Prerequisites

### Controller

The controller device requires:

| Dependency  | Purpose                                                         |
| ----------- | --------------------------------------------------------------- |
| Bash        | Executes the shell scripts                                      |
| FFmpeg      | Splits input audio into fixed-length WAV chunks                 |
| yq          | Reads worker settings from the YAML configuration               |
| bc          | Performs workload allocation calculations                       |
| inotifywait | Monitors the signal directory for worker completion signals     |
| SSH         | Starts worker processes remotely                                |
| rsync       | Transfers audio chunks, transcription results, and signal files |
| uv          | Runs the Python scripts and their environment                   |

### Workers

Workers require:

* Bash
* `uv`
* `rsync`
* SSH access back to the controller
* Python dependencies required by `transcribe_chunks.py`

Android workers can run the worker-side scripts through Termux.

Worker-specific setup and dependencies may vary depending on the worker environment.

---

## Environment Variables

The project uses different environment variables on the controller and worker machines.

Configure the environment variables in the `.env` file placed at the project root
### Controller Machine

The controller requires:

```bash
export workerProjectRoot=<path to the repo on the worker>
```

Example:

```bash
export workerProjectRoot=/data/data/com.termux/files/home/distributed-audio-transcription
```

`workerProjectRoot` is the path to the project repository as seen from the worker environment.

The controller uses this value when executing commands remotely on workers.

### Worker Machines

Each worker requires:

```bash
export controller=<SSH host alias for the controller>
export controllerProjectRoot=<path to the repo on the controller>
```

Example:

```bash
export controller=controller
export controllerProjectRoot=/home/user/distributed-audio-transcription
```

`controller` identifies the SSH host used by the worker to connect back to the controller.

`controllerProjectRoot` is the path to the project repository on the controller machine.

---

## Worker Configuration

The controller uses a YAML configuration file to define the available workers.

### Configuration Fields

| Field             | Purpose                                                         |
| ----------------- | --------------------------------------------------------------- |
| `alias`           | Unique identifier used by the controller to identify the worker |
| `host`            | Hostname or network address used for SSH and rsync              |
| `user`            | SSH username used to access the worker                          |
| `port`            | SSH port used by the worker                                     |
| `password`        | Authentication credential used when connecting to the worker    |
| `workload_weight` | Relative amount of transcription work assigned to the worker    |

### `alias`

The alias must be unique within the configuration because it is used as the worker identifier throughout the controller/worker workflow.

### `workload_weight`

Workload weights determine the relative number of audio chunks assigned to each worker.

For example:

```text
worker1: workload_weight = 1
worker2: workload_weight = 2
worker3: workload_weight = 3
```

The workers receive approximately:

```text
worker1 → 1/6 of the chunks
worker2 → 2/6 of the chunks
worker3 → 3/6 of the chunks
```

The workload weight must be a numeric value.

The controller rounds the initial proportional allocation to whole chunks. Any remaining chunks are assigned to workers with the smallest current allocation.

### Example

```yaml
configs:
  - alias: worker1
    host: worker1.example
    user: username
    port: 22
    password: <worker-password>
    workload_weight: 1

  - alias: worker2
    host: worker2.example
    user: username
    port: 22
    password: <worker-password>
    workload_weight: 2
```

> Do not commit real worker passwords or other credentials to the repository.

---

## Usage

### Controller

The controller coordinates the transcription process across all configured workers.

Run `controller.sh` from the project root:

```bash
./controller.sh \
  -i <input_directory> \
  -o <output_directory> \
  -c <worker_config_file>
```

### Arguments

| Option | Description                                     |
| ------ | ----------------------------------------------- |
| `-i`   | Directory containing input audio files          |
| `-o`   | Directory where the final SRT files are written |
| `-c`   | YAML file containing the worker configuration   |

Example:

```bash
./controller.sh \
  -i input \
  -o output \
  -c ssh-configs/workers.yaml
```

### Before Running

Make sure that:

1. The required controller dependencies are installed.
2. The required environment variables are configured.
3. The worker configuration file contains at least one valid worker.
4. The configured workers are accessible through SSH.
5. Workers can connect back to the controller when required.
6. Input audio files are located directly inside the specified input directory.

### Processing Flow

For each input file, the controller follows this workflow:

```text
Input audio
     │
     ▼
Rename input file
     │
     ▼
Split into WAV chunks
     │
     ▼
Calculate worker allocation
     │
     ▼
Distribute chunks into worker directories
     │
     ▼
Start workers
     │
     ▼
Transfer chunks to workers
     │
     ▼
Signal workers that all chunks are ready
     │
     ▼
Workers transcribe chunks
     │
     ▼
Workers transfer CSV results
     │
     ▼
Workers send completion signals
     │
     ▼
Controller waits for all workers
     │
     ▼
Consolidate CSV results
     │
     ▼
Final SRT file
```

Workers can begin transcribing chunks while the controller is still transferring additional chunks.

If multiple input files are present, the controller processes them sequentially.

### Output

For each successfully processed input file, the controller generates an SRT file in the specified output directory.

The output filename is based on the input filename.

For example:

```text
input/
└── meeting.mp3

output/
└── meeting.SRT
```

### Logs

The controller records informational and error messages with timestamps.

Example:

```text
[2026-09-23 19:00:00] INFO: Script started
[2026-09-23 19:00:01] INFO: Found 2 file(s) in input
[2026-09-23 19:00:02] INFO: Start processing meeting.mp3
```

Worker logs are stored in the staging directory for the corresponding input file:

```text
staging/
└── <timestamp>-<input_file_name>/
    └── logs/
        ├── worker1.logs
        └── worker2.logs
```

These logs can be used to inspect worker-side processing when troubleshooting.

### Multiple Input Files

If the input directory contains multiple audio files, each file receives its own staging directory.

The controller processes each file sequentially:

```text
Input file 1
     ↓
Process all workers
     ↓
Consolidate SRT
     ↓
Input file 2
     ↓
Process all workers
     ↓
Consolidate SRT
     ↓
...
```

The controller reports the number of successfully processed files after all input files have been handled.

---

## Directory Structure

A typical project structure is:

```text
distributed-audio-transcription/
├── .env
├── controller.sh
├── scripts/
│   └── worker.sh
├── src/
│   └── distributed_audio_transcription/
│       ├── controller/
│       │   └── consolidate_srt.py
│       └── worker/
│           └── transcribe_chunks.py
├── ssh-configs/
│   └── <worker_config_file>
├── staging/
├── <input_directory>/
└── <output_directory>/
```

The exact directory structure may vary depending on the local environment.

### Staging

The controller creates a separate staging directory for each input file:

```text
staging/
└── <timestamp>-<input_file_name>/
    ├── audioChunks/
    ├── srtChunks/
    ├── signal/
    ├── logs/
    └── archive/
```

#### `audioChunks/`

Contains the WAV chunks generated by FFmpeg.

Before transfer, chunks are moved into worker-specific directories:

```text
audioChunks/
├── worker1/
│   ├── chunk_000.wav
│   └── chunk_001.wav
└── worker2/
    ├── chunk_002.wav
    └── chunk_003.wav
```

On each worker, processed chunks are moved into an archive directory.

#### `srtChunks/`

Contains the transcription CSV files returned by the workers.

Each worker has its own subdirectory:

```text
srtChunks/
├── worker1/
│   ├── chunk_000.csv
│   └── chunk_001.csv
└── worker2/
    ├── chunk_002.csv
    └── chunk_003.csv
```

These files are later used by `consolidate_srt.py` to generate the final SRT file.

#### `signal/`

Contains the controller/worker signal files used to coordinate processing.

The controller sends a signal to each worker after its assigned chunks have been completely transferred:

```text
controller-<worker>.signal
```

Workers send a completion signal back to the controller after all transcription results have been transferred successfully:

```text
<worker>-controller.signal
```

The controller monitors this directory and starts SRT consolidation after all workers have reported completion.

#### `logs/`

Contains worker-specific log files:

```text
logs/
├── worker1.logs
└── worker2.logs
```

#### `archive/`

Processed WAV chunks are moved to the archive directory by the worker after transcription.

This prevents already-processed chunks from being processed again.

---

## Workflow

### 1. Controller prepares the input

The controller finds audio files directly inside the configured input directory.

Before processing, filenames are normalized by:

* Removing non-ASCII characters.
* Replacing spaces with underscores.
* Preserving the original file extension.

### 2. Controller splits the audio

Each audio file is split into WAV chunks using FFmpeg.

The current chunk length is **300 seconds**.

```text
Original audio
     │
     ├── chunk_000.wav
     ├── chunk_001.wav
     ├── chunk_002.wav
     └── ...
```

### 3. Controller allocates chunks

Chunks are distributed according to each worker's `workload_weight`.

For example:

```text
worker1 → weight 1
worker2 → weight 2
```

means worker2 receives approximately twice as many chunks as worker1.

### 4. Controller starts workers and transfers chunks

The controller starts `worker.sh` remotely for each worker.

Chunk transfers are performed in parallel.

Workers can therefore start processing chunks while additional chunks are still being transferred.

### 5. Controller signals workers

After a worker's chunk transfer finishes, the controller creates:

```text
controller-<worker>.signal
```

and transfers the signal to that worker.

The signal tells the worker that no more chunks will be transferred for the current input file.

### 6. Workers transcribe chunks

Workers repeatedly check their assigned input directory for WAV files.

Each available WAV file is passed to `transcribe_chunks.py`.

After successful transcription, the WAV file is moved to the archive directory.

A worker finishes its transcription loop only when:

* the controller's completion-of-transfer signal exists; and
* no WAV chunks remain in its input directory.

### 7. Workers return results

After transcription is complete, each worker transfers its generated CSV files back to the corresponding `srtChunks/<worker>/` directory on the controller.

After the result transfer succeeds, the worker creates:

```text
<worker>-controller.signal
```

and transfers the signal to the controller.

### 8. Controller waits for all workers

The controller monitors the signal directory and waits until every configured worker has sent its completion signal.

### 9. Controller consolidates the results

After all workers have completed, the controller runs `consolidate_srt.py`.

The script reads the worker CSV files and combines their transcription segments into a single SRT file.

---

## Components

### `controller.sh`

Runs on the controller device and coordinates the complete distributed transcription workflow.

Responsibilities include:

* Input file preparation
* Audio splitting
* Worker configuration validation
* Workload allocation
* Chunk distribution
* Remote worker startup
* Chunk transfer
* Worker completion monitoring
* SRT consolidation

### `worker.sh`

Runs on each worker device and processes the audio chunks assigned to that worker.

#### Usage

```bash
./worker.sh \
  -i <input_directory> \
  -o <output_directory> \
  -s <signal_file>
```

| Option | Description                                                                          |
| ------ | ------------------------------------------------------------------------------------ |
| `-i`   | Directory containing the worker's assigned WAV chunks                                |
| `-o`   | Directory where transcription CSV files are written                                  |
| `-s`   | Signal file created by the controller when all assigned chunks have been transferred |

#### Processing

For each worker:

1. Wait for WAV chunks to become available.
2. Transcribe each available WAV chunk using `transcribe_chunks.py`.
3. Write the transcription result as a CSV file.
4. Move the processed WAV chunk to the archive directory.
5. Continue checking for additional chunks.
6. Stop when all assigned chunks have been transferred and processed.
7. Transfer the transcription results back to the controller.
8. Send a completion signal to the controller.

### `transcribe_chunks.py`

Runs on each worker device and transcribes a single audio chunk using Faster Whisper.

The script is invoked by `worker.sh` once for each WAV chunk assigned to the worker.

#### Usage

```bash
uv run python -m distributed_audio_transcription.worker.transcribe_chunks \
  -i <input_audio_file> \
  -o <output_csv_file>
```

| Option                | Description                                           |
| --------------------- | ----------------------------------------------------- |
| `-i`, `--input-file`  | Path to the audio chunk to transcribe                 |
| `-o`, `--output-file` | Path where the transcription CSV file will be written |

#### Processing

For each audio chunk, the script:

1. Attempts to load the Whisper model from the local cache.
2. If the model is unavailable or the local cache cannot be used, downloads the model from Hugging Face.
3. Transcribes the audio using Faster Whisper.
4. Writes the transcription segments to a CSV file.

The current configuration uses:

* **Model:** `large-v3-turbo`
* **Device:** CPU
* **Compute type:** `int8`
* **Beam size:** `5`

#### Model Cache

The worker first attempts to load the model using the local cache without accessing the internet.

If the required model files are missing or the cached model cannot be loaded, the script falls back to downloading the model from Hugging Face.

#### Output

The output is a CSV file with the following columns:

```text
startTime,endTime,text
```

Each transcription segment is written as one row:

```text
startTime,endTime,text
"0.0","3.52","Hello everyone."
"3.52","7.84","Welcome to today's meeting."
```

These CSV files are transferred back to the controller by `worker.sh` and are later used by `consolidate_srt.py`.

#### Logging

The script logs:

* Script start
* Model loading
* Whether the model is loaded from cache or downloaded
* The audio chunk being transcribed
* The output file being written
* Script completion

Faster Whisper progress logging is also enabled during transcription.

### `consolidate_srt.py`

Runs on the controller after all workers have completed transcription.

It combines the worker transcription CSV files into a single SRT subtitle file.

#### Usage

```bash
uv run src/distributed_audio_transcription/controller/consolidate_srt.py \
  --srt-chunks-dir <srt_chunks_directory> \
  --output-file-path <output_srt_file>
```

| Option               | Description                                             |
| -------------------- | ------------------------------------------------------- |
| `--srt-chunks-dir`   | Directory containing the worker transcription CSV files |
| `--output-file-path` | Path where the consolidated SRT file will be written    |

#### Input

The script expects the worker results to be organised by worker:

```text
<srt_chunks_directory>/
├── worker1/
│   ├── chunk_000.csv
│   ├── chunk_001.csv
│   └── ...
├── worker2/
│   ├── chunk_002.csv
│   ├── chunk_003.csv
│   └── ...
└── ...
```

Each CSV file contains:

```text
startTime,endTime,text
```

The script searches for files matching:

```text
*/chunk_*.csv
```

within the specified SRT chunks directory.

#### Processing

The script:

1. Finds all worker transcription CSV files.
2. Sorts the chunk files by filename.
3. Reads the transcription segments from each CSV file.
4. Converts timestamps from seconds to SRT timestamp format.
5. Applies a cumulative time offset to the segments.
6. Assigns sequential SRT subtitle numbers starting from `1`.
7. Writes the formatted subtitles into the output SRT file.

Chunk files are processed in filename order:

```text
chunk_000.csv
chunk_001.csv
chunk_002.csv
...
```

#### Timestamp Conversion

Transcription timestamps are initially represented in seconds.

The script converts them into the standard SRT timestamp format:

```text
HH:MM:SS,mmm
```

For example:

```text
12.345
```

becomes:

```text
00:00:12,345
```

The timestamp of each segment is adjusted using the cumulative time calculated while processing the preceding transcription segments.

#### Output

The final output is an SRT subtitle file containing sequential subtitle entries:

```text
1
00:00:00,000 --> 00:00:03,520
Hello everyone.

2
00:00:03,520 --> 00:00:07,840
Welcome to today's meeting.
```

The controller determines the output filename.

For example:

```text
input/meeting.mp3
        ↓
output/meeting.SRT
```

#### Progress and Logging

The script displays a progress bar while consolidating the CSV files.

It also logs:

* Script start
* Input transcription directory
* Output SRT path
* Completion of SRT consolidation
* Script completion

---

## Troubleshooting

Common troubleshooting guidance will be documented after the main workflow and failure points have been reviewed.

Potential areas include:

* Worker SSH connectivity
* rsync transfers
* Worker completion signals
* Missing or corrupted Whisper model files
* Transcription failures
* Missing worker CSV files
* SRT consolidation issues
