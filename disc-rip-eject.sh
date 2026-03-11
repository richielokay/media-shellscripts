#!/bin/bash
set -x

# Use "Movies" as the default if no argument is given
DEST_TYPE="${1:-Movies}"

case "$DEST_TYPE" in
  Movies)
    DEST_DIR="/mnt/jellyfin/Movies"
    ;;
  Television)
    DEST_DIR="/mnt/jellyfin/Television"
    ;;
  *)
    echo "Invalid argument: $DEST_TYPE. Use 'Movies' or 'Television'."
    exit 2
    ;;
esac

# Set MakeMKV output directory (temporary)
RIP_DIR="/tmp"

# Set your optical drive device
DRIVE="/dev/sr0"

# Wait for disc to be present
while [ ! -e "$DRIVE" ]; do
    echo "Waiting for disc..."
    sleep 5
done

# Get disc label (for naming)
DISC_LABEL=$(blkid -o value -s LABEL $DRIVE 2>/dev/null | tr -cd '[:alnum:]._-')
if [ -z "$DISC_LABEL" ]; then
    DISC_LABEL="Unknown_Disc_$(date +%Y%m%d_%H%M%S)"
fi

# Create output folder
OUTPUT_FOLDER="$DEST_DIR/$DISC_LABEL"
mkdir -p "$OUTPUT_FOLDER"

# Run MakeMKV to rip all titles
makemkvcon mkv --progress=-stdout disc:0 all "$OUTPUT_FOLDER" --minlength=1200

# Optional: Clean up file names (remove spaces, etc.)
cd "$OUTPUT_FOLDER"
for f in *.mkv; do
    mv "$f" "$(echo "$f" | tr ' ' '_' | tr -cd '[:alnum:]._-')"
done

# Eject the disc
eject $DRIVE

echo "Rip complete: $OUTPUT_FOLDER"

