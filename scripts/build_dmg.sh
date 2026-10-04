#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
SIGN_DISK=false
NOTARIZE_DISK=false
APP_FLAGS=()
while (( $# )); do
    case "$1" in
        --sign) SIGN_DISK=true; APP_FLAGS+=(--sign) ;;
        --notarize) NOTARIZE_DISK=true; APP_FLAGS+=(--notarize) ;;
        --help)
            printf '%s\n' 'Usage: zsh scripts/build_dmg.sh [--sign] [--notarize]' \
                'Default: clearly labeled ad-hoc Beta drag-to-Applications disk image.' \
                'Signing/notarization use the same fail-closed Developer ID / Keychain options as build_app.sh.' \
                'Explicit --sign --notarize notarizes/staples the app and then the enclosing disk image.'
            exit 0 ;;
        *) printf '%s\n' "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done
if $SIGN_DISK && [[ "${AGENTJOURNAL_SIGNING_IDENTITY:-}" != 'Developer ID Application:'* ]]; then
    printf '%s\n' 'A Developer ID Application identity is required. No ad-hoc fallback is allowed.' >&2; exit 1
fi
if $NOTARIZE_DISK && { ! $SIGN_DISK || [[ -z "${AGENTJOURNAL_NOTARY_PROFILE:-}" ]]; }; then
    printf '%s\n' 'Notarization requires --sign and a Keychain profile. No upload was attempted.' >&2; exit 1
fi
cd "$PROJECT_DIR"
zsh scripts/build_app.sh "${APP_FLAGS[@]}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
MODE=adhoc
if $SIGN_DISK; then MODE=developer-id; fi
if $NOTARIZE_DISK; then MODE=notarized; fi
STEM="AgentJournal-$VERSION-macOS-arm64-$MODE"
PACKAGE_TEMP=$(mktemp -d "${TMPDIR:-/private/tmp}/agentjournal-dmg.XXXXXX")
trap 'rm -r -- "$PACKAGE_TEMP"' EXIT
mkdir -p "$PACKAGE_TEMP/disk"
# Use the verified release archive, never the Desktop/iCloud development copy.
ditto -x -k "$PROJECT_DIR/dist/$STEM.zip" "$PACKAGE_TEMP/disk"
ln -s /Applications "$PACKAGE_TEMP/disk/Applications"
cp -X "$PROJECT_DIR/Resources/Install.txt" "$PACKAGE_TEMP/disk/Install.txt"
VOLUME="AgentJournal $VERSION"
if [[ "$MODE" == adhoc ]]; then VOLUME="$VOLUME Beta"; fi
ASSET_DMG="$PROJECT_DIR/dist/$STEM.dmg"
hdiutil create -ov -format UDZO -volname "$VOLUME" -srcfolder "$PACKAGE_TEMP/disk" "$PACKAGE_TEMP/release.dmg"
if $SIGN_DISK; then
    codesign --force --timestamp --sign "$AGENTJOURNAL_SIGNING_IDENTITY" "$PACKAGE_TEMP/release.dmg"
    codesign --verify --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$PACKAGE_TEMP/release.dmg"
fi
if $NOTARIZE_DISK; then
    mkdir -p "$PROJECT_DIR/.build/notary-results"
    chmod 700 "$PROJECT_DIR/.build/notary-results"
    RESULT=$(mktemp "$PROJECT_DIR/.build/notary-results/disk-submission.XXXXXX")
    if ! xcrun notarytool submit "$PACKAGE_TEMP/release.dmg" --keychain-profile "$AGENTJOURNAL_NOTARY_PROFILE" \
        --wait --timeout 20m --output-format json > "$RESULT"; then
        printf '%s\n' "Disk submission failed or is pending. Private result: $RESULT" >&2; exit 1
    fi
    [[ "$(plutil -extract status raw -o - "$RESULT")" == Accepted ]] || {
        printf '%s\n' 'Disk notarization was not accepted. No notarized disk image produced.' >&2; exit 1
    }
    xcrun stapler staple "$PACKAGE_TEMP/release.dmg"
    xcrun stapler validate "$PACKAGE_TEMP/release.dmg"
fi
cp -X "$PACKAGE_TEMP/release.dmg" "$ASSET_DMG"
VERIFY_FLAGS=()
if $NOTARIZE_DISK; then VERIFY_FLAGS+=(--require-notarized); fi
zsh scripts/verify_dmg.sh "$ASSET_DMG" "${VERIFY_FLAGS[@]}"
ruby scripts/release_metadata.rb "$PACKAGE_TEMP/disk/AgentJournal.app" "$ASSET_DMG" "$MODE"
printf '%s\n' "Disk image: $ASSET_DMG" "Signing: $MODE"
