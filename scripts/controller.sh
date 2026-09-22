#! /bin/bash

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $@" >&2
}
log_info() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $@"
}

function rename_files() {
    local -n localInputFiles="$1"

    renamedFiles=()
    for file in "${localInputFiles[@]}"; do
        parentDir=$(dirname "$file")
        extension=$(basename "$file" | sed "s/^\(.*\)\(\..*\)$/\2/")
        newBaseName=$(basename "$file" | sed "s/^\(.*\)\..*$/\1/" | LC_ALL=C sed 's/[^\x00-\x7F]//g' | tr '[:blank:]' '_')

        renamedFile="$parentDir/${newBaseName}${extension}"
        mv "$file" "$renamedFile" 2>/dev/null
        renamedFiles+=("$renamedFile")
    done

    printf "%s\n" "${renamedFiles[@]}"
}

function split_audio() {
    input_file="$1"
    chunk_length="$2"
    chunks_dir="$3"

    ffmpeg -i "$input_file" \
        -f segment \
        -segment_time "$chunk_length" \
        -c pcm_s16le \
        -hide_banner \
        -loglevel error \
        "${chunks_dir}/chunk_%03d.wav"
}

function validate_config() {
    local -n localWorkerAliases="$1"
    workerConfigDir="$2"

    mapfile -t uniqueWorkerAliases < <(printf "%s\n" "${localWorkerAliases[@]}" | sort -u)

    if [[ "${#localWorkerAliases[@]}" -eq 0 ]]; then
        log_error "No workers in config"
        exit 1
    fi

    if [[ "${#localWorkerAliases[@]}" -ne "${#uniqueWorkerAliases[@]}" ]]; then
        log_error "Invalid config: Duplicated aliases detected"
        exit 1
    fi

    fields=("host" "user" "port" "password" "workload_weight")
    validatedWorkers=()
    for worker in "${localWorkerAliases[@]}"; do
        validWorker=1
        for field in "${fields[@]}"; do
            if ! output=$(yq -e ".configs[] | select(.alias == \"$worker\") | .$field" "$workerConfigDir" 2>/dev/null); then
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

function get_config() {
    alias="$1"
    fieldname="$2"
    workerConfigDir="$3"

    value=$(yq ".configs[] | select(.alias == \"$alias\") | .$fieldname" "$workerConfigDir")
    echo "$value"
}

function get_total_workload() {
    local -n localValidatedWorkers="$1"
    workerConfigDir="$2"

    totalWeight=0
    for worker in "${localValidatedWorkers[@]}"; do
        weight=$(get_config "$worker" "workload_weight" "$workerConfigDir")
        totalWeight=$((totalWeight + $weight))
    done
    echo "$totalWeight"
}

function get_index_of_min() {
    local -n array="$1"
    min="${array[0]}"
    indexOfMin=0
    index=0
    for element in "${array[@]}"; do
        if ((element < min)); then
            min=$element
            indexOfMin=$index
        fi
        index=$((index + 1))
    done
    echo "$indexOfMin"
}

function get_chunks_by_worker() {
    local -n localValidatedWorkers="$1"
    workerConfigDir="$2"
    totalNumOfChunks="$3"
    totalWorkload="$4"

    assignedChunk=0
    chunksByWorker=()
    workerToDeploy=1
    for worker in "${localValidatedWorkers[@]}"; do
        workload=$(get_config $worker workload_weight "$workerConfigDir")
        numOfChunks=$(printf "%.0f\n" $(echo "scale=2; $workload * $totalNumOfChunks / $totalWorkload" | bc))
        chunksByWorker+=($numOfChunks)
        assignedChunk=$((assignedChunk + numOfChunks))
        workerToDeploy=$((workerToDeploy + 1))
    done

    remainingChunks=$((totalNumOfChunks - assignedChunk))

    while ((remainingChunks > 0)); do
        indexOfMin=$(get_index_of_min chunksByWorker)
        chunksByWorker[$indexOfMin]=$((chunksByWorker[$indexOfMin] + 1))
        remainingChunks=$((remainingChunks - 1))
    done

    printf "%s\n" "${chunksByWorker[@]}"
}

function distribute_chunks_to_workers() {
    local -n localValidatedWorkers="$1"
    numberOfWorkers="$2"
    local -n localChunksByWorker="$3"
    audioChunksDir="$4"

    assignedChunk=0
    counter=0
    currentWorkerChunks=0
    while ((counter < numberOfWorkers)); do
        currentWorker=${localValidatedWorkers[$counter]}
        currentWorkerChunks=$((currentWorkerChunks + ${localChunksByWorker[$counter]}))
        mkdir -p "$audioChunksDir/$currentWorker"

        while ((assignedChunk < currentWorkerChunks)); do
            filename=$(printf "chunk_%03d.wav" $assignedChunk)
            sourceDirectory="$audioChunksDir"
            destinationDirectory="$audioChunksDir/$currentWorker"
            mv "$sourceDirectory/$filename" "$destinationDirectory/$filename"
            assignedChunk=$((assignedChunk + 1))
        done
        counter=$((counter + 1))
    done
}

function start_workers() {
    local -n localValidatedWorkers="$1"
    audioChunksDir="$2"
    currentFileSignalDir="$3"
    pids=()
    for worker in "${localValidatedWorkers[@]}"; do
        ssh "$worker" "nohup proot-distro login ubuntu -- bash -c 'cd \"$workerProjectRoot\" && mkdir -p \"$audioChunksDir/../logs\" && scripts/worker.sh -i $workerProjectRoot/$audioChunksDir/$worker -o $workerProjectRoot/$audioChunksDir/../srtChunks/$worker -s $workerProjectRoot/$audioChunksDir/../../signal > \"$audioChunksDir/../logs/${worker}.logs\" 2>&1' </dev/null >/dev/null 2>&1 &"
        log_info "Started script on $worker"
        rsync -azp --mkpath "$audioChunksDir/$worker" "$worker:$workerProjectRoot/$audioChunksDir/" &
        pid=$!
        pids+=($pid)
        log_info "PID $pid: Started transferring chunks to $worker"
    done
    counter=0
    while ((counter < numberOfWorkers)); do
        currentWorker="${validatedWorkers[$counter]}"
        currentPid="${pids[$counter]}"
        wait "$currentPid"
        signalFile="$currentFileSignalDir/controller-$currentWorker.signal"
        touch "$signalFile"
        rsync -azp --mkpath $signalFile "$currentWorker:$workerProjectRoot/$currentFileSignalDir/"
        log_info "Transfer chunks to $currentWorker complete"
        counter=$((counter + 1))
    done
}

function get_signal_file_names() {
    local -n localValidatedWorkers="$1"
    signalFilesToWait=()
    for worker in "${localValidatedWorkers[@]}"; do
        signalFile="$worker-controller.signal"
        signalFilesToWait+=($signalFile)
    done
    printf "%s\n" "${signalFilesToWait[@]}"
}

function wait_signal_files() {
    local -n localSignalFilesToWait="$1"
    currentFileSignalDir="$2"

    pattern="($(
        IFS='|'
        echo "${localSignalFilesToWait[*]}"
    ))"

    count=0
    needed=${#localSignalFilesToWait[@]}

    # 2. Use an associative array to track uniquely received signals
    declare -A received_signals

    # 3. Only listen for close_write to avoid double-firing events per file
    while read -r created; do
        # Only process if we haven't seen this specific file yet
        if [ -z "${received_signals[$created]}" ]; then
            received_signals[$created]=1
            ((count++))

            log_info "Received $created ($count/$needed)"
        fi

        if [ "$count" -ge "$needed" ]; then
            break
        fi
    done < <(inotifywait -m -e close_write --format '%f' --include "$pattern" "$currentFileSignalDir" 2>/dev/null)

}

