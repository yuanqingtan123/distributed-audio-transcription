#! /bin/bash

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $@" >&2
}
log_info() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $@"
}

function split_audio() {
    input_file="$1"
    chunk_length="$2"
    chunks_dir="$3"

    ffmpeg -i "$input_file" \
        -f segment \
        -segment_time "$chunk_length" \
        -c pcm_s161e \
        -hide_banner \
        -loglevel error \
        "${chunks_dir}/chunk_%03d.wav"
}

function validate_config() {
    workerAliases=("$@")
    workerConfigDir="${workerAliases[-1]}"
    unset 'workerAliases[-1]'

    mapfile -t uniqueWorkerAliases < <(printf "%s\n" "${workerAliases[@]}" | sort -u)

    if [[ "${#workerAliases[@]}" -eq 0 ]]; then
        log_error "No workers in config"
        exit 1
    fi

    if [[ "${#workerAliases[@]}" -ne "${#uniqueWorkerAliases[@]}" ]]; then
        log_error "Invalid config: Duplicated aliases detected"
        exit 1
    fi

    fields=("host" "user" "port" "password" "workload_weight")
    validatedWorkers=()
    for worker in "${workerAliases[@]}"; do
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
    workerAliases=("$@")
    workerConfigDir="${workerAliases[-1]}"
    unset 'workerAliases[-1]'

    totalWeight=0
    for worker in "${workerAliases[@]}"; do
        weight=$(get_config "$worker" "workload_weight" "$workerConfigDir")
        totalWeight=$((totalWeight + $weight))
    done
    echo "$totalWeight"
}

function get_index_of_min() {
    array=("$@")
    min="${array[0]}"
    indexOfMin=0
    index=0
    for element in "${array[@]}"; do
        if (( element < min )); then
            min=$element
            indexOfMin=$index
        fi
        index=$((index + 1))
    done
    echo "$indexOfMin"
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
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

mapfile -t inputFiles < <(find "$inputDir" -maxdepth 1 -type f)

numberOfInputFiles="${#inputFiles[@]}"
if [[ "$numberOfInputFiles" -gt 0 ]]; then
    log_info "Found $numberOfInputFiles file(s) in $inputDir"
fi

log_info "Validating worker config at $workerConfigDir"

mapfile -t workerAliases < <(yq -r ".configs[].alias" "$workerConfigDir")

mapfile -t validatedWorkers < <(validate_config "${workerAliases[@]}" "$workerConfigDir")

numberOfWorkers="${#validatedWorkers[@]}"
if [[ "$numberOfWorkers" -gt 0 ]]; then
    log_info "Found $numberOfWorkers worker config(s) in $workerConfigDir"
fi

totalWorkload=$(get_total_workload "${validatedWorkers[@]}" "$workerConfigDir")

for inputFile in "${inputFiles[@]}"; do
    chunksDir="$TIMESTAMP-$inputFile"
    # split_audio "$inputFile" 300 "$chunksDir"

    chunksDir="inputAudioFiles/20260911T175429-6 May, 22.35​.m4a_chunks"
    totalNumOfChunks=$(find "$chunksDir" -maxdepth 1 -name "*.wav" | wc -l)

    log_info "Found $totalNumOfChunks chunks in <$chunksDir>"

    log_info "Calculating chunk allocation for workers"
    assignedChunk=0
    chunksByWorker=()
    workerToDeploy=1
    for worker in "${validatedWorkers[@]}"; do
        workload=$(get_config $worker workload_weight "$workerConfigDir")
        numOfChunks=$(printf "%.0f\n" $(echo "scale=2; $workload * $totalNumOfChunks / $totalWorkload" | bc))
        chunksByWorker+=($numOfChunks)
        assignedChunk=$((assignedChunk + numOfChunks))
        workerToDeploy=$((workerToDeploy + 1))
    done
    
    remainingChunks=$((totalNumOfChunks - assignedChunk))

    while ((remainingChunks > 0)); do
        indexOfMin=$(get_index_of_min "${chunksByWorker[@]}")
        chunksByWorker[$indexOfMin]=$((chunksByWorker[$indexOfMin] + 1))
        remainingChunks=$((remainingChunks - 1))
    done


    log_info "Distributing chunks to each worker"
    assignedChunk=0
    counter=0
    currentWorkerChunks=0
    while ((counter < numberOfWorkers)); do
        currentWorker=${validatedWorkers[$counter]}
        currentWorkerChunks=$((currentWorkerChunks + ${chunksByWorker[$counter]}))
        mkdir -p "$chunksDir/$currentWorker"

        while ((assignedChunk < currentWorkerChunks)); do
            filename=$(printf "chunk_%03d.wav" $assignedChunk)
            sourceDirectory="$chunksDir"
            destinationDirectory="$chunksDir/$currentWorker"
            cp "$sourceDirectory/$filename" "$destinationDirectory/$filename" 
            assignedChunk=$((assignedChunk + 1))
        done
        counter=$((counter + 1))
    done


    # if [[ "$assignedChunk" -lt "$totalNumOfChunks" ]]; then

    # fi

        # if [[ $workerToDeploy -eq $numberOfWorkers ]]; then
        #     log_info $worker
        #     numOfChunks=$((totalNumOfChunks - assignedChunk))
        # fi
        # chunks="${fileChunks[@]:$assignedChunk:$numOfChunks}"
        # # chunksByWorker+=($chunks)
        # log_info "$chunks"
        # assignedChunk=$((assignedChunk + numOfChunks))
        # workerToDeploy=$((workerToDeploy + 1))
done

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

split_audio
