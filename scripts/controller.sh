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
            if ! output=$(yq -e ".configs[] | select(.alias == $worker) | .$field" "$workerConfigDir" 2>/dev/null); then
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

    value=$(yq ".configs[] | select(.alias == $alias) | .$fieldname" "$workerConfigDir")
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

mapfile -t workerAliases < <(yq ".configs[].alias" "$workerConfigDir")

mapfile -t validatedWorkers < <(validate_config "${workerAliases[@]}" "$workerConfigDir")

numberOfWorkers="${#validatedWorkers[@]}"
if [[ "$numberOfWorkers" -gt 0 ]]; then
    log_info "Found $numberOfWorkers worker config(s) in $workerConfigDir"
fi

totalWeight=$(get_total_workload "${validatedWorkers[@]}" "$workerConfigDir")

log_info $totalWeight

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
