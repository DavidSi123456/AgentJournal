#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/private/tmp}/agentjournal-portable-swift-cache"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/private/tmp}/agentjournal-portable-clang-cache"
mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH"
PACKAGE_DIR=$(zsh "$PROJECT_DIR/scripts/stage_portable.sh" core)
swift run --package-path "$PACKAGE_DIR" --scratch-path "$PROJECT_DIR/.build/windows-core" --disable-sandbox --jobs 4 AgentJournalPortableChecks "$@"
