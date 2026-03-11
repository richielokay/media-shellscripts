#!/bin/bash

search_dir="/mnt/plexmedia/Movies/"

find "$search_dir" -type f -name "*.mkv" | while read -r inputfile; do
    outputfile="${inputfile%.mkv}.mp4"
    HandBrakeCLI -i "$inputfile" -o "$outputfile" \
        --encoder x264 --encoder-profile high --encoder-level 4.0 \
        --encoder-tune film --quality 18 --audio 1 --aencoder faac \
        --mixdown stereo --ab 192 --format av_mp4 --width 1920 --height 1080 \
        --decomb --crop auto

    if [ $? -eq 0 ]; then
        rm "$inputfile"
    else
        echo "Failed to encode $inputfile"
    fi
done