SCRIPT_NAME=$(basename "$0")
USAGE_MSG="./$SCRIPT_NAME -i [input directory] -o [output directory] -c [workers config directory]"

# -------------------------------
# Argument validation
# -------------------------------
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

# Parse arguments into array
while getopts "i:o:c:" opt; do
    case "$opt" in
    i) inputDir="$OPTARG" ;;
    o) outputDir="$OPTARG" ;;
    c) workerConfigDir="$OPTARG" ;;
    \?)
        echo "Invalid usage"
        echo "$USAGE_MSG"
        exit 1
        ;;
    esac
done

log_info "Script started"
log_info "Input directory: $inputDir"
log_info "Output directory: $outputDir"
log_info "Worker config directory: $workerConfigDir"

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

log_info "Validating worker config at $workerConfigDir"

mapfile -t workerAliases < <(yq -r ".configs[].alias" "$workerConfigDir")

mapfile -t validatedWorkers < <(validate_config workerAliases "$workerConfigDir")

numberOfWorkers="${#validatedWorkers[@]}"
if [[ "$numberOfWorkers" -gt 0 ]]; then
    log_info "Found $numberOfWorkers worker config(s) in $workerConfigDir"
fi

totalWorkload=$(get_total_workload validatedWorkers "$workerConfigDir")

