#!/bin/bash

# ==============================================================================
# controller.sh
#
# Controller script for distributed audio transcription.
#
# This script runs on the controller device and coordinates the transcription
# of audio files across multiple worker devices. It:
#
#   1. Finds and prepares input audio files.
#   2. Splits each audio file into fixed-length chunks.
#   3. Allocates chunks to workers according to their workload weights.
#   4. Transfers the chunks to the workers and starts the transcription process.
#   5. Waits for all workers to finish.
#   6. Consolidates the transcription results into a single SRT file.
#
# Worker devices are configured in a YAML configuration file. Remote workers
# are accessed through SSH, and file transfers are performed using rsync.
#
# Usage:
#   ./controller.sh -i <input_directory> \
#                   -o <output_directory> \
#                   -c <worker_config_file>
#
# Dependencies:
#   bash, ffmpeg, yq, bc, inotifywait, ssh, rsync, uv
#
# Related components:
#   worker.sh             - Runs the transcription process on worker devices.
#   transcribe_chunks.py  - Transcribes individual audio chunks.
#   consolidate_srt.py    - Combines worker transcription results into one SRT.
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
# Input file preparation
# ==============================================================================
# Rename input files to remove non-ASCII characters and replace spaces with
# underscores while preserving the original file extension.
#
# Arguments:
#   $1 - Name of an array variable containing input file paths.
#
# Output:
#   Prints the renamed file paths, one per line.
#
# Note:
#   Files are renamed in place in their original directories.
function rename_files() {
    local -n localInputFiles="$1"

    renamedFiles=()
    for file in "${localInputFiles[@]}"; do
        local parentDir=$(dirname "$file")
        local extension=$(basename "$file" | sed "s/^\(.*\)\(\..*\)$/\2/")
        local newBaseName=$(basename "$file" | sed "s/^\(.*\)\..*$/\1/" | LC_ALL=C sed 's/[^\x00-\x7F]//g' | tr '[:blank:]' '_')

        local renamedFile="$parentDir/${newBaseName}${extension}"
        mv "$file" "$renamedFile" 2>/dev/null
        renamedFiles+=("$renamedFile")
    done

    printf "%s\n" "${renamedFiles[@]}"
}

# ==============================================================================
# Audio processing
# ==============================================================================
# Split an audio file into fixed-length WAV chunks using ffmpeg.
#
# Arguments:
#   $1 - Input audio file path.
#   $2 - Chunk length in seconds.
#   $3 - Directory where the generated chunks are stored.
#
# Output:
#   Creates sequentially numbered WAV files in the specified directory.
function split_audio() {
    local input_file="$1"
    local chunk_length="$2"
    local chunks_dir="$3"

    ffmpeg -i "$input_file" \
        -f segment \
        -segment_time "$chunk_length" \
        -c pcm_s16le \
        -hide_banner \
        -loglevel error \
        "${chunks_dir}/chunk_%03d.wav"
}

# ==============================================================================
# Worker configuration
# ==============================================================================
# Validate the configuration of the requested workers.
#
# Arguments:
#   $1 - Name of an array variable containing worker aliases.
#   $2 - Path to the worker configuration YAML file.
#
# Output:
#   Prints the aliases of workers with valid configuration, one per line.
#
# Validation checks:
#   - At least one worker is configured.
#   - Worker aliases are unique.
#   - Required fields exist for each worker.
#   - workload_weight contains a numeric value.
function validate_config() {
    local -n localWorkerAliases="$1"
    local workerConfigFile="$2"

    local uniqueWorkerAliases=()
    mapfile -t uniqueWorkerAliases < <(printf "%s\n" "${localWorkerAliases[@]}" | sort -u)

    if [[ "${#localWorkerAliases[@]}" -eq 0 ]]; then
        log_error "No workers in config"
        exit 1
    fi

    if [[ "${#localWorkerAliases[@]}" -ne "${#uniqueWorkerAliases[@]}" ]]; then
        log_error "Invalid config: Duplicated aliases detected"
        exit 1
    fi

    local fields=("host" "user" "port" "password" "workload_weight")
    local validatedWorkers=()
    for worker in "${localWorkerAliases[@]}"; do
        local validWorker=1
        for field in "${fields[@]}"; do
            local output=0
            if ! output=$(yq -e ".configs[] | select(.alias == \"$worker\") | .$field" "$workerConfigFile" 2>/dev/null); then
                log_error "$field not found for $worker"
                validWorker=0
                break
            fi
            if [[ "$field" == "workload_weight" ]] && ! ([ -n "$output" ] && [ "$output" -eq "$output" ] 2>/dev/null); then
                log_error "Invalid workload_weight for $worker"
                validWorker=0
                break
            fi
        done
        if [[ "$validWorker" -eq 1 ]]; then
            validatedWorkers+=("$worker")
        fi
    done
    printf "%s\n" "${validatedWorkers[@]}"
}

