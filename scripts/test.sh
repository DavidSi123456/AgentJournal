#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
AJ_CHECK_LOCALES=false
if [[ "${1:-}" == --all-locales ]]; then
    AJ_CHECK_LOCALES=true
    shift
fi
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/private/tmp}/agentjournal-swift-cache"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/private/tmp}/agentjournal-clang-cache"
mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH"
cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.build"
swiftc -swift-version 5 -parse-as-library -o "$PROJECT_DIR/.build/JournalChecks" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalLanguage.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalModels.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalPlatform.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalPortableHash.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalWindowsCLI.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalReader.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalSummarizer.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalModelCatalog.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalShare.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalStore.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalAgent.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalWorkflow.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalThreadProgress.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalThreadProgressView.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalReports.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalAppearance.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalReportsView.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalView.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalOnboarding.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalAgentView.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalManagementView.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalDiagnosticsView.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalNavigation.swift" \
    "$PROJECT_DIR/Sources/AgentJournalKit/JournalDiagnostics.swift" \
    "$PROJECT_DIR/Tests/AgentJournalKitTests/JournalTests.swift" \
    "$PROJECT_DIR/Tests/AgentJournalKitTests/AgentTests.swift" \
    "$PROJECT_DIR/Tests/AgentJournalKitTests/WorkflowTests.swift" \
    "$PROJECT_DIR/Tests/AgentJournalKitTests/ProgressTests.swift" \
    "$PROJECT_DIR/Tests/AgentJournalKitTests/DiagnosticsTests.swift" \
    "$PROJECT_DIR/Tests/AgentJournalKitTests/CheckRunner.swift"
if $AJ_CHECK_LOCALES; then
    # Foundation launch arguments affect this process only, not system preferences.
    # Assert the effective default so a locale regression cannot silently pass.
    for AJ_SYSTEM_LANGUAGE in en zh; do
        if [[ "$AJ_SYSTEM_LANGUAGE" == en ]]; then
            AJ_APPLE_LANGUAGE=en
            AJ_APPLE_LOCALE=en_US
        else
            AJ_APPLE_LANGUAGE=zh-Hans
            AJ_APPLE_LOCALE=zh_CN
        fi
        printf '%s\n' "Checking system language: $AJ_SYSTEM_LANGUAGE"
        "$PROJECT_DIR/.build/JournalChecks" -AppleLanguages "($AJ_APPLE_LANGUAGE)" -AppleLocale "$AJ_APPLE_LOCALE" \
            --expect-system-language "$AJ_SYSTEM_LANGUAGE" "$@"
    done
else
    "$PROJECT_DIR/.build/JournalChecks" "$@"
fi
