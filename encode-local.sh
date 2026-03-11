#!/bin/bash

search_dir="/srv/plexmedia/"

find "$search_dir" -type f -name "*.mkv" | while read -r inputfile; do
    outputfile="${inputfile%.mkv}.mp4"
    HandBrakeCLI -i "$inputfile" -o "$outputfile" \
        --preset "Apple 2160p60 4K HEVC Surround" \
        --quality 16 \
        --all-audio \
        --all-subtitles \
        --auto-anamorphic \
        --crop auto \
       #  --verbose

    if [ $? -eq 0 ]; then
        rm "$inputfile"
    else
        echo "Failed to encode $inputfile"
    fi
done
