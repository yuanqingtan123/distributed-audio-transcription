#!/bin/bash

# ==============================================================================
# worker.sh
#
# Worker-side script for distributed audio transcription.
#
# This script runs on a worker device and:
#
#   1. Waits for audio chunks to become available.
#   2. Transcribes each assigned WAV chunk.
#   3. Archives processed audio chunks.
#   4. Transfers the transcription results back to the controller.
#   5. Signals the controller after all results have been transferred.
#
# The controller starts this script remotely and provides:
#   - The directory containing the worker's assigned audio chunks.
#   - The directory where transcription results should be written.
#   - A signal file indicating that all assigned chunks have been transferred.
#
# Usage:
#   ./worker.sh -i <input_directory> \
#               -o <output_directory> \
#               -s <signal_file>
#
# Dependencies:
#   bash, uv, rsync, SSH access to the controller
#
# Related components:
#   controller.sh          - Starts and coordinates worker processes.
#   transcribe_chunks.py   - Transcribes individual audio chunks.
# ==============================================================================

# ==============================================================================
# Logging utilities
# ==============================================================================
log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $@" >&2
}
log_info() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $@"
}

# ==============================================================================
# Argument parsing
# ==============================================================================

SCRIPT_NAME=$(basename "$0")
USAGE_MSG="./$SCRIPT_NAME -i [input directory] -o [output directory] -s [signal file]"

