#!/bin/zsh
# A separate demo-only bundle for public screenshots; never replaces the app.
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
DEMO_LANGUAGE=${1:-en}
[[ "$DEMO_LANGUAGE" == en || "$DEMO_LANGUAGE" == zh ]] || { printf '%s\n' 'Usage: zsh scripts/preview_readme_demo.sh [en|zh]' >&2; exit 1; }
DEMO_NAME='AgentJournal Readme Demo'
DEMO_IDENTIFIER='dev.agentjournal.readme-demo'
if [[ "$DEMO_LANGUAGE" == zh ]]; then
    DEMO_NAME+=' ZH'
    DEMO_IDENTIFIER+='.zh'
fi
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/private/tmp}/agentjournal-readme-swift-cache"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/private/tmp}/agentjournal-readme-clang-cache"
BUILD_FLAGS=(--scratch-path "$PROJECT_DIR/.build/app-swiftpm" --disable-sandbox -c release --jobs 4
    --triple arm64-apple-macosx14.0 --product AgentJournal)
swift build --package-path "$PROJECT_DIR" "${BUILD_FLAGS[@]}"
BIN_DIR=$(swift build --package-path "$PROJECT_DIR" "${BUILD_FLAGS[@]}" --show-bin-path)
DEMO_DIR=$(mktemp -d "${TMPDIR:-/private/tmp}/agentjournal-readme-demo.XXXXXX")
DEMO_APP="$DEMO_DIR/$DEMO_NAME.app"
mkdir -p "$DEMO_APP/Contents/MacOS" "$DEMO_APP/Contents/Resources"
cp -X "$BIN_DIR/AgentJournal" "$DEMO_APP/Contents/MacOS/AgentJournalReadmeDemo"
cp -X "$PROJECT_DIR/Resources/Info.plist" "$DEMO_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEMO_IDENTIFIER" "$DEMO_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DEMO_NAME" "$DEMO_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable AgentJournalReadmeDemo' "$DEMO_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DEMO_NAME" "$DEMO_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :AgentJournalDemoOnly bool true' "$DEMO_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :AgentJournalDemoLanguage string $DEMO_LANGUAGE" "$DEMO_APP/Contents/Info.plist"
if [[ -f "$PROJECT_DIR/dist/AgentJournal.app/Contents/Resources/AppIcon.icns" ]]; then
    cp -X "$PROJECT_DIR/dist/AgentJournal.app/Contents/Resources/AppIcon.icns" "$DEMO_APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --timestamp=none --sign - "$DEMO_APP"
codesign --verify --strict "$DEMO_APP"
printf '%s\n' "$DEMO_APP"
