import Foundation
@testable import AgentJournalCore
#if canImport(CryptoKit)
import CryptoKit
#endif

final class PortableJournalTests {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentjournal-portable-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ objects: [[String: Any]], to file: URL, trailingNewline: Bool = true) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try objects.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8).write(to: file)
    }
    private func fixture(_ root: URL) throws -> PortableConfiguration {
        var config = PortableConfiguration()
        config.codexHome = root.appendingPathComponent("codex").path
        config.claudeHome = root.appendingPathComponent("claude").path
        config.timeZoneID = "UTC"; config.interfaceLanguage = "en"
        try write([
            ["type":"session_meta", "payload":["id":"00000000-0000-4000-8000-000000000001", "cwd":"C:\\Research", "source":"cli"]],
            ["type":"response_item", "timestamp":"2026-10-01T23:30:00Z",
             "payload":["type":"message", "role":"user", "content":[["type":"input_text", "text":"Review a synthetic paper"]]]],
            ["type":"response_item", "timestamp":"2026-10-02T09:00:00Z",
             "payload":["type":"message", "role":"assistant", "content":[["type":"output_text", "text":"Synthetic assistant-only private marker"]]]]
        ], to: root.appendingPathComponent("codex/sessions/rollout-example.jsonl"))
        try write([
            ["type":"user", "sessionId":"00000000-0000-4000-8000-000000000002", "uuid":"synthetic-1",
             "timestamp":"2026-10-02T10:00:00Z", "cwd":"C:\\Notebook", "message":["content":"Test a synthetic notebook"]],
            ["type":"assistant", "sessionId":"00000000-0000-4000-8000-000000000002", "uuid":"synthetic-2",
             "timestamp":"2026-10-02T10:01:00Z", "message":["content":[["type":"text", "text":"Added one synthetic check"]]]],
            ["type":"assistant", "sessionId":"00000000-0000-4000-8000-000000000002", "isSidechain":true,
             "timestamp":"2026-10-02T10:02:00Z", "message":["content":"Excluded synthetic subagent"]]
        ], to: root.appendingPathComponent("claude/projects/example/session.jsonl"))
        return config
    }
    private func makeJournal(_ root: URL) async throws -> PortableJournal {
        let config = try fixture(root)
        let journal = try PortableJournal(directory: root.appendingPathComponent("storage"))
        try await journal.saveConfiguration(config)
        return journal
    }
    func testSHA256Compatibility() {
        expectEqual(JournalPortableHash.hash(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        expectEqual(JournalPortableHash.hash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        expectEqual(JournalPortableHash.hash("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #if canImport(CryptoKit)
        for text in ["中文 📚", String(repeating: "a", count: 64), String(repeating: "xyz", count: 10000)] {
            expectEqual(JournalPortableHash.hash(text), SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
        }
        #endif
    }
    func testSharedReaderGroupsBothProvidersAndDays() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await makeJournal(root)
        let result = try await journal.refresh()
        expectEqual(result.entries.count, 3)
        expectEqual(Set(result.entries.map(\.day)), ["2026-10-01", "2026-10-02"])
        expectEqual(Set(result.entries.map(\.provider)), ["codex", "claude"])
        expectEqual(result.entries.first(where: { $0.provider == "claude" })?.messageCount, 2)
        expectEqual(Set(result.entries.map(\.threadKey)).count, 2)
    }
    func testNotesSurviveRestartAndSourceCleanup() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await makeJournal(root)
        let snapshot = try await journal.refresh()
        let id = try unwrap(snapshot.entries.first?.id)
        _ = try await journal.saveNote(id: id, summary: "Handwritten note", nextStep: "Check again", confirmed: true)
        try FileManager.default.removeItem(at: root.appendingPathComponent("codex"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("claude"))
        let restarted = try PortableJournal(directory: root.appendingPathComponent("storage"))
        let restored = try await restarted.refresh()
        expectEqual(restored.entries.count, 3)
        expectEqual(restored.entries.first(where: { $0.id == id })?.summary, "Handwritten note")
        expectEqual(restored.entries.first(where: { $0.id == id })?.confirmed, true)
    }
    func testChangingTimezonePreservesButDoesNotMisattachNotes() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await makeJournal(root)
        let before = try await journal.refresh()
        let row = try unwrap(before.entries.first(where: { $0.day == "2026-10-01" }))
        _ = try await journal.saveNote(id: row.id, summary: "UTC day only", nextStep: "", confirmed: false)
        var config = await journal.configuration()
        config.timeZoneID = "Asia/Shanghai"
        try await journal.saveConfiguration(config)
        let shifted = try await journal.refresh()
        expectTrue(shifted.entries.allSatisfy { $0.summary.isEmpty })
        config.timeZoneID = "UTC"
        try await journal.saveConfiguration(config)
        let original = try await journal.refresh()
        expectEqual(original.entries.first(where: { $0.id == row.id })?.summary, "UTC day only")
    }
    func testProviderFilterDoesNotDeleteOtherProviderHistory() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await makeJournal(root)
        _ = try await journal.refresh()
        var config = await journal.configuration(); config.sources = "codex"
        try await journal.saveConfiguration(config)
        let codexOnly = try await journal.refresh()
        expectEqual(codexOnly.entries.count, 2)
        config.sources = "both"; try await journal.saveConfiguration(config)
        let both = try await journal.refresh(); expectEqual(both.entries.count, 3)
    }
    func testConcurrentInstanceCannotOverwriteNotes() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await makeJournal(root)
        let snapshot = try await first.refresh()
        let second = try PortableJournal(directory: root.appendingPathComponent("storage"))
        let id = try unwrap(snapshot.entries.first?.id)
        _ = try await first.saveNote(id: id, summary: "Keep this", nextStep: "", confirmed: false)
        do {
            _ = try await second.saveNote(id: id, summary: "Must not replace", nextStep: "", confirmed: false)
            failCheck("Expected optimistic write conflict")
        } catch { expectTrue(error.localizedDescription.contains("另一个实例")) }
        let reloaded = try PortableJournal(directory: root.appendingPathComponent("storage"))
        let saved = try await reloaded.snapshot()
        expectEqual(saved.entries.first(where: { $0.id == id })?.summary, "Keep this")
    }
    func testGenerationRequiresConsentAndHonorsZeroLimit() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await makeJournal(root)
        let snapshot = try await journal.refresh()
        let recorder = TestSummarizer()
        await journal.useTestSummarizer(recorder)
        let id = try unwrap(snapshot.entries.first?.id)
        do { _ = try await journal.generate(ids: [id], consent: false); failCheck("Missing consent") } catch {}
        var config = await journal.configuration(); config.dailyCallLimit = 0
        try await journal.saveConfiguration(config)
        do { _ = try await journal.generate(ids: [id], consent: true); failCheck("Zero limit") } catch {}
        let calls = await recorder.count; expectEqual(calls, 0)
    }
    func testGenerationStoresDraftAndProtectsHumanEdits() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await makeJournal(root)
        let snapshot = try await journal.refresh()
        let recorder = TestSummarizer(); await journal.useTestSummarizer(recorder)
        let id = try unwrap(snapshot.entries.first?.id)
        let generated = try await journal.generate(ids: [id], consent: true)
        expectEqual(generated.entries.first(where: { $0.id == id })?.summary, "Synthetic model draft")
        expectEqual(generated.entries.first(where: { $0.id == id })?.confirmed, false)
        expectEqual(generated.remainingCalls, 19)
        _ = try await journal.saveNote(id: id, summary: "Protected edit", nextStep: "", confirmed: true)
        do { _ = try await journal.generate(ids: [id], consent: true); failCheck("Must preserve human edit") } catch {}
        let calls = await recorder.count; expectEqual(calls, 1)
        let saved = try await journal.snapshot(); expectEqual(saved.entries.first(where: { $0.id == id })?.summary, "Protected edit")
    }
    func testInvalidModelResponseIsNotSaved() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await makeJournal(root)
        let snapshot = try await journal.refresh()
        await journal.useTestSummarizer(TestSummarizer(invalid: true))
        let id = try unwrap(snapshot.entries.first?.id)
        do { _ = try await journal.generate(ids: [id], consent: true); failCheck("Invalid schema") } catch {}
        let saved = try await journal.snapshot(); expectTrue(saved.entries.allSatisfy { $0.summary.isEmpty })
        expectEqual(saved.remainingCalls, 19)
    }
    func testWindowsCLIResolutionDoesNotUseShellOrSplitSpaces() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Path with spaces")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("node.exe"))
        let appData = root.appendingPathComponent("Roaming")
        let script = appData.appendingPathComponent("npm/node_modules/@openai/codex/bin/codex.js")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// synthetic fixture, never executed".utf8).write(to: script)
        let launch = try JournalWindowsCLI.resolve(engine: .codex, home: root,
            environment: ["Path": folder.path + ";" + root.appendingPathComponent("Other").path, "AppData": appData.path])
        expectEqual(launch.executable.lastPathComponent, "node.exe")
        expectEqual(launch.arguments, [script.path])
        expectThrows(try JournalWindowsCLI.resolve(engine: .codex, override: folder.appendingPathComponent("codex.cmd")))
    }
    func testCorruptStorageIsPreserved() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("prototype-journal.json")
        let original = Data("not json".utf8); try original.write(to: file)
        expectThrows(try PortableJournal(directory: root))
        expectEqual(try Data(contentsOf: file), original)
    }
    func testDemoIsSyntheticAndDoesNotReadSources() {
        let rows = PortableJournal.demoEntries(now: Date(timeIntervalSince1970: 1790899200))
        expectEqual(rows.count, 6); expectEqual(Set(rows.map(\.threadKey)).count, 2)
        expectTrue(rows.allSatisfy { $0.project.contains("Synthetic demo") && $0.summaryModel.contains("no model") })
    }
    func testCancellationDoesNotSaveLateResults() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await makeJournal(root)
        let snapshot = try await journal.refresh()
        let id = try unwrap(snapshot.entries.first?.id)
        let delayed = DelayedSummarizer(); await journal.useTestSummarizer(delayed)
        let task = Task { try await journal.generate(ids: [id], consent: true) }
        for _ in 0..<40 {
            if await delayed.started { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let started = await delayed.started; expectTrue(started)
        task.cancel()
        do { _ = try await task.value; failCheck("Expected cancellation") } catch {}
        let after = try await journal.snapshot(); expectTrue(after.entries.allSatisfy { $0.summary.isEmpty })
        let workflow = try JournalWorkflowFile.load(root.appendingPathComponent("storage/prototype-workflow.json"))
        expectEqual(workflow.calls.last?.outcome, .cancelled)
    }
    func testUpdatedMessagesMakeConfirmationStale() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await makeJournal(root)
        let initial = try await journal.refresh()
        let row = try unwrap(initial.entries.first(where: { $0.provider == "claude" }))
        _ = try await journal.saveNote(id: row.id, summary: "Keep human note", nextStep: "", confirmed: true)
        let file = root.appendingPathComponent("claude/projects/example/session.jsonl")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        let data = try JSONSerialization.data(withJSONObject: ["type":"user", "sessionId":"00000000-0000-4000-8000-000000000002",
            "uuid":"synthetic-later", "timestamp":"2026-10-02T11:00:00Z", "message":["content":"A later synthetic question"]])
        try handle.write(contentsOf: data + Data([10])); try handle.close()
        let refreshed = try await journal.refresh()
        let changed = try unwrap(refreshed.entries.first(where: { $0.id == row.id }))
        expectTrue(changed.stale); expectTrue(!changed.confirmed); expectTrue(!changed.canGenerate)
        expectEqual(changed.summary, "Keep human note")
    }
    func testDuplicateLibraryIDsAreRejectedWithoutOverwrite() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await makeJournal(root); _ = try await journal.refresh()
        let file = root.appendingPathComponent("storage/prototype-journal.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var library = object["library"] as! [String: [[String: Any]]]
        let key = try unwrap(library.keys.first); let item = try unwrap(library[key]?.first)
        library[key]?.append(item); object["library"] = library
        let corrupted = try JSONSerialization.data(withJSONObject: object); try corrupted.write(to: file)
        expectThrows(try PortableJournal(directory: root.appendingPathComponent("storage")))
        expectEqual(try Data(contentsOf: file), corrupted)
    }
    func testMetadataFileOmitsConversationExcerpts() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await makeJournal(root); _ = try await journal.refresh()
        let text = try String(contentsOf: root.appendingPathComponent("storage/prototype-journal.json"), encoding: .utf8)
        expectTrue(!text.contains("Synthetic assistant-only private marker"))
        expectTrue(text.contains("Review a synthetic paper")) // thread title is intentionally retained
    }
}

private actor TestSummarizer: JournalSummarizing {
    var count = 0
    let invalid: Bool
    init(invalid: Bool = false) { self.invalid = invalid }
    func summarize(_ activities: [JournalActivity], settings: JournalSettings) async throws -> JournalSummaryBatch {
        count += 1
        return JournalSummaryBatch(entries: activities.map {
            JournalSummaryRow(id: invalid ? "wrong-id" : $0.id, summary: "Synthetic model draft", nextStep: "Verify next",
                              status: "待确认", category: "研究")
        }, engine: "Synthetic test", model: "fixture-only")
    }
}

private actor DelayedSummarizer: JournalSummarizing {
    var started = false
    func summarize(_ activities: [JournalActivity], settings: JournalSettings) async throws -> JournalSummaryBatch {
        started = true
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return JournalSummaryBatch(entries: [], engine: "Synthetic delay", model: nil)
    }
}