# Retrieve a configuration value for a specific worker.
#
# Arguments:
#   $1 - Worker alias.
#   $2 - Configuration field name.
#   $3 - Path to the worker configuration YAML file.
#
# Output:
#   Prints the requested configuration value.
function get_config() {
    local alias="$1"
    local fieldname="$2"
    local workerConfigFile="$3"

    local value
    value=$(yq ".configs[] | select(.alias == \"$alias\") | .$fieldname" "$workerConfigFile")
    echo "$value"
}

# Calculate the total workload weight of all validated workers.
#
# Arguments:
#   $1 - Name of an array variable containing validated worker aliases.
#   $2 - Path to the worker configuration YAML file.
#
# Output:
#   Prints the sum of all worker workload weights.
function get_total_workload() {
    local -n localValidatedWorkers="$1"
    local workerConfigFile="$2"

    local totalWeight=0
    for worker in "${localValidatedWorkers[@]}"; do
        local weight
        weight=$(get_config "$worker" "workload_weight" "$workerConfigFile")
        totalWeight=$((totalWeight + $weight))
    done
    echo "$totalWeight"
}

# ==============================================================================
# Workload allocation
# ==============================================================================
#
# Audio chunks are distributed proportionally according to each worker's
# workload_weight. A worker with twice the weight of another worker is assigned
# approximately twice as many chunks.
#
# Because the calculated allocation may contain fractional chunks, each
# worker's initial allocation is rounded to a whole number. Any chunks left
# over after rounding are assigned one at a time to the workers with the
# smallest current allocation.
#
# Example:
#   Workers:
#     worker_a: workload_weight = 1
#     worker_b: workload_weight = 2
#     worker_c: workload_weight = 3
#
#   Total workload weight = 6
#
#   For 12 chunks, the proportional allocation is:
#     worker_a:  2 chunks
#     worker_b:  4 chunks
#     worker_c:  6 chunks

# Find the index of the element with the smallest value in an array.
#
# Arguments:
#   $1 - Name of the array to search.
#
# Output:
#   Prints the index of the first element with the minimum value.
function get_index_of_min() {
    local -n array="$1"
    local min="${array[0]}"
    local indexOfMin=0
    local index=0
    for element in "${array[@]}"; do
        if ((element < min)); then
            min=$element
            indexOfMin=$index
        fi
        index=$((index + 1))
    done
    echo "$indexOfMin"
}

# Calculate how many audio chunks should be assigned to each worker based on
# their configured workload weights.
#
# Arguments:
#   $1 - Name of an array variable containing validated worker aliases.
#   $2 - Path to the worker configuration YAML file.
#   $3 - Total number of audio chunks.
#   $4 - Total workload weight across all workers.
#
# Output:
#   Prints the number of chunks assigned to each worker, in the same order as
#   the worker aliases.
#
# Note:
#   Initial allocations are rounded to the nearest whole chunk. Any remaining
#   chunks caused by rounding are assigned one at a time to the workers with
#   the smallest current allocation.
function get_chunks_by_worker() {
    local -n localValidatedWorkers="$1"
    workerConfigFile="$2"
    totalNumOfChunks="$3"
    local totalWorkload="$4"

    local nextChunkIndex=0
    local chunksByWorker=()
    workerToDeploy=1
    for worker in "${localValidatedWorkers[@]}"; do
        local workload=$(get_config "$worker" workload_weight "$workerConfigFile")

        # Calculate this worker's proportional share and round it to a whole chunk.
        local numOfChunks=$(printf "%.0f\n" $(echo "scale=2; $workload * $totalNumOfChunks / $totalWorkload" | bc))
        chunksByWorker+=("$numOfChunks")
        nextChunkIndex=$((nextChunkIndex + numOfChunks))
        workerToDeploy=$((workerToDeploy + 1))
    done

    # Determine how many chunks remain after the initial rounded allocation.
    local remainingChunks=$((totalNumOfChunks - nextChunkIndex))

    # Distribute any remaining chunks to workers with the smallest allocation.
    while ((remainingChunks > 0)); do
        local indexOfMin=$(get_index_of_min chunksByWorker)
        chunksByWorker[$indexOfMin]=$((chunksByWorker[$indexOfMin] + 1))
        remainingChunks=$((remainingChunks - 1))
    done

    printf "%s\n" "${chunksByWorker[@]}"
}