# ------------------------------------------------------------------------------
# Argument validation
# ------------------------------------------------------------------------------
if [[ $# -gt 6 ]]; then
    echo "Too many arguments"
    echo "$USAGE_MSG"
    exit 1
fi

if [[ $(($# % 2)) -ne 0 ]]; then
    echo "Invalid number of arguments"
    echo "$USAGE_MSG"
    exit 1
fi

# ------------------------------------------------------------------------------
# Parse command-line arguments
# ------------------------------------------------------------------------------
while getopts "i:o:s:" opt; do
    case "$opt" in
    i) inputDir="$OPTARG" ;;
    o) outputDir="$OPTARG" ;;
    s) signalFile="$OPTARG" ;;
    \?)
        echo "Invalid usage"
        echo "$USAGE_MSG"
        exit 1
        ;;
    esac
done

# ------------------------------------------------------------------------------
# Validate required arguments
# ------------------------------------------------------------------------------
if [[ -z "$inputDir" || -z "$outputDir" || -z "$signalFile" ]]; then
    echo "Missing required argument"
    echo "$USAGE_MSG"
    exit 1
fi

# ==============================================================================
# Worker paths
# ==============================================================================
# Derive worker-specific paths from the input and signal locations.
workerName=$(basename "$inputDir")
archiveDir="$(dirname "$(dirname "$inputDir")")/archive"
signalFileDir="$(dirname "$signalFile")"

# ==============================================================================
# Initialization
# ==============================================================================
log_info "Script started"
log_info "Input directory: $inputDir"
log_info "Output directory: $outputDir"
log_info "Archive directory: $archiveDir"
log_info "Signal file: $signalFile"

source .env
mkdir -p "$outputDir"
mkdir -p "$archiveDir"

# ==============================================================================
# Transcription loop
# ==============================================================================
#
# The worker polls the input directory for WAV chunks while the controller is
# transferring them. Each available chunk is transcribed and then moved to the
# archive directory so it is not processed again.
#
# The loop ends only when:
#   1. The controller has created the signal file indicating that all chunks
#      have been transferred.
#   2. No WAV chunks remain in the input directory.
#
# This allows transcription to begin before all chunks have finished
# transferring.
while true; do
    for f in "$inputDir"/*.wav; do
        [ -e "$f" ] || continue
        chunkFileName=$(basename "$f")
        "$UV_PATH" run python -m distributed_audio_transcription.worker.transcribe_chunks \
            --input-file "$f" \
            --output-file "$outputDir/${chunkFileName/%.wav/}.csv"
        log_info "$?"
        # Move the processed chunk to the archive directory so it is not processed
        # again during the next polling cycle.
        mv "$f" "$archiveDir/"
    done
    # The worker can stop only after the controller has confirmed that all
    # assigned chunks have been transferred and the input directory is empty.
    if [ -e "$signalFile" ] && [ ! "$(ls -A $inputDir)" ]; then
        break
    fi
    sleep 2
done

log_info "Finished transcribing all chunks in <$inputDir>"

# ==============================================================================
# Transfer results
# ==============================================================================
#
# After all assigned chunks have been transcribed, transfer the generated
# transcription files back to the controller.
#
# The controller is notified only after the result transfer succeeds.
transcriptionOutputDir="$(dirname "$outputDir")/$(basename "$outputDir")"

# No transfer needed when this script is run in the localWorker
if [[ "$workerName" == "localWorker" ]]; then
    signalFileToController="$signalFileDir/$workerName-controller.signal"
    touch "$signalFileToController"
    log_info "Script ended"
    exit 0
else
    # if using remote worker
    log_info "Transferring transcriptions back to controller"
    rsync -azp --mkpath --ignore-existing "$transcriptionOutputDir/" "$controller:$controllerProjectRoot/$transcriptionOutputDir"
fi

# ==============================================================================
# Worker completion
# ==============================================================================
#
# Create and transfer the worker completion signal after all transcription
# results have been successfully transferred to the controller.
#
# Signal:
#   <worker>-controller.signal
if [[ "$?" -eq 0 ]]; then
    signalFileToController="$signalFileDir/$workerName-controller.signal"
    touch "$signalFileToController"
    rsync -avp --mkpath "./$signalFileToController" "$controller:$controllerProjectRoot/$signalFileDir/"
    log_info "Finished transferring all transcriptions back to controller"
    log_info "Script ended"
    exit 0
else
    log_error "Failed to transfer all transcriptions back to controller."
    exit 1
fi

#!/bin/bash

# ==============================================================================
# worker.sh
#
# Worker-side script for distributed audio transcription.
#
# This script runs on a worker device and:
#
#   1. Waits for audio chunks to become available.
#   2. Transcribes each assigned WAV chunk.
#   3. Archives processed audio chunks.
#   4. Transfers the transcription results back to the controller.
#   5. Signals the controller after all results have been transferred.
#
# The controller starts this script remotely and provides:
#   - The directory containing the worker's assigned audio chunks.
#   - The directory where transcription results should be written.
#   - A signal file indicating that all assigned chunks have been transferred.
#
# Usage:
#   ./worker.sh -i <input_directory> \
#               -o <output_directory> \
#               -s <signal_file>
#
# Dependencies:
#   bash, uv, rsync, SSH access to the controller
#
# Related components:
#   controller.sh          - Starts and coordinates worker processes.
#   transcribe_chunks.py   - Transcribes individual audio chunks.
# ==============================================================================

# ==============================================================================
# Logging utilities
# ==============================================================================
log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $@" >&2
}

log_info() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $@"
}

# ==============================================================================
# Argument parsing
# ==============================================================================

SCRIPT_NAME=$(basename "$0")
USAGE_MSG="./$SCRIPT_NAME -i [input directory] -o [output directory] -s [signal file]"

# ------------------------------------------------------------------------------
# Argument validation
# ------------------------------------------------------------------------------
if [[ $# -gt 6 ]]; then
    echo "Too many arguments"
    echo "$USAGE_MSG"
    exit 1
fi

if [[ $(($# % 2)) -ne 0 ]]; then
    echo "Invalid number of arguments"
    echo "$USAGE_MSG"
    exit 1
fi

# ------------------------------------------------------------------------------
# Parse command-line arguments
# ------------------------------------------------------------------------------
while getopts "i:o:s:" opt; do
    case "$opt" in
    i) inputDir="$OPTARG" ;;
    o) outputDir="$OPTARG" ;;
    s) signalFile="$OPTARG" ;;
    \?)
        echo "Invalid usage"
        echo "$USAGE_MSG"
        exit 1
        ;;
    esac
done

# ------------------------------------------------------------------------------
# Validate required arguments
# ------------------------------------------------------------------------------
if [[ -z "$inputDir" || -z "$outputDir" || -z "$signalFile" ]]; then
    echo "Missing required argument"
    echo "$USAGE_MSG"
    exit 1
fi

# ==============================================================================
# Worker paths
# ==============================================================================
workerName=$(basename "$inputDir")
archiveDir="$(dirname "$(dirname "$inputDir")")/archive"
signalFileDir="$(dirname "$signalFile")"

# ==============================================================================
# Initialization
# ==============================================================================
log_info "Script started"
log_info "Input directory: $inputDir"
log_info "Output directory: $outputDir"
log_info "Archive directory: $archiveDir"
log_info "Signal file: $signalFile"

source .env
mkdir -p "$outputDir"
mkdir -p "$archiveDir"

# ==============================================================================
# Transcription loop
# ==============================================================================
#
# The worker polls the input directory for WAV chunks while the controller is
# transferring them. Each available chunk is transcribed and then moved to the
# archive directory so it is not processed again.
#
# The loop ends only when:
#   1. The controller has created the signal file indicating that all chunks
#      have been transferred.
#   2. No WAV chunks remain in the input directory.
#
# This allows transcription to begin before all chunks have finished
# transferring.

while true; do
    for f in "$inputDir"/*.wav; do
        [ -e "$f" ] || continue

        chunkFileName=$(basename "$f")

        "$UV_PATH" run python \
            -m distributed_audio_transcription.worker.transcribe_chunks \
            --input-file "$f" \
            --output-file "$outputDir/${chunkFileName/%.wav/}.csv"

        log_info "$?"

        # Move the processed chunk to the archive directory so it is not
        # processed again during the next polling cycle.
        mv "$f" "$archiveDir/"
    done

    # The worker can stop only after the controller has confirmed that all
    # assigned chunks have been transferred and the input directory is empty.
    if [[ -e "$signalFile" && -z "$(ls -A "$inputDir")" ]]; then
        break
    fi

    sleep 2
done

log_info "Finished transcribing all chunks in <$inputDir>"

# ==============================================================================
# Transfer results
# ==============================================================================
#
# Remote workers transfer their transcription results back to the controller.
# localWorker already has its results in the controller's filesystem, so no
# transfer is required.

# Normalize output directory path to ensure it has no trailing slash.
# This is important because rsync treats a source directory with and without
# a trailing slash differently.
transcriptionOutputDir="$(dirname "$outputDir")/$(basename "$outputDir")"

if [[ "$workerName" != "localWorker" ]]; then
    log_info "Transferring transcriptions back to controller"

    if ! rsync -azp --mkpath --ignore-existing \
        "$transcriptionOutputDir/" \
        "$controller:$controllerProjectRoot/$transcriptionOutputDir"; then

        log_error "Failed to transfer all transcriptions back to controller."
        exit 1
    fi
fi

# ==============================================================================
# Worker completion
# ==============================================================================
#
# Create the worker completion signal after all transcription results have been
# successfully transferred.
#
# Signal:
#   <worker>-controller.signal

signalFileToController="$signalFileDir/$workerName-controller.signal"
touch "$signalFileToController"

if [[ "$workerName" != "localWorker" ]]; then
    rsync -avp --mkpath \
        "./$signalFileToController" \
        "$controller:$controllerProjectRoot/$signalFileDir/"

    if [[ "$?" -ne 0 ]]; then
        log_error "Failed to transfer completion signal to controller."
        exit 1
    fi

    log_info "Finished transferring all transcriptions back to controller"
fi

log_info "Script ended"
exit 0
