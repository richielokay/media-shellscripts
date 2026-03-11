#!/bin/bash
# Encode MKVs with HandBrakeCLI using a preset, delete originals

set -e

if [ $# -lt 1 ]; then
  echo "Usage: $0 <input_filename>"
  exit 1
fi

input_filename="$1"

HandBrakeCLI -i "${input_filename}.mkv" -o "${input_filename}.mp4" \
  --preset "Apple 2160p60 4K HEVC Surround" \
  --quality 18 \
  --all-audio \
  --all-subtitles \
  --auto-anamorphic \
  --decomb \
  --crop auto \
  --verbose


