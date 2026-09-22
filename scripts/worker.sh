#! /bin/bash

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $@" >&2
}
log_info() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $@"
}

SCRIPT_NAME=$(basename "$0")
USAGE_MSG="./$SCRIPT_NAME -i [input directory] -o [output directory] -s [signal file]"
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

# eg inputDir = staging/20260919_201738-6_May,_22.35.m4a/audioChunks/termux-phone
workerName=$(basename "$inputDir")
archiveDir="$(dirname "$(dirname "$inputDir")")/archive"
signalFileDir="$(dirname "$signalFile")"

log_info "Script started"
log_info "Input directory: $inputDir"
log_info "Output directory: $outputDir"
log_info "Archive directory: $archiveDir"
log_info "Signal file: $signalFile"

mkdir -p "$outputDir"
mkdir -p "$archiveDir"

while true; do
    for f in "$inputDir"/*.wav; do
        [ -e "$f" ] || continue
        fileBasename=$(basename "$f")
        ~/.local/bin/uv run python -m distributed_audio_transcription.worker.transcribe_chunks \
        --input-file "$f" \
        --output-file "$outputDir/${fileBasename/%.wav/}.csv"
        log_info "$?"
        mv "$f" "$archiveDir/"
    done
    if [ -e "$signalFile" ] && [ ! "$(ls -A $inputDir)" ]; then
        break
    fi
    sleep 2
done

log_info "Finished transcribing all chunks in <$inputDir>"
log_info "Transferring transcriptions back to controller"

cleansedOutputDir="$(dirname "$outputDir")/$(basename "$outputDir")"
rsync -azpR --mkpath --ignore-existing "./$cleansedOutputDir" "$controller:$controllerProjectRoot/"
if [[ "$?" -eq 0 ]]; then
    signalFileToController="$signalFileDir/$workerName-controller.signal"
    touch "$signalFileToController"
    rsync -avp --mkpath "./$signalFileToController" "$controller:$controllerProjectRoot/"
    log_info "Finished transferring all transcriptions back to controller"
    log_info "Script ended"
    exit 0
else
    log_error "Failed to transfer all transcriptions back to controller."
    exit 1
fi

# keep_scanning=true
# while $keep_scanning; do
#   chunkfile=$(find staging -name chunk_*.wav | head)
#   uv run transcription.py --input $chunkfile && mv $chunkfile $archive_dir
#   chunkfile=$(find staging -name chunk_*.wav | head)
#   if # chunkfile not available and worker_signal_dir/controller-worker signal file present
#     keep_scanning=false
# done

# rsync $worker_srt_chunk_dir controller:$controller_srt_chunk_dir && \
#   touch $worker-controller &&  \
#   scp $worker-controller controller:$controller_signal_dir/  # a file to signal completion
