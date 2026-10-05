import Foundation
import SwiftUI

final class MockProgressDrafter: JournalProgressDrafting {
    var calls = 0
    var pause: UInt64 = 0
    var fail = false
    var responseOverride: JournalProgressResponse?
    var received: JournalProgressInput?
    func draft(_ input: JournalProgressInput, settings: JournalSettings) async throws -> JournalProgressGeneration {
        calls += 1; received = input
        if pause > 0 { try? await Task.sleep(nanoseconds: pause) }
        if fail { throw JournalError.message("synthetic task failure") }
        var result = JournalCLIProgressDrafter.demo(input, settings: settings)
        if let responseOverride { result.response = responseOverride }
        return result
    }
}

extension JournalTests {
    private func progressPlan() -> JournalThreadPlan {
        let date = Date(timeIntervalSince1970: 1791158400)
        return JournalThreadPlan(goal: "Synthetic finite goal", kind: .fixed, scopeConfirmed: true, nodes: [
            JournalTaskNode(id: "root", title: "Deliverable"),
            JournalTaskNode(id: "one", parentID: "root", title: "Implemented", status: .completed, confirmedAt: date, userEdited: true),
            JournalTaskNode(id: "two", parentID: "root", title: "Verify", status: .needsConfirmation)
        ])
    }
    private func progressSnapshot(_ plan: JournalThreadPlan, key: String = "synthetic-thread", day: String = "2026-10-05") -> JournalProgressSnapshot {
        let clock = JournalClock(timeZoneID: settings.timeZoneID)
        return JournalProgressSnapshot(threadKey: key, createdAt: clock.date(day).addingTimeInterval(10 * 3600),
            day: day, timeZoneID: settings.timeZoneID, reason: .edit, plan: plan)
    }
    @MainActor private func seedProgressStore(_ mock: MockProgressDrafter,
        summarizer: JournalSummarizing = MockSummarizer(), advisor: JournalAgentAdvising = MockAgentAdvisor(),
        reporter: JournalPeriodReporting = MockPeriodReporter()) async throws -> JournalStore {
        let activity = sample()
        var metadata = activity; metadata.excerpts = []
        var note = JournalDraft(); note.summary = "Implemented the prototype. Verification remains."
        note.nextStep = "Verify the prototype."; note.fingerprint = activity.fingerprint
        try JSONEncoder().encode(JournalStore.Saved(drafts: [activity.id: note], autoSummarize: false, settings: settings))
            .write(to: root.appendingPathComponent("journal.json"))
        try JournalWorkflowFile.update(root.appendingPathComponent("journal-workflow.json")) { $0.library = [metadata] }
        let store = JournalStore(directory: root, settings: settings, summarizer: summarizer,
            advisor: advisor, reporter: reporter, progressDrafter: mock)
        await store.refresh(on: activity.firstActivity)
        return store
    }
    @MainActor private func waitForTaskTree(_ store: JournalStore) async {
        for _ in 0..<300 {
            if !store.isDraftingTasks { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Synthetic task tree generation did not finish")
    }
    func testTaskTreeCountsConfirmedLeavesAndResearchStages() throws {
        var plan = progressPlan()
        try JournalProgressFile.validate(plan, threadKey: "synthetic-thread")
        XCTAssertEqual(plan.leaves.count, 2); XCTAssertEqual(plan.completedCount, 1)
        XCTAssertEqual(plan.fraction, 0.5); XCTAssertEqual(plan.pendingCount, 1)
        XCTAssertEqual(plan.orderedNodes.map(\.depth), [0, 1, 1])
        // Parent status never inflates completion. Unconfirmed reports contribute zero.
        plan.nodes[0].status = .completed; plan.nodes[0].confirmedAt = Date(); plan.nodes[0].userEdited = true
        XCTAssertEqual(plan.completedCount, 1)
        plan.scopeConfirmed = false; XCTAssertNil(plan.fraction)
        plan.scopeConfirmed = true; plan.kind = .research; plan.stage = "Evaluate hypotheses"
        XCTAssertNil(plan.fraction); XCTAssertEqual(plan.stage, "Evaluate hypotheses")
        plan.nodes = []; plan.kind = .fixed; XCTAssertNil(plan.fraction)
    }
    func testTaskTreeRejectsCyclesInvalidEvidenceAndForgedCompletion() throws {
        var plan = progressPlan()
        plan.nodes[0].parentID = "two"
        XCTAssertThrowsError(try JournalProgressFile.validate(plan, threadKey: "synthetic-thread"))
        plan = progressPlan(); plan.nodes[1].confirmedAt = nil
        XCTAssertThrowsError(try JournalProgressFile.validate(plan, threadKey: "synthetic-thread"))
        plan = progressPlan(); plan.nodes[1].userEdited = false
        XCTAssertThrowsError(try JournalProgressFile.validate(plan, threadKey: "synthetic-thread"))
        plan = progressPlan(); plan.nodes[1].evidence = [JournalProgressEvidence(id: "other|2026-10-05", day: "2026-10-05", summary: "private", nextStep: "", freshness: "current")]
        XCTAssertThrowsError(try JournalProgressFile.validate(plan, threadKey: "synthetic-thread"))
        plan = progressPlan(); plan.nodes.append(plan.nodes[0])
        XCTAssertThrowsError(try JournalProgressFile.validate(plan, threadKey: "synthetic-thread"))
        plan = progressPlan(); plan.nodes = (0..<6).map { JournalTaskNode(id: "\($0)", parentID: $0 == 0 ? nil : "\($0 - 1)", title: "Level \($0)") }
        XCTAssertThrowsError(try JournalProgressFile.validate(plan, threadKey: "synthetic-thread"))
    }
    func testTaskTreeInputKeepsBeginningRecentNotesAndProviderIsolation() throws {
        let clock = JournalClock(timeZoneID: settings.timeZoneID)
        var activities: [JournalActivity] = [], drafts: [String: JournalDraft] = [:]
        for index in 0..<75 {
            let date = clock.calendar.date(byAdding: .day, value: index, to: clock.date("2026-07-01"))!
            var activity = sample(); activity.day = clock.key(date); activity.firstActivity = date; activity.lastActivity = date
            var draft = JournalDraft(); draft.summary = "Note \(index) " + String(repeating: "s", count: 1500)
            draft.nextStep = String(repeating: "n", count: 800); draft.fingerprint = index == 3 ? "old" : activity.fingerprint
            activities.append(activity); drafts[activity.id] = draft
        }
        var other = activities.last!; other.provider = .claude; activities.append(other)
        drafts[other.id] = JournalDraft(summary: "Do not read another provider's thread.")
        let input = JournalProgressInput.build(key: sample().threadKey, activities: activities, drafts: drafts, existing: nil)
        XCTAssertEqual(input.coverage.total, 75); XCTAssertEqual(input.records.count, 60)
        XCTAssertEqual(input.coverage.outdated, 1); XCTAssertEqual(input.records.first?.day, "2026-07-01")
        XCTAssertEqual(input.records[7].day, activities[7].day)
        XCTAssertEqual(input.records[8].day, activities[23].day)
        XCTAssertEqual(input.records.last?.day, activities[74].day)
        XCTAssertTrue(input.records.allSatisfy { $0.summary.count <= 1200 && $0.nextStep.count <= 600 && !$0.id.hasPrefix("claude:") })
        let prompt = try JournalCLIProgressDrafter.prompt(input, settings: settings)
        XCTAssertFalse(prompt.contains("Do not read another provider"))
        XCTAssertTrue(prompt.contains("NEVER output completed")); XCTAssertTrue(prompt.contains("not the full conversation"))
        XCTAssertTrue((try JSONSerialization.jsonObject(with: Data(JournalCLIProgressDrafter.schema.utf8))) is [String: Any])
    }
    func testTaskTreeModelMergeProtectsEditsAndRequiresScopeReconfirmation() throws {
        let activity = sample()
        var note = JournalDraft(); note.summary = "Prototype reported implemented."; note.fingerprint = activity.fingerprint
        let input = JournalProgressInput.build(key: activity.threadKey, activities: [activity], drafts: [activity.id: note], existing: progressPlan())
        var result = JournalCLIProgressDrafter.demo(input, settings: settings).response
        result.nodes[1].title = "Model must not rename this manual task"
        result.nodes[1].status = .todo
        let preserved = try JournalCLIProgressDrafter.merge(result, input: input)
        XCTAssertEqual(preserved.nodes[1], input.existing?.nodes[1]); XCTAssertEqual(preserved.fraction, 0.5)
        result.nodes.append(JournalProposedTask(id: "new", parentID: "root", title: "Additional evidenced step", detail: "", status: .todo, evidenceIDs: [activity.id]))
        let expanded = try JournalCLIProgressDrafter.merge(result, input: input)
        XCTAssertEqual(expanded.completedCount, 1); XCTAssertFalse(expanded.scopeConfirmed); XCTAssertNil(expanded.fraction)
        result.nodes[0].status = .completed
        let proposal = try JournalCLIProgressDrafter.merge(result, input: input)
        XCTAssertEqual(proposal.nodes[0].status, .needsConfirmation); XCTAssertNil(proposal.nodes[0].confirmedAt)
        XCTAssertEqual(proposal.completedCount, 1) // Only the previously human-confirmed leaf.
        result.nodes[0].status = .todo; result.nodes[0].evidenceIDs = ["other|2026-10-05"]
        XCTAssertThrowsError(try JournalCLIProgressDrafter.merge(result, input: input))
        result = JournalCLIProgressDrafter.demo(input, settings: settings).response; result.nodes.removeLast()
        XCTAssertThrowsError(try JournalCLIProgressDrafter.merge(result, input: input))
        var stale = input; stale.records[0].freshness = "outdated"
        result = JournalCLIProgressDrafter.demo(input, settings: settings).response; result.nodes[0].status = .needsConfirmation
        let conservative = try JournalCLIProgressDrafter.merge(result, input: stale)
        XCTAssertEqual(conservative.nodes[0].status, .inProgress)
        XCTAssertEqual(conservative.generationNotices, [.outdatedCompletion])
    }
    func testTaskTreeShortReferencesAndSchemaStayWithinSuppliedEvidence() throws {
        let activity = sample(), note = JournalDraft(summary: "Synthetic recorded progress.", fingerprint: sample().fingerprint)
        let input = JournalProgressInput.build(key: activity.threadKey, activities: [activity], drafts: [activity.id: note], existing: nil)
        let prompt = try JournalCLIProgressDrafter.prompt(input, settings: settings)
        XCTAssertTrue(prompt.contains("note1")); XCTAssertFalse(prompt.contains(activity.id))
        let object = try JSONSerialization.jsonObject(with: Data(JournalCLIProgressDrafter.schema(for: input).utf8)) as! [String: Any]
        let props = object["properties"] as! [String: Any], nodes = props["nodes"] as! [String: Any]
        let item = nodes["items"] as! [String: Any], nodeProps = item["properties"] as! [String: Any]
        let refs = nodeProps["evidenceIDs"] as! [String: Any], refItem = refs["items"] as! [String: Any]
        XCTAssertEqual(refItem["enum"] as? [String], ["note1"])
        let status = nodeProps["status"] as! [String: Any]
        XCTAssertFalse((status["enum"] as! [String]).contains("completed"))
        var response = JournalCLIProgressDrafter.demo(input, settings: settings).response
        for index in response.nodes.indices { response.nodes[index].evidenceIDs = ["note1"] }
        let merged = try JournalCLIProgressDrafter.merge(response, input: input)
        XCTAssertTrue(merged.nodes.allSatisfy { $0.evidence == input.records })
        response.nodes[0].evidenceIDs = ["note1", activity.id]
        XCTAssertEqual(try JournalCLIProgressDrafter.merge(response, input: input).nodes[0].evidence.count, 1)
        response.nodes[0].evidenceIDs = ["claude:other-thread|\(activity.day)"]
        XCTAssertThrowsError(try JournalCLIProgressDrafter.merge(response, input: input))
        response.nodes[0].evidenceIDs = [activity.day]
        XCTAssertThrowsError(try JournalCLIProgressDrafter.merge(response, input: input))
    }
    func testTaskTreeCompletionProposalsNeverConfirmOrLoseOutdatedDrafts() throws {
        let activity = sample(), note = JournalDraft(summary: "Reported output.", fingerprint: sample().fingerprint)
        var input = JournalProgressInput.build(key: activity.threadKey, activities: [activity], drafts: [activity.id: note], existing: nil)
        var response = JournalCLIProgressDrafter.demo(input, settings: settings).response
        for index in response.nodes.indices { response.nodes[index].status = .completed }
        let proposed = try JournalCLIProgressDrafter.merge(response, input: input)
        XCTAssertTrue(proposed.nodes.allSatisfy { $0.status == .needsConfirmation && $0.confirmedAt == nil && !$0.userEdited })
        XCTAssertEqual(proposed.completedCount, 0); XCTAssertEqual(proposed.generationNotices, [.completionProposal])
        input.records[0].freshness = "outdated"
        let stale = try JournalCLIProgressDrafter.merge(response, input: input)
        XCTAssertTrue(stale.nodes.allSatisfy { $0.status == .inProgress && $0.confirmedAt == nil })
        XCTAssertEqual(stale.completedCount, 0); XCTAssertEqual(stale.generationNotices, [.completionProposal, .outdatedCompletion])
        let snapshot = progressSnapshot(stale, key: activity.threadKey)
        let restored = try JournalProgressFile.decode(JSONEncoder().encode(JournalProgressState(snapshots: [snapshot])))
        XCTAssertEqual(restored.snapshots.first?.plan.generationNotices, stale.generationNotices)
        // Old histories have no notice field; they remain readable without migration.
        var legacy = proposed; legacy.generationNotices = nil
        XCTAssertNil(try JournalProgressFile.decode(JSONEncoder().encode(JournalProgressState(snapshots: [progressSnapshot(legacy, key: activity.threadKey)]))).snapshots.first?.plan.generationNotices)
    }
    func testTaskTreeProtectedManualNodesNeedNoRegeneratedEvidence() throws {
        let activity = sample(), note = JournalDraft(summary: "Synthetic note.", fingerprint: sample().fingerprint)
        var manual = progressPlan()
        manual.nodes[1].evidence = [JournalProgressEvidence(id: "\(activity.threadKey)|2026-09-29", day: "2026-09-29",
            summary: "Historical confirmation.", nextStep: "", freshness: "current")]
        manual.nodes[2].userEdited = true // A manual task may have no model evidence at all.
        let input = JournalProgressInput.build(key: activity.threadKey, activities: [activity], drafts: [activity.id: note], existing: manual)
        var response = JournalCLIProgressDrafter.demo(input, settings: settings).response
        response.nodes[1].evidenceIDs = []; response.nodes[1].title = "Do not apply this rewrite"
        response.nodes[2].evidenceIDs = []; response.nodes[2].parentID = "Do not apply this reparent"
        let preserved = try JournalCLIProgressDrafter.merge(response, input: input)
        XCTAssertEqual(preserved.nodes[1], manual.nodes[1]); XCTAssertEqual(preserved.nodes[2], manual.nodes[2])
        XCTAssertEqual(preserved.completedCount, 1); XCTAssertEqual(preserved.fraction, 0.5)
    }
    @MainActor func testTaskTreeManualEditingWorksDuringOtherModelJobs() async throws {
        let summary = MockSummarizer(), advisor = MockAgentAdvisor(), reporter = MockPeriodReporter(), tree = MockProgressDrafter()
        summary.pause = 150_000_000; advisor.pause = 150_000_000; reporter.pause = 150_000_000; tree.pause = 150_000_000
        let store = try await seedProgressStore(tree, summarizer: summary, advisor: advisor, reporter: reporter)
        let activity = sample()
        for kind in 0..<3 {
            if kind == 0 { store.generate([activity], force: true) }
            if kind == 1 { store.analyzeProgress() }
            if kind == 2 { store.generateReport(kind: .month, start: activity.firstActivity, end: activity.lastActivity) }
            XCTAssertTrue(store.isModelBusy); XCTAssertTrue(store.canEditThreadPlan); XCTAssertFalse(store.canDraftThreadPlan)
            XCTAssertNotNil(store.threadPlanBackgroundMessage); XCTAssertNil(store.threadPlanStorageMessage)
            var plan = store.threadProgress.latest(activity.threadKey)?.plan ?? progressPlan()
            plan.stage = "Manual edit during job \(kind)"
            let saved = try store.saveThreadPlan(plan, for: activity.threadKey, expected: store.threadProgress.latest(activity.threadKey)?.id)
            XCTAssertEqual(saved.plan.stage, plan.stage)
            store.cancelBackgroundModelWork()
            for _ in 0..<300 {
                if !store.isModelBusy { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(store.isModelBusy); XCTAssertTrue(store.canDraftThreadPlan)
        }
        store.draftThreadPlan(for: activity.threadKey)
        XCTAssertFalse(store.canEditThreadPlan); XCTAssertFalse(store.canDraftThreadPlan)
        XCTAssertEqual(store.threadPlanBackgroundMessage, "正在生成任务树，完成或停止后可编辑。")
        store.cancelTaskTree(); await waitForTaskTree(store)
        XCTAssertTrue(store.canEditThreadPlan); XCTAssertNil(store.threadPlanBackgroundMessage)
    }
    @MainActor func testTaskTreeValidationFailureIsSpecificAndPreservesHistory() async throws {
        let mock = MockProgressDrafter(), store = try await seedProgressStore(MockProgressDrafter())
        let saved = try store.saveThreadPlan(progressPlan(), for: sample().threadKey, expected: nil)
        let input = store.progressInput(for: sample().threadKey)
        var response = JournalCLIProgressDrafter.demo(input, settings: settings).response
        response.nodes[0].evidenceIDs = ["note999"]
        mock.responseOverride = response
        let invalid = JournalStore(directory: root, settings: settings, progressDrafter: mock)
        await invalid.refresh(on: sample().firstActivity)
        invalid.draftThreadPlan(for: sample().threadKey); await waitForTaskTree(invalid)
        XCTAssertEqual(mock.calls, 1); XCTAssertEqual(invalid.workflow.calls.last?.outcome, .failed)
        XCTAssertEqual(invalid.taskTreeError, "模型引用的摘要编号不在本次输入中，本次未保存；可重试或手动建立。")
        XCTAssertEqual(invalid.threadProgress.latest(sample().threadKey)?.id, saved.id)
        XCTAssertEqual(invalid.threadProgress.snapshots.count, 1); XCTAssertTrue(invalid.canEditThreadPlan)
        XCTAssertEqual(JournalText(.english).message(invalid.taskTreeError!), "A summary reference is not in this input. Nothing saved; retry or create tasks manually.")
    }
    func testTaskTreeHistoryRetainsDaysRevisionsAndConcurrentThreads() throws {
        let file = root.appendingPathComponent("journal-progress.json")
        let old = progressSnapshot(progressPlan(), day: "2026-10-04")
        _ = try JournalProgressFile.append(old, expected: nil, to: file)
        var plan = old.plan; plan.nodes[2].status = .completed; plan.nodes[2].userEdited = true; plan.nodes[2].confirmedAt = Date()
        let latest = progressSnapshot(plan)
        _ = try JournalProgressFile.append(latest, expected: old.id, to: file)
        let another = progressSnapshot(progressPlan(), key: "claude:synthetic-thread")
        _ = try JournalProgressFile.append(another, expected: nil, to: file)
        XCTAssertThrowsError(try JournalProgressFile.append(progressSnapshot(plan), expected: old.id, to: file))
        let state = try JournalProgressFile.load(file)
        XCTAssertEqual(state.snapshots.count, 3); XCTAssertEqual(state.history(old.threadKey).map(\.day), ["2026-10-05", "2026-10-04"])
        XCTAssertEqual(state.history(old.threadKey).last?.plan.fraction, 0.5)
        XCTAssertEqual(state.latest(old.threadKey)?.plan.fraction, 1)
        XCTAssertEqual(state.latest(another.threadKey)?.id, another.id)
        let attributes = try manager.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var malformed = state; malformed.version = 999
        try JSONEncoder().encode(malformed).write(to: file)
        let bytes = try Data(contentsOf: file)
        XCTAssertThrowsError(try JournalProgressFile.append(latest, expected: latest.id, to: file))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    @MainActor func testTaskTreeGenerationBudgetsCancellationAndConfirmedNotes() async throws {
        let mock = MockProgressDrafter(); let store = try await seedProgressStore(mock)
        XCTAssertEqual(mock.calls, 0)
        let activity = sample()
        store.draftThreadPlan(for: activity.threadKey); await waitForTaskTree(store)
        XCTAssertEqual(mock.calls, 1); XCTAssertEqual(store.workflow.calls.last?.kind, .taskTree)
        XCTAssertEqual(store.workflow.calls.last?.outcome, .succeeded)
        let saved = try XCTUnwrap(store.threadProgress.latest(activity.threadKey))
        XCTAssertEqual(saved.plan.completedCount, 0); XCTAssertNil(saved.plan.fraction)
        XCTAssertEqual(saved.plan.nodes[1].status, .needsConfirmation)
        // Model completion proposals don't mark the source thread or daily notes complete.
        XCTAssertEqual(store.threadStatus(activity.threadKey), .active)
        XCTAssertFalse(store.draft(for: activity).isConfirmed)
        mock.pause = 200_000_000
        store.draftThreadPlan(for: activity.threadKey); store.cancelTaskTree(); await waitForTaskTree(store)
        XCTAssertEqual(store.threadProgress.snapshots.count, 1)
        XCTAssertEqual(store.workflow.calls.last?.outcome, .cancelled)
        try store.configureCalls(daily: 0, automatic: 0, paused: true, includeHistory: false)
        let before = mock.calls
        store.draftThreadPlan(for: activity.threadKey); await waitForTaskTree(store)
        XCTAssertEqual(mock.calls, before); XCTAssertEqual(store.threadProgress.snapshots.count, 1)
    }
    @MainActor func testTaskTreeLateResultsCannotOverwriteNewNotesOrManualChanges() async throws {
        let mock = MockProgressDrafter(); let store = try await seedProgressStore(mock)
        mock.pause = 120_000_000
        let activity = sample()
        store.draftThreadPlan(for: activity.threadKey)
        try await Task.sleep(nanoseconds: 30_000_000)
        store.update(activity, summary: "New manual note while the model was running", nextStep: "Recheck", category: "研究", confirmed: true)
        await waitForTaskTree(store)
        XCTAssertTrue(store.threadProgress.snapshots.isEmpty); XCTAssertEqual(store.workflow.calls.last?.outcome, .failed)
        XCTAssertTrue(store.taskTreeError?.contains("摘要已变化") == true)
        store.draftThreadPlan(for: activity.threadKey)
        try await Task.sleep(nanoseconds: 30_000_000)
        let manual = try store.saveThreadPlan(progressPlan(), for: activity.threadKey, expected: nil)
        await waitForTaskTree(store)
        XCTAssertEqual(store.threadProgress.latest(activity.threadKey)?.id, manual.id)
        XCTAssertEqual(store.threadProgress.snapshots.count, 1); XCTAssertEqual(store.workflow.calls.last?.outcome, .failed)
        XCTAssertTrue(store.taskTreeError?.contains("另一个窗口") == true)
    }
    @MainActor func testTaskTreeInterruptedRestoreRecoversFourthFile() throws {
        let files = ["journal.json", "journal-advice.json", "journal-workflow.json", "journal-progress.json"]
        let original = try JSONEncoder().encode(JournalProgressState(snapshots: [progressSnapshot(progressPlan())]))
        let id = UUID(); let safety = root.appendingPathComponent("Restore Backups/\(id.uuidString)")
        try manager.createDirectory(at: safety, withIntermediateDirectories: true)
        try original.write(to: safety.appendingPathComponent("journal-progress.json"))
        try Data("incomplete restore".utf8).write(to: root.appendingPathComponent("journal-progress.json"))
        let manifest = JournalBackupFile.RestoreManifest(version: 2, backupID: id, files: files,
            missing: ["journal.json", "journal-advice.json", "journal-workflow.json"])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent(".restore-transaction.json"))
        let store = JournalStore(directory: root, settings: settings)
        XCTAssertTrue(store.canManageProgress); XCTAssertEqual(store.threadProgress.snapshots.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("journal-progress.json")), original)
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent(".restore-transaction.json").path))
    }
    @MainActor func testTaskTreeBackupRestoreAndLegacyBackupPreservation() async throws {
        let mock = MockProgressDrafter(); let store = try await seedProgressStore(mock)
        let first = try store.saveThreadPlan(progressPlan(), for: sample().threadKey, expected: nil)
        let backup = try store.backupData(); let envelope = try JournalBackupFile.decode(backup)
        XCTAssertEqual(envelope.version, 3); XCTAssertEqual(envelope.progress?.snapshots.count, 1)
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("\"excerpts\":[{\""))
        var changed = first.plan; changed.stage = "Manual later change"
        try store.saveThreadPlan(changed, for: sample().threadKey, expected: first.id)
        let safety = try store.restoreBackup(backup)
        XCTAssertEqual(store.threadProgress.latest(sample().threadKey)?.id, first.id)
        let preRestore = try JournalBackupFile.decode(Data(contentsOf: safety.appendingPathComponent("AgentJournal-PreRestore.json")))
        XCTAssertEqual(preRestore.progress?.snapshots.count, 2)
        XCTAssertEqual(mock.calls, 0)
        var legacy = envelope; legacy.version = 2; legacy.progress = nil
        _ = try store.restoreBackup(JSONEncoder().encode(legacy))
        XCTAssertEqual(store.threadProgress.latest(sample().threadKey)?.id, first.id)
        var invalid = envelope; invalid.progress?.snapshots[0].plan.nodes[0].parentID = "one"
        let before = try Data(contentsOf: root.appendingPathComponent("journal-progress.json"))
        XCTAssertThrowsError(try store.restoreBackup(JSONEncoder().encode(invalid)))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("journal-progress.json")), before)
    }
    @MainActor func testTaskTreeCorruptStorageOnlyBlocksTreesAndDemoIsLocal() async throws {
        let file = root.appendingPathComponent("journal-progress.json")
        let bad = Data("invalid synthetic tree".utf8); try bad.write(to: file)
        let store = JournalStore(directory: root, settings: settings)
        XCTAssertTrue(store.canEdit); XCTAssertFalse(store.canManageProgress)
        XCTAssertTrue(store.progressStorageError != nil); XCTAssertEqual(try Data(contentsOf: file), bad)
        var demoSettings = settings!; demoSettings.uiLanguage = .english
        let demo = JournalStore(directory: root, settings: demoSettings, demo: true, progressDrafter: MockProgressDrafter())
        XCTAssertFalse(demo.threadProgress.snapshots.isEmpty)
        let activity = try XCTUnwrap(demo.activities.first)
        demo.draftThreadPlan(for: activity.threadKey)
        XCTAssertEqual(try Data(contentsOf: file), bad)
        XCTAssertTrue(demo.workflow.calls.isEmpty)
        XCTAssertEqual(JournalText(.english)("线程任务树"), "Thread task tree")
        XCTAssertEqual(JournalText(.english)("已确认完成 %d / %d 项", 1, 2), "1 / 2 tasks confirmed complete")
    }
}
