#!/bin/bash

# HandBrake Batch Encoder with Safe Replace
# Recursively processes all MKV files in directory and subfolders
# Usage: ./encode.sh <input_dir> [quality]
# Quality: low, medium, high (default: high)

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <input_dir> [quality]"
  echo "Quality options: low, medium, high (default: high)"
  exit 1
fi

INPUT_DIR="${1%/}"  # Remove trailing slash
QUALITY="${2:-high}"

declare -A PRESETS=(
  [low]="-q 22 --encoder-preset fast"
  [medium]="-q 20 --encoder-preset slow"
  [high]="-q 18 --encoder-preset slower"
)

if [[ ! -v PRESETS[$QUALITY] ]]; then
  echo "Invalid quality: $QUALITY. Use low/medium/high"
  exit 1
fi

# Find all MKV files recursively
while IFS= read -r -d $'\0' INFILE; do
  BASENAME="$(basename "${INFILE%.*}")"
  TMP_OUT="$(mktemp "/tmp/${BASENAME}_XXXXXX.mkv")"
  OUTDIR="$(dirname "$INFILE")"
  
  echo "--------------------------------------------------"
  echo "Processing: $INFILE"
  echo "Quality: $QUALITY"
  echo "Temp output: $TMP_OUT"

  # Encode command
  if HandBrakeCLI -i "$INFILE" -o "$TMP_OUT" \
		--preset="H.265 MKV 1080p30" \
		${PRESETS[$QUALITY]} \
		--audio-lang-list eng --all-audio \
		--subtitle-lang-list eng --all-subtitles; then

	if [ -s "$TMP_OUT" ]; then
	  echo "Encode successful. Replacing original file."
	  rm -f "$INFILE"
	  mv -f "$TMP_OUT" "$INFILE"
	  echo "Replacement complete: $INFILE"
	else
	  echo "ERROR: Output file is empty for $INFILE"
	  rm -f "$TMP_OUT"
	fi
  else
	echo "ERROR: Encoding failed for $INFILE"
	rm -f "$TMP_OUT"
  fi
done < <(find "$INPUT_DIR" -type f -name "*.mkv" -print0)

echo "--------------------------------------------------"
echo "Batch encoding complete. All MKV files processed to $INPUT_DIR."