# ==============================================================================
# Chunk distribution
# ==============================================================================
# Move audio chunks into worker-specific directories according to the
# calculated chunk allocation.
#
# Arguments:
#   $1 - Name of an array variable containing validated worker aliases.
#   $2 - Number of workers.
#   $3 - Name of an array variable containing each worker's chunk allocation.
#   $4 - Directory containing the audio chunks.
#
# Output:
#   Moves the assigned chunk files into a subdirectory named after each worker.
function distribute_chunks_to_workers() {
    local -n localValidatedWorkers="$1"
    numberOfWorkers="$2"
    local -n localChunksByWorker="$3"
    audioChunksDir="$4"

    local nextChunkIndex=0
    local counter=0
    local cumulativeChunkCount=0
    while ((counter < numberOfWorkers)); do
        local currentWorker=${localValidatedWorkers[$counter]}
        cumulativeChunkCount=$((cumulativeChunkCount + ${localChunksByWorker[$counter]}))
        mkdir -p "$audioChunksDir/$currentWorker"

        while ((nextChunkIndex < cumulativeChunkCount)); do
            local filename=$(printf "chunk_%03d.wav" "$nextChunkIndex")
            local sourceDirectory="$audioChunksDir"
            local destinationDirectory="$audioChunksDir/$currentWorker"
            mv "$sourceDirectory/$filename" "$destinationDirectory/$filename"
            nextChunkIndex=$((nextChunkIndex + 1))
        done
        counter=$((counter + 1))
    done
}

# ==============================================================================
# Worker execution
# ==============================================================================
#
# Each worker is started remotely before its assigned chunks are transferred.
# Chunk transfers run in parallel so that multiple workers can receive their
# data simultaneously.
#
# After a worker's chunk transfer completes, the controller creates a signal
# file and transfers it to the worker. The signal tells the worker that all
# input chunks are ready and it can begin processing them.

# Start the transcription process on each worker and transfer its assigned
# audio chunks.
#
# Arguments:
#   $1 - Name of an array variable containing validated worker aliases.
#   $2 - Directory containing worker-specific audio chunks.
#   $3 - Directory used for controller/worker signal files.
#
# Process:
#   1. Start worker.sh remotely through SSH.
#   2. Transfer the worker's assigned chunks using rsync.
#   3. Wait for the chunk transfer to complete.
#   4. Create and transfer a signal file indicating that all chunks are ready.
#
# Note:
#   Chunk transfers are started in parallel for all workers.
function start_workers() {
    local -n localValidatedWorkers="$1"
    audioChunksDir="$2"
    currentFileSignalDir="$3"
    local pids=()
    for worker in "${localValidatedWorkers[@]}"; do
        # Start the worker before transferring its input chunks.
        ssh "$worker" "nohup proot-distro login ubuntu -- bash -c 'cd \"$workerProjectRoot\" && mkdir -p \"$audioChunksDir/../logs\" && scripts/worker.sh -i $audioChunksDir/$worker -o $audioChunksDir/../srtChunks/$worker -s $currentFileSignalDir/controller-$worker.signal > \"$audioChunksDir/../logs/${worker}.logs\" 2>&1' </dev/null >/dev/null 2>&1 &"
        log_info "Started script on $worker"

        # Transfer this worker's chunks asynchronously so all workers can receive
        # their input in parallel.
        rsync -azp --mkpath "$audioChunksDir/$worker" "$worker:$workerProjectRoot/$audioChunksDir/" &
        local pid=$!
        pids+=($pid)
        log_info "PID $pid: Started transferring chunks to $worker"
    done
    local counter=0
    while ((counter < numberOfWorkers)); do
        local currentWorker="${validatedWorkers[$counter]}"
        local currentPid="${pids[$counter]}"

        # Wait for each worker's chunk transfer to finish before sending its
        # "chunks ready" signal.
        wait "$currentPid"
        local signalFile="$currentFileSignalDir/controller-$currentWorker.signal"

        # Create the signal locally only after the complete chunk transfer succeeds.
        touch "$signalFile"
        rsync -azp --mkpath "$signalFile" "$currentWorker:$workerProjectRoot/$currentFileSignalDir/"
        log_info "Transfer chunks to $currentWorker complete"
        counter=$((counter + 1))
    done
}

