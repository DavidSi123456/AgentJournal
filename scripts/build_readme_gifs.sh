#!/bin/zsh
# Raw input must be window-only captures of the English, demo-only app.
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
SOURCE_DIR=${1:-"$PROJECT_DIR/.build/readme-gif"}
FRAME_DIR="$PROJECT_DIR/.build/readme-gif-rendered"
OUTPUT_DIR="$PROJECT_DIR/docs/media"
command -v ffmpeg >/dev/null || { printf '%s\n' 'ffmpeg is required.' >&2; exit 1; }
mkdir -p "$FRAME_DIR" "$OUTPUT_DIR"
export SWIFT_MODULECACHE_PATH="${TMPDIR:-/private/tmp}/agentjournal-readme-image-cache"
swift -module-cache-path "$SWIFT_MODULECACHE_PATH" "$PROJECT_DIR/scripts/render_readme_gif_frames.swift" "$SOURCE_DIR" "$FRAME_DIR"
for SEQUENCE in daily thread share; do
    ffmpeg -hide_banner -loglevel error -nostdin -y -safe 0 -f concat \
        -i "$FRAME_DIR/$SEQUENCE/frames.ffconcat" \
        -filter_complex 'fps=6,split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle' \
        -loop 0 "$OUTPUT_DIR/agentjournal-$SEQUENCE-en.gif"
done
printf '%s\n' "English demo GIFs: $OUTPUT_DIR"
