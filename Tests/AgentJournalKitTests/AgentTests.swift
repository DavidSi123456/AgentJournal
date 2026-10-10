import Foundation

final class MockAgentAdvisor: JournalAgentAdvising {
    var calls = 0
    var pause: UInt64 = 0
    var fail = false
    func advise(_ input: JournalAgentInput, settings: JournalSettings) async throws -> JournalAgentResult {
        calls += 1
        if pause > 0 { try? await Task.sleep(nanoseconds: pause) } // deliberately returns even after cancellation
        if fail { throw JournalError.message("synthetic failure") }
        let candidate = input.candidates[0]
        let row = JournalAgentSuggestion(threadKey: candidate.id, disposition: .review, reason: "Check the latest progress.",
            nextAction: "Review the recorded next step.", confidence: "low", evidenceIDs: [candidate.records[0].id])
        return JournalAgentResult(response: JournalAgentResponse(overview: "Progress only.", suggestions: [row]),
            input: input, engine: "test-advisor", model: "test-model")
    }
}

extension JournalTests {
    private func projectEntry(_ thread: String, folder: String, day: String = "2026-10-09",
                              provider: JournalProvider = .codex, time: TimeInterval = 0) -> JournalActivity {
        let stamp = JournalClock(timeZoneID: "UTC").date(day).addingTimeInterval(time)
        return JournalActivity(provider: provider, threadID: thread, day: day, title: "Synthetic \(thread)",
            cwd: folder, firstActivity: stamp, lastActivity: stamp, messageIDs: ["\(thread)-\(day)"])
    }
    func testMacProjectsGroupFullFoldersAcrossProvidersAndDays() throws {
        let codex = projectEntry("shared-id", folder: "/demo/project/./", time: 120)
        let old = projectEntry("shared-id", folder: "/demo/project", day: "2026-10-08")
        let claude = projectEntry("shared-id", folder: "/demo/project", provider: .claude, time: 60)
        let group = try XCTUnwrap(JournalProjectGroup.build(from: [old, codex, claude, old]).first)
        XCTAssertEqual(JournalProjectGroup.build(from: [old, codex, claude]).count, 1)
        XCTAssertEqual(group.directory, "/demo/project")
        XCTAssertEqual(group.title, "project")
        XCTAssertEqual(group.threads.map(\.threadKey), [codex.threadKey, claude.threadKey])
        XCTAssertEqual(group.records.count, 3)
        XCTAssertEqual(group.days, ["2026-10-08", "2026-10-09"])
        XCTAssertTrue(group.contains(claude.threadKey))
        XCTAssertFalse(group.contains(nil))
    }
    func testMacProjectsKeepSameNamesSubfoldersAndUnknownPathsSeparate() throws {
        let rows = [
            projectEntry("one", folder: "/demo/one/research"),
            projectEntry("two", folder: "/demo/two/research"),
            projectEntry("child", folder: "/demo/one/research/notes"),
            projectEntry("case", folder: "/demo/one/Research"),
            projectEntry("unknown-1", folder: ""),
            projectEntry("unknown-2", folder: ""),
            projectEntry("relative", folder: "research"),
            projectEntry("tilde", folder: "~/research"),
            projectEntry("root", folder: "/")
        ]
        let groups = JournalProjectGroup.build(from: rows)
        XCTAssertEqual(groups.count, rows.count)
        XCTAssertEqual(groups.filter { $0.directory == nil }.count, 4)
        XCTAssertEqual(Set(groups.map(\.id)).count, rows.count)
        XCTAssertEqual(JournalProjectGroup.directoryKey("/demo/project/../research/"), "/demo/research")
        XCTAssertEqual(JournalProjectGroup.directoryKey("/demo/ folder "), "/demo/ folder ")
        XCTAssertEqual(JournalProjectGroup.directoryKey("/../../"), "/")
        XCTAssertNil(JournalProjectGroup.directoryKey("/demo/\0private"))
        XCTAssertTrue(groups.allSatisfy { $0.threads.count == 1 })
    }
    func testMacProjectsUseLatestFolderWithoutDuplicatingThreadHistory() throws {
        let before = projectEntry("moving", folder: "/demo/old", day: "2026-10-08")
        let after = projectEntry("moving", folder: "/demo/new")
        let peer = projectEntry("peer", folder: "/demo/new", time: 60)
        let groups = JournalProjectGroup.build(from: [before, peer, after])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.directory, "/demo/new")
        XCTAssertEqual(groups.first?.threads.count, 2)
        XCTAssertEqual(groups.first?.records.count, 3)
        XCTAssertEqual(groups.first?.records.first(where: { $0.id == before.id })?.cwd, "/demo/old")
        XCTAssertEqual(before.cwd, "/demo/old")
        XCTAssertEqual(after.threadKey, before.threadKey)
    }
    func testMacProjectProjectionIsDeterministicAndRespectsFilteredInput() throws {
        let rows = [projectEntry("b", folder: "/demo/b"), projectEntry("a", folder: "/demo/a"),
                    projectEntry("c", folder: "/demo/a", provider: .claude)]
        let groups = JournalProjectGroup.build(from: rows)
        let reversed = JournalProjectGroup.build(from: Array(rows.reversed()))
        XCTAssertEqual(groups.map(\.id), reversed.map(\.id))
        XCTAssertEqual(groups.flatMap { $0.threads.map(\.id) }, reversed.flatMap { $0.threads.map(\.id) })
        var scope = try XCTUnwrap(settings)
        scope.excludedProjects = "/demo/b"
        let filtered = rows.filter { $0.source == .codex && scope.includesProject($0.cwd) }
        let visible = JournalProjectGroup.build(from: filtered)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.threads.map(\.threadKey), ["a"])
        XCTAssertTrue(JournalProjectGroup.build(from: []).isEmpty)
    }
    func testMacCombinedProjectTimelineGroupsDaysWithoutLosingAttribution() throws {
        let codex = projectEntry("shared", folder: "/demo/project", time: 60)
        let claude = projectEntry("shared", folder: "/demo/project", provider: .claude, time: 120)
        let older = projectEntry("shared", folder: "/demo/project", day: "2026-10-08")
        let group = try XCTUnwrap(JournalProjectGroup.build(from: [older, codex, claude, older]).first)
        XCTAssertEqual(group.timeline.map(\.id), ["2026-10-09", "2026-10-08"])
        XCTAssertEqual(group.timeline.first?.records.map(\.id), [claude.id, codex.id])
        XCTAssertEqual(group.timeline.flatMap(\.records).map(\.id), [claude.id, codex.id, older.id])
        XCTAssertEqual(Set(group.timeline.flatMap(\.records).map(\.threadKey)), [codex.threadKey, claude.threadKey])
        let reversed = try XCTUnwrap(JournalProjectGroup.build(from: [claude, codex, older]).first)
        XCTAssertEqual(group.timeline.flatMap(\.records).map(\.id), reversed.timeline.flatMap(\.records).map(\.id))
        let filtered = try XCTUnwrap(JournalProjectGroup.build(from: [codex, older]).first)
        XCTAssertTrue(filtered.timeline.flatMap(\.records).allSatisfy { $0.source == .codex })
    }
    func testMacCombinedProjectSelectionRepairsAfterFilteringAndEmptyResults() throws {
        let a = projectEntry("a", folder: "/demo/a", time: 60)
        let b = projectEntry("b", folder: "/demo/b", provider: .claude)
        let groups = JournalProjectGroup.build(from: [a, b])
        let aid = try XCTUnwrap(groups.first(where: { $0.contains(a.threadKey) })?.id)
        let bid = try XCTUnwrap(groups.first(where: { $0.contains(b.threadKey) })?.id)
        XCTAssertEqual(JournalProjectGroup.selectedID(nil, preferredThread: b.threadKey, in: groups), bid)
        XCTAssertEqual(JournalProjectGroup.selectedID(aid, preferredThread: b.threadKey, in: groups), aid)
        XCTAssertEqual(JournalProjectGroup.selectedID(bid, preferredThread: b.threadKey,
            in: JournalProjectGroup.build(from: [a])), aid)
        XCTAssertNil(JournalProjectGroup.selectedID(aid, preferredThread: a.threadKey, in: []))
        XCTAssertEqual(JournalProjectGroup.selectedID("missing", preferredThread: nil, in: groups), aid)
    }
    @MainActor
    func testMacProjectGroupingNeverChangesNotesPlansOrModelInputs() async throws {
        try write([meta("project-test"), codex("2026-10-09T02:00:00Z", "user", "Synthetic project")], to: codexFile)
        let summarizer = MockSummarizer(), advisor = MockAgentAdvisor()
        let store = JournalStore(directory: root.appendingPathComponent("store"), settings: settings,
                                 summarizer: summarizer, advisor: advisor)
        await store.refresh(on: Date())
        let item = try XCTUnwrap(store.activities.first)
        store.update(item, summary: "Synthetic manual note", nextStep: "Review", category: "研究", confirmed: true)
        let note = store.draft(for: item)
        let input = store.agentInput.fingerprint
        let before = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("store").path)
        for _ in 0..<3 { _ = JournalProjectGroup.build(from: store.activities).flatMap(\.timeline) }
        XCTAssertEqual(store.draft(for: item), note)
        XCTAssertEqual(store.agentInput.fingerprint, input)
        XCTAssertTrue(store.threadProgress.snapshots.isEmpty)
        XCTAssertTrue(store.todayCalls.isEmpty)
        XCTAssertEqual(summarizer.calls + advisor.calls, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("store").path).sorted(), before.sorted())
    }
    func testMacProjectCopyIsBilingual() throws {
        let en = JournalMacText(.english), zh = JournalMacText(.chinese)
        for key in ["按项目", "跨天项目总览", "相同工作目录归为一个项目；展开后选择原线程。", "全部项目的线程", "项目如何分组？",
                    "未记录完整目录 · 此线程单独展示", "已展开", "已收起", "展开项目，选择线程查看时间线；不会合并原会话。",
                    "合并为一张卡片", "默认关闭。开启后整合已有摘要，不额外调用模型，也不合并原会话。",
                    "一个项目一张卡片；右侧汇总每天的进展。", "最新进展", "已选中项目", "未选中项目",
                    "选择项目，查看所有线程的每日进展。", "查看原线程时间线", "编辑最新摘要", "导出项目摘要",
                    "项目的每一天", "同一天的进展集中展示；每段摘要仍属于原线程，可单独编辑。",
                    "选择左侧的项目卡片", "选择一个项目，在这里一起查看各线程每天的进展。"] {
            XCTAssertEqual(zh(key), key)
            XCTAssertFalse(en(key) == key)
        }
        XCTAssertEqual(en("%d 组 · %d 个线程", 2, 3), "Groups: 2 · Threads: 3")
        XCTAssertEqual(zh("%d 条每日记录 · %d 个记录日", 4, 2), "4 条每日记录 · 2 个记录日")
        XCTAssertEqual(en("原线程（%d）", 3), "Original threads (3)")
    }

    @MainActor
    func testMacFirstSummaryUnlocksAdviceWithoutEmptyCalls() async throws {
        try write([meta(), codex("2026-09-30T02:00:00Z", "user", "Synthetic first entry")], to: codexFile)
        let advisor = MockAgentAdvisor(), summarizer = MockSummarizer(), reporter = MockPeriodReporter()
        let store = JournalStore(directory: root.appendingPathComponent("store"), settings: settings,
                                 summarizer: summarizer, advisor: advisor, reporter: reporter)
        await store.refresh(on: Date())
        let item = try XCTUnwrap(store.activities.first)
        XCTAssertEqual(store.agentInput.candidates.count, 1)
        XCTAssertEqual(store.adviceReadyThreadCount, 0)
        XCTAssertFalse(store.canStartProgressAnalysis)
        store.analyzeProgress()
        store.generateReport(kind: .custom, start: store.clock.date(item.day), end: store.clock.date(item.day))
        store.draftThreadPlan(for: item.threadKey)
        XCTAssertFalse(store.isModelBusy)
        XCTAssertEqual(advisor.calls + summarizer.calls + reporter.calls, 0)
        XCTAssertTrue(store.todayCalls.isEmpty)
        XCTAssertTrue(store.agentHistory.isEmpty)
        XCTAssertTrue(store.agentError?.contains("未调用模型") == true)
        store.generate([item])
        try await wait(store)
        XCTAssertEqual(summarizer.calls, 1)
        XCTAssertEqual(store.adviceReadyThreadCount, 1)
        XCTAssertTrue(store.canStartProgressAnalysis)
        store.analyzeProgress()
        try await waitMacAdvice(store)
        XCTAssertEqual(advisor.calls, 1)
        XCTAssertEqual(store.todayCalls.count, 2)
        XCTAssertEqual(store.agentHistory.count, 1)
    }

    @MainActor
    func testMacManualSummaryIsCurrentWithoutCallsOrConfirmation() async throws {
        try write([meta(), codex("2026-09-30T02:00:00Z", "user", "Synthetic manual note")], to: codexFile)
        let store = JournalStore(directory: root.appendingPathComponent("store"), settings: settings)
        await store.refresh(on: Date())
        let item = try XCTUnwrap(store.activities.first)
        store.update(item, summary: "A design was discussed; implementation remains.", nextStep: "Verify the design.", category: "研究", confirmed: false)
        XCTAssertFalse(store.draft(for: item).isConfirmed)
        XCTAssertEqual(store.draft(for: item).fingerprint, item.fingerprint)
        XCTAssertEqual(store.agentInput.candidates.first?.records.first?.freshness, "current")
        XCTAssertEqual(store.progressInput(for: item.threadKey).records.first?.freshness, "current")
        XCTAssertEqual(store.adviceReadyThreadCount, 1)
        XCTAssertFalse(store.canGeneratePreparedSummary(item))
        XCTAssertTrue(store.todayCalls.isEmpty)
        let reopened = JournalStore(directory: root.appendingPathComponent("store"), settings: settings)
        await reopened.refresh(on: Date())
        XCTAssertEqual(reopened.agentInput.candidates.first?.records.first?.freshness, "current")
    }

    @MainActor
    func testMacAdvicePrefersUsableNotesBeforeFortyThreadLimit() async throws {
        let base = storeDateForMacTests()
        let formatter = ISO8601DateFormatter()
        for index in 0..<45 {
            let file = codexFile.deletingLastPathComponent().appendingPathComponent("rollout-\(index).jsonl")
            try write([meta("mac-synthetic-\(index)"), codex(formatter.string(from: base.addingTimeInterval(Double(-index * 60))), "user", "Synthetic work \(index)")], to: file)
        }
        let store = JournalStore(directory: root.appendingPathComponent("store"), settings: settings)
        await store.refresh(on: base)
        XCTAssertEqual(store.activities.count, 45)
        XCTAssertEqual(store.agentInput.candidates.count, 40)
        XCTAssertEqual(store.adviceReadyThreadCount, 0)
        let oldest = try XCTUnwrap(store.activities.last)
        XCTAssertFalse(store.agentInput.candidates.contains { $0.id == oldest.threadKey })
        store.update(oldest, summary: "One recorded step is ready for review.", nextStep: "Review it.", category: "研究", confirmed: false)
        XCTAssertEqual(store.agentInput.totalThreads, 45)
        XCTAssertEqual(store.agentInput.candidates.count, 40)
        XCTAssertEqual(store.agentInput.candidates.first?.id, oldest.threadKey)
        XCTAssertEqual(store.adviceReadyThreadCount, 1)
        for status in [JournalThreadStatus.paused, .completed] {
            store.setThreadStatus(status, for: oldest.threadKey)
            XCTAssertEqual(store.adviceReadyThreadCount, 0)
            XCTAssertFalse(store.canStartProgressAnalysis)
            XCTAssertEqual(store.history(for: oldest.threadKey).count, 1)
        }
        store.setThreadStatus(.active, for: oldest.threadKey)
        XCTAssertEqual(store.adviceReadyThreadCount, 1)
        XCTAssertTrue(store.todayCalls.isEmpty)
    }

    @MainActor
    func testMacPreparedSummaryRespectsScopeStalenessAndBudget() async throws {
        try write([meta(), codex("2026-09-30T02:00:00Z", "user", "Synthetic scope")], to: codexFile)
        let store = JournalStore(directory: root.appendingPathComponent("store"), settings: settings)
        await store.refresh(on: Date())
        let item = try XCTUnwrap(store.activities.first)
        XCTAssertTrue(store.canGeneratePreparedSummary(item))
        var old = item
        old.append(JournalExcerpt(timestamp: item.lastActivity.addingTimeInterval(1), role: "assistant", text: "Not the current snapshot"))
        XCTAssertFalse(store.canGeneratePreparedSummary(old))
        var unavailable = item; unavailable.excerpts = []
        XCTAssertFalse(store.canGeneratePreparedSummary(unavailable))
        try store.configureCalls(daily: 0, automatic: 0, paused: true, includeHistory: false)
        XCTAssertFalse(store.canGeneratePreparedSummary(item))
        try store.configureCalls(daily: 20, automatic: 5, paused: true, includeHistory: false)
        var selected = store.settings; selected.sourceSelection = .claude
        try store.saveSettings(selected)
        XCTAssertFalse(store.canGeneratePreparedSummary(item))
        XCTAssertEqual(store.adviceReadyThreadCount, 0)
        selected.sourceSelection = .both; try store.saveSettings(selected)
        XCTAssertTrue(store.canGeneratePreparedSummary(item))
        store.update(item, summary: "Protected manual note.", nextStep: "", category: "研究", confirmed: true)
        XCTAssertFalse(store.canGeneratePreparedSummary(item))
        XCTAssertTrue(store.todayCalls.isEmpty)
    }

    @MainActor
    func testMacAdviceWaitingPhaseAndCancellation() async throws {
        try write([meta(), codex("2026-09-30T02:00:00Z", "user", "Synthetic wait")], to: codexFile)
        let advisor = MockAgentAdvisor(); advisor.pause = 200_000_000
        let store = JournalStore(directory: root.appendingPathComponent("store"), settings: settings, advisor: advisor)
        await store.refresh(on: Date())
        let item = try XCTUnwrap(store.activities.first)
        store.update(item, summary: "Explicit unfinished verification.", nextStep: "Verify.", category: "研究", confirmed: false)
        store.analyzeProgress()
        XCTAssertTrue(store.isAdvising)
        XCTAssertFalse(store.canStartProgressAnalysis)
        XCTAssertNotNil(store.adviceStartedAt)
        XCTAssertTrue(store.advicePhase == .preparing)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(advisor.calls, 1)
        XCTAssertTrue(store.advicePhase == .waitingForCLI)
        store.cancelAdvice()
        try await waitMacAdvice(store)
        XCTAssertNil(store.adviceStartedAt)
        XCTAssertTrue(store.advicePhase == .idle)
        XCTAssertNil(store.agentResult)
        XCTAssertTrue(store.agentHistory.isEmpty)
        XCTAssertEqual(store.todayCalls.first?.outcome, .cancelled)
    }

    @MainActor
    func testMacConsentAndRepairCopyIsBilingual() throws {
        let english = JournalMacText(.english), chinese = JournalMacText(.chinese)
        for (key, value) in JournalMacText.english {
            XCTAssertFalse(key == value)
            XCTAssertEqual(english(key), value)
            XCTAssertEqual(chinese(key), key)
            let pattern = "%[@df]"
            let regex = try NSRegularExpression(pattern: pattern)
            XCTAssertEqual(regex.matches(in: key, range: NSRange(key.startIndex..., in: key)).map { (key as NSString).substring(with: $0.range) },
                           regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { (value as NSString).substring(with: $0.range) })
        }
        XCTAssertEqual(english("当前可分析：%d / %d 个候选线程有摘要", 1, 3), "Ready to analyze: 1 / 3 candidate threads have summaries")
        settings.uiLanguage = .english
        let store = JournalStore(directory: root.appendingPathComponent("store"), settings: settings)
        let defaultNotice = store.modelAccountNotice(for: settings)
        XCTAssertTrue(defaultNotice.contains("CLI default"))
        XCTAssertTrue(defaultNotice.contains("not a developer account"))
        XCTAssertTrue(defaultNotice.contains("not provider credits or billing"))
        var custom = settings!; custom.summaryEngine = .claude; custom.model = "synthetic-model"
        let customNotice = store.modelAccountNotice(for: custom)
        XCTAssertTrue(customNotice.contains("Claude Code CLI"))
        XCTAssertTrue(customNotice.contains("synthetic-model"))
        XCTAssertFalse(customNotice.contains("CLI default"))
        XCTAssertTrue(store.todayCalls.isEmpty)
    }

    private func storeDateForMacTests() -> Date { JournalClock(timeZoneID: "Asia/Shanghai").date("2026-09-30") }
    @MainActor private func waitMacAdvice(_ store: JournalStore) async throws {
        for _ in 0..<300 {
            if !store.isAdvising { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Advice did not settle")
    }

    func testAgentInputIsBoundedProgressOnlyAndDeterministic() throws {
        var activities: [JournalActivity] = []
        var drafts: [String: JournalDraft] = [:]
        let base = settings.timeZoneID == "Asia/Shanghai" ? JournalClock(timeZoneID: settings.timeZoneID).date("2026-09-30") : Date()
        for thread in 0..<45 {
            for day in 0..<5 {
                var activity = sample()
                activity.threadID = "thread-\(thread)"
                activity.day = "2026-09-\(30-day)"
                activity.lastActivity = base.addingTimeInterval(Double(-thread * 60 - day * 86400))
                activity.cwd = "PRIVATE_CWD"
                activity.excerpts = [JournalExcerpt(timestamp: base, role: "user", text: "PRIVATE_RAW_CHAT")]
                activities.append(activity)
                var draft = JournalDraft()
                draft.summary = String(repeating: "s", count: 1000)
                draft.nextStep = "Continue explicit unfinished verification."
                draft.fingerprint = activity.fingerprint
                draft.status = "已完成" // daily completion must not eliminate the thread
                draft.category = "PRIVATE_CATEGORY"
                drafts[activity.id] = draft
            }
        }
        let now = base.addingTimeInterval(3600)
        let input = JournalAgentInput.build(activities: activities.reversed(), drafts: drafts, now: now)
        XCTAssertEqual(input.totalThreads, 45)
        XCTAssertEqual(input.candidates.count, 40)
        XCTAssertEqual(input.candidates[0].id, "thread-0")
        XCTAssertEqual(input.candidates[0].records.count, 3)
        XCTAssertEqual(input.candidates[0].records[0].summary.count, 900)
        let encoded = String(decoding: try JSONEncoder().encode(input.candidates), as: UTF8.self)
        for secret in ["PRIVATE_CWD", "PRIVATE_RAW_CHAT", "PRIVATE_CATEGORY", "已完成"] { XCTAssertFalse(encoded.contains(secret)) }
        XCTAssertEqual(input.fingerprint, JournalAgentInput.build(activities: activities, drafts: drafts, now: now).fingerprint)
        XCTAssertEqual(input.fingerprint, input.fingerprint)
        let first = activities[0]
        drafts[first.id]?.editedNextStep = "Changed step"
        XCTAssertFalse(input.fingerprint == JournalAgentInput.build(activities: activities, drafts: drafts, now: now).fingerprint)
        drafts[first.id]?.fingerprint = "old"
        XCTAssertEqual(JournalAgentInput.build(activities: activities, drafts: drafts, now: now).candidates[0].records[0].freshness, "outdated")
        drafts[first.id]?.confirmedFingerprint = first.fingerprint
        XCTAssertEqual(JournalAgentInput.build(activities: activities, drafts: drafts, now: now).candidates[0].records[0].freshness, "current")
    }

    func testAgentPromptAndEvidenceValidation() throws {
        let activity = sample()
        var draft = JournalDraft()
        draft.summary = "Foundation verified; another verification is unfinished."
        draft.nextStep = "Verify the remaining scenario."
        draft.fingerprint = activity.fingerprint
        var input = JournalAgentInput.build(activities: [activity], drafts: [activity.id: draft], now: activity.lastActivity.addingTimeInterval(300))
        settings.uiLanguage = .english; settings.summaryLanguage = .english
        let prompt = try JournalCLIAgentAdvisor.prompt(input, settings: settings)
        XCTAssertTrue(prompt.contains("ONLY the supplied thread progress"))
        XCTAssertTrue(prompt.contains("No fabricated IDs"))
        XCTAssertTrue(prompt.contains("Write overview, reason and nextAction in English"))
        XCTAssertFalse(prompt.contains("/demo"))
        settings.summaryLanguage = .automatic
        XCTAssertTrue(try JournalCLIAgentAdvisor.prompt(input, settings: settings).contains("not original transcripts"))
        var row = JournalAgentSuggestion(threadKey: activity.threadKey, disposition: .advance, reason: "A verified foundation leaves an explicit next step.",
            nextAction: draft.nextStep, confidence: "medium", evidenceIDs: [activity.id])
        var response = JournalAgentResponse(overview: "Continue explicit remaining work.", suggestions: [row])
        XCTAssertNoThrow(try JournalCLIAgentAdvisor.validate(response, input: input))
        response.suggestions.append(row)
        XCTAssertThrowsError(try JournalCLIAgentAdvisor.validate(response, input: input))
        response.suggestions = [row]
        response.suggestions[0].evidenceIDs = ["other-thread|2026-09-30"]
        XCTAssertThrowsError(try JournalCLIAgentAdvisor.validate(response, input: input))
        response.suggestions[0] = row
        input.candidates[0].records[0].freshness = "outdated"
        XCTAssertThrowsError(try JournalCLIAgentAdvisor.validate(response, input: input))
        row.disposition = .review; row.confidence = "low"; response.suggestions = [row]
        XCTAssertNoThrow(try JournalCLIAgentAdvisor.validate(response, input: input))
        response.suggestions[0].confidence = "certain"
        XCTAssertThrowsError(try JournalCLIAgentAdvisor.validate(response, input: input))
        input.candidates[0].records[0].freshness = "current"
        input.candidates[0].recentlyActive = true
        row.disposition = .advance; response.suggestions = [row]
        XCTAssertThrowsError(try JournalCLIAgentAdvisor.validate(response, input: input))
    }

    func testAgentSchemaUsesSameRestrictedCLIAndReportsModel() throws {
        let schema = JournalCLIAgentAdvisor.schema
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(schema.utf8)))
        let args = JournalCLISummarizer.arguments(engine: .claude, model: "chosen-model", schemaPath: "/schema", outputPath: "/out", schemaContent: schema)
        XCTAssertTrue(args.contains(schema)); XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertTrue(args.contains("--restricted")); XCTAssertTrue(args.contains("chosen-model"))
        XCTAssertFalse(args.contains("--resume")); XCTAssertFalse(args.contains("--continue"))
        let body = "{\"type\":\"result\",\"structured_output\":{\"overview\":\"No supported next step.\",\"suggestions\":[]},\"modelUsage\":{\"claude-test-model\":{}}}"
        let output = try JournalCLISummarizer.parseClaudeOutput(body)
        let response = try JSONDecoder().decode(JournalAgentResponse.self, from: output.data)
        XCTAssertTrue(response.suggestions.isEmpty)
        XCTAssertEqual(output.model, "claude-test-model")
        XCTAssertEqual(output.engine, "Claude Code")
    }

    func testDesktopMetadataEnrichesCachedThreadWithoutDuplicateOrPrivateConfig() async throws {
        let id = "00000000-0000-4000-8000-000000000123"
        let desktopID = "local_00000000-0000-4000-8000-000000000456"
        let desktopRoot = root.appendingPathComponent("desktop")
        settings.claudeDesktopSessionsHome = desktopRoot.path
        var row = claude("2026-09-30T02:00:00Z", "user", "Desktop Code work")
        row["sessionId"] = id
        try write([row], to: claudeFile)
        let metadata = desktopRoot.appendingPathComponent("org/account/\(desktopID).json")
        try manager.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        var object: [String: Any] = ["sessionId": desktopID, "cliSessionId": id, "title": "Native desktop title", "isArchived": false,
            "lastActivityAt": 1770000000000, "remoteMcpConfigs": "SECRET_CONFIG", "permissionMode": "PRIVATE_PERMISSION"]
        try JSONSerialization.data(withJSONObject: object).write(to: metadata)
        let reader = JournalReader(settings: settings, indexURL: indexFile)
        let first = try await reader.scan()
        XCTAssertEqual(first.activities.count, 1)
        let item = try XCTUnwrap(first.activities.first)
        XCTAssertEqual(item.threadID, id)
        XCTAssertEqual(item.desktopSessionID, desktopID)
        XCTAssertEqual(item.title, "Native desktop title")
        XCTAssertEqual(JournalNavigation.url(for: item)?.absoluteString, "claude://code/continue?session=\(desktopID)")
        object["title"] = "Renamed in desktop"; object["isArchived"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: metadata)
        let second = try await reader.scan()
        let updated = try XCTUnwrap(second.activities.first)
        XCTAssertEqual(updated.title, "Renamed in desktop")
        XCTAssertEqual(updated.id, item.id); XCTAssertEqual(updated.fingerprint, item.fingerprint)
        XCTAssertNil(JournalNavigation.url(for: updated))
        let encoded = String(decoding: try JSONEncoder().encode(second.activities), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SECRET_CONFIG")); XCTAssertFalse(encoded.contains("PRIVATE_PERMISSION"))
        XCTAssertFalse(try String(contentsOf: indexFile, encoding: .utf8).contains("SECRET_CONFIG"))
        try manager.removeItem(at: metadata)
        let third = try await reader.scan()
        XCTAssertNil(third.activities.first?.desktopSessionID)
        XCTAssertEqual(third.activities.first?.id, item.id)
    }

    func testDesktopMetadataRejectsInvalidIDsSymlinksAndOversizedFiles() throws {
        let desktopRoot = root.appendingPathComponent("desktop")
        try manager.createDirectory(at: desktopRoot, withIntermediateDirectories: true)
        let bad = desktopRoot.appendingPathComponent("local_bad.json")
        try Data("{\"sessionId\":\"local_bad?prompt=run\",\"cliSessionId\":\"00000000-0000-4000-8000-000000000123\"}".utf8).write(to: bad)
        let huge = desktopRoot.appendingPathComponent("local_huge.json")
        try Data(repeating: 32, count: 1024 * 1024 + 1).write(to: huge)
        let external = root.appendingPathComponent("local_external.json")
        try Data("{\"sessionId\":\"local_external\",\"cliSessionId\":\"00000000-0000-4000-8000-000000000123\"}".utf8).write(to: external)
        try manager.createSymbolicLink(at: desktopRoot.appendingPathComponent("local_external.json"), withDestinationURL: external)
        let snapshot = JournalDesktopSessions.load(desktopRoot)
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.incomplete)
        XCTAssertNil(settings.desktopSessionsURL) // custom transcript roots don't read personal desktop metadata
    }

    func testOriginalThreadNavigationIsValidatedAndNeverImports() throws {
        var activity = sample()
        XCTAssertNil(JournalNavigation.url(for: activity))
        activity.threadID = "00000000-0000-4000-8000-000000000123"
        XCTAssertEqual(JournalNavigation.url(for: activity)?.absoluteString, "codex://threads/\(activity.threadID)")
        activity.provider = .claude
        XCTAssertNil(JournalNavigation.url(for: activity))
        activity.desktopSessionID = "local_original-123"
        XCTAssertEqual(JournalNavigation.url(for: activity)?.path, "/continue")
        XCTAssertFalse(JournalNavigation.url(for: activity)!.absoluteString.contains("resume"))
        activity.desktopSessionID = "local_original&prompt=execute"
        XCTAssertNil(JournalNavigation.url(for: activity))
        activity.desktopSessionID = "last"
        XCTAssertNil(JournalNavigation.url(for: activity))
        activity.cwd = "/demo/it'$not-executed"
        let command = try XCTUnwrap(JournalNavigation.resumeCommand(for: activity))
        XCTAssertTrue(command.contains("'\\''")); XCTAssertTrue(command.contains("claude --resume"))
        activity.cwd = ""
        XCTAssertFalse(JournalNavigation.resumeCommand(for: activity)!.contains("cd "))
    }

    @MainActor
    func testAgentAnalysisDoesNotWriteJournalAndCancellationDropsLateResults() async throws {
        try write([meta(), codex("2026-09-30T02:00:00Z", "user", "Synthetic work")], to: codexFile)
        let advisor = MockAgentAdvisor()
        let summarizer = MockSummarizer()
        let store = JournalStore(directory: root.appendingPathComponent("store"), settings: settings, summarizer: summarizer, advisor: advisor)
        await store.refresh(on: Date())
        let activity = try XCTUnwrap(store.activities.first)
        store.update(activity, summary: "One verification finished; another remains.", nextStep: "Check the next case.", category: "研究", confirmed: true)
        let journal = root.appendingPathComponent("store/journal.json")
        let before = try Data(contentsOf: journal)
        let archive = root.appendingPathComponent("store/journal-advice.json")
        advisor.pause = 100_000_000
        store.analyzeProgress()
        XCTAssertTrue(store.isAdvising)
        store.generate([activity], force: true)
        XCTAssertFalse(store.isSummarizing)
        XCTAssertThrowsError(try store.saveSettings(settings))
        try await Task.sleep(nanoseconds: 10_000_000)
        store.cancelAdvice()
        while store.isAdvising { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(store.agentResult)
        XCTAssertTrue(store.agentHistory.isEmpty)
        XCTAssertFalse(manager.fileExists(atPath: archive.path))
        XCTAssertEqual(try Data(contentsOf: journal), before)
        advisor.pause = 0
        store.analyzeProgress()
        while store.isAdvising { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(store.agentResult?.model, "test-model")
        XCTAssertEqual(store.agentResult?.engine, "test-advisor")
        XCTAssertEqual(store.agentHistory.count, 1)
        XCTAssertEqual(store.agentResult?.timeZoneID, settings.timeZoneID)
        XCTAssertEqual(store.agentResult?.languageCode, settings.summaryLanguage.rawValue)
        let saved = try Data(contentsOf: archive)
        let reopened = JournalStore(directory: root.appendingPathComponent("store"), settings: settings, advisor: advisor)
        XCTAssertEqual(reopened.agentHistory.first?.id, store.agentResult?.id)
        XCTAssertEqual(reopened.agentHistory.first?.input.fingerprint, store.agentInput.fingerprint)
        _ = reopened.advice(on: store.clock.key(Date()))
        XCTAssertEqual(advisor.calls, 2) // cancellation + manual analysis; browsing/load use no model
        XCTAssertEqual(try Data(contentsOf: journal), before)
        XCTAssertFalse(store.agentResultIsOutdated)
        store.update(activity, summary: "Changed progress.", nextStep: "Review changed evidence.", category: "生活", confirmed: true)
        XCTAssertTrue(store.agentResultIsOutdated)
        advisor.fail = true
        store.analyzeProgress()
        while store.isAdvising { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(store.agentError)
        XCTAssertEqual(store.agentResult?.model, "test-model") // errors don't replace a valid snapshot
        XCTAssertEqual(store.agentHistory.count, 1)
        XCTAssertEqual(try Data(contentsOf: archive), saved)
        XCTAssertEqual(summarizer.calls, 0)
    }

    @MainActor
    func testAgentDemoNeverCallsModelOrPersists() throws {
        let advisor = MockAgentAdvisor()
        let directory = root.appendingPathComponent("demo-no-data")
        settings.uiLanguage = .english
        let store = JournalStore(directory: directory, settings: settings, demo: true, advisor: advisor)
        XCTAssertEqual(store.agentHistoryDays.count, 3)
        for snapshot in store.agentHistory {
            XCTAssertTrue(snapshot.input.candidates.allSatisfy { $0.records.allSatisfy { $0.day <= snapshot.day } })
        }
        store.analyzeProgress()
        XCTAssertEqual(store.agentHistory.count, 4)
        XCTAssertEqual(advisor.calls, 0)
        XCTAssertFalse(store.agentResult!.response.suggestions.isEmpty)
        XCTAssertTrue(store.agentResult!.response.overview.contains("Demo"))
        XCTAssertTrue(store.agentResult!.response.suggestions.allSatisfy { !$0.nextAction.isEmpty })
        XCTAssertFalse(manager.fileExists(atPath: directory.path))
    }

    private func adviceSnapshot(day: String, hour: Int = 12, timeZoneID: String = "Asia/Shanghai", text: String = "Original advice.") -> JournalAgentResult {
        let record = JournalAgentRecord(id: "synthetic-thread@2026-09-28", day: "2026-09-28",
            summary: "Synthetic progress; verify the remaining test.", nextStep: "Check the remaining test.", freshness: "current")
        let candidate = JournalAgentCandidate(threadKey: "synthetic-thread", source: "Codex", title: "Synthetic thread",
            lastDay: record.day, recentlyActive: false, records: [record])
        let input = JournalAgentInput(candidates: [candidate], totalThreads: 1)
        let suggestion = JournalAgentSuggestion(threadKey: candidate.id, disposition: .advance,
            reason: "An explicit verification remains.", nextAction: "Check the remaining test.", confidence: "medium", evidenceIDs: [record.id])
        return JournalAgentResult(response: JournalAgentResponse(overview: text, suggestions: [suggestion]), input: input,
            engine: "test-advisor", model: "test-model", generatedAt: JournalClock(timeZoneID: timeZoneID).date(day).addingTimeInterval(Double(hour) * 3600),
            timeZoneID: timeZoneID, languageCode: "en")
    }

    @MainActor
    func testAgentHistoryRetainsDaysVersionsAndOriginalEvidence() throws {
        let directory = root.appendingPathComponent("archive-store")
        let file = directory.appendingPathComponent("journal-advice.json")
        let oldest = adviceSnapshot(day: "2026-09-28")
        let morning = adviceSnapshot(day: "2026-09-30", hour: 9)
        let evening = adviceSnapshot(day: "2026-09-30", hour: 18, text: "Later advice.")
        try JournalAgentHistoryFile.save([morning, oldest], to: file)
        // A stale writer cannot discard another writer's saved day or run.
        let merged = try JournalAgentHistoryFile.save([evening, morning], to: file)
        XCTAssertEqual(merged.map(\.id), [evening.id, morning.id, oldest.id])
        let advisor = MockAgentAdvisor()
        let store = JournalStore(directory: directory, settings: settings, advisor: advisor)
        XCTAssertEqual(store.agentHistoryDays, ["2026-09-30", "2026-09-28"])
        XCTAssertEqual(store.advice(on: "2026-09-30").map(\.id), [evening.id, morning.id])
        XCTAssertTrue(store.advice(on: "2026-09-29").isEmpty)
        XCTAssertTrue(store.hasAdvice(on: store.clock.date("2026-09-28")))
        XCTAssertEqual(store.agentResult?.id, evening.id)
        XCTAssertEqual(store.agentHistory.last?.response.overview, "Original advice.")
        XCTAssertEqual(store.agentHistory.last?.input.candidates[0].records[0].summary, oldest.input.candidates[0].records[0].summary)
        XCTAssertEqual(advisor.calls, 0)
        XCTAssertFalse(manager.fileExists(atPath: directory.appendingPathComponent("journal.json").path))
        let mode = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let encoded = try String(contentsOf: file, encoding: .utf8)
        for field in ["excerpts", "cwd", "providerModels", "category", "confirmedAt"] {
            XCTAssertFalse(encoded.contains("\"\(field)\""))
        }
    }

    @MainActor
    func testAgentHistoryPreservesGenerationDayTimezoneAndLanguage() throws {
        let directory = root.appendingPathComponent("timezone-store")
        let file = directory.appendingPathComponent("journal-advice.json")
        var snapshot = adviceSnapshot(day: "2026-10-01", hour: 7)
        snapshot.generatedAt = ISO8601DateFormatter().date(from: "2026-09-30T23:30:00Z")!
        snapshot.day = "2026-10-01" // Shanghai date, not UTC or new viewing timezone
        try JournalAgentHistoryFile.save([snapshot], to: file)
        settings.timeZoneID = "America/Los_Angeles"
        settings.summaryLanguage = .chinese
        settings.uiLanguage = .chinese
        let store = JournalStore(directory: directory, settings: settings, advisor: MockAgentAdvisor())
        XCTAssertEqual(store.agentHistoryDays, ["2026-10-01"])
        XCTAssertEqual(store.agentHistory[0].generatedAt, snapshot.generatedAt)
        XCTAssertEqual(store.agentHistory[0].timeZoneID, "Asia/Shanghai")
        XCTAssertEqual(store.agentHistory[0].languageCode, "en")
        XCTAssertEqual(store.agentHistory[0].response.overview, "Original advice.")
        XCTAssertEqual(JournalClock(timeZoneID: store.settings.timeZoneID).key(snapshot.generatedAt), "2026-09-30")
        var changed = store.settings; changed.uiLanguage = .english; changed.timeZoneID = "UTC"
        try store.saveSettings(changed)
        XCTAssertEqual(store.agentHistory[0].day, "2026-10-01")
        XCTAssertEqual(try JournalAgentHistoryFile.load(file).first?.id, snapshot.id)
    }

    @MainActor
    func testInvalidAgentHistoryIsPreservedAndOnlyBlocksAnalysis() async throws {
        try write([meta(), codex("2026-09-30T02:00:00Z", "user", "Synthetic work")], to: codexFile)
        let good = adviceSnapshot(day: "2026-09-30")
        var duplicateCandidate = good
        duplicateCandidate.input.candidates.append(good.input.candidates[0])
        duplicateCandidate.input.totalThreads = 2
        var wrongDay = good; wrongDay.day = "2026-09-29"
        var fabricatedEvidence = good; fabricatedEvidence.response.suggestions[0].evidenceIDs = ["other-thread-record"]
        func bytes(_ results: [JournalAgentResult], version: Int = 1) throws -> Data {
            let objects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))
            return try JSONSerialization.data(withJSONObject: ["version": version, "results": objects])
        }
        let invalids = try [Data("broken history".utf8), bytes([good], version: 99), bytes([good, good]),
                            bytes([duplicateCandidate]), bytes([wrongDay]), bytes([fabricatedEvidence])]
        for (index, original) in invalids.enumerated() {
            let directory = root.appendingPathComponent("bad-archive-\(index)")
            let file = directory.appendingPathComponent("journal-advice.json")
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try original.write(to: file)
            let advisor = MockAgentAdvisor()
            let store = JournalStore(directory: directory, settings: settings, advisor: advisor)
            await store.refresh(on: Date())
            XCTAssertTrue(store.canEdit)
            XCTAssertFalse(store.canAnalyzeProgress)
            XCTAssertNotNil(store.agentHistoryError)
            store.analyzeProgress()
            XCTAssertFalse(store.isAdvising); XCTAssertEqual(advisor.calls, 0)
            let activity = try XCTUnwrap(store.activities.first)
            store.update(activity, summary: "Still editable.", nextStep: "", category: "生活", confirmed: true)
            XCTAssertEqual(store.draft(for: activity).displaySummary, "Still editable.")
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertThrowsError(try JournalAgentHistoryFile.save([good], to: file))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testAgentHistoryRejectsUnsafePathsWithoutOverwriting() throws {
        let original = adviceSnapshot(day: "2026-09-30")
        let target = root.appendingPathComponent("external-advice.json")
        try JournalAgentHistoryFile.save([original], to: target)
        let before = try Data(contentsOf: target)
        let symlink = root.appendingPathComponent("linked-advice.json")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: target)
        XCTAssertThrowsError(try JournalAgentHistoryFile.load(symlink))
        XCTAssertThrowsError(try JournalAgentHistoryFile.save([adviceSnapshot(day: "2026-10-01")], to: symlink))
        XCTAssertEqual(try Data(contentsOf: target), before)
        let directory = root.appendingPathComponent("directory-advice.json")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try JournalAgentHistoryFile.save([original], to: directory))
        XCTAssertTrue(manager.fileExists(atPath: directory.path))
        let oversized = root.appendingPathComponent("oversized-advice.json")
        try Data().write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 64 * 1024 * 1024 + 1)
        try handle.close()
        XCTAssertThrowsError(try JournalAgentHistoryFile.load(oversized))
        XCTAssertThrowsError(try JournalAgentHistoryFile.save([original], to: oversized))
        XCTAssertEqual(try oversized.resourceValues(forKeys: [.fileSizeKey]).fileSize, 64 * 1024 * 1024 + 1)
    }

    @MainActor
    func testAgentHistorySaveFailureCanRetryWithoutAnotherModelCall() async throws {
        try write([meta(), codex("2026-09-30T02:00:00Z", "user", "Synthetic work")], to: codexFile)
        let directory = root.appendingPathComponent("retry-store")
        let file = directory.appendingPathComponent("journal-advice.json")
        let original = adviceSnapshot(day: "2026-09-29")
        try JournalAgentHistoryFile.save([original], to: file)
        let before = try Data(contentsOf: file)
        let advisor = MockAgentAdvisor()
        let store = JournalStore(directory: directory, settings: settings, advisor: advisor)
        await store.refresh(on: Date())
        let activity = try XCTUnwrap(store.activities.first)
        store.update(activity, summary: "Verify remaining work.", nextStep: "Check the remaining case.", category: "研究", confirmed: true)
        let journal = directory.appendingPathComponent("journal.json")
        let journalBytes = try Data(contentsOf: journal)
        try manager.removeItem(at: file) // synthetic fixture only
        try manager.createDirectory(at: file, withIntermediateDirectories: true)
        store.analyzeProgress()
        while store.isAdvising { try await Task.sleep(nanoseconds: 5_000_000) }
        let unsaved = try XCTUnwrap(store.agentResult)
        XCTAssertNotNil(store.agentHistoryError)
        XCTAssertEqual(store.agentHistory.map(\.id), [original.id])
        XCTAssertFalse(store.agentHistory.contains { $0.id == unsaved.id })
        XCTAssertEqual(try Data(contentsOf: journal), journalBytes)
        try manager.removeItem(at: file) // synthetic empty directory only
        try before.write(to: file)
        store.retrySavingAdvice()
        XCTAssertNil(store.agentHistoryError)
        XCTAssertEqual(store.agentHistory.count, 2)
        XCTAssertTrue(store.agentHistory.contains { $0.id == unsaved.id })
        XCTAssertTrue(try JournalAgentHistoryFile.load(file).contains { $0.id == unsaved.id })
        store.retrySavingAdvice()
        XCTAssertEqual(store.agentHistory.count, 2)
        XCTAssertEqual(advisor.calls, 1)
        XCTAssertEqual(try Data(contentsOf: journal), journalBytes)
    }

    func testAdviceHistoryEnglishLabelsAndDiagnostics() throws {
        let l = JournalText(.english)
        XCTAssertEqual(l("%d 天 · %d 次分析", 2, 3), "2 days · 3 analyses")
        XCTAssertEqual(l("%@，%d 次分析", "2026-09-30", 2), "2026-09-30, 2 analyses")
        for key in ["每日建议", "推进建议", "当天推进建议", "分析当前进展", "尚未保存 · 退出后会丢失", "重试保存（不调用模型）",
                    "推进建议历史读取失败，原文件已保留；请备份并修复后重启。", "本次建议尚未保存；已有历史未删除，请检查存储空间和权限后重试。"] {
            XCTAssertFalse(l.message(key).contains("建议"))
            XCTAssertFalse(l(key) == key)
        }
    }

    func testOptionalLiveAgentAdvice() async throws {
        guard let name = ProcessInfo.processInfo.environment["AGENTJOURNAL_LIVE_ADVICE"], let engine = JournalProvider(rawValue: name) else {
            throw XCTSkip("Set AGENTJOURNAL_LIVE_ADVICE=codex or claude; only synthetic progress is sent")
        }
        let activity = sample()
        var draft = JournalDraft()
        draft.summary = "Implemented a synthetic greeting function. A test is explicitly still unfinished."
        draft.nextStep = "Write a test for the greeting function."
        draft.fingerprint = activity.fingerprint
        settings.summaryEngine = engine; settings.summaryLanguage = .english; settings.uiLanguage = .english
        // Use standard login paths, but send only the synthetic notes above.
        let loginSettings = JournalSettings()
        settings.codexHome = loginSettings.codexHome; settings.claudeHome = loginSettings.claudeHome
        let input = JournalAgentInput.build(activities: [activity], drafts: [activity.id: draft], now: activity.lastActivity.addingTimeInterval(300))
        let result = try await JournalCLIAgentAdvisor().advise(input, settings: settings)
        XCTAssertFalse(result.response.overview.isEmpty)
        print("Synthetic advisor verified: \(result.engine), \(result.model ?? "not reported")")
    }
}