# ==============================================================================
# Worker completion signals
# ==============================================================================
#
# Signal files are used to coordinate the controller and workers without
# requiring the controller to continuously poll the transcription process.
#
# Controller → Worker:
#   controller-<worker>.signal
#   Indicates that all chunks assigned to the worker have been transferred.
#
# Worker → Controller:
#   <worker>-controller.signal
#   Indicates that the worker has finished processing all assigned chunks.

# Generate the expected completion signal filenames for all workers.
#
# Arguments:
#   $1 - Name of an array variable containing validated worker aliases.
#
# Output:
#   Prints one expected worker completion signal filename per line.
function get_signal_file_names() {
    local -n localValidatedWorkers="$1"
    local signalFilesToWait=()
    for worker in "${localValidatedWorkers[@]}"; do
        # Workers create these files after completing all assigned transcription tasks.
        local signalFile="$worker-controller.signal"
        signalFilesToWait+=("$signalFile")
    done
    printf "%s\n" "${signalFilesToWait[@]}"
}

# Wait until all workers have created their completion signal files.
#
# Arguments:
#   $1 - Name of an array variable containing the expected signal filenames.
#   $2 - Directory containing the signal files.
#
# Process:
#   Monitors the signal directory with inotifywait and counts each expected
#   signal once it has been completely written.
#
# Output:
#   Returns when a completion signal has been received from every worker.
function wait_signal_files() {
    local -n localSignalFilesToWait="$1"
    currentFileSignalDir="$2"

    # Build a regular expression matching the expected signal filenames.
    local pattern="($(
        IFS='|'
        echo "${localSignalFilesToWait[*]}"
    ))"

    local count=0
    local needed=${#localSignalFilesToWait[@]}

    # Track received signals so each worker is counted only once.
    local -A received_signals

    # Monitor the signal directory until every worker has reported completion.
    while read -r created; do
        # Only process if we haven't seen this specific file yet
        if [ -z "${received_signals[$created]}" ]; then
            received_signals[$created]=1
            ((count++))

            log_info "Received $created ($count/$needed)"
        fi

        # Stop monitoring once every worker has reported completion.
        if [ "$count" -ge "$needed" ]; then
            break
        fi
        # Listen for close_write so the signal is processed after the file has been
        # completely written.
    done < <(inotifywait -m -e close_write --format '%f' --include "$pattern" "$currentFileSignalDir" 2>/dev/null)

}

# ==============================================================================
# Main script
# ==============================================================================
SCRIPT_NAME=$(basename "$0")
USAGE_MSG="./$SCRIPT_NAME -i [input directory] -o [output directory] -c [worker config file]"

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
while getopts "i:o:c:" opt; do
    case "$opt" in
    i) inputDir="$OPTARG" ;;
    o) outputDir="$OPTARG" ;;
    c) workerConfigFile="$OPTARG" ;;
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
if [[ -z "$inputDir" || -z "$outputDir" || -z "$workerConfigFile" ]]; then
    echo "Missing required argument"
    echo "$USAGE_MSG"
    exit 1
fi

if [[ ! -d "$inputDir" ]]; then
    log_error "Input directory does not exist: $inputDir"
    exit 1
fi

if [[ ! -f "$workerConfigFile" ]]; then
    log_error "Worker config file does not exist: $workerConfigFile"
    exit 1
fi

mkdir -p "$outputDir"
log_info "Script started"
log_info "Input directory: $inputDir"
log_info "Output directory: $outputDir"
log_info "Worker config directory: $workerConfigFile"

