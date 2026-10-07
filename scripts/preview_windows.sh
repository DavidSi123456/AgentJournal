#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/private/tmp}/agentjournal-portable-swift-cache"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/private/tmp}/agentjournal-portable-clang-cache"
mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH"
PACKAGE_DIR=$(zsh "$PROJECT_DIR/scripts/stage_portable.sh" desktop)
swift build --package-path "$PACKAGE_DIR" --scratch-path "$PROJECT_DIR/.build/windows-desktop" --disable-sandbox --jobs 4 --product AgentJournalWindows
BIN_DIR=$(swift build --package-path "$PACKAGE_DIR" --scratch-path "$PROJECT_DIR/.build/windows-desktop" --show-bin-path)
# Sign outside Desktop/iCloud, where File Provider may attach FinderInfo while
# codesign runs. Keep this synthetic preview separate from the installed app.
PREVIEW_ROOT=$(mktemp -d "${TMPDIR:-/private/tmp}/agentjournal-windows-preview.XXXXXX")
PREVIEW_APP="$PREVIEW_ROOT/AgentJournalWindowsPreview.app"
mkdir -p "$PREVIEW_APP/Contents/MacOS"
cp -X "$BIN_DIR/AgentJournalWindows" "$PREVIEW_APP/Contents/MacOS/AgentJournalWindows"
cp -X "$PROJECT_DIR/Windows/Preview-Info.plist" "$PREVIEW_APP/Contents/Info.plist"
codesign --force --sign - "$PREVIEW_APP"
codesign --verify --strict "$PREVIEW_APP"
open -n "$PREVIEW_APP" --args --demo-only
printf '%s\n' "Synthetic-only preview: $PREVIEW_APP"
