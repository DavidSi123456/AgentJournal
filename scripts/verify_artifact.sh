#!/bin/zsh
set -euo pipefail
if (( $# < 1 || $# > 2 )) || [[ "${1:-}" == --help ]]; then
    printf '%s\n' 'Usage: zsh scripts/verify_artifact.sh ZIP [--require-notarized]' \
        'Extracts and verifies a build asset without launching the app or any CLI.'
    [[ "${1:-}" == --help ]] && exit 0
    exit 1
fi
ASSET_ZIP=${1:A}
REQUIRE_NOTARIZED=false
if (( $# == 2 )); then
    [[ "$2" == --require-notarized ]] || { printf '%s\n' 'Unknown verification option.' >&2; exit 1; }
    REQUIRE_NOTARIZED=true
fi
[[ -f "$ASSET_ZIP" ]] || { printf '%s\n' 'ZIP not found.' >&2; exit 1; }
VERIFY_TEMP=$(mktemp -d "${TMPDIR:-/private/tmp}/agentjournal-verify.XXXXXX")
trap 'rm -r -- "$VERIFY_TEMP"' EXIT
# Reject traversal and unexpected top-level content before extraction.
unzip -Z -1 "$ASSET_ZIP" > "$VERIFY_TEMP/entries.txt"
unzip -Z -l "$ASSET_ZIP" > "$VERIFY_TEMP/layout.txt"
ruby -e 'entries = File.readlines(ARGV[0], chomp: true); layout = File.read(ARGV[1]); abort "Unexpected ZIP layout" if entries.empty? || entries.length > 10000 || entries.any? { |p| p.start_with?("/") || p.include?("\\") || p.split("/").include?("..") || !(p.start_with?("AgentJournal.app/") || p.start_with?("__MACOSX/")) }; abort "Symlinks are not expected in this app" if layout.match?(/^l[rwx-]{9}/); size = layout[/([0-9]+) bytes uncompressed/, 1]; abort "ZIP is too large or has an unknown layout" unless size && size.to_i <= 268435456' "$VERIFY_TEMP/entries.txt" "$VERIFY_TEMP/layout.txt"
ditto -x -k "$ASSET_ZIP" "$VERIFY_TEMP"
APP="$VERIFY_TEMP/AgentJournal.app"
plutil -lint "$APP/Contents/Info.plist"
[[ "$(lipo -archs "$APP/Contents/MacOS/AgentJournal")" == arm64 ]] || { printf '%s\n' 'Expected an Apple Silicon arm64 executable.' >&2; exit 1; }
[[ "$('/usr/libexec/PlistBuddy' -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" == 14.0 ]] || { printf '%s\n' 'Unexpected minimum macOS version.' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
ruby "${0:A:h}/privacy_check.rb" --artifact "$APP"
if $REQUIRE_NOTARIZED; then
    codesign --verify --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi
printf '%s\n' 'ZIP verified: arm64, macOS 14+, intact app signature. No app launched.'
if ! $REQUIRE_NOTARIZED; then
    printf '%s\n' 'Notarization / Gatekeeper approval was NOT verified. This is not a clean-Mac installation test.'
fi
