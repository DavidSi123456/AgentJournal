#!/bin/zsh
# Input: window-only demo captures or a verified synthetic PNG exported by the demo.
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
DEMO_LANGUAGE=${2:-en}
[[ "$DEMO_LANGUAGE" == en || "$DEMO_LANGUAGE" == zh ]] || { printf '%s\n' 'Usage: zsh scripts/build_readme_gifs.sh [raw-frames] [en|zh]' >&2; exit 1; }
DEFAULT_SOURCE_DIR="$PROJECT_DIR/.build/readme-gif"
FRAME_DIR="$PROJECT_DIR/.build/readme-gif-rendered"
if [[ "$DEMO_LANGUAGE" == zh ]]; then
    DEFAULT_SOURCE_DIR+='-zh'
    FRAME_DIR+='-zh'
fi
SOURCE_DIR=${1:-"$DEFAULT_SOURCE_DIR"}
OUTPUT_DIR="$PROJECT_DIR/docs/media"
command -v ffmpeg >/dev/null || { printf '%s\n' 'ffmpeg is required.' >&2; exit 1; }
mkdir -p "$FRAME_DIR" "$OUTPUT_DIR"
export SWIFT_MODULECACHE_PATH="${TMPDIR:-/private/tmp}/agentjournal-readme-image-cache"
swift -module-cache-path "$SWIFT_MODULECACHE_PATH" "$PROJECT_DIR/scripts/render_readme_gif_frames.swift" "$SOURCE_DIR" "$FRAME_DIR" "$DEMO_LANGUAGE"
for SEQUENCE in daily thread share; do
    ffmpeg -hide_banner -loglevel error -nostdin -y -safe 0 -f concat \
        -i "$FRAME_DIR/$SEQUENCE/frames.ffconcat" \
        -filter_complex 'fps=6,split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle' \
        -loop 0 "$OUTPUT_DIR/agentjournal-$SEQUENCE-$DEMO_LANGUAGE.gif"
done
printf '%s\n' "$DEMO_LANGUAGE demo GIFs: $OUTPUT_DIR"
