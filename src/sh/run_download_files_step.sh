#!/bin/zsh
set -euo pipefail

if [[ "$#" -lt 9 ]]; then
  print -r -- "usage: run_download_files_step.sh script manifest output-root download-log archive-root result-json timeout max-attempts retry-delay [force] [preserve-archive] [new-files-root] [quarantine-root] [download-start-timeout] [download-stall-timeout]" >&2
  exit 64
fi

SCRIPT_PATH="$1"
MANIFEST_JSON="$2"
OUTPUT_ROOT="$3"
DOWNLOAD_LOG_JSON="$4"
DOWNLOAD_ARCHIVE_ROOT="$5"
DOWNLOAD_RESULT_JSON="$6"
TIMEOUT_SECONDS="$7"
MAX_ATTEMPTS="$8"
RETRY_DELAY_SECONDS="$9"
FORCE_DOWNLOAD="${10:-0}"
PRESERVE_DOWNLOAD_ARCHIVE="${11:-0}"
NEW_FILES_ROOT="${12:-}"
QUARANTINE_ROOT="${13:-}"
DOWNLOAD_START_TIMEOUT_SECONDS="${14:-180}"
DOWNLOAD_STALL_TIMEOUT_SECONDS="${15:-900}"

download_args=(
  /usr/bin/osascript
  -l
  JavaScript
  "$SCRIPT_PATH"
  "--manifest=$MANIFEST_JSON"
  "--output-root=$OUTPUT_ROOT"
  "--download-log=$DOWNLOAD_LOG_JSON"
  "--download-archive-root=$DOWNLOAD_ARCHIVE_ROOT"
  "--result-json=$DOWNLOAD_RESULT_JSON"
  "--timeout=$TIMEOUT_SECONDS"
  "--download-start-timeout=$DOWNLOAD_START_TIMEOUT_SECONDS"
  "--download-stall-timeout=$DOWNLOAD_STALL_TIMEOUT_SECONDS"
  "--max-file-attempts=$MAX_ATTEMPTS"
  "--retry-delay-seconds=$RETRY_DELAY_SECONDS"
)

if [[ -n "$NEW_FILES_ROOT" ]]; then
  download_args+=("--new-files-root=$NEW_FILES_ROOT")
fi

if [[ -n "$QUARANTINE_ROOT" ]]; then
  download_args+=("--quarantine-root=$QUARANTINE_ROOT")
fi

case "${FORCE_DOWNLOAD:l}" in
  1|true|yes|on)
    download_args+=("--force-download")
    ;;
esac

case "${PRESERVE_DOWNLOAD_ARCHIVE:l}" in
  1|true|yes|on)
    download_args+=("--preserve-download-archive")
    ;;
esac

"${download_args[@]}"