# ------------------------------------------------------------------------------
# Load configuration and discover input files
# ------------------------------------------------------------------------------
source .env
mapfile -t inputFiles < <(find "$inputDir" -maxdepth 1 -type f)

numberOfInputFiles="${#inputFiles[@]}"
if [[ "$numberOfInputFiles" -gt 0 ]]; then
    log_info "Found $numberOfInputFiles file(s) in $inputDir"
else
    log_info "No files to process"
    log_info "Script ended"
    exit 0
fi

log_info "Renaming input files"
mapfile -t renamedFiles < <(rename_files inputFiles)

# ------------------------------------------------------------------------------
# Validate workers
# ------------------------------------------------------------------------------
log_info "Validating worker config at $workerConfigFile"

if [[ ! -f "$workerConfigFile" ]]; then
    log_error "Worker config file does not exist: $workerConfigFile"
    exit 1
fi
mapfile -t workerAliases < <(yq -r ".configs[].alias" "$workerConfigFile")

mapfile -t validatedWorkers < <(validate_config workerAliases "$workerConfigFile")

numberOfWorkers="${#validatedWorkers[@]}"
if [[ "$numberOfWorkers" -eq 0 ]]; then
    log_error "No valid workers available"
    exit 1
fi
if [[ "$numberOfWorkers" -gt 0 ]]; then
    log_info "Found $numberOfWorkers worker config(s) in $workerConfigFile"
fi

totalWorkload=$(get_total_workload validatedWorkers "$workerConfigFile")

if [[ "$totalWorkload" -le 0 ]]; then
    log_error "Total worker workload must be greater than 0"
    exit 1
fi

# ------------------------------------------------------------------------------
# Process input files
# ------------------------------------------------------------------------------
processedFileCount=0
for inputFilePath in "${renamedFiles[@]}"; do
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    inputFileName=$(basename "$inputFilePath")
    inputFileBaseName="${inputFileName%.*}"
    currentFileStagingDir="staging/$TIMESTAMP-$inputFileBaseName"
    audioChunksDir="$currentFileStagingDir/audioChunks"
    srtChunksDir="$currentFileStagingDir/srtChunks"
    currentFileSignalDir="$currentFileStagingDir/signal"
    mkdir -p "$currentFileSignalDir"
    mkdir -p "$audioChunksDir"
    mkdir -p "$srtChunksDir"

    log_info "Start processing $inputFilePath"
    split_audio "$inputFilePath" 300 "$audioChunksDir"
    totalNumOfChunks=$(find "$audioChunksDir" -maxdepth 1 -name "*.wav" | wc -l)
    log_info "Finished splitting $inputFileName into $totalNumOfChunks chunks to <$audioChunksDir>"

    log_info "Calculating chunk allocation for workers"
    mapfile -t chunksByWorker < <(get_chunks_by_worker validatedWorkers "$workerConfigFile" "$totalNumOfChunks" "$totalWorkload")

    log_info "Distributing chunks to each worker"
    distribute_chunks_to_workers validatedWorkers "$numberOfWorkers" chunksByWorker "$audioChunksDir"

    log_info "Transferring chunks to workers and starting processes on workers"
    start_workers validatedWorkers "$audioChunksDir" "$currentFileSignalDir"

    mapfile -t signalFilesToWait < <(get_signal_file_names validatedWorkers)
    log_info "Waiting for signal from workers"
    wait_signal_files signalFilesToWait "$currentFileSignalDir"
    log_info "All workers done."

    log_info "Start consolidating SRT chunks from <$audioChunksDir>"
    outputFilePath="$outputDir/$inputFileBaseName.SRT"
    uv run src/distributed_audio_transcription/controller/consolidate_srt.py --srt-chunks-dir "$srtChunksDir" --output-file-path "$outputFilePath"

    log_info "Done processing $inputFilePath"
    processedFileCount=$((processedFileCount + 1))
done

# ------------------------------------------------------------------------------
# Report final result
# ------------------------------------------------------------------------------
if [[ "$processedFileCount" -eq "$numberOfInputFiles" ]]; then
    log_info "Successfully processed all $numberOfInputFiles files"
else
    log_error "Successfully processed $processedFileCount of $numberOfInputFiles files"
    log_error "Failed to process $((numberOfInputFiles - processedFileCount))"
fi

log_info "Script ended"
exit 0
