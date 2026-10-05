import Foundation

final class MockPeriodReporter: JournalPeriodReporting {
    var calls = 0
    var pause: UInt64 = 0
    var fail = false
    func report(_ input: JournalPeriodInput, kind: JournalPeriodKind, settings: JournalSettings) async throws -> JournalPeriodReport {
        calls += 1
        if pause > 0 { try? await Task.sleep(nanoseconds: pause) }
        if fail { throw JournalError.message("synthetic report failure") }
        let record = input.records[0]
        return JournalPeriodReport(kind: kind, timeZoneID: settings.timeZoneID, languageCode: settings.summaryLanguage.rawValue,
            input: input, response: JournalPeriodResponse(overview: "Compared recorded progress only.", completed: [],
                ongoing: [JournalPeriodItem(text: "Discussion remains in progress.", evidenceIDs: [record.id])], blockers: [], nextSteps: []),
            engine: "test-reporter", model: "test-report-model")
    }
}

extension JournalTests {
    @MainActor func testPeriodReportPNGPagesAndBounds() throws {
        let activity = sample()
        var draft = JournalDraft(); draft.summary = "Recorded discussion."; draft.fingerprint = activity.fingerprint
        let input = JournalPeriodInput.build(activities: [activity], drafts: [activity.id: draft], start: "2026-09-01", end: "2026-09-30")
        var report = JournalPeriodReporter.demo(input, kind: .month, settings: settings)
        report.response.ongoing = (0..<8).map { JournalPeriodItem(text: "Outcome \($0): " + String(repeating: "a", count: 650), evidenceIDs: [activity.id]) }
        XCTAssertTrue(JournalPeriodCard.pageCount(report) > 1)
        for language in [JournalInterfaceLanguage.chinese, .english] {
            for page in 0..<JournalPeriodCard.pageCount(report) {
                let bytes = try JournalPeriodRenderer.png(report, page: page, language: language)
                XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            }
        }
        XCTAssertThrowsError(try JournalPeriodRenderer.png(report, page: -1, language: .english))
        XCTAssertThrowsError(try JournalPeriodRenderer.png(report, page: JournalPeriodCard.pageCount(report), language: .english))
    }
    func testConcurrentRequestReservationsRespectOneSharedLimit() throws {
        let file = root.appendingPathComponent("workflow.json")
        try JournalWorkflowFile.update(file) { $0.dailyCallLimit = 2 }
        let lock = NSLock()
        var succeeded = 0
        let defaults = settings!
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if (try? JournalWorkflowFile.reserve(file, kind: .summary, settings: defaults, itemCount: 1)) != nil {
                lock.lock(); succeeded += 1; lock.unlock()
            }
        }
        XCTAssertEqual(succeeded, 2)
        XCTAssertEqual(try JournalWorkflowFile.load(file).calls.count, 2)
    }
    @MainActor func testInterruptedRestoreRollsBackBeforeAnyModels() throws {
        let journal = root.appendingPathComponent("journal.json")
        let advice = root.appendingPathComponent("journal-advice.json")
        let workflow = root.appendingPathComponent("journal-workflow.json")
        let original = try JSONEncoder().encode(JournalStore.Saved(drafts: [:], autoSummarize: false, settings: settings))
        let id = UUID()
        let safety = root.appendingPathComponent("Restore Backups/\(id.uuidString)")
        try manager.createDirectory(at: safety, withIntermediateDirectories: true)
        try original.write(to: safety.appendingPathComponent("journal.json"))
        try Data("partially restored".utf8).write(to: journal)
        try JSONEncoder().encode(JournalWorkflowState()).write(to: workflow)
        let manifest = JournalBackupFile.RestoreManifest(backupID: id,
            files: ["journal.json", "journal-advice.json", "journal-workflow.json"], missing: ["journal-advice.json", "journal-workflow.json"])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent(".restore-transaction.json"))
        XCTAssertThrowsError(try JournalWorkflowFile.reserve(workflow, kind: .summary, settings: settings, itemCount: 1))
        let store = JournalStore(directory: root, settings: settings)
        XCTAssertEqual(try Data(contentsOf: journal), original)
        XCTAssertFalse(manager.fileExists(atPath: workflow.path)); XCTAssertFalse(manager.fileExists(atPath: advice.path))
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent(".restore-transaction.json").path))
        XCTAssertTrue(store.canEdit); XCTAssertFalse(store.autoSummarize)
        XCTAssertTrue(store.workflow.calls.isEmpty)
    }
    @MainActor private func waitForModel(_ store: JournalStore) async throws {
        for _ in 0..<300 {
            if !store.isModelBusy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Synthetic model task did not finish")
    }
    @MainActor func testInterruptedArchiveRestoreRollsBackOnlyImportedFiles() throws {
        let journal = root.appendingPathComponent("journal.json")
        let original = try JSONEncoder().encode(JournalStore.Saved(drafts: [:], autoSummarize: false, settings: settings))
        let id = UUID()
        let safety = root.appendingPathComponent("Restore Backups/\(id.uuidString)")
        try manager.createDirectory(at: safety, withIntermediateDirectories: true)
        try original.write(to: safety.appendingPathComponent("journal.json"))
        try Data("partially restored".utf8).write(to: journal)
        let folder = root.appendingPathComponent("Archive")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent("existing-history.json")
        let existingBytes = try JSONEncoder().encode(JournalArchive.Envelope())
        try existingBytes.write(to: existing)
        let name = "restore-\(id.uuidString)-0.json"
        let imported = folder.appendingPathComponent(name)
        try existingBytes.write(to: imported)
        let manifest = JournalBackupFile.RestoreManifest(version: 2, backupID: id,
            files: ["journal.json", "journal-advice.json", "journal-workflow.json"],
            missing: ["journal-advice.json", "journal-workflow.json"], newArchives: [name])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent(".restore-transaction.json"))
        let mock = MockSummarizer()
        let store = JournalStore(directory: root, settings: settings, summarizer: mock)
        XCTAssertEqual(try Data(contentsOf: journal), original)
        XCTAssertEqual(try Data(contentsOf: existing), existingBytes)
        XCTAssertFalse(manager.fileExists(atPath: imported.path))
        XCTAssertTrue(store.canEdit); XCTAssertEqual(mock.calls, 0)
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent(".restore-transaction.json").path))
    }
    func testThreadStatesAndFeedbackRespectNewProgress() throws {
        var activity = sample()
        var draft = JournalDraft(); draft.summary = "Foundation ready."; draft.nextStep = "Verify remaining branch."
        draft.fingerprint = activity.fingerprint
        let input = JournalAgentInput.build(activities: [activity], drafts: [activity.id: draft])
        let fingerprint = input.candidates[0].progressFingerprint
        let feedback = JournalAdviceFeedback(resultID: UUID(), threadKey: activity.threadKey,
            progressFingerprint: fingerprint, status: .handled)
        XCTAssertTrue(JournalAgentInput.build(activities: [activity], drafts: [activity.id: draft], feedback: [feedback]).candidates.isEmpty)
        var oldCandidate = input.candidates[0]; oldCandidate.records[0].summary = "Older unrelated progress."
        let olderFeedback = JournalAdviceFeedback(resultID: UUID(), threadKey: activity.threadKey,
            progressFingerprint: oldCandidate.progressFingerprint, status: .pending)
        XCTAssertTrue(JournalAgentInput.build(activities: [activity], drafts: [activity.id: draft], feedback: [feedback, olderFeedback]).candidates.isEmpty)
        var states = [activity.threadKey: JournalThreadState(status: .completed)]
        XCTAssertTrue(JournalAgentInput.build(activities: [activity], drafts: [activity.id: draft], threads: states).candidates.isEmpty)
        states[activity.threadKey]?.status = .paused
        XCTAssertTrue(JournalAgentInput.build(activities: [activity], drafts: [activity.id: draft], threads: states).candidates.isEmpty)
        states[activity.threadKey]?.status = .active
        XCTAssertEqual(JournalAgentInput.build(activities: [activity], drafts: [activity.id: draft], threads: states).candidates.count, 1)
        activity.append(JournalExcerpt(timestamp: activity.lastActivity.addingTimeInterval(300), role: "assistant", text: "New progress."))
        XCTAssertEqual(JournalAgentInput.build(activities: [activity], drafts: [activity.id: draft], feedback: [feedback]).candidates.count, 1)
        var waiting = feedback; waiting.status = .waiting
        var waitingInput = input; waitingInput.candidates[0].feedbackStatus = .waiting
        let row = JournalAgentSuggestion(threadKey: activity.threadKey, disposition: .advance, reason: "Ready.",
            nextAction: "Verify.", confidence: "medium", evidenceIDs: [activity.id])
        XCTAssertThrowsError(try JournalCLIAgentAdvisor.validate(JournalAgentResponse(overview: "Ready.", suggestions: [row]), input: waitingInput))
    }
    func testWorkflowPersistenceMergeAndSafety() throws {
        let file = root.appendingPathComponent("workflow.json")
        try JournalWorkflowFile.update(file) { $0.threads["one"] = JournalThreadState(status: .paused) }
        try JournalWorkflowFile.update(file) { $0.threads["two"] = JournalThreadState(status: .completed) }
        let state = try JournalWorkflowFile.load(file)
        XCTAssertEqual(state.threads.count, 2)
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try JournalWorkflowFile.update(file) { $0.dailyCallLimit = -1 })
        XCTAssertEqual(try Data(contentsOf: file), before)
        let linked = root.appendingPathComponent("linked.json")
        try manager.createSymbolicLink(at: linked, withDestinationURL: file)
        XCTAssertThrowsError(try JournalWorkflowFile.load(linked))
        XCTAssertThrowsError(try JournalWorkflowFile.update(linked) { $0.dailyCallLimit = 50 })
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testRequestBudgetsArePersistedAcrossInstancesAndDays() throws {
        let file = root.appendingPathComponent("workflow.json")
        try JournalWorkflowFile.update(file) { $0.dailyCallLimit = 2; $0.automaticCallLimit = 1 }
        let now = JournalClock(timeZoneID: settings.timeZoneID).date("2026-10-02").addingTimeInterval(86300)
        let first = try JournalWorkflowFile.reserve(file, kind: .automatic, settings: settings, itemCount: 4, now: now)
        XCTAssertEqual(first.0.calls.count, 1)
        XCTAssertThrowsError(try JournalWorkflowFile.reserve(file, kind: .automatic, settings: settings, itemCount: 4, now: now))
        try JournalWorkflowFile.update(file) { $0.calls[0].outcome = .failed }
        _ = try JournalWorkflowFile.reserve(file, kind: .advice, settings: settings, itemCount: 1, now: now)
        XCTAssertThrowsError(try JournalWorkflowFile.reserve(file, kind: .report, settings: settings, itemCount: 1, now: now))
        _ = try JournalWorkflowFile.reserve(file, kind: .report, settings: settings, itemCount: 1, now: now.addingTimeInterval(200))
        XCTAssertEqual(try JournalWorkflowFile.load(file).calls.count, 3)
    }
    @MainActor func testStoreFeedbackPersistsAndAdvisorModelIsIndependent() async throws {
        try write([meta(), codex("2026-09-30T00:00:00Z", "user", "Synthetic question")], to: codexFile)
        let advisor = MockAgentAdvisor()
        let store = JournalStore(directory: root, settings: settings, advisor: advisor)
        await store.refresh(on: sample().lastActivity)
        let activity = store.activities[0]
        store.update(activity, summary: "Foundation ready.", nextStep: "Verify.", category: "研究", confirmed: true)
        store.analyzeProgress(); try await waitForModel(store)
        let result = try XCTUnwrap(store.agentResult)
        store.setFeedback(.dismissed, suggestion: result.response.suggestions[0], result: result)
        XCTAssertTrue(store.agentInput.candidates.isEmpty)
        store.setThreadStatus(.completed, for: activity.threadKey)
        let reopened = JournalStore(directory: root, settings: settings)
        XCTAssertEqual(reopened.workflow.feedback.count, 1)
        XCTAssertEqual(reopened.threadStatus(activity.threadKey), .completed)
        var changed = store.settings; changed.advisorEngine = .claude; changed.advisorModel = "advisor-only"
        try store.saveSettings(changed)
        XCTAssertEqual(store.settings.summaryEngine, settings.summaryEngine)
        XCTAssertEqual(store.settings.model, settings.model)
        XCTAssertEqual(store.settings.adviceSettings.model, "advisor-only")
    }
    @MainActor func testRequestLimitPreventsAllModelKinds() async throws {
        try write([meta(), codex("2026-09-30T00:00:00Z", "user", "Synthetic question")], to: codexFile)
        let summary = MockSummarizer(), advisor = MockAgentAdvisor(), reporter = MockPeriodReporter()
        let store = JournalStore(directory: root, settings: settings, summarizer: summary, advisor: advisor, reporter: reporter)
        await store.refresh(on: sample().lastActivity)
        let activity = store.activities[0]
        store.update(activity, summary: "Recorded only.", nextStep: "Verify.", category: "研究", confirmed: false)
        try store.configureCalls(daily: 0, automatic: 0, paused: false, includeHistory: false)
        store.generate([activity], force: true); try await waitForModel(store)
        store.analyzeProgress(); try await waitForModel(store)
        store.generateReport(kind: .month, start: settingsClock.date("2026-09-01"), end: settingsClock.date("2026-09-30"))
        try await waitForModel(store)
        XCTAssertEqual(summary.calls + advisor.calls + reporter.calls, 0)
        XCTAssertTrue(store.workflow.calls.isEmpty)
    }
    private var settingsClock: JournalClock { JournalClock(timeZoneID: settings.timeZoneID) }
    @MainActor func testAutomaticScopeAndPauseNeverFillOldThreadByDefault() async throws {
        try write([meta(), codex("2026-09-28T00:00:00Z", "user", "Old question"), codex("2026-09-30T00:00:00Z", "user", "New question")], to: codexFile)
        let summary = MockSummarizer()
        let store = JournalStore(directory: root, settings: settings, summarizer: summary)
        await store.refresh(on: settingsClock.date("2026-09-30"))
        store.followThread("same-id")
        XCTAssertEqual(store.automaticPending.count, 1)
        try store.configureCalls(daily: 20, automatic: 5, paused: true, includeHistory: true)
        XCTAssertEqual(store.automaticPending.count, 2)
        store.autoSummarize = true
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(summary.calls, 0)
    }
    @MainActor func testConcurrentJournalEditDoesNotOverwriteOtherInstance() async throws {
        try write([meta(), codex("2026-09-30T00:00:00Z", "user", "Question")], to: codexFile)
        let one = JournalStore(directory: root, settings: settings)
        let two = JournalStore(directory: root, settings: settings)
        await one.refresh(on: sample().lastActivity); await two.refresh(on: sample().lastActivity)
        one.update(one.activities[0], summary: "First edit.", nextStep: "", category: "研究", confirmed: true)
        let bytes = try Data(contentsOf: root.appendingPathComponent("journal.json"))
        two.update(two.activities[0], summary: "Second edit.", nextStep: "", category: "生活", confirmed: true)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("journal.json")), bytes)
        XCTAssertFalse(two.canEdit)
        XCTAssertNotNil(two.errorMessage)
        let backup = try JournalBackupFile.decode(two.backupData())
        let saved = try JSONDecoder().decode(JournalStore.Saved.self, from: backup.journal)
        XCTAssertEqual(saved.drafts[two.activities[0].id]?.displaySummary, "Second edit.")
    }
    func testPeriodReportsAreBoundedAndEvidenceValidated() throws {
        var activity = sample(); activity.cwd = "PRIVATE_PATH"; activity.excerpts[0].text = "PRIVATE_RAW_TRANSCRIPT"
        var draft = JournalDraft(); draft.summary = "Discussed the first approach."; draft.nextStep = "Run the experiment."; draft.fingerprint = activity.fingerprint
        let input = JournalPeriodInput.build(activities: [activity], drafts: [activity.id: draft], start: "2026-09-01", end: "2026-09-30")
        let prompt = try JournalPeriodReporter.prompt(input, settings: settings)
        XCTAssertFalse(prompt.contains("PRIVATE_PATH")); XCTAssertFalse(prompt.contains("PRIVATE_RAW_TRANSCRIPT"))
        XCTAssertTrue(prompt.contains("Newer notes supersede older next steps"))
        var report = JournalPeriodReporter.demo(input, kind: .month, settings: settings)
        XCTAssertNoThrow(try JournalPeriodReporter.validate(report))
        report.response.ongoing[0].evidenceIDs = ["nonexistent"]
        XCTAssertThrowsError(try JournalPeriodReporter.validate(report))
        report = JournalPeriodReporter.demo(input, kind: .month, settings: settings)
        report.input.start = "2026-09-31"
        XCTAssertThrowsError(try JournalPeriodReporter.validate(report))
        report = JournalPeriodReporter.demo(input, kind: .month, settings: settings)
        report.input.records[0].nextStep = ""
        XCTAssertThrowsError(try JournalPeriodReporter.validate(report))
        let states = [activity.threadKey: JournalThreadState(status: .completed, updatedAt: activity.lastActivity)]
        let closedInput = JournalPeriodInput.build(activities: [activity], drafts: [activity.id: draft], start: "2026-09-01", end: "2026-09-30", threads: states, timeZoneID: settings.timeZoneID)
        XCTAssertEqual(closedInput.records[0].userThreadStatus, .completed)
        var closedReport = JournalPeriodReporter.demo(closedInput, kind: .month, settings: settings)
        XCTAssertTrue(closedReport.response.nextSteps.isEmpty)
        XCTAssertNoThrow(try JournalPeriodReporter.validate(closedReport))
        closedReport.input.records[0].statusDay = "2026-10-02"
        XCTAssertThrowsError(try JournalPeriodReporter.validate(closedReport))
        closedReport.input.records[0].statusDay = nil
        XCTAssertThrowsError(try JournalPeriodReporter.validate(closedReport))
        closedReport = JournalPeriodReporter.demo(closedInput, kind: .month, settings: settings)
        closedReport.response.nextSteps = [JournalPeriodItem(text: draft.nextStep, evidenceIDs: [activity.id])]
        XCTAssertThrowsError(try JournalPeriodReporter.validate(closedReport))
        let futureState = [activity.threadKey: JournalThreadState(status: .completed, updatedAt: settingsClock.date("2026-10-02"))]
        XCTAssertNil(JournalPeriodInput.build(activities: [activity], drafts: [activity.id: draft], start: "2026-09-01", end: "2026-09-30", threads: futureState, timeZoneID: settings.timeZoneID).records[0].userThreadStatus)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(JournalPeriodReporter.schema.utf8)))
        var many: [JournalActivity] = [], drafts: [String: JournalDraft] = [:]
        for index in 0..<125 { var item = activity; item.threadID = "thread-\(index)"; many.append(item); drafts[item.id] = draft }
        let bounded = JournalPeriodInput.build(activities: many, drafts: drafts, start: "2026-09-01", end: "2026-09-30")
        XCTAssertEqual(bounded.records.count, 120); XCTAssertEqual(bounded.totalRecords, 125)
    }
    @MainActor func testReportPersistenceCancellationAndFailure() async throws {
        try write([meta(), codex("2026-09-30T00:00:00Z", "user", "Question")], to: codexFile)
        let reporter = MockPeriodReporter()
        let store = JournalStore(directory: root, settings: settings, reporter: reporter)
        await store.refresh(on: sample().lastActivity)
        store.update(store.activities[0], summary: "Recorded discussion.", nextStep: "Verify.", category: "研究", confirmed: true)
        let start = settingsClock.date("2026-09-01"), end = settingsClock.date("2026-09-30")
        store.generateReport(kind: .month, start: start, end: end); try await waitForModel(store)
        XCTAssertEqual(store.workflow.reports.count, 1)
        XCTAssertEqual(JournalStore(directory: root, settings: settings).workflow.reports.count, 1)
        reporter.pause = 100_000_000
        store.generateReport(kind: .month, start: start, end: end)
        try await Task.sleep(nanoseconds: 20_000_000); store.cancelReport(); try await waitForModel(store)
        XCTAssertEqual(store.workflow.reports.count, 1)
        XCTAssertEqual(store.todayCalls.first?.outcome, .cancelled)
        reporter.pause = 0; reporter.fail = true
        store.generateReport(kind: .month, start: start, end: end); try await waitForModel(store)
        XCTAssertEqual(store.workflow.reports.count, 1); XCTAssertNotNil(store.reportError)
        XCTAssertEqual(store.todayCalls.first?.outcome, .failed)
    }
    @MainActor func testBackupRestoresNotesStatesAndHistoryWithoutRawChatsOrCalls() async throws {
        try write([meta(), codex("2026-09-30T00:00:00Z", "user", "Synthetic question"),
                   codex("2026-09-30T00:01:00Z", "assistant", "RAW_NEVER_IN_BACKUP")], to: codexFile)
        let advisor = MockAgentAdvisor(), reporter = MockPeriodReporter()
        let store = JournalStore(directory: root, settings: settings, advisor: advisor, reporter: reporter)
        await store.refresh(on: sample().lastActivity)
        let activity = store.activities[0]
        store.update(activity, summary: "Original note.", nextStep: "Verify.", category: "研究", confirmed: true)
        store.analyzeProgress(); try await waitForModel(store)
        let result = try XCTUnwrap(store.agentResult)
        store.setFeedback(.handled, suggestion: result.response.suggestions[0], result: result)
        store.setThreadStatus(.paused, for: activity.threadKey)
        let backupData = try store.backupData()
        let backup = try JournalBackupFile.decode(backupData)
        XCTAssertTrue(backup.workflow.library.allSatisfy { $0.excerpts.isEmpty })
        XCTAssertFalse(String(decoding: backupData, as: UTF8.self).contains("RAW_NEVER_IN_BACKUP"))
        store.update(activity, summary: "Later note.", nextStep: "", category: "生活", confirmed: true)
        store.generateReport(kind: .month, start: settingsClock.date("2026-09-01"), end: settingsClock.date("2026-09-30")); try await waitForModel(store)
        let before = try Data(contentsOf: root.appendingPathComponent("journal.json"))
        let safety = try store.restoreBackup(backupData)
        XCTAssertEqual(try Data(contentsOf: safety.appendingPathComponent("journal.json")), before)
        let preRestore = try JournalBackupFile.decode(Data(contentsOf: safety.appendingPathComponent("AgentJournal-PreRestore.json")))
        let previousJournal = try JSONDecoder().decode(JournalStore.Saved.self, from: preRestore.journal)
        XCTAssertEqual(previousJournal.drafts[activity.id]?.displaySummary, "Later note.")
        XCTAssertEqual(store.draft(for: activity).displaySummary, "Original note.")
        XCTAssertEqual(store.threadStatus(activity.threadKey), .paused)
        XCTAssertEqual(store.agentHistory.count, 1); XCTAssertEqual(store.workflow.feedback.count, 1)
        XCTAssertEqual(store.workflow.calls.count, 2) // restoring an old backup cannot reset today's requests
        XCTAssertFalse(store.autoSummarize); XCTAssertTrue(store.workflow.automaticPaused)
        XCTAssertEqual(advisor.calls, 1); XCTAssertEqual(reporter.calls, 1)
        let reopened = JournalStore(directory: root, settings: settings)
        await reopened.refresh(on: sample().lastActivity)
        XCTAssertEqual(reopened.draft(for: activity).displaySummary, "Original note.")
    }
    @MainActor func testInvalidBackupAndCorruptWorkflowNeverOverwriteOriginals() async throws {
        let clean = JournalStore(directory: root.appendingPathComponent("clean"), settings: settings)
        let backup = try clean.backupData()
        let bad = Data("{\"version\":999}".utf8)
        let file = root.appendingPathComponent("journal-workflow.json")
        try bad.write(to: file)
        let summary = MockSummarizer()
        let broken = JournalStore(directory: root, settings: settings, summarizer: summary)
        XCTAssertNotNil(broken.workflowError)
        XCTAssertThrowsError(try broken.restoreBackup(Data("bad backup".utf8)))
        XCTAssertEqual(try Data(contentsOf: file), bad)
        let safety = try broken.restoreBackup(backup)
        XCTAssertEqual(try Data(contentsOf: safety.appendingPathComponent("journal-workflow.json")), bad)
        XCTAssertNil(broken.workflowError); XCTAssertEqual(summary.calls, 0)
    }
    @MainActor func testOversizedHistoriesAreArchivedNotDeleted() async throws {
        let activity = sample()
        var draft = JournalDraft(); draft.summary = String(repeating: "Recorded progress. ", count: 30); draft.nextStep = "Verify."
        draft.fingerprint = activity.fingerprint
        let input = JournalAgentInput.build(activities: [activity], drafts: [activity.id: draft], now: activity.lastActivity.addingTimeInterval(3600))
        let demo = JournalCLIAgentAdvisor.demo(input, settings: settings)
        let advice = root.appendingPathComponent("journal-advice.json")
        var saved: [JournalAgentResult] = []
        for index in 0..<40 {
            let result = JournalAgentResult(response: demo.response, input: input, engine: "test", model: nil,
                generatedAt: activity.lastActivity.addingTimeInterval(Double(index * 60)), timeZoneID: settings.timeZoneID)
            saved.append(result)
            _ = try JournalAgentHistoryFile.save([result], to: advice, archiveLimit: 20_000)
        }
        let live = try JournalAgentHistoryFile.load(advice)
        XCTAssertTrue(live.count < saved.count && live.count > 0)
        XCTAssertTrue(try Data(contentsOf: advice).count <= 20_000)
        XCTAssertEqual(live.first?.id, saved.last?.id)
        let archive = JournalArchive.directory(beside: advice)
        XCTAssertEqual(JournalArchive.summary(in: archive).advice + live.count, saved.count)
        for file in try manager.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil) {
            let mode = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600)
        }

        let workflow = root.appendingPathComponent("journal-workflow.json")
        let period = JournalPeriodInput.build(activities: [activity], drafts: [activity.id: draft], start: "2026-09-01", end: "2026-09-30")
        let now = activity.lastActivity.addingTimeInterval(40 * 86400)
        var reports: [JournalPeriodReport] = []
        for index in 0..<20 {
            var report = JournalPeriodReporter.demo(period, kind: .month, settings: settings)
            report.createdAt = activity.lastActivity.addingTimeInterval(Double(index * 60))
            reports.append(report)
        }
        let old = JournalCallRecord(createdAt: activity.lastActivity, kind: .report, engine: .codex, model: "", itemCount: 1)
        let recent = JournalCallRecord(createdAt: now, kind: .summary, engine: .codex, model: "", itemCount: 1)
        let state = try JournalWorkflowFile.update(workflow, now: now, archiveLimit: 20_000) {
            $0.reports = reports; $0.calls = [old, recent]; $0.threads["kept"] = JournalThreadState(status: .waiting)
        }
        XCTAssertTrue(state.reports.count < reports.count)
        XCTAssertEqual(state.reports.last?.id, reports.last?.id)
        XCTAssertEqual(state.calls.map(\.id), [recent.id])
        XCTAssertEqual(state.threads["kept"]?.status, .waiting)
        XCTAssertEqual(try JournalWorkflowFile.load(workflow).reports.count, state.reports.count)
        let summary = JournalArchive.summary(in: archive)
        XCTAssertEqual(summary.reports + state.reports.count, reports.count)
        XCTAssertEqual(summary.calls, 1)
        let store = JournalStore(directory: root, settings: settings)
        await store.loadArchivedHistory()
        XCTAssertEqual(Set(store.agentHistory.map(\.id)), Set(saved.map(\.id)))
        XCTAssertEqual(Set(store.savedReports.map(\.id)), Set(reports.map(\.id)))
        let backupData = try store.backupData()
        let backup = try JournalBackupFile.decode(backupData)
        XCTAssertEqual(backup.version, 3)
        XCTAssertEqual(Set(JournalArchive.advice(live: backup.advice, archives: backup.archives ?? []).map(\.id)), Set(saved.map(\.id)))
        XCTAssertEqual(Set(JournalArchive.reports(live: backup.workflow.reports, archives: backup.archives ?? []).map(\.id)), Set(reports.map(\.id)))
        XCTAssertEqual(Set(backup.workflow.calls.map(\.id) + (backup.archives ?? []).flatMap(\.calls).map(\.id)), [old.id, recent.id])
        let restoredRoot = root.appendingPathComponent("restored")
        let restored = JournalStore(directory: restoredRoot, settings: settings)
        try restored.restoreBackup(backupData)
        XCTAssertEqual(restored.agentHistory.count, 40)
        XCTAssertEqual(restored.savedReports.count, 20)
        let restoredFolder = restoredRoot.appendingPathComponent("Archive")
        let importedCount = try manager.contentsOfDirectory(at: restoredFolder, includingPropertiesForKeys: nil).count
        try restored.restoreBackup(backupData)
        XCTAssertEqual(try manager.contentsOfDirectory(at: restoredFolder, includingPropertiesForKeys: nil).count, importedCount)
        let reopened = JournalStore(directory: restoredRoot, settings: settings)
        await reopened.loadArchivedHistory()
        XCTAssertEqual(Set(reopened.agentHistory.map(\.id)), Set(saved.map(\.id)))
        XCTAssertEqual(Set(reopened.savedReports.map(\.id)), Set(reports.map(\.id)))
        let exportedAgain = try JournalBackupFile.decode(reopened.backupData())
        XCTAssertEqual(JournalArchive.advice(live: exportedAgain.advice, archives: exportedAgain.archives ?? []).count, 40)
        for file in try manager.contentsOfDirectory(at: restoredFolder, includingPropertiesForKeys: nil) {
            XCTAssertEqual(try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        }
        XCTAssertTrue(JournalClock.isDayKey("2026-09-30"))
        for invalid in ["2026-9-30", "2026-09-30\n", "２０２６-09-30", "2026/09/30"] { XCTAssertFalse(JournalClock.isDayKey(invalid)) }
    }
    @MainActor func testArchiveBackupValidationAndLegacyCompatibility() async throws {
        let store = JournalStore(directory: root, settings: settings)
        var legacy = try JournalBackupFile.decode(store.backupData())
        legacy.version = 1; legacy.archives = nil; legacy.progress = nil
        let legacyData = try JSONEncoder().encode(legacy)
        XCTAssertNoThrow(try store.restoreBackup(legacyData))
        let before = try Data(contentsOf: root.appendingPathComponent("journal.json"))
        var invalid = legacy; invalid.version = 2
        invalid.archives = [JournalArchive.Envelope(version: 999)]
        XCTAssertThrowsError(try store.restoreBackup(JSONEncoder().encode(invalid)))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("journal.json")), before)
        let folder = root.appendingPathComponent("Archive")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let corrupt = folder.appendingPathComponent("broken.json")
        let corruptBytes = Data("invalid archived data".utf8)
        try corruptBytes.write(to: corrupt)
        XCTAssertThrowsError(try store.backupData()) // never export a partial "full" backup
        let reopened = JournalStore(directory: root, settings: settings)
        await reopened.loadArchivedHistory()
        XCTAssertNotNil(reopened.archiveHistoryError)
        XCTAssertFalse(reopened.canManageWorkflow)
        XCTAssertEqual(try Data(contentsOf: corrupt), corruptBytes)
    }
    func testArchivedCallsStillRespectDailyRequestLimit() throws {
        let url = root.appendingPathComponent("journal-workflow.json")
        let call = JournalCallRecord(kind: .advice, engine: .codex, model: "", itemCount: 1)
        try JournalArchive.write(JournalArchive.Envelope(calls: [call]), beside: url)
        _ = try JournalWorkflowFile.update(url) { $0.dailyCallLimit = 1 }
        XCTAssertThrowsError(try JournalWorkflowFile.reserve(url, kind: .summary, settings: settings, itemCount: 1))
        XCTAssertEqual(try JournalWorkflowFile.load(url).calls.count, 0)
    }
    @MainActor func testWorkflowDemoAndEnglishRemainModelFree() throws {
        var defaults = settings!; defaults.uiLanguage = .english
        let demoRoot = root.appendingPathComponent("demo")
        let store = JournalStore(directory: demoRoot, settings: defaults, demo: true)
        store.setThreadStatus(.paused, for: store.activities[0].threadKey)
        store.generateReport(kind: .month, start: settingsClock.date("2026-01-01"), end: settingsClock.date("2027-01-01"))
        XCTAssertNotNil(store.reportResult)
        XCTAssertFalse(manager.fileExists(atPath: demoRoot.path))
        XCTAssertThrowsError(try store.backupData())
        for key in ["调用控制", "线程状态", "建议反馈", "周报／月报", "备份恢复", "已处理", "不采纳"] {
            XCTAssertFalse(JournalText(.english)(key) == key)
        }
    }
}
