import Foundation

// Foundation-only runner: Apple's Command Line Tools do not ship XCTest.
// Failures are reported with exit 1, not a fatal-error trap / exit 133.
private final class AssertionLog: @unchecked Sendable {
    static let shared = AssertionLog()
    private let lock = NSLock()
    private var messages: [String] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return messages.count }
    func add(_ message: String, file: StaticString, line: UInt) {
        lock.lock(); defer { lock.unlock() }
        messages.append("\(file):\(line): \(message)")
        print("FAIL \(file):\(line): \(message)")
    }
}
private struct CheckError: Error {}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    if actual != expected { AssertionLog.shared.add("Values differ", file: file, line: line) }
}
func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value { AssertionLog.shared.add("Expected true", file: file, line: line) }
}
func failCheck(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    AssertionLog.shared.add(message, file: file, line: line)
}
func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { failCheck("Expected non-nil value", file: file, line: line); throw CheckError() }
    return value
}
func expectThrows(_ expression: @autoclosure () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); failCheck("Expected an error", file: file, line: line) } catch {}
}

@main
struct PortableCheckRunner {
    static func main() async {
        let suite = PortableJournalTests()
        let checks: [(String, () async throws -> Void)] = [
            ("SHA-256 compatibility", { suite.testSHA256Compatibility() }),
            ("Shared reader / two providers / day grouping", suite.testSharedReaderGroupsBothProvidersAndDays),
            ("Restart and source cleanup retention", suite.testNotesSurviveRestartAndSourceCleanup),
            ("Timezone note isolation", suite.testChangingTimezonePreservesButDoesNotMisattachNotes),
            ("Provider filtering preserves history", suite.testProviderFilterDoesNotDeleteOtherProviderHistory),
            ("Conflicting-instance protection", suite.testConcurrentInstanceCannotOverwriteNotes),
            ("Consent and daily call limit", suite.testGenerationRequiresConsentAndHonorsZeroLimit),
            ("Draft generation and human-edit protection", suite.testGenerationStoresDraftAndProtectsHumanEdits),
            ("Invalid model response is not saved", suite.testInvalidModelResponseIsNotSaved),
            ("Windows executable / Node resolution without a shell", { try suite.testWindowsCLIResolutionDoesNotUseShellOrSplitSpaces() }),
            ("Corrupt storage is preserved", { try suite.testCorruptStorageIsPreserved() }),
            ("Demo is synthetic and source-free", { suite.testDemoIsSyntheticAndDoesNotReadSources() }),
            ("Cancellation drops late results", suite.testCancellationDoesNotSaveLateResults),
            ("New messages invalidate confirmation", suite.testUpdatedMessagesMakeConfirmationStale),
            ("Duplicate cached IDs fail closed", suite.testDuplicateLibraryIDsAreRejectedWithoutOverwrite),
            ("Notes metadata omits raw excerpts", suite.testMetadataFileOmitsConversationExcerpts)
        ]
        var passed = 0
        for (name, run) in checks {
            let before = AssertionLog.shared.count
            do { try await run() }
            catch { failCheck("\(name): \(error.localizedDescription)") }
            if AssertionLog.shared.count == before { passed += 1; print("PASS \(name)") }
        }
        print("\(passed)/\(checks.count) portable checks passed; no real conversations or model calls.")
        if passed != checks.count { exit(1) }
    }
}
