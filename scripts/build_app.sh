#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
SIGN_APP=false
NOTARIZE_APP=false
while (( $# )); do
    case "$1" in
        --sign) SIGN_APP=true ;;
        --notarize) NOTARIZE_APP=true ;;
        --help)
            printf '%s\n' 'Usage: zsh scripts/build_app.sh [--sign] [--notarize]' \
                'Default: Apple Silicon ad-hoc Beta; no Apple upload or credentials needed.' \
                '--sign: requires AGENTJOURNAL_SIGNING_IDENTITY = Developer ID Application: ...' \
                '--notarize: requires --sign and AGENTJOURNAL_NOTARY_PROFILE (stored in Keychain).' \
                'Notarization uploads the built app only, never your journal or transcripts.'
            exit 0 ;;
        *) printf '%s\n' "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done
if $SIGN_APP && [[ "${AGENTJOURNAL_SIGNING_IDENTITY:-}" != 'Developer ID Application:'* ]]; then
    printf '%s\n' 'A Developer ID Application identity is required. No ad-hoc fallback is allowed.' >&2
    exit 1
fi
if $NOTARIZE_APP && { ! $SIGN_APP || [[ -z "${AGENTJOURNAL_NOTARY_PROFILE:-}" ]]; }; then
    printf '%s\n' 'Notarization requires --sign and a Keychain profile. No upload was attempted.' >&2
    exit 1
fi
BUILD_DIR="$PROJECT_DIR/.build/app-swiftpm"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/private/tmp}/agentjournal-swift-cache"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/private/tmp}/agentjournal-clang-cache"
mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH"
cd "$PROJECT_DIR"
BUILD_FLAGS=(--scratch-path "$BUILD_DIR" --disable-sandbox -c release --triple arm64-apple-macosx14.0 \
    -debug-info-format none -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_DIR=AgentJournal")
swift build "${BUILD_FLAGS[@]}"
BIN_DIR=$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)
swift "$PROJECT_DIR/scripts/make_icon.swift" "$PROJECT_DIR/.build/AgentJournal.iconset"
OUTPUT_DIR="$PROJECT_DIR/dist/AgentJournal.app"
# Sign outside Desktop/iCloud: File Provider can reattach FinderInfo immediately
# after xattr cleanup, causing codesign to reject an otherwise clean bundle.
PACKAGE_TEMP=$(mktemp -d "${TMPDIR:-/private/tmp}/agentjournal-package.XXXXXX")
trap 'rm -r -- "$PACKAGE_TEMP"' EXIT
PACKAGE_APP="$PACKAGE_TEMP/AgentJournal.app"
mkdir -p "$PACKAGE_APP/Contents/MacOS" "$PACKAGE_APP/Contents/Resources" "$PROJECT_DIR/dist"
cp -X "$BIN_DIR/AgentJournal" "$PACKAGE_APP/Contents/MacOS/AgentJournal"
cp -X "$PROJECT_DIR/Resources/Info.plist" "$PACKAGE_APP/Contents/Info.plist"
swift "$PROJECT_DIR/scripts/pack_icon.swift" "$PROJECT_DIR/.build/AgentJournal.iconset" "$PACKAGE_APP/Contents/Resources/AppIcon.icns"
chmod +x "$PACKAGE_APP/Contents/MacOS/AgentJournal"
SIGNING_MODE=adhoc
if $SIGN_APP; then
    codesign --force --options runtime --timestamp --sign "$AGENTJOURNAL_SIGNING_IDENTITY" "$PACKAGE_APP"
    codesign --verify --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$PACKAGE_APP"
    SIGNING_MODE=developer-id
else
    codesign --force --options runtime --timestamp=none --sign - "$PACKAGE_APP"
fi
codesign --verify --deep --strict "$PACKAGE_APP"
if $NOTARIZE_APP; then
    ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_APP" "$PACKAGE_TEMP/notary-upload.zip"
    mkdir -p "$PROJECT_DIR/.build/notary-results"
    chmod 700 "$PROJECT_DIR/.build/notary-results"
    NOTARY_LOG=$(mktemp "$PROJECT_DIR/.build/notary-results/submission.XXXXXX")
    # Explicit opt-in only. Authentication stays in the Keychain, not shell arguments.
    if ! xcrun notarytool submit "$PACKAGE_TEMP/notary-upload.zip" --keychain-profile "$AGENTJOURNAL_NOTARY_PROFILE" \
        --wait --timeout 20m --output-format json > "$NOTARY_LOG"; then
        printf '%s\n' "Submission failed or is still pending. Private result: $NOTARY_LOG" >&2
        exit 1
    fi
    NOTARY_STATUS=$(plutil -extract status raw -o - "$NOTARY_LOG")
    if [[ "$NOTARY_STATUS" != Accepted ]]; then
        printf '%s\n' "Notarization status: $NOTARY_STATUS. No notarized release was produced. Private result: $NOTARY_LOG" >&2
        exit 1
    fi
    xcrun stapler staple "$PACKAGE_APP"
    xcrun stapler validate "$PACKAGE_APP"
    SIGNING_MODE=notarized
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PACKAGE_APP/Contents/Info.plist")
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { printf '%s\n' 'Invalid app version.' >&2; exit 1; }
ASSET_STEM="AgentJournal-$VERSION-macOS-arm64-$SIGNING_MODE"
ASSET_ZIP="$PROJECT_DIR/dist/$ASSET_STEM.zip"
ditto --norsrc --noextattr "$PACKAGE_APP" "$OUTPUT_DIR"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_APP" "$ASSET_ZIP"
VERIFY_FLAGS=()
if $NOTARIZE_APP; then VERIFY_FLAGS+=(--require-notarized); fi
zsh "$PROJECT_DIR/scripts/verify_artifact.sh" "$ASSET_ZIP" "${VERIFY_FLAGS[@]}"
ruby "$PROJECT_DIR/scripts/release_metadata.rb" "$PACKAGE_APP" "$ASSET_ZIP" "$SIGNING_MODE"
# Preserve the local development shortcut. Publish only the versioned asset + sidecars.
cp -X "$ASSET_ZIP" "$PROJECT_DIR/dist/AgentJournal.zip"
printf '%s\n' "Release asset: $ASSET_ZIP" "Signing: $SIGNING_MODE"
printf '%s\n' "$OUTPUT_DIR"