processedFile=0
for inputFilePath in "${renamedFiles[@]}"; do
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    inputFileName=$(basename "$inputFilePath")
    inputFileNameNoExtension="${inputFileName%.*}"
    currentFileStaging="staging/$TIMESTAMP-$inputFileNameNoExtension"
    audioChunksDir="$currentFileStaging/audioChunks"
    srtChunksDir="$currentFileStaging/srtChunks"
    currentFileSignalDir="$currentFileStaging/signal"
    mkdir -p "$currentFileSignalDir"
    mkdir -p "$audioChunksDir"
    mkdir -p "$srtChunksDir"

    log_info "Start processing $inputFilePath"
    split_audio "$inputFilePath" 300 "$audioChunksDir"
    totalNumOfChunks=$(find "$audioChunksDir" -maxdepth 1 -name "*.wav" | wc -l)
    log_info "Finished splitting $inputFileName into $totalNumOfChunks chunks to <$audioChunksDir>"

    # # temporary for testing purpose
    # audioChunksDir="inputAudioFiles/20260911T175429-6 May, 22.35​.m4a_chunks"

    log_info "Calculating chunk allocation for workers"
    mapfile -t chunksByWorker < <(get_chunks_by_worker validatedWorkers "$workerConfigDir" "$totalNumOfChunks" "$totalWorkload")

    log_info "Distributing chunks to each worker"
    distribute_chunks_to_workers validatedWorkers $numberOfWorkers chunksByWorker "$audioChunksDir"

    log_info "Transferring chunks to workers and starting processes on workers"
    start_workers validatedWorkers "$audioChunksDir" "$currentFileSignalDir"

    mapfile -t signalFilesToWait < <(get_signal_file_names validatedWorkers)
    log_info "Waiting for signal from workers"
    wait_signal_files signalFilesToWait "$currentFileSignalDir"
    log_info "All workers done."

    log_info "Start consolidating SRT chunks from <$audioChunksDir>"
    outputFilePath="$outputDir/$inputFileNameNoExtension.SRT"
    # uv run src/distributed_audio_transcription/controller/consolidate_srt.py --srt-chunks-dir "tests/20260919_163731-test_data.m4a/audioChunks"
    uv run src/distributed_audio_transcription/controller/consolidate_srt.py --srt-chunks-dir "$srtChunksDir" --output-file-path "$outputFilePath"

    log_info "Done processing $inputFilePath"
    processedFile=$((processedFile + 1))
done

if [[ "$processedFile" -eq "$numberOfInputFiles" ]]; then
    log_info "Successfully processed all $numberOfInputFiles files"
else
    log_error "Successfully processed $processedFile of $numberOfInputFiles files"
    log_error "Failed to process $((numberOfInputFiles - processedFile))"
fi

log_info "Script ended"
exit 0
# # use bash yq to read configs for each worker
# for worker in $worker_configs; do
#   # mv chunks into sub-dir for each worker node
#   ssh $worker "./worker_transcription.sh &" # to start scanning in the $worker_staging_dir
#   rsync controller/${worker}-sub-dir/ $worker:$worker_staging_dir && \
#   touch controller-$worker &&  \
#   scp controller-$worker $worker:$worker_signal_dir/ & # a file to signal completion, runs entire thing in background to immediately start the next worker
# done

# keep_scanning=true
# while keep_scanning; do
#   # scans controller_signal_dir for all the worker-controller signal files
#   # if found all signal files, keep_scanning = false
# done

# # start consolidate_srt.py in the controller to read srt_chunks_dir and consolidate all srt_chunks into a single srt file
