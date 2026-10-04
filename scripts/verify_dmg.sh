#!/bin/zsh
set -euo pipefail
if (( $# < 1 || $# > 2 )) || [[ "${1:-}" == --help ]]; then
    printf '%s\n' 'Usage: zsh scripts/verify_dmg.sh DMG [--require-notarized]' \
        'Mounts read-only without opening Finder or launching any app, then detaches.'
    [[ "${1:-}" == --help ]] && exit 0
    exit 1
fi
ASSET_DMG=${1:A}
REQUIRE_NOTARIZED=false
if (( $# == 2 )); then
    [[ "$2" == --require-notarized ]] || { printf '%s\n' 'Unknown verification option.' >&2; exit 1; }
    REQUIRE_NOTARIZED=true
fi
[[ -f "$ASSET_DMG" ]] || { printf '%s\n' 'DMG not found.' >&2; exit 1; }
VERIFY_TEMP=$(mktemp -d "${TMPDIR:-/private/tmp}/agentjournal-dmg-verify.XXXXXX")
MOUNTED=false
cleanup() {
    if $MOUNTED; then
        if ! hdiutil detach -quiet "$VERIFY_TEMP/mount"; then
            printf '%s\n' "Could not detach verification image: $VERIFY_TEMP/mount" >&2
            return 1
        fi
    fi
    rm -r -- "$VERIFY_TEMP"
}
trap cleanup EXIT
mkdir -p "$VERIFY_TEMP/mount"
hdiutil verify -quiet "$ASSET_DMG"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$VERIFY_TEMP/mount" "$ASSET_DMG"
MOUNTED=true
APP="$VERIFY_TEMP/mount/AgentJournal.app"
[[ -d "$APP" && ! -L "$APP" && "$(readlink "$VERIFY_TEMP/mount/Applications")" == /Applications ]] || {
    printf '%s\n' 'Unexpected disk-image installation layout.' >&2; exit 1
}
plutil -lint "$APP/Contents/Info.plist"
[[ "$(lipo -archs "$APP/Contents/MacOS/AgentJournal")" == arm64 ]] || { printf '%s\n' 'Expected arm64.' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" == 14.0 ]] || {
    printf '%s\n' 'Unexpected minimum macOS.' >&2; exit 1
}
codesign --verify --deep --strict "$APP"
ruby "${0:A:h}/privacy_check.rb" --artifact "$APP"
if $REQUIRE_NOTARIZED; then
    codesign --verify --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$APP"
    codesign --verify --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$ASSET_DMG"
    xcrun stapler validate "$APP"
    xcrun stapler validate "$ASSET_DMG"
    spctl --assess --type execute --verbose=2 "$APP"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$ASSET_DMG"
fi
printf '%s\n' 'DMG verified: read-only layout, arm64, macOS 14+, intact app signature. No app launched.'
if ! $REQUIRE_NOTARIZED; then
    printf '%s\n' 'Notarization / Gatekeeper approval was NOT verified. A clean-Mac test is still required.'
fi
