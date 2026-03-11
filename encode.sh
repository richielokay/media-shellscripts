#!/bin/bash

# Usage: ./encode_mkv.sh /path/to/search [quality] [cpu]
# Example: ./encode_mkv.sh /media/videos medium
#          ./encode_mkv.sh /media/videos high cpu   # Force CPU encoding

set -euo pipefail

SEARCH_DIR="${1:-}"
QUALITY="${2:-high}"
FORCE_CPU="${3:-}"

TEMP_DIR="/tmp"

declare -A PRESETS
PRESETS[high]="-q 18 --encoder-preset slow"
PRESETS[medium]="-q 20 --encoder-preset medium"
PRESETS[low]="-q 22 --encoder-preset fast"

if ! command -v HandBrakeCLI &> /dev/null; then
  echo "Error: HandBrakeCLI is not installed."
  exit 1
fi

if [[ -z "$SEARCH_DIR" || ! -d "$SEARCH_DIR" ]]; then
  echo "Usage: $0 /path/to/search [quality: high|medium|low] [cpu]"
  exit 1
fi

mkdir -p "$TEMP_DIR"

# Detect AMD GPU and HandBrakeCLI VCE support
AMD_GPU=false
AMD_ENCODER=""
if [[ -z "$FORCE_CPU" ]]; then
  if lspci | grep -qi 'AMD/ATI'; then
    if HandBrakeCLI --help | grep -qi 'vce_h265'; then
      AMD_GPU=true
      AMD_ENCODER="--encoder=vce_h265"
      echo "AMD GPU detected. Will use hardware encoding (vce_h265)."
    fi
  fi
fi

find "$SEARCH_DIR" -type f -iname "*.mkv" -print0 | while IFS= read -r -d '' FILE; do
  BASENAME=$(basename "$FILE")
  HASH=$(echo "$FILE" | md5sum | cut -d' ' -f1)
  TEMP_FILE="$TEMP_DIR/${HASH}_$BASENAME"

  echo "Encoding: $FILE -> $TEMP_FILE with quality '$QUALITY'..."

  if [[ "$AMD_GPU" == true ]]; then
    echo "Using AMD GPU hardware encoder (vce_h265)."
    HandBrakeCLI -i "$FILE" -o "$TEMP_FILE" $AMD_ENCODER ${PRESETS[$QUALITY]}
  else
    echo "Using CPU software encoder (x265)."
    HandBrakeCLI -i "$

