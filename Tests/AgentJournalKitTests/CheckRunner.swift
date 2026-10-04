import Foundation
import Darwin

// Tiny dependency-free assertions let the suite run with Command Line Tools alone.
struct XCTSkip: Error { let message: String; init(_ message: String) { self.message = message } }
func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> Never {
    fatalError(message, file: (file), line: line)
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { XCTFail("Expected true", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() { XCTFail("Expected false", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T,
                                 file: StaticString = #filePath, line: UInt = #line) {
    do { if try left() != right() { XCTFail("Values differ", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value != nil { XCTFail("Expected nil", file: file, line: line) }
}
func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value == nil { XCTFail("Expected a value", file: file, line: line) }
}
func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { XCTFail("Expected a value", file: file, line: line) }
    return value
}
func XCTAssertNoThrow<T>(_ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try value() } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try value(); XCTFail("Expected an error", file: file, line: line) } catch {}
}

@main
struct CheckRunner {
    @MainActor
    static func main() async throws {
        // Fatal assertions must not discard buffered RUN/PASS lines in CI logs.
        setbuf(stdout, nil)
        if let index = CommandLine.arguments.firstIndex(of: "--expect-system-language") {
            guard index + 1 < CommandLine.arguments.count,
                  let expected = JournalInterfaceLanguage(rawValue: CommandLine.arguments[index + 1]) else {
                throw JournalError.message("Expected --expect-system-language en or zh")
            }
            XCTAssertEqual(JournalInterfaceLanguage.systemDefault, expected)
            print("SYSTEM LANGUAGE \(expected.rawValue)")
        }
        let suite = JournalTests()
        let tests: [(String, () async throws -> Void)] = [
            ("testPeriodReportPNGPagesAndBounds", { try suite.testPeriodReportPNGPagesAndBounds() }),
            ("testConcurrentRequestReservationsRespectOneSharedLimit", { try suite.testConcurrentRequestReservationsRespectOneSharedLimit() }),
            ("testInterruptedRestoreRollsBackBeforeAnyModels", { try suite.testInterruptedRestoreRollsBackBeforeAnyModels() }),
            ("testInterruptedArchiveRestoreRollsBackOnlyImportedFiles", { try suite.testInterruptedArchiveRestoreRollsBackOnlyImportedFiles() }),
            ("testThreadStatesAndFeedbackRespectNewProgress", { try suite.testThreadStatesAndFeedbackRespectNewProgress() }),
            ("testWorkflowPersistenceMergeAndSafety", { try suite.testWorkflowPersistenceMergeAndSafety() }),
            ("testRequestBudgetsArePersistedAcrossInstancesAndDays", { try suite.testRequestBudgetsArePersistedAcrossInstancesAndDays() }),
            ("testStoreFeedbackPersistsAndAdvisorModelIsIndependent", { try await suite.testStoreFeedbackPersistsAndAdvisorModelIsIndependent() }),
            ("testRequestLimitPreventsAllModelKinds", { try await suite.testRequestLimitPreventsAllModelKinds() }),
            ("testAutomaticScopeAndPauseNeverFillOldThreadByDefault", { try await suite.testAutomaticScopeAndPauseNeverFillOldThreadByDefault() }),
            ("testConcurrentJournalEditDoesNotOverwriteOtherInstance", { try await suite.testConcurrentJournalEditDoesNotOverwriteOtherInstance() }),
            ("testPeriodReportsAreBoundedAndEvidenceValidated", { try suite.testPeriodReportsAreBoundedAndEvidenceValidated() }),
            ("testReportPersistenceCancellationAndFailure", { try await suite.testReportPersistenceCancellationAndFailure() }),
            ("testBackupRestoresNotesStatesAndHistoryWithoutRawChatsOrCalls", { try await suite.testBackupRestoresNotesStatesAndHistoryWithoutRawChatsOrCalls() }),
            ("testInvalidBackupAndCorruptWorkflowNeverOverwriteOriginals", { try await suite.testInvalidBackupAndCorruptWorkflowNeverOverwriteOriginals() }),
            ("testOversizedHistoriesAreArchivedNotDeleted", { try await suite.testOversizedHistoriesAreArchivedNotDeleted() }),
            ("testArchiveBackupValidationAndLegacyCompatibility", { try await suite.testArchiveBackupValidationAndLegacyCompatibility() }),
            ("testArchivedCallsStillRespectDailyRequestLimit", { try suite.testArchivedCallsStillRespectDailyRequestLimit() }),
            ("testWorkflowDemoAndEnglishRemainModelFree", { try suite.testWorkflowDemoAndEnglishRemainModelFree() }),
            ("testTwoProvidersDailyGroupingAndNoiseFiltering", { try await suite.testTwoProvidersDailyGroupingAndNoiseFiltering() }),
            ("testOnlyClaudeAndOldFilesAreSupported", { try await suite.testOnlyClaudeAndOldFilesAreSupported() }),
            ("testIncompleteAppendCacheAndRetainedHistory", { try await suite.testIncompleteAppendCacheAndRetainedHistory() }),
            ("testMalformedLinesAndFileTruncation", { try await suite.testMalformedLinesAndFileTruncation() }),
            ("testSubagentsAndExecAreExcluded", { try await suite.testSubagentsAndExecAreExcluded() }),
            ("testCodexNoncanonicalWhitespaceIsNotSkipped", { try await suite.testCodexNoncanonicalWhitespaceIsNotSkipped() }),
            ("testProjectExclusionRebuildsIndexWithoutExcerpts", { try await suite.testProjectExclusionRebuildsIndexWithoutExcerpts() }),
            ("testIndexRebuildKeepsCleanedUpHistoryButNotExclusions", { try await suite.testIndexRebuildKeepsCleanedUpHistoryButNotExclusions() }),
            ("testUnchangedScansSkipIndexWritesAndReplayLaterOnes", { try await suite.testUnchangedScansSkipIndexWritesAndReplayLaterOnes() }),
            ("testLegacyV2IndexRetainsCleanedSourcesAcrossSettingsUpgrade", { try await suite.testLegacyV2IndexRetainsCleanedSourcesAcrossSettingsUpgrade() }),
            ("testConsecutiveTimezoneDaysMigrateByMessagesAcrossRestartAndBackup", { try await suite.testConsecutiveTimezoneDaysMigrateByMessagesAcrossRestartAndBackup() }),
            ("testSplitTimezoneDayDoesNotMisattributeConfirmedNote", { try await suite.testSplitTimezoneDayDoesNotMisattributeConfirmedNote() }),
            ("testTimezoneChangeKeepsNotesVisibleWithoutOverwriting", { try await suite.testTimezoneChangeKeepsNotesVisibleWithoutOverwriting() }),
            ("testLargeIncompleteLineDoesNotCorruptNextRecord", { try await suite.testLargeIncompleteLineDoesNotCorruptNextRecord() }),
            ("testDraftPersistenceDeduplicationAndMetadata", { try await suite.testDraftPersistenceDeduplicationAndMetadata() }),
            ("testLegacyPlanDeskDraftMigrationAndBackup", { try suite.testLegacyPlanDeskDraftMigrationAndBackup() }),
            ("testCorruptAndFutureVersionFilesAreNeverOverwritten", { try suite.testCorruptAndFutureVersionFilesAreNeverOverwritten() }),
            ("testCancellationCannotSaveLateResults", { try await suite.testCancellationCannotSaveLateResults() }),
            ("testSchemaValidationAndModelParsing", { try suite.testSchemaValidationAndModelParsing() }),
            ("testSummaryArgumentsAreToolFreeAndEphemeral", { suite.testSummaryArgumentsAreToolFreeAndEphemeral() }),
            ("testDemoReadsAndWritesNothingAndExportOmitsPaths", { try await suite.testDemoReadsAndWritesNothingAndExportOmitsPaths() }),
            ("testModelCatalogAndPerEnginePreferences", { try suite.testModelCatalogAndPerEnginePreferences() }),
            ("testShareDateRangePrivacyAndPendingDrafts", { suite.testShareDateRangePrivacyAndPendingDrafts() }),
            ("testSharePaginationAndPNGRendering", { try suite.testSharePaginationAndPNGRendering() }),
            ("testLanguagePreferencesCompatibilityAndPromptPolicy", { try suite.testLanguagePreferencesCompatibilityAndPromptPolicy() }),
            ("testFirstLaunchLanguageSelectionAndPreservedNotes", { try await suite.testFirstLaunchLanguageSelectionAndPreservedNotes() }),
            ("testSelectedSourcesDoNotScanOtherProviderAndKeepRetainedHistory", { try await suite.testSelectedSourcesDoNotScanOtherProviderAndKeepRetainedHistory() }),
            ("testOnboardingBlocksPrivateScanAndModelsUntilComplete", { try await suite.testOnboardingBlocksPrivateScanAndModelsUntilComplete() }),
            ("testOnboardingUpgradePreservesNotesModelsAndExplicitPreferences", { try suite.testOnboardingUpgradePreservesNotesModelsAndExplicitPreferences() }),
            ("testEnglishTranslationFormatsAndStableDateKeys", { try suite.testEnglishTranslationFormatsAndStableDateKeys() }),
            ("testEnglishSharingAndDemoWithoutModelCalls", { try suite.testEnglishSharingAndDemoWithoutModelCalls() }),
            ("testAgentInputIsBoundedProgressOnlyAndDeterministic", { try suite.testAgentInputIsBoundedProgressOnlyAndDeterministic() }),
            ("testAgentPromptAndEvidenceValidation", { try suite.testAgentPromptAndEvidenceValidation() }),
            ("testAgentSchemaUsesSameRestrictedCLIAndReportsModel", { try suite.testAgentSchemaUsesSameRestrictedCLIAndReportsModel() }),
            ("testDesktopMetadataEnrichesCachedThreadWithoutDuplicateOrPrivateConfig", { try await suite.testDesktopMetadataEnrichesCachedThreadWithoutDuplicateOrPrivateConfig() }),
            ("testDesktopMetadataRejectsInvalidIDsSymlinksAndOversizedFiles", { try suite.testDesktopMetadataRejectsInvalidIDsSymlinksAndOversizedFiles() }),
            ("testOriginalThreadNavigationIsValidatedAndNeverImports", { try suite.testOriginalThreadNavigationIsValidatedAndNeverImports() }),
            ("testAgentAnalysisDoesNotWriteJournalAndCancellationDropsLateResults", { try await suite.testAgentAnalysisDoesNotWriteJournalAndCancellationDropsLateResults() }),
            ("testAgentDemoNeverCallsModelOrPersists", { try suite.testAgentDemoNeverCallsModelOrPersists() }),
            ("testAgentHistoryRetainsDaysVersionsAndOriginalEvidence", { try suite.testAgentHistoryRetainsDaysVersionsAndOriginalEvidence() }),
            ("testAgentHistoryPreservesGenerationDayTimezoneAndLanguage", { try suite.testAgentHistoryPreservesGenerationDayTimezoneAndLanguage() }),
            ("testInvalidAgentHistoryIsPreservedAndOnlyBlocksAnalysis", { try await suite.testInvalidAgentHistoryIsPreservedAndOnlyBlocksAnalysis() }),
            ("testAgentHistoryRejectsUnsafePathsWithoutOverwriting", { try suite.testAgentHistoryRejectsUnsafePathsWithoutOverwriting() }),
            ("testAgentHistorySaveFailureCanRetryWithoutAnotherModelCall", { try await suite.testAgentHistorySaveFailureCanRetryWithoutAnotherModelCall() }),
            ("testAdviceHistoryEnglishLabelsAndDiagnostics", { try suite.testAdviceHistoryEnglishLabelsAndDiagnostics() }),
            ("testMissingCLIDiagnosticsStillAllowBrowsing", { suite.testMissingCLIDiagnosticsStillAllowBrowsing() }),
            ("testDiagnosticsDirectoryFailuresAndTranslation", { suite.testDiagnosticsDirectoryFailuresAndTranslation() }),
            ("testDiagnosticsArchivedOnlyAndNoCredentialPaths", { suite.testDiagnosticsArchivedOnlyAndNoCredentialPaths() }),
            ("testDiagnosticsDemoNeverProbesPrivateEnvironment", { suite.testDiagnosticsDemoNeverProbesPrivateEnvironment() }),
            ("testLocalDiagnosticsMetadataAndInvalidPaths", { try suite.testLocalDiagnosticsMetadataAndInvalidPaths() }),
            ("testCLIFailureMessagesWithoutAccountsOrModelCalls", { try await suite.testCLIFailureMessagesWithoutAccountsOrModelCalls() }),
            ("testOptionalLiveAgentAdvice", { try await suite.testOptionalLiveAgentAdvice() }),
            ("testOptionalLiveModelCatalog", { try await suite.testOptionalLiveModelCatalog() }),
            ("testOptionalLiveRead", { try await suite.testOptionalLiveRead() }),
            ("testOptionalLiveSummary", { try await suite.testOptionalLiveSummary() })
        ]
        let filterIndex = CommandLine.arguments.firstIndex(of: "--filter")
        let filter = filterIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
        var passed = 0, skipped = 0, selected = 0
        for (name, run) in tests where filter == nil || name.contains(filter!) {
            selected += 1
            print("RUN \(name)")
            try suite.setUpWithError()
            do { try await run(); passed += 1; print("PASS \(name)") }
            catch let skip as XCTSkip { skipped += 1; print("SKIP \(name): \(skip.message)") }
            catch { try? suite.tearDownWithError(); throw error }
            try suite.tearDownWithError()
        }
        guard selected > 0 else { throw JournalError.message("No tests matched the filter") }
        print("\(passed) passed, \(skipped) skipped")
    }
}
