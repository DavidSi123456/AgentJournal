import Foundation

final class MockSummarizer: JournalSummarizing {
    var calls = 0
    var pause: UInt64 = 0
    func summarize(_ activities: [JournalActivity], settings: JournalSettings) async throws -> JournalSummaryBatch {
        calls += 1
        if pause > 0 { try await Task.sleep(nanoseconds: pause) }
        return JournalSummaryBatch(entries: activities.map {
            JournalSummaryRow(id: $0.id, summary: "处理了示例问题，完成验证。", nextStep: "", status: "已完成", category: "研究")
        }, engine: "test", model: "test-model")
    }
}

final class JournalTests {
    var root: URL!
    var settings: JournalSettings!
    let manager = FileManager.default
    func setUpWithError() throws {
        root = manager.temporaryDirectory.appendingPathComponent("agentjournal-test-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        settings = JournalSettings()
        settings.codexHome = root.appendingPathComponent("codex").path
        settings.claudeHome = root.appendingPathComponent("claude").path
        settings.timeZoneID = "Asia/Shanghai"
    }
    func tearDownWithError() throws { try manager.removeItem(at: root) }
    var codexFile: URL { URL(fileURLWithPath: settings.codexHome).appendingPathComponent("sessions/2026/09/30/rollout-test.jsonl") }
    var claudeFile: URL { URL(fileURLWithPath: settings.claudeHome).appendingPathComponent("projects/demo/demo-session.jsonl") }
    var indexFile: URL { root.appendingPathComponent("index.json") }

    func write(_ rows: [[String: Any]], to url: URL, newline: Bool = true) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = Data()
        for row in rows {
            bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            bytes.append(10)
        }
        if !newline && !bytes.isEmpty { bytes.removeLast() }
        try bytes.write(to: url)
    }
    func append(_ bytes: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: bytes)
    }
    func meta(_ id: String = "same-id", source: Any = "desktop") -> [String: Any] {
        ["type": "session_meta", "payload": ["id": id, "cwd": "/demo/project", "source": source]]
    }
    func codex(_ stamp: String, _ role: String, _ text: String, phase: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]
        if let phase { payload["phase"] = phase }
        return ["type": "response_item", "timestamp": stamp, "payload": payload]
    }
    func claude(_ stamp: String, _ role: String, _ content: Any, sidechain: Bool = false) -> [String: Any] {
        ["type": role, "sessionId": "same-id", "cwd": "/demo/project", "isSidechain": sidechain,
         "timestamp": stamp, "uuid": UUID().uuidString,
         "message": ["role": role, "content": content, "model": "claude-test"]]
    }
    func sample() -> JournalActivity {
        let date = JournalClock(timeZoneID: "Asia/Shanghai").date("2026-09-30")
        var activity = JournalActivity(threadID: "same-id", day: "2026-09-30", title: "示例", cwd: "/demo", firstActivity: date, lastActivity: date)
        activity.append(JournalExcerpt(timestamp: date, role: "user", text: "讨论示例方案，不曾实现。"))
        return activity
    }

    func testTwoProvidersDailyGroupingAndNoiseFiltering() async throws {
        try write([meta(), codex("2026-09-30T15:59:00Z", "user", "设计任务"),
                   codex("2026-09-30T16:01:00.000Z", "assistant", "实现任务"),
                   codex("2026-09-30T16:02:00Z", "assistant", "NOISE", phase: "commentary"),
                   codex("2026-09-30T16:03:00Z", "user", "# AGENTS.md instructions NOISE")], to: codexFile)
        try write([claude("2026-09-30T15:59:00Z", "user", "研究问题"),
                   claude("2026-09-30T16:01:00Z", "assistant", [["type": "thinking", "thinking": "NOISE"],
                                                               ["type": "text", "text": "讨论了方案"]]),
                   claude("2026-09-30T16:02:00Z", "user", [["type": "tool_result", "content": "NOISE"]]),
                   claude("2026-09-30T16:03:00Z", "assistant", "NOISE", sidechain: true),
                   ["type": "custom-title", "sessionId": "same-id", "customTitle": "研究笔记"]], to: claudeFile)
        let snapshot = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(snapshot.activities.count, 4)
        XCTAssertEqual(Set(snapshot.activities.map(\.day)), ["2026-09-30", "2026-10-01"])
        XCTAssertEqual(Set(snapshot.activities.map(\.threadKey)).count, 2)
        XCTAssertTrue(snapshot.activities.filter { $0.source == .claude }.allSatisfy { $0.title == "研究笔记" })
        XCTAssertFalse(snapshot.activities.flatMap(\.excerpts).contains { $0.text.contains("NOISE") })
        XCTAssertEqual(snapshot.activities.first { $0.source == .claude && $0.day == "2026-10-01" }?.sourceModel, "claude-test")
    }

    func testOnlyClaudeAndOldFilesAreSupported() async throws {
        try write([claude("2020-01-01T00:00:00Z", "user", "旧问题")], to: claudeFile)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1577836800)], ofItemAtPath: claudeFile.path)
        let snapshot = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(snapshot.activities.count, 1)
        XCTAssertEqual(snapshot.activities[0].day, "2020-01-01")
        XCTAssertTrue(snapshot.warnings.contains { $0.contains("Codex") })
    }

    func testIncompleteAppendCacheAndRetainedHistory() async throws {
        try write([meta(), codex("2026-09-30T00:00:00Z", "user", "原问题")], to: codexFile)
        let reader = JournalReader(settings: settings, indexURL: indexFile)
        let first = try await reader.scan()
        XCTAssertEqual(first.activities[0].messageCount, 1)
        let unfinished = try JSONSerialization.data(withJSONObject: codex("2026-09-30T01:00:00Z", "assistant", "完成"))
        try append(unfinished, to: codexFile)
        let partial = try await reader.scan()
        XCTAssertEqual(partial.activities[0].messageCount, 1)
        try append(Data([10]), to: codexFile)
        let completed = try await reader.scan()
        XCTAssertEqual(completed.activities[0].messageCount, 2)
        let cached = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(cached.activities[0].messageCount, 2)
        try manager.removeItem(at: codexFile)
        let retained = try await reader.scan()
        XCTAssertEqual(retained.activities[0].messageCount, 2)
    }

    func testMalformedLinesAndFileTruncation() async throws {
        try write([meta(), codex("2026-09-30T00:00:00Z", "user", "一个稍微长一些的问题")], to: codexFile)
        try append(Data("broken json\n".utf8), to: codexFile)
        let reader = JournalReader(settings: settings, indexURL: indexFile)
        let first = try await reader.scan()
        XCTAssertEqual(first.activities[0].messageCount, 1)
        try write([meta(), codex("2026-09-30T00:00:00Z", "user", "新")], to: codexFile)
        let rewritten = try await reader.scan()
        XCTAssertEqual(rewritten.activities[0].messageCount, 1)
        XCTAssertEqual(rewritten.activities[0].excerpts[0].text, "新")
    }

    func testSubagentsAndExecAreExcluded() async throws {
        try write([meta(source: "exec"), codex("2026-09-30T00:00:00Z", "user", "NOISE")], to: codexFile)
        let subFile = URL(fileURLWithPath: settings.claudeHome).appendingPathComponent("projects/demo/subagents/agent-test.jsonl")
        try write([claude("2026-09-30T00:00:00Z", "user", "NOISE")], to: subFile)
        let result = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertTrue(result.activities.isEmpty)
    }

    func testCodexNoncanonicalWhitespaceIsNotSkipped() async throws {
        try write([meta()], to: codexFile)
        let row = "{\"type\"  :  \"response_item\",\"timestamp\":\"2026-09-30T00:00:00Z\",\"payload\":{\"type\" :  \"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"问题\"}]}}\n"
        try append(Data(row.utf8), to: codexFile)
        let snapshot = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(snapshot.activities.count, 1)
    }

    func testProjectExclusionRebuildsIndexWithoutExcerpts() async throws {
        try write([meta(), codex("2026-09-30T00:00:00Z", "user", "PRIVATE-SENTINEL")], to: codexFile)
        let first = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(first.activities.count, 1)
        settings.excludedProjects = "/demo/project"
        let excluded = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertTrue(excluded.activities.isEmpty)
        XCTAssertFalse(try String(contentsOf: indexFile, encoding: .utf8).contains("PRIVATE-SENTINEL"))
    }

    func testIndexRebuildKeepsCleanedUpHistoryButNotExclusions() async throws {
        let secretFile = URL(fileURLWithPath: settings.codexHome).appendingPathComponent("sessions/2026/09/30/rollout-secret.jsonl")
        let liveFile = URL(fileURLWithPath: settings.codexHome).appendingPathComponent("sessions/2026/09/30/rollout-live.jsonl")
        try write([meta(), codex("2026-09-30T20:00:00Z", "user", "Cleaned-up Codex question")], to: codexFile)
        try write([["type": "session_meta", "payload": ["id": "secret-id", "cwd": "/demo/secret", "source": "desktop"]],
                   codex("2026-09-30T20:00:00Z", "user", "PRIVATE-SENTINEL")], to: secretFile)
        try write([meta("live-id"), codex("2026-09-30T20:00:00Z", "user", "Still on disk")], to: liveFile)
        try write([claude("2026-09-30T20:00:00Z", "user", "Cleaned-up Claude question")], to: claudeFile)
        let first = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(first.activities.count, 4)
        for file in [codexFile, secretFile, claudeFile] { try manager.removeItem(at: file) }
        settings.timeZoneID = "UTC"
        settings.excludedProjects = "/demo/secret"
        let rebuilt = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        // Cleaned-up transcripts keep their original day; the live file follows the new timezone.
        XCTAssertEqual(Set(rebuilt.activities.map(\.id)), ["same-id|2026-10-01", "claude:same-id|2026-10-01", "live-id|2026-09-30"])
        XCTAssertFalse(try String(contentsOf: indexFile, encoding: .utf8).contains("PRIVATE-SENTINEL"))
        settings.timeZoneID = "Asia/Shanghai"
        let again = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(Set(again.activities.map(\.id)), ["same-id|2026-10-01", "claude:same-id|2026-10-01", "live-id|2026-10-01"])
        settings.excludedProjects = ""
        let included = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertFalse(included.activities.contains { $0.threadID == "secret-id" })
        // Another source folder is another history; never carry entries across it.
        settings.codexHome = root.appendingPathComponent("other-codex").path
        let otherSource = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertTrue(otherSource.activities.isEmpty)
    }

    func testUnchangedScansSkipIndexWritesAndReplayLaterOnes() async throws {
        try write([meta(), codex("2026-09-30T00:00:00Z", "user", "First")], to: codexFile)
        let reader = JournalReader(settings: settings, indexURL: indexFile)
        _ = try await reader.scan()
        let written = try Data(contentsOf: indexFile)
        try manager.removeItem(at: indexFile)
        _ = try await reader.scan()
        XCTAssertFalse(manager.fileExists(atPath: indexFile.path))
        try written.write(to: indexFile)
        try append(try JSONSerialization.data(withJSONObject: codex("2026-09-30T01:00:00Z", "assistant", "Second")) + Data([10]), to: codexFile)
        let appended = try await reader.scan()
        XCTAssertEqual(appended.activities[0].messageCount, 2)
        XCTAssertFalse(try Data(contentsOf: indexFile) == written)
        // Changed scans persist before returning, even if the source is cleaned
        // up and the app restarts within the former five-minute throttle window.
        try manager.removeItem(at: codexFile)
        let replayed = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(replayed.activities[0].messageCount, 2)
    }

    func testLegacyV2IndexRetainsCleanedSourcesAcrossSettingsUpgrade() async throws {
        try write([meta(), codex("2026-09-30T20:00:00Z", "user", "Legacy retained question")], to: codexFile)
        try write([claude("2026-09-30T20:00:00Z", "user", "Legacy Claude question")], to: claudeFile)
        settings.excludedProjects = "/unrelated/private-project"
        let original = settings!
        // Literal legacy schema, not an index emitted by the new writer. Older
        // v2 files have no sourceSignature or retainedOnly fields.
        let stamp = ISO8601DateFormatter().date(from: "2026-09-30T20:00:00Z")!.timeIntervalSinceReferenceDate
        func legacyState(_ provider: String, text: String) -> [String: Any] {
            let activity: [String: Any] = ["provider": provider, "threadID": "same-id", "day": "2026-10-01",
                "title": "Legacy question", "cwd": "/demo/project", "firstActivity": stamp, "lastActivity": stamp,
                "messageIDs": [JournalClock.hash(text)], "excerpts": [["timestamp": stamp, "role": "user", "text": text]]]
            return ["offset": 1000, "modifiedAt": stamp, "threadID": "same-id", "cwd": "/demo/project",
                    "title": "Legacy question", "excluded": false, "days": ["2026-10-01": activity]]
        }
        var old: [String: Any] = ["version": 2,
            "signature": JournalClock.hash("\(settings.codexHome)|\(settings.claudeHome)|Asia/Shanghai|\(settings.excludedProjects)"),
            "files": ["codex|rollout-test.jsonl": legacyState("codex", text: "Legacy retained question"),
                      "claude|\(claudeFile.path)": legacyState("claude", text: "Legacy Claude question")]]
        let oldBytes = try JSONSerialization.data(withJSONObject: old)
        try oldBytes.write(to: indexFile)
        try manager.removeItem(at: codexFile); try manager.removeItem(at: claudeFile)
        settings.timeZoneID = "UTC"; settings.excludedProjects = "/new/exclusion"
        let migrated = try await JournalReader(settings: settings, indexURL: indexFile, previousSettings: original).scan()
        XCTAssertEqual(Set(migrated.activities.map(\.id)), ["same-id|2026-10-01", "claude:same-id|2026-10-01"])
        XCTAssertEqual(migrated.activities.reduce(0) { $0 + $1.messageCount }, 2)
        let migratedAgain = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(migratedAgain.activities.count, 2)

        // A cold timezone upgrade with the default exclusions also verifies the
        // legacy signature, without relying on a newly generated sourceSignature.
        settings = original; settings.excludedProjects = ""
        old["signature"] = JournalClock.hash("\(settings.codexHome)|\(settings.claudeHome)|Asia/Shanghai|")
        try JSONSerialization.data(withJSONObject: old).write(to: indexFile)
        settings.timeZoneID = "UTC"
        let coldUpgrade = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(coldUpgrade.activities.count, 2)
        // Changing roots must not import an unverifiable legacy history. Its
        // exact original bytes remain recoverable rather than being overwritten.
        try oldBytes.write(to: indexFile)
        settings.codexHome = root.appendingPathComponent("other-codex").path
        let other = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertTrue(other.activities.isEmpty)
        XCTAssertFalse(other.warnings.isEmpty)
        let preserved = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("index-preserved-v2-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: preserved[0]), oldBytes)
    }

    @MainActor func testConsecutiveTimezoneDaysMigrateByMessagesAcrossRestartAndBackup() async throws {
        settings.timeZoneID = "UTC"
        try write([meta(), codex("2026-09-30T23:30:00Z", "user", "First day"),
                   codex("2026-10-01T23:30:00Z", "user", "Second day")], to: codexFile)
        let directory = root.appendingPathComponent("store")
        let store = JournalStore(directory: directory, settings: settings)
        await store.refresh(on: Date())
        for activity in store.activities {
            store.update(activity, summary: "UTC note \(activity.day)", nextStep: "Check \(activity.day)", category: "研究", confirmed: true)
        }
        let utcBackup = try store.backupData()
        var changed = store.settings; changed.timeZoneID = "Asia/Shanghai"
        try store.saveSettings(changed)
        // Quit before refreshing: pending migration must itself be durable.
        let reopened = JournalStore(directory: directory, settings: settings)
        await reopened.refresh(on: Date())
        let first = try XCTUnwrap(reopened.activities.first { $0.day == "2026-10-01" })
        let second = try XCTUnwrap(reopened.activities.first { $0.day == "2026-10-02" })
        XCTAssertEqual(reopened.draft(for: first).displaySummary, "UTC note 2026-09-30")
        XCTAssertEqual(reopened.draft(for: second).displaySummary, "UTC note 2026-10-01")
        XCTAssertEqual(reopened.draft(for: first).displayNextStep, "Check 2026-09-30")
        XCTAssertTrue(reopened.draft(for: second).isConfirmed)
        XCTAssertNil(reopened.noticeMessage)
        let crossZone = JournalStore(directory: root.appendingPathComponent("cross-zone-restore"), settings: changed)
        try crossZone.restoreBackup(utcBackup)
        await crossZone.refresh(on: Date())
        XCTAssertEqual(crossZone.activities.count, 2)
        XCTAssertEqual(crossZone.draft(for: first).displaySummary, "UTC note 2026-09-30")
        XCTAssertEqual(crossZone.draft(for: second).displaySummary, "UTC note 2026-10-01")
        let backup = try reopened.backupData()
        let restored = JournalStore(directory: root.appendingPathComponent("restored"), settings: changed)
        try restored.restoreBackup(backup)
        changed.timeZoneID = "UTC"; try restored.saveSettings(changed)
        await restored.refresh(on: Date())
        for activity in restored.activities {
            XCTAssertEqual(restored.draft(for: activity).displaySummary, "UTC note \(activity.day)")
        }
    }

    @MainActor func testSplitTimezoneDayDoesNotMisattributeConfirmedNote() async throws {
        settings.timeZoneID = "UTC"
        try write([meta(), codex("2026-09-30T02:00:00Z", "user", "Morning"),
                   codex("2026-09-30T23:30:00Z", "user", "Night")], to: codexFile)
        let store = JournalStore(directory: root.appendingPathComponent("store"), settings: settings)
        await store.refresh(on: Date())
        store.update(store.activities[0], summary: "Both messages", nextStep: "", category: "研究", confirmed: true)
        var changed = store.settings; changed.timeZoneID = "Asia/Shanghai"
        try store.saveSettings(changed); await store.refresh(on: Date())
        XCTAssertEqual(store.activities.count, 2)
        XCTAssertTrue(store.activities.allSatisfy { store.draft(for: $0).displaySummary.isEmpty })
        XCTAssertNotNil(store.noticeMessage)
        changed.timeZoneID = "UTC"; try store.saveSettings(changed); await store.refresh(on: Date())
        XCTAssertEqual(store.draft(for: store.activities[0]).displaySummary, "Both messages")
    }

    @MainActor
    func testTimezoneChangeKeepsNotesVisibleWithoutOverwriting() async throws {
        let second = URL(fileURLWithPath: settings.codexHome).appendingPathComponent("sessions/2026/09/30/rollout-second.jsonl")
        try write([meta("moved"), codex("2026-09-30T20:00:00Z", "user", "Late question")], to: codexFile)
        try write([meta("conflict"), codex("2026-09-30T02:00:00Z", "user", "Morning question"),
                   codex("2026-09-30T20:00:00Z", "user", "Late question")], to: second)
        let store = JournalStore(directory: root.appendingPathComponent("store"), settings: settings)
        await store.refresh(on: Date())
        XCTAssertEqual(Set(store.activities.map(\.id)), ["moved|2026-10-01", "conflict|2026-09-30", "conflict|2026-10-01"])
        for activity in store.activities {
            store.update(activity, summary: "Note \(activity.id)", nextStep: "", category: "研究", confirmed: true)
        }
        var changed = store.settings
        changed.timeZoneID = "UTC"
        try store.saveSettings(changed)
        await store.refresh(on: Date())
        XCTAssertEqual(Set(store.activities.map(\.id)), ["moved|2026-09-30", "conflict|2026-09-30"])
        let moved = try XCTUnwrap(store.activities.first { $0.threadID == "moved" })
        XCTAssertEqual(store.draft(for: moved).displaySummary, "Note moved|2026-10-01")
        XCTAssertTrue(store.draft(for: moved).isConfirmed)
        // Both old days of this thread now fall on one UTC day; existing confirmed text wins.
        let conflict = try XCTUnwrap(store.activities.first { $0.threadID == "conflict" })
        XCTAssertEqual(store.draft(for: conflict).displaySummary, "Note conflict|2026-09-30")
        XCTAssertNotNil(store.noticeMessage)
        store.noticeMessage = nil
        changed.timeZoneID = "Asia/Shanghai"
        try store.saveSettings(changed)
        await store.refresh(on: Date())
        for activity in store.activities { XCTAssertEqual(store.draft(for: activity).displaySummary, "Note \(activity.id)") }
        XCTAssertNil(store.noticeMessage)
        let reopened = JournalStore(directory: root.appendingPathComponent("store"), settings: store.settings)
        XCTAssertEqual(reopened.drafts.count, 3)
    }

    func testLargeIncompleteLineDoesNotCorruptNextRecord() async throws {
        try write([meta()], to: codexFile)
        try append(Data(repeating: 65, count: 9 * 1024 * 1024), to: codexFile)
        let reader = JournalReader(settings: settings, indexURL: indexFile)
        let first = try await reader.scan()
        XCTAssertTrue(first.activities.isEmpty)
        try append(Data([10]), to: codexFile)
        let row = try JSONSerialization.data(withJSONObject: codex("2026-09-30T00:00:00Z", "user", "下一条记录"))
        try append(row + Data([10]), to: codexFile)
        let next = try await reader.scan()
        XCTAssertEqual(next.activities[0].excerpts[0].text, "下一条记录")
    }

    @MainActor
    func testDraftPersistenceDeduplicationAndMetadata() async throws {
        try write([meta(), codex("2026-09-30T00:00:00Z", "user", "设计")], to: codexFile)
        let mock = MockSummarizer()
        let store = JournalStore(directory: root.appendingPathComponent("store"), settings: settings, summarizer: mock)
        XCTAssertFalse(store.autoSummarize)
        await store.refresh(on: JournalClock(timeZoneID: "Asia/Shanghai").date("2026-09-30"))
        let activity = try XCTUnwrap(store.activities.first)
        store.generate([activity]); try await wait(store)
        XCTAssertEqual(store.draft(for: activity).summaryModel, "test-model")
        store.generate([activity]); try await wait(store)
        XCTAssertEqual(mock.calls, 1)
        store.update(activity, summary: "人工确认内容", nextStep: "继续", category: "学工", confirmed: true)
        store.generate([activity], force: true); try await wait(store)
        XCTAssertEqual(store.draft(for: activity).displaySummary, "人工确认内容")
        let reloaded = JournalStore(directory: root.appendingPathComponent("store"), settings: settings, summarizer: mock)
        XCTAssertTrue(reloaded.draft(for: activity).isConfirmed)
        XCTAssertEqual(reloaded.draft(for: activity).category, "学工")
        XCTAssertEqual(reloaded.draft(for: activity).displayNextStep, "继续")
    }

    @MainActor
    func testLegacyPlanDeskDraftMigrationAndBackup() throws {
        let activity = sample()
        let old: [String: Any] = ["version": 1, "autoSummarize": false, "drafts": [activity.id: [
            "summary": "旧模型草稿", "nextStep": "", "status": "进行中", "category": "课程", "fingerprint": activity.fingerprint,
            "editedSummary": "旧人工确认", "confirmedAt": 1.0, "confirmedFingerprint": activity.fingerprint]]]
        let file = root.appendingPathComponent("codex-journal.json")
        let bytes = try JSONSerialization.data(withJSONObject: old)
        try bytes.write(to: file)
        let store = JournalStore(directory: root, settings: settings, planDesk: true)
        XCTAssertEqual(store.draft(for: activity).displaySummary, "旧人工确认")
        XCTAssertTrue(store.draft(for: activity).isConfirmed)
        store.update(activity, summary: "新人工确认", nextStep: "", category: "课程", confirmed: true)
        let backups = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("journal-v1-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), bytes)
        XCTAssertEqual(JournalStore(directory: root, settings: settings, planDesk: true).draft(for: activity).displaySummary, "新人工确认")
    }

    @MainActor
    func testCorruptAndFutureVersionFilesAreNeverOverwritten() throws {
        for bytes in [Data("broken".utf8), Data("{\"version\":99,\"autoSummarize\":false,\"drafts\":{}}".utf8)] {
            let file = root.appendingPathComponent("journal.json")
            try bytes.write(to: file)
            let store = JournalStore(directory: root, settings: settings)
            XCTAssertFalse(store.canEdit)
            store.autoSummarize = true
            store.update(sample(), summary: "不可写", nextStep: "", category: "研究", confirmed: true)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    @MainActor
    func testCancellationCannotSaveLateResults() async throws {
        let mock = MockSummarizer(); mock.pause = 10_000_000_000
        let store = JournalStore(directory: root, settings: settings, summarizer: mock)
        store.generate([sample()])
        try await Task.sleep(nanoseconds: 20_000_000)
        store.cancelGeneration()
        try await wait(store)
        XCTAssertTrue(store.drafts.isEmpty)
    }

    func testSchemaValidationAndModelParsing() throws {
        let row = JournalSummaryRow(id: sample().id, summary: "讨论了方案。", nextStep: "", status: "待确认", category: "研究")
        XCTAssertNoThrow(try JournalCLISummarizer.validate([row], for: [sample()]))
        XCTAssertThrowsError(try JournalCLISummarizer.validate([], for: [sample()]))
        XCTAssertThrowsError(try JournalCLISummarizer.validate([row, row], for: [sample()]))
        XCTAssertEqual(JournalCLISummarizer.modelFromCodexLog("Codex CLI\nmodel: gpt-test\nreasoning: low"), "gpt-test")
        XCTAssertNil(JournalCLISummarizer.modelFromCodexLog("no model reported"))
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JournalSummaryResponse(entries: [row])))
        let data = try JSONSerialization.data(withJSONObject: ["type": "result", "is_error": false,
                                                             "structured_output": body, "modelUsage": ["claude-test": [:]]])
        let result = try JournalCLISummarizer.parseClaudeResult(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.model, "claude-test")
        XCTAssertThrowsError(try JournalCLISummarizer.parseClaudeResult("{\"is_error\":true}"))
    }

    func testSummaryArgumentsAreToolFreeAndEphemeral() {
        let codex = JournalCLISummarizer.arguments(engine: .codex, model: "gpt-test", schemaPath: "/tmp/schema", outputPath: "/tmp/result")
        XCTAssertTrue(codex.contains("--ephemeral")); XCTAssertTrue(codex.contains("--ignore-user-config"))
        XCTAssertTrue(codex.contains("read-only")); XCTAssertTrue(codex.contains("gpt-test"))
        let claude = JournalCLISummarizer.arguments(engine: .claude, model: "", schemaPath: "", outputPath: "")
        XCTAssertTrue(claude.contains("--restricted")); XCTAssertTrue(claude.contains("--no-session-persistence"))
        XCTAssertTrue(claude.contains("--safe-mode"))
        XCTAssertEqual(claude[claude.firstIndex(of: "--tools")! + 1], "")
        XCTAssertFalse(claude.contains("--resume")); XCTAssertFalse(claude.contains("--dangerously-skip-permissions"))
        let home = URL(fileURLWithPath: "/tmp/synthetic-home")
        var defaults = JournalSettings()
        defaults.claudeHome = home.appendingPathComponent(".claude").path
        let environment = JournalCLISummarizer.environment(settings: defaults, inherited: ["CLAUDECODE": "1"], home: home)
        XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(environment["CLAUDECODE"])
        defaults.claudeHome = "/tmp/synthetic-other-profile"
        XCTAssertEqual(JournalCLISummarizer.environment(settings: defaults, inherited: [:], home: home)["CLAUDE_CONFIG_DIR"], defaults.claudeHome)
    }

    @MainActor
    func testDemoReadsAndWritesNothingAndExportOmitsPaths() async throws {
        let store = JournalStore(directory: root.appendingPathComponent("no-write"), settings: settings, demo: true)
        XCTAssertEqual(Set(store.activities.map(\.source)), [.codex, .claude])
        await store.refresh(on: Date())
        store.autoSummarize = true
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("no-write").path))
        XCTAssertFalse(store.markdown(for: store.activities, title: "演示").contains("/demo/projects"))
    }

    func testOptionalLiveRead() async throws {
        guard ProcessInfo.processInfo.environment["AGENTJOURNAL_LIVE_READ"] == "1" else { throw XCTSkip("Opt-in local read only") }
        var real = JournalSettings(); real.timeZoneID = "Asia/Shanghai"
        let snapshot = try await JournalReader(settings: real, indexURL: indexFile).scan()
        for provider in JournalProvider.allCases {
            let items = snapshot.activities.filter { $0.source == provider }
            print("Local read: \(provider.label), \(Set(items.map(\.threadKey)).count) threads, \(items.count) daily records")
            XCTAssertFalse(items.isEmpty)
        }
    }

    func testOptionalLiveSummary() async throws {
        guard let engine = ProcessInfo.processInfo.environment["AGENTJOURNAL_LIVE_SUMMARY"],
              let provider = JournalProvider(rawValue: engine) else { throw XCTSkip("Opt-in model call with synthetic data only") }
        var real = JournalSettings(); real.timeZoneID = "Asia/Shanghai"; real.summaryEngine = provider
        if let model = ProcessInfo.processInfo.environment["AGENTJOURNAL_LIVE_MODEL"] { real.selectModel(model) }
        if let language = ProcessInfo.processInfo.environment["AGENTJOURNAL_LIVE_LANGUAGE"],
           let choice = JournalSummaryLanguage(rawValue: language) { real.summaryLanguage = choice }
        let result = try await JournalCLISummarizer().summarize([sample()], settings: real)
        XCTAssertEqual(result.entries.count, 1)
        print("Synthetic live summary: \(result.engine), model: \(result.model ?? "not reported")")
        XCTAssertNotNil(result.model)
        if real.summaryLanguage == .english {
            XCTAssertFalse(result.entries[0].summary.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) })
        }
    }

    func testModelCatalogAndPerEnginePreferences() throws {
        let cache = Data("""
        {"models":[{"slug":"hidden","visibility":"hide"},{"slug":"model-a","display_name":"Model A","visibility":"list"},{"slug":"model-a","visibility":"list"},{"slug":"model-b","visibility":"list"}]}
        """.utf8)
        XCTAssertEqual(JournalModelCatalog.parseCache(cache).map(\.id), ["model-a", "model-b"])
        XCTAssertEqual(JournalModelCatalog.parseRPC(["result": ["data": [
            ["model": "model-c", "displayName": "Model C", "hidden": false],
            ["id": "hidden", "hidden": true]
        ]]]).map(\.id), ["model-c"])
        var values = JournalSettings()
        values.selectModel("codex-choice")
        values.selectEngine(.claude)
        XCTAssertEqual(values.model, "")
        values.selectModel("haiku")
        values.selectEngine(.codex)
        XCTAssertEqual(values.model, "codex-choice")
        values.selectEngine(.claude)
        XCTAssertEqual(values.model, "haiku")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) as! [String: Any]
        legacy.removeValue(forKey: "codexModelChoice"); legacy.removeValue(forKey: "claudeModelChoice")
        let decoded = try JSONDecoder().decode(JournalSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.model, "haiku")
    }

    func testShareDateRangePrivacyAndPendingDrafts() {
        var first = sample(), second = sample(), third = sample(), outside = sample()
        first.title = "不应出现的私密标题"; first.cwd = "/private/demo/source"
        second.day = "2026-10-01"; second.lastActivity = first.lastActivity.addingTimeInterval(86400)
        third.provider = .claude
        outside.day = "2026-10-02"
        var edited = JournalDraft()
        edited.summary = "不应覆盖编辑后的文字"
        edited.editedSummary = "核对了报告 /Users/demo/private/report.md 并修正结论。"
        edited.confirmedAt = Date(); edited.category = "研究"
        let drafts = [first.id: edited]
        let report = JournalShareReport(activities: [outside, third, second, first], drafts: drafts,
                                       start: "2026-09-30", end: "2026-10-01")
        XCTAssertEqual(report.items.count, 3)
        XCTAssertEqual(report.threadCount, 2)
        XCTAssertEqual(report.activeDays, 2)
        XCTAssertEqual(report.codexCount, 1); XCTAssertEqual(report.claudeCount, 1)
        XCTAssertEqual(report.pending.count, 2)
        XCTAssertFalse(report.rows.contains { $0.title.contains("私密标题") || $0.summary.contains("/Users/") })
        XCTAssertTrue(report.rows.contains { $0.summary.contains("核对了报告 [本地路径]") })
        let cc = JournalShareReport(activities: report.items, drafts: drafts, start: report.start, end: report.end, provider: "claude")
        XCTAssertEqual(cc.items.count, 1)
        let confirmed = JournalShareReport(activities: report.items, drafts: drafts, start: report.start, end: report.end, confirmedOnly: true)
        XCTAssertEqual(confirmed.items.count, 1)
        let invalid = JournalShareReport(activities: report.items, drafts: drafts, start: report.end, end: report.start)
        XCTAssertTrue(invalid.items.isEmpty)
    }

    func testShareThreadSelectionExcludesEveryDayAndUpdatesCounts() {
        var first = sample(), next = sample(), cc = sample(), other = sample()
        first.title = "私密线程标题"
        next.day = "2026-10-01"; next.lastActivity = first.lastActivity.addingTimeInterval(86400)
        next.title = "最新线程标题"
        cc.provider = .claude; cc.title = "CC 同名 ID 的线程"
        other.threadID = "other-id"; other.day = next.day; other.lastActivity = next.lastActivity
        let activities = [first, next, cc, other]
        var longDraft = JournalDraft()
        longDraft.summary = String(repeating: "不应泄露的排除线程内容。", count: 180)
        let drafts = [first.id: longDraft]
        let all = JournalShareReport(activities: activities, drafts: drafts, start: first.day, end: next.day)
        XCTAssertEqual(all.threadCount, 3)
        XCTAssertEqual(all.threads.count, 3)
        XCTAssertEqual(all.items.count, 4)
        XCTAssertTrue(all.pageCount > 1)
        let option = all.threads.first { $0.id == first.threadKey }!
        XCTAssertEqual(option.recordCount, 2)
        XCTAssertEqual(option.start, first.day); XCTAssertEqual(option.end, next.day)
        XCTAssertEqual(option.title, next.title)

        let exclusions: Set<String> = [first.threadKey]
        let selected = JournalShareReport(activities: activities, drafts: drafts, start: first.day, end: next.day,
            excludedThreadKeys: exclusions)
        XCTAssertEqual(selected.threadCount, 2); XCTAssertEqual(selected.items.count, 2)
        XCTAssertEqual(selected.activeDays, 2)
        XCTAssertEqual(selected.codexCount, 1); XCTAssertEqual(selected.claudeCount, 1)
        XCTAssertEqual(selected.pending.count, 2); XCTAssertEqual(selected.pageCount, 1)
        XCTAssertFalse(selected.items.contains { $0.threadKey == first.threadKey })
        XCTAssertFalse(selected.rows.contains { $0.summary.contains("不应泄露") })
        XCTAssertEqual(Set(selected.rows.map(\.title)), Set(["线程 01", "线程 02"]))
        // Provider-qualified keys cannot hide a CC thread sharing the same raw ID.
        let onlyCC = JournalShareReport(activities: activities, drafts: drafts, start: first.day, end: next.day,
            provider: "claude", excludedThreadKeys: exclusions)
        XCTAssertEqual(onlyCC.items.map(\.id), [cc.id])
        let narrower = JournalShareReport(activities: activities, drafts: drafts, start: next.day, end: next.day,
            excludedThreadKeys: exclusions)
        XCTAssertEqual(narrower.items.map(\.id), [other.id])
        let none = JournalShareReport(activities: activities, drafts: drafts, start: first.day, end: next.day,
            excludedThreadKeys: Set(all.threads.map(\.id)))
        XCTAssertTrue(none.items.isEmpty); XCTAssertTrue(none.rows.isEmpty); XCTAssertTrue(none.pending.isEmpty)
        XCTAssertEqual(none.threadCount, 0); XCTAssertEqual(none.activeDays, 0)
        // Newly discovered threads are included without resetting earlier opt-outs.
        var arrived = sample(); arrived.threadID = "new-thread"
        let refreshed = JournalShareReport(activities: activities + [arrived], drafts: drafts,
            start: first.day, end: next.day, excludedThreadKeys: exclusions)
        XCTAssertTrue(refreshed.items.contains { $0.id == arrived.id })
        var confirmedDraft = longDraft; confirmedDraft.confirmedAt = Date()
        let confirmed = JournalShareReport(activities: activities, drafts: [first.id: confirmedDraft],
            start: first.day, end: next.day, confirmedOnly: true, excludedThreadKeys: exclusions)
        XCTAssertTrue(confirmed.items.isEmpty)
    }

    @MainActor
    func testShareTitleChoiceAndRepositoryCredit() throws {
        var excluded = sample(), kept = sample()
        excluded.threadID = "excluded"; excluded.title = "不可分享的线程名字"
        kept.title = "公开进展 /Users/demo/private/project"
        var note = JournalDraft(); note.editedSummary = "整理完公开文档。"
        let drafts = [kept.id: note]
        let hidden = JournalShareReport(activities: [excluded, kept], drafts: drafts,
            start: kept.day, end: kept.day, excludedThreadKeys: [excluded.threadKey], language: .english)
        let named = JournalShareReport(activities: [excluded, kept], drafts: drafts,
            start: kept.day, end: kept.day, showTitles: true, excludedThreadKeys: [excluded.threadKey], language: .english)
        XCTAssertEqual(hidden.rows.map(\.title), ["Thread 01"])
        XCTAssertEqual(named.rows.map(\.title), ["公开进展 [local path]"])
        XCTAssertEqual(hidden.items.map(\.id), named.items.map(\.id))
        XCTAssertFalse(named.rows.contains { $0.title.contains("不可分享") || $0.title.contains("/Users/") })
        XCTAssertEqual(JournalShareReport.repositoryURL.absoluteString, "https://github.com/DavidSi123456/AgentJournal")
        XCTAssertEqual(JournalText(.english)("来自 %@", JournalShareReport.repositoryURL.absoluteString),
            "From https://github.com/DavidSi123456/AgentJournal")
        let hiddenPNG = try JournalShareRenderer.png(hidden, page: 0)
        let namedPNG = try JournalShareRenderer.png(named, page: 0)
        XCTAssertEqual(Array(namedPNG.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertFalse(hiddenPNG == namedPNG)
        for key in ["先选择要分享的线程，再预览图片", "1 · 选择内容", "2 · 预览图片", "关闭后使用线程编号，不显示原始名字。",
                    "生成所选线程草稿", "返回选择", "预览图片", "选择要分享的线程", "全部选中", "全部取消",
                    "所选日期没有符合条件的线程。", "至少选择一个线程，才能预览图片。"] {
            XCTAssertFalse(JournalText(.english)(key) == key)
        }
        XCTAssertEqual(JournalText(.english)("%d / %d 个线程已选择", 2, 3), "2 / 3 threads selected")
    }

    @MainActor
    func testSharePaginationAndPNGRendering() throws {
        var item = sample()
        item.title = "共享工作日志"; item.day = "2026-09-30"
        var draft = JournalDraft()
        draft.summary = String(repeating: "完成了来源筛选、模型选择和每日进展归档。", count: 100)
        draft.category = "生活"
        let report = JournalShareReport(activities: [item], drafts: [item.id: draft], start: item.day, end: item.day)
        XCTAssertTrue(report.pageCount > 1)
        XCTAssertEqual((0..<report.pageCount).flatMap { report.page($0) }.map(\.summary).joined(), draft.summary)
        let png = try JournalShareRenderer.png(report, page: 0)
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let store = JournalStore(directory: root.appendingPathComponent("no-write"), settings: settings, demo: true)
        let days = store.activities.map(\.day).sorted()
        let demo = JournalShareReport(activities: store.activities, drafts: store.drafts, start: days.first!, end: days.last!, showTitles: true)
        if let path = ProcessInfo.processInfo.environment["AGENTJOURNAL_SHARE_PREVIEW_PATH"] {
            try JournalShareRenderer.png(demo, page: 0).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testLanguagePreferencesCompatibilityAndPromptPolicy() throws {
        var old = settings!
        old.language = "English"
        let bytes = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(JournalSettings.self, from: bytes)
        XCTAssertEqual(decoded.summaryLanguage, .english)
        XCTAssertNil(decoded.languageSetupComplete)
        XCTAssertNil(decoded.interfaceLanguageCode)
        var choices = decoded
        choices.uiLanguage = .chinese
        let english = try JournalCLISummarizer.prompt(for: [sample()], settings: choices)
        XCTAssertTrue(english.contains("Write every summary and nextStep in English."))
        choices.uiLanguage = .english; choices.summaryLanguage = .chinese
        let chinese = try JournalCLISummarizer.prompt(for: [sample()], settings: choices)
        XCTAssertTrue(chinese.contains("Write every summary and nextStep in Simplified Chinese."))
        choices.summaryLanguage = .automatic; choices.languageSetupComplete = true
        let automatic = try JournalCLISummarizer.prompt(for: [sample()], settings: choices)
        XCTAssertTrue(automatic.contains("For each entry independently"))
        XCTAssertTrue(automatic.contains("Prioritize human user messages"))
        XCTAssertTrue(automatic.contains("Different entries may use different languages"))
        let reloaded = try JSONDecoder().decode(JournalSettings.self, from: JSONEncoder().encode(choices))
        XCTAssertEqual(reloaded.uiLanguage, .english)
        XCTAssertEqual(reloaded.summaryLanguage, .automatic)
        XCTAssertEqual(reloaded.languageSetupComplete, true)
        XCTAssertNoThrow(try JournalCLISummarizer.validate([
            JournalSummaryRow(id: sample().id, summary: "Completed the verification.", nextStep: "", status: "已完成", category: "研究")
        ], for: [sample()]))
    }

    @MainActor
    func testFirstLaunchLanguageSelectionAndPreservedNotes() async throws {
        let mock = MockSummarizer()
        let folder = root.appendingPathComponent("onboarding")
        let store = JournalStore(directory: folder, settings: settings, summarizer: mock, requireLanguageSetup: true)
        XCTAssertTrue(store.needsLanguageSetup)
        store.autoSummarize = true
        store.generate([sample()])
        XCTAssertEqual(mock.calls, 0)
        var choice = settings!
        choice.uiLanguage = .english; choice.summaryLanguage = .automatic; choice.languageSetupComplete = true
        try store.completeOnboarding(choice)
        choice = store.settings
        XCTAssertFalse(store.needsLanguageSetup)
        store.generate([sample()]); try await wait(store)
        XCTAssertEqual(mock.calls, 1)
        store.update(sample(), summary: "Manually confirmed — 保留这段文字。", nextStep: "Keep this exact note.", category: "研究", confirmed: true)
        choice.uiLanguage = .chinese; choice.summaryLanguage = .english
        try store.saveSettings(choice)
        let savedURL = folder.appendingPathComponent("journal.json")
        let savedBytes = try Data(contentsOf: savedURL)
        let reopened = JournalStore(directory: folder, settings: settings, summarizer: mock, requireLanguageSetup: true)
        XCTAssertEqual(try Data(contentsOf: savedURL), savedBytes)
        XCTAssertFalse(reopened.needsLanguageSetup)
        XCTAssertEqual(reopened.settings.uiLanguage, .chinese)
        XCTAssertEqual(reopened.settings.summaryLanguage, .english)
        XCTAssertEqual(reopened.draft(for: sample()).displaySummary, "Manually confirmed — 保留这段文字。")
        XCTAssertTrue(reopened.draft(for: sample()).isConfirmed)
    }

    func testEnglishTranslationFormatsAndStableDateKeys() throws {
        let english = JournalText(.english)
        let chinese = JournalText(.chinese)
        XCTAssertEqual(english("应用语言"), "App language")
        XCTAssertEqual(english("生成内容语言"), "Summary language")
        XCTAssertEqual(english("保存修改"), "Save changes")
        XCTAssertEqual(english("AgentJournal · 两种工具，一份进展"), "AgentJournal · Two tools. One story of progress.")
        XCTAssertEqual(english("%d 个线程", 12), "12 threads")
        XCTAssertEqual(english("%@，%d 个线程", "Oct 1", 3), "Oct 1, 3 threads")
        XCTAssertEqual(english.category("学工"), "Student affairs")
        XCTAssertEqual(chinese.category("学工"), "学工")
        XCTAssertEqual(english.weekdayItems.map(\.label), ["M", "T", "W", "T", "F", "S", "S"])
        XCTAssertEqual(Set(english.weekdayItems.map(\.id)).count, 7)
        XCTAssertEqual(english.weekdayItems.map(\.id), chinese.weekdayItems.map(\.id))
        XCTAssertTrue(english.weekdayItems.allSatisfy { $0.id.hasPrefix("weekday-") })
        let clock = JournalClock(timeZoneID: "Asia/Shanghai"), date = clockDate()
        XCTAssertTrue(english.date(date, clock: clock, style: .month).contains("September"))
        XCTAssertTrue(chinese.date(date, clock: clock, style: .month).contains("9月"))
        XCTAssertEqual(clock.key(date), "2026-09-30")
        let pattern = try NSRegularExpression(pattern: "%[@df]")
        func fields(_ value: String) -> [String] {
            pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                String(value[Range($0.range, in: value)!])
            }
        }
        for (key, translated) in JournalText.english {
            XCTAssertEqual(fields(key), fields(translated))
            XCTAssertFalse(translated.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) })
        }
    }

    func testSelectedSourcesDoNotScanOtherProviderAndKeepRetainedHistory() async throws {
        try write([meta(), codex("2026-09-30T00:00:00Z", "user", "Codex selected")], to: codexFile)
        try write([claude("2026-09-30T00:00:00Z", "user", "UNSELECTED_CLAUDE_SENTINEL")], to: claudeFile)
        settings.sourceSelection = .codex
        let codexOnly = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(codexOnly.activities.count, 1)
        XCTAssertEqual(codexOnly.activities[0].source, .codex)
        XCTAssertFalse(try String(contentsOf: indexFile, encoding: .utf8).contains("UNSELECTED_CLAUDE_SENTINEL"))
        XCTAssertFalse(codexOnly.warnings.contains { $0.contains("Claude") })
        settings.sourceSelection = .both
        let both = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(both.activities.count, 2)
        try manager.removeItem(at: claudeFile)
        settings.sourceSelection = .codex
        let switched = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(switched.activities.count, 1)
        settings.sourceSelection = .claude
        let retained = try await JournalReader(settings: settings, indexURL: indexFile).scan()
        XCTAssertEqual(retained.activities.count, 1)
        XCTAssertEqual(retained.activities[0].source, .claude)
        XCTAssertEqual(retained.activities[0].excerpts[0].text, "UNSELECTED_CLAUDE_SENTINEL")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        old.removeValue(forKey: "sourceSelectionCode"); old.removeValue(forKey: "onboardingVersion")
        let upgraded = try JSONDecoder().decode(JournalSettings.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(upgraded.sourceSelection, .both)
        XCTAssertNil(upgraded.onboardingVersion)
    }

    @MainActor func testOnboardingBlocksPrivateScanAndModelsUntilComplete() async throws {
        try write([meta(), codex("2026-09-30T00:00:00Z", "user", "PRIVATE_FIRST_RUN_SENTINEL")], to: codexFile)
        let mock = MockSummarizer(), advisor = MockAgentAdvisor(), reporter = MockPeriodReporter()
        let directory = root.appendingPathComponent("first-run")
        let store = JournalStore(directory: directory, settings: settings, summarizer: mock,
            requireLanguageSetup: true, advisor: advisor, reporter: reporter)
        XCTAssertTrue(store.needsOnboarding)
        await store.refresh(on: Date())
        XCTAssertTrue(store.activities.isEmpty)
        XCTAssertFalse(manager.fileExists(atPath: directory.appendingPathComponent("index.json").path))
        store.generate([sample()]); store.analyzeProgress()
        store.generateReport(kind: .week, start: Date(), end: Date())
        XCTAssertEqual(mock.calls + advisor.calls + reporter.calls, 0)
        let demo = JournalOnboardingView.makeDemo(settings)
        XCTAssertTrue(demo.isDemo)
        XCTAssertFalse(demo.needsOnboarding)
        XCTAssertTrue(demo.settings.codexHome.hasPrefix("/demo/"))
        XCTAssertTrue(demo.settings.claudeHome.hasPrefix("/demo/"))
        XCTAssertTrue(demo.activities.allSatisfy { !$0.excerpts.contains { $0.text.contains("PRIVATE_FIRST_RUN_SENTINEL") } })
        demo.analyzeProgress()
        XCTAssertNotNil(demo.agentResult)
        XCTAssertThrowsError(try demo.backupData())
        var choice = settings!; choice.sourceSelection = .codex; choice.uiLanguage = .english
        try store.completeOnboarding(choice)
        XCTAssertFalse(store.needsOnboarding)
        XCTAssertFalse(store.autoSummarize)
        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertEqual(mock.calls + advisor.calls + reporter.calls, 0)
        let reopened = JournalStore(directory: directory, settings: settings, requireLanguageSetup: true)
        XCTAssertFalse(reopened.needsOnboarding)
        XCTAssertEqual(reopened.settings.sourceSelection, .codex)
        await reopened.refresh(on: Date())
        XCTAssertEqual(reopened.activities.count, 1)
    }

    @MainActor func testOnboardingUpgradePreservesNotesModelsAndExplicitPreferences() throws {
        let directory = root.appendingPathComponent("upgrade-tour")
        var existing = settings!; existing.languageSetupComplete = true
        existing.summaryLanguage = .english; existing.model = "synthetic-model"; existing.sourceSelection = .claude
        var draft = JournalDraft(); draft.editedSummary = "Keep my original note."
        let saved = JournalStore.Saved(drafts: [sample().id: draft], autoSummarize: true, settings: existing)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: directory, settings: settings, requireLanguageSetup: true)
        XCTAssertTrue(store.needsOnboarding)
        XCTAssertFalse(store.needsLanguageSetup)
        try store.completeOnboarding(store.settings)
        XCTAssertEqual(store.draft(for: sample()).displaySummary, "Keep my original note.")
        XCTAssertEqual(store.settings.model, "synthetic-model")
        XCTAssertEqual(store.settings.summaryLanguage, .english)
        XCTAssertEqual(store.settings.sourceSelection, .claude)
        XCTAssertTrue(store.autoSummarize) // preserve a prior explicit opt-in; fresh installs remain off
        for step in JournalTourStep.allCases {
            XCTAssertFalse(JournalText(.english)(step.title) == step.title)
            XCTAssertFalse(JournalText(.english)(step.detail) == step.detail)
        }
    }

    private func clockDate() -> Date { JournalClock(timeZoneID: "Asia/Shanghai").date("2026-09-30") }

    @MainActor
    func testEnglishSharingAndDemoWithoutModelCalls() throws {
        var english = settings!
        english.uiLanguage = .english; english.summaryLanguage = .english
        let store = JournalStore(directory: root.appendingPathComponent("english-demo"), settings: english, demo: true)
        XCTAssertTrue(store.activities.first!.title.contains("Plans"))
        let days = store.activities.map(\.day).sorted()
        let report = JournalShareReport(activities: store.activities, drafts: store.drafts,
            start: days.first!, end: days.last!, language: .english)
        XCTAssertEqual(report.rows.first!.title, "Thread 01")
        XCTAssertTrue(report.rows.allSatisfy { !$0.summary.contains("完成") })
        XCTAssertEqual(JournalShareReport.clean("See /Users/demo/private.md", language: .english), "See [local path]")
        let markdown = store.markdown(for: store.activities, title: "Daily progress")
        XCTAssertTrue(markdown.contains("Category: Life"))
        XCTAssertTrue(markdown.contains("Organized by thread · AgentJournal"))
        XCTAssertFalse(markdown.contains("ThreadJournal"))
        XCTAssertFalse(markdown.contains("分类"))
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("english-demo").path))
        let image = try JournalShareRenderer.png(report, page: 0)
        XCTAssertEqual(Array(image.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        if let path = ProcessInfo.processInfo.environment["AGENTJOURNAL_ENGLISH_PREVIEW_PATH"] {
            try image.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testOptionalLiveModelCatalog() async throws {
        guard ProcessInfo.processInfo.environment["AGENTJOURNAL_LIVE_MODELS"] == "1" else { throw XCTSkip("Opt-in CLI catalog only, no inference") }
        let models = try JournalModelCatalog.requestCodexModels(JournalSettings())
        XCTAssertFalse(models.isEmpty)
        print("Codex model/list: \(models.count) picker-visible models")
    }

    @MainActor
    func wait(_ store: JournalStore) async throws {
        for _ in 0..<300 {
            if !store.isSummarizing { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Summary did not settle")
    }
}
