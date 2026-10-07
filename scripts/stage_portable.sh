#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
MODE=${1:-core}
case "$MODE" in
    core) PACKAGE_DIR="$PROJECT_DIR/.build/portable-core-package"; MANIFEST=CorePackage.swift ;;
    desktop) PACKAGE_DIR="$PROJECT_DIR/.build/portable-desktop-package"; MANIFEST=DesktopPackage.swift ;;
    *) printf '%s\n' 'Usage: zsh scripts/stage_portable.sh [core|desktop]' >&2; exit 1 ;;
esac
mkdir -p "$PACKAGE_DIR/Sources/AgentJournalCore"
cp -X "$PROJECT_DIR/Windows/$MANIFEST" "$PACKAGE_DIR/Package.swift"
while IFS= read -r SOURCE_FILE; do
    [[ "$SOURCE_FILE" == *.swift && "$SOURCE_FILE" != */* ]] || { printf '%s\n' 'Invalid core source filename.' >&2; exit 1; }
    cp -X "$PROJECT_DIR/Sources/AgentJournalKit/$SOURCE_FILE" "$PACKAGE_DIR/Sources/AgentJournalCore/$SOURCE_FILE"
done < "$PROJECT_DIR/Windows/CoreSources.txt"
if [[ "$MODE" == core ]]; then
    mkdir -p "$PACKAGE_DIR/Sources/AgentJournalPortableChecks" "$PACKAGE_DIR/Sources/AgentJournalPortableCLI"
    cp -X "$PROJECT_DIR/Tests/AgentJournalPortableTests/CheckRunner.swift" "$PACKAGE_DIR/Sources/AgentJournalPortableChecks/CheckRunner.swift"
    cp -X "$PROJECT_DIR/Tests/AgentJournalPortableTests/PortableJournalTests.swift" "$PACKAGE_DIR/Sources/AgentJournalPortableChecks/PortableJournalTests.swift"
    cp -X "$PROJECT_DIR/Sources/AgentJournalPortableCLI/main.swift" "$PACKAGE_DIR/Sources/AgentJournalPortableCLI/main.swift"
else
    mkdir -p "$PACKAGE_DIR/Sources/AgentJournalWindows"
    cp -X "$PROJECT_DIR/Sources/AgentJournalWindows/AgentJournalWindowsApp.swift" "$PACKAGE_DIR/Sources/AgentJournalWindows/AgentJournalWindowsApp.swift"
fi
printf '%s\n' "$PACKAGE_DIR"
