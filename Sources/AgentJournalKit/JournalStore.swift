import Foundation
import Combine

enum JournalAdvicePhase {
    case idle, preparing, waitingForCLI, checking, saving
    var label: String {
        switch self {
        case .idle: return ""
        case .preparing: return "正在准备本次分析"
        case .waitingForCLI: return "正在等待 CLI 返回分析结果"
        case .checking: return "正在核对结果与摘要依据"
        case .saving: return "正在保存建议和每日历史"
        }
    }
}

@MainActor
public final class JournalStore: ObservableObject {
    @Published private(set) var activities: [JournalActivity] = [] { didSet { cachedAgentInput = nil } }
    @Published private(set) var drafts: [String: JournalDraft] = [:] { didSet { cachedAgentInput = nil } }
    @Published private(set) var settings: JournalSettings
    @Published private(set) var isLoading = false
    @Published private(set) var isSummarizing = false
    @Published private(set) var isAdvising = false
    @Published private(set) var adviceStartedAt: Date?
    @Published private(set) var advicePhase: JournalAdvicePhase = .idle
    @Published private(set) var isReporting = false
    @Published private(set) var isDraftingTasks = false
    @Published private(set) var threadProgress = JournalProgressState()
    @Published private(set) var progressStorageError: String?
    @Published var taskTreeError: String?
    @Published private(set) var workflow = JournalWorkflowState() {
        didSet {
            cachedAgentInput = nil
            let liveReports = Set(workflow.reports.map(\.id)), liveCalls = Set(workflow.calls.map(\.id))
            archivedReports = JournalArchive.reports(live: archivedReports + oldValue.reports.filter { !liveReports.contains($0.id) }, archives: [])
            var seen = Set<UUID>()
            archivedCalls = (archivedCalls + oldValue.calls.filter { !liveCalls.contains($0.id) }).filter { seen.insert($0.id).inserted }
        }
    }
    @Published var noticeMessage: String?
    @Published private(set) var workflowError: String?
    @Published private(set) var controlNotice: String?
    @Published private(set) var reportResult: JournalPeriodReport?
    @Published var reportError: String?
    @Published private(set) var agentResult: JournalAgentResult?
    @Published private(set) var agentHistory: [JournalAgentResult] = []
    @Published private(set) var agentHistoryError: String?
    @Published private(set) var archiveHistoryError: String?
    @Published private(set) var archivedReports: [JournalPeriodReport] = []
    @Published private(set) var archivedCalls: [JournalCallRecord] = []
    @Published var agentError: String?
    @Published private(set) var summarizingIDs: Set<String> = []
    @Published private(set) var progressText = ""
    @Published private(set) var lastRefreshed: Date?
    @Published var errorMessage: String?
    @Published private(set) var warningMessage: String?
    @Published private(set) var settingsRequest = 0
    @Published var autoSummarize: Bool {
        didSet {
            guard !isInitializing else { return }
            save()
            if autoSummarize { generateAutomatic() }
        }
    }
    let isDemo: Bool
    var clock: JournalClock { JournalClock(timeZoneID: settings.timeZoneID) }
    var canEdit: Bool { canSave || isDemo }
    private let requiresLanguageSetup: Bool
    var needsLanguageSetup: Bool { requiresLanguageSetup && settings.languageSetupComplete != true && canEdit }
    static let onboardingVersion = 1
    var needsOnboarding: Bool { requiresLanguageSetup && settings.onboardingVersion != Self.onboardingVersion && canEdit }
    private var l: JournalMacText { JournalMacText(settings.uiLanguage) }
    public var settingsMenuTitle: String { l("设置…") }
    public var waitingForLanguageSelection: Bool { needsLanguageSetup || needsOnboarding }
    public func openSettings() { settingsRequest += 1 }

    typealias Saved = JournalSaved
    private var reader: JournalReader
    private let summarizer: JournalSummarizing
    private let advisor: JournalAgentAdvising
    private let reporter: JournalPeriodReporting
    private let progressDrafter: JournalProgressDrafting
    private let dataURL: URL
    private let indexURL: URL
    private let agentHistoryURL: URL
    private let workflowURL: URL
    private let threadProgressURL: URL
    private var expectedJournalBytes: Data?
    private var canSaveAgentHistory = true
    private var isInitializing = true
    private var canSave = true
    private var legacyBytes: Data?
    private var requestedDate = Date()
    private var selectedHistoryThreadKey: String?
    private var lastAttempts: [String: Date] = [:]
    private var generationTask: Task<Void, Never>?
    private var advisorTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    private var taskTreeTask: Task<Void, Never>?
    // Activities indexed under the previous timezone, kept until the next successful scan.
    private var timeZoneMigrationSource: [JournalActivity]?
    private var draftTimeZones: [String: [String: JournalDraft]] = [:]
    private var cachedAgentInput: (input: JournalAgentInput, fingerprint: String, expires: Date)?
    private var resultFingerprints: [UUID: String] = [:]
    private var archiveHistoryLoaded = false
    var isModelBusy: Bool { isSummarizing || isAdvising || isReporting || isDraftingTasks }
    var canManageProgress: Bool { canManageWorkflow && progressStorageError == nil }
    // Manual trees live in their own file. Unrelated model requests must not lock
    // this editor; only scanning or a tree draft can change its editing baseline.
    var canEditThreadPlan: Bool { canManageProgress && !isLoading && !isDraftingTasks }
    var canDraftThreadPlan: Bool { canManageProgress && !isLoading && !isModelBusy && !needsLanguageSetup && !needsOnboarding }
    var threadPlanStorageMessage: String? {
        progressStorageError ?? workflowError ?? archiveHistoryError
            ?? (canEdit ? nil : errorMessage ?? "任务树暂时不能保存，请检查存储或等待读取结束。")
    }
    var threadPlanBackgroundMessage: String? {
        if isLoading { return "正在读取线程记录，读取完成后可编辑任务树。" }
        if isDraftingTasks { return "正在生成任务树，完成或停止后可编辑。" }
        if isSummarizing { return "后台正在生成每日摘要；手动编辑仍可用，自动草拟需等待或停止后台生成。" }
        if isAdvising { return "后台正在生成推进建议；手动编辑仍可用，自动草拟需等待或停止后台生成。" }
        if isReporting { return "后台正在生成回顾报告；手动编辑仍可用，自动草拟需等待或停止后台生成。" }
        return nil
    }
    func cancelBackgroundModelWork() {
        cancelGeneration(); cancelAdvice(); cancelReport()
    }
    var archiveURL: URL { JournalArchive.directory(beside: workflowURL) }
    var canManageWorkflow: Bool { (workflowError == nil && archiveHistoryError == nil && canEdit) || isDemo }
    var todayCalls: [JournalCallRecord] {
        var seen = Set<UUID>()
        return JournalWorkflowState(calls: (workflow.calls + archivedCalls).filter { seen.insert($0.id).inserted })
            .calls(on: Date(), clock: clock)
    }
    var savedReports: [JournalPeriodReport] {
        JournalArchive.reports(live: workflow.reports, archives: [JournalArchive.Envelope(reports: archivedReports)])
    }
    var remainingCalls: Int { max(0, workflow.dailyCallLimit - todayCalls.count) }

    public convenience init(planDesk: Bool = false, demo: Bool = false, demoLanguage: String? = nil,
                            demoLanguageSetup: Bool = false) {
        var defaults = JournalSettings()
        defaults.summaryLanguage = .automatic
        if demo {
            defaults.codexHome = "/demo/codex"
            defaults.claudeHome = "/demo/claude"
            defaults.claudeDesktopSessionsHome = ""
            defaults.uiLanguage = JournalInterfaceLanguage(rawValue: demoLanguage ?? "") ?? .systemDefault
            defaults.languageSetupComplete = !demoLanguageSetup
            defaults.onboardingVersion = demoLanguageSetup ? nil : Self.onboardingVersion
            defaults.summaryLanguage = .automatic
        }
        if planDesk { defaults.timeZoneID = "Asia/Shanghai" }
        if !demo && JournalCLISummarizer.executable(for: .codex) == nil { defaults.summaryEngine = .claude }
        self.init(directory: nil, settings: defaults, planDesk: planDesk, demo: demo, requireLanguageSetup: !planDesk)
    }

    init(directory: URL?, settings defaults: JournalSettings, planDesk: Bool = false,
         demo: Bool = false, summarizer: JournalSummarizing = JournalCLISummarizer(), requireLanguageSetup: Bool = false,
         advisor: JournalAgentAdvising = JournalCLIAgentAdvisor(),
         reporter: JournalPeriodReporting = JournalPeriodReporter(),
         progressDrafter: JournalProgressDrafting = JournalCLIProgressDrafter()) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            // Keep the original storage identity so the rename never hides existing journals.
            .appendingPathComponent(planDesk ? "PlanDeskMac" : "ThreadJournal")
        dataURL = base.appendingPathComponent(planDesk ? "codex-journal.json" : "journal.json")
        indexURL = base.appendingPathComponent(planDesk ? "codex-journal-index.json" : "index.json")
        agentHistoryURL = base.appendingPathComponent(planDesk ? "codex-journal-advice.json" : "journal-advice.json")
        workflowURL = base.appendingPathComponent(planDesk ? "codex-journal-workflow.json" : "journal-workflow.json")
        threadProgressURL = base.appendingPathComponent(planDesk ? "codex-journal-progress.json" : "journal-progress.json")
        settings = defaults
        autoSummarize = false
        isDemo = demo
        requiresLanguageSetup = requireLanguageSetup
        self.summarizer = summarizer
        self.advisor = advisor
        self.reporter = reporter
        self.progressDrafter = progressDrafter
        reader = JournalReader(settings: defaults, indexURL: indexURL)
        if !demo {
            do { try JournalBackupFile.recover(in: base, expectedFiles: [dataURL, agentHistoryURL, workflowURL, threadProgressURL]) }
            catch {
                canSave = false; canSaveAgentHistory = false
                workflowError = "检测到未完成的恢复，请重新打开以恢复原文件；不会继续写入或调用模型。"
                errorMessage = error.localizedDescription
            }
        }
        if !demo && FileManager.default.fileExists(atPath: dataURL.path) {
            do {
                let bytes = try JournalFileAccess.read(dataURL)!
                expectedJournalBytes = bytes
                let saved = try JSONDecoder().decode(Saved.self, from: bytes)
                guard [1, 2].contains(saved.version) else { throw JournalError.message("日志版本不兼容") }
                drafts = saved.drafts
                draftTimeZones = saved.draftTimeZones ?? [:]
                timeZoneMigrationSource = saved.pendingTimeZoneActivities
                autoSummarize = saved.autoSummarize
                settings = saved.settings ?? defaults
                reader = JournalReader(settings: settings, indexURL: indexURL)
                if saved.version == 1 { legacyBytes = bytes }
            } catch {
                canSave = false
                errorMessage = "工作日志读取失败，原文件已保留；请备份并修复后重启。"
            }
        }
        if demo {
            loadDemo()
            loadDemoAdvice()
            loadDemoProgress()
        } else {
            do { workflow = try JournalWorkflowFile.load(workflowURL) }
            catch { workflowError = "状态与调用记录读取失败；模型调用已停止，原文件已保留，可从备份恢复。" }
            do { threadProgress = try JournalProgressFile.load(threadProgressURL) }
            catch { progressStorageError = "任务树历史读取失败，原文件已保留；请从完整备份恢复。" }
            do {
                agentHistory = try JournalAgentHistoryFile.load(agentHistoryURL)
                agentResult = agentHistory.first
            } catch {
                canSaveAgentHistory = false
                agentHistoryError = "推进建议历史读取失败，原文件已保留；请备份并修复后重启。"
            }
        }
        isInitializing = false
    }

    func activities(on date: Date) -> [JournalActivity] {
        let day = clock.key(date)
        return activities.filter { $0.day == day }.sorted { $0.lastActivity > $1.lastActivity }
    }
    func history(for threadKey: String) -> [JournalActivity] {
        activities.filter { $0.threadKey == threadKey }.sorted { $0.day > $1.day }
    }
    func draft(for activity: JournalActivity) -> JournalDraft { drafts[activity.id] ?? JournalDraft() }
    func refresh(on date: Date) async {
        requestedDate = date
        guard !isDemo, !isLoading, !needsOnboarding else { return }
        isLoading = true
        progressText = l("正在读取 Codex 与 Claude Code…")
        do {
            let snapshot = try await reader.scan()
            var scannedMessages: [String: Set<String>] = [:]
            for activity in snapshot.activities { scannedMessages[activity.threadKey, default: []].formUnion(activity.messageIDs) }
            var merged: [String: JournalActivity] = [:]
            for var activity in workflow.library where settings.includesProject(activity.cwd) && settings.includesProvider(activity.source) {
                // A restored metadata row must not leave a phantom old day after
                // its messages have been regrouped by a real transcript scan.
                if !activity.messageIDs.isEmpty,
                   activity.messageIDs.isSubset(of: scannedMessages[activity.threadKey] ?? []) { continue }
                let first = clock.key(activity.firstActivity)
                if first == clock.key(activity.lastActivity) { activity.day = first }
                if var existing = merged[activity.id] { existing.merge(activity); merged[activity.id] = existing }
                else { merged[activity.id] = activity }
            }
            for activity in snapshot.activities { merged[activity.id] = activity }
            activities = Array(merged.values).sorted { $0.lastActivity > $1.lastActivity }
            if let previous = timeZoneMigrationSource {
                timeZoneMigrationSource = nil
                migrateDrafts(from: previous)
            }
            warningMessage = snapshot.warnings.isEmpty ? nil : snapshot.warnings.joined(separator: " ")
            lastRefreshed = Date()
            await loadArchivedHistory()
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
        if !isSummarizing { progressText = "" }
        if autoSummarize && canSave { generateAutomatic() }
    }
    func loadArchivedHistory() async {
        guard !isDemo, !archiveHistoryLoaded else { return }
        let folder = archiveURL
        do {
            let archives = try await Task.detached(priority: .utility) { try JournalArchive.load(in: folder) }.value
            agentHistory = JournalArchive.advice(live: agentHistory, archives: archives)
            archivedReports = JournalArchive.reports(live: [], archives: archives)
            var seen = Set<UUID>()
            archivedCalls = archives.flatMap(\.calls).filter { seen.insert($0.id).inserted }
            agentResult = agentResult ?? agentHistory.first
            archiveHistoryError = nil
            archiveHistoryLoaded = true
        } catch {
            archiveHistoryError = "历史归档读取失败，原文件已保留；无法导出完整备份，请检查归档文件。"
            warningMessage = [warningMessage, archiveHistoryError].compactMap { $0 }.joined(separator: " ")
        }
    }
    func followThread(_ key: String?) {
        selectedHistoryThreadKey = key
        if autoSummarize { generateAutomatic() }
    }
    private func generateAutomatic() {
        guard !workflow.automaticPaused, workflowError == nil,
              remainingCalls > 0, todayCalls.filter({ $0.kind == .automatic }).count < workflow.automaticCallLimit else { return }
        generate(automaticPending, automatic: true)
    }
    var automaticPending: [JournalActivity] {
        let timeline = workflow.includeHistoricalAutomaticDrafts ? (selectedHistoryThreadKey.map { history(for: $0) } ?? []) : []
        var seen = Set<String>()
        return (activities(on: requestedDate) + timeline).filter {
            guard seen.insert($0.id).inserted, !$0.excerpts.isEmpty else { return false }
            let draft = draft(for: $0)
            return draft.fingerprint != $0.fingerprint && !draft.isConfirmed && draft.editedSummary == nil
        }
    }
    func generate(_ input: [JournalActivity], automatic: Bool = false, force: Bool = false) {
        guard !isInitializing, !isModelBusy, canSave, workflowError == nil, !isDemo, !needsLanguageSetup, !needsOnboarding else { return }
        var seen = Set<String>()
        let pending = input.filter { seen.insert($0.id).inserted }.filter { activity in
            guard !activity.excerpts.isEmpty else { return false }
            let draft = draft(for: activity)
            if !force && draft.fingerprint == activity.fingerprint { return false }
            if automatic {
                if draft.isConfirmed || draft.editedSummary != nil { return false }
                if activity.lastActivity.timeIntervalSinceNow > -60 { return false }
                if let attempted = lastAttempts[activity.id], attempted.timeIntervalSinceNow > -300 { return false }
            }
            return true
        }
        guard !pending.isEmpty else { return }
        let generationSettings = settings
        isSummarizing = true
        errorMessage = nil
        summarizingIDs = Set(pending.map(\.id))
        generationTask = Task {
            var failed = false
            defer {
                isSummarizing = false
                summarizingIDs = []
                progressText = ""
                generationTask = nil
                if autoSummarize && !failed && !Task.isCancelled { generateAutomatic() }
            }
            var completed = 0
            for start in stride(from: 0, to: pending.count, by: 4) {
                if Task.isCancelled { break }
                let batch = Array(pending[start..<min(start + 4, pending.count)])
                for activity in batch { lastAttempts[activity.id] = Date() }
                progressText = l("正在生成草稿 %d/%d…", completed, pending.count)
                var callID: UUID?
                do {
                    callID = try reserveCall(automatic ? .automatic : .summary, settings: generationSettings, itemCount: batch.count)
                    let result = try await summarizer.summarize(batch, settings: generationSettings)
                    if Task.isCancelled { finishCall(callID, outcome: .cancelled); break }
                    try JournalCLISummarizer.validate(result.entries, for: batch)
                    let sources = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })
                    for row in result.entries {
                        guard let source = sources[row.id] else { continue }
                        var draft = drafts[row.id] ?? JournalDraft()
                        draft.summary = row.summary
                        draft.nextStep = row.nextStep
                        draft.status = row.status
                        if draft.category == "未分类" { draft.category = row.category }
                        draft.fingerprint = source.fingerprint
                        draft.generatedAt = Date()
                        draft.summaryEngine = result.engine
                        draft.summaryModel = result.model
                        drafts[row.id] = draft
                    }
                    save()
                    finishCall(callID, outcome: .succeeded)
                    completed += batch.count
                } catch {
                    finishCall(callID, outcome: Task.isCancelled ? .cancelled : .failed)
                    failed = true
                    if !Task.isCancelled { errorMessage = error.localizedDescription }
                    break
                }
            }
        }
    }
    func cancelGeneration() { generationTask?.cancel() }
    var agentInput: JournalAgentInput { currentAgentInput().input }
    /// Views read the input and its fingerprint on every render. Rebuild only after notes,
    /// activities or workflow change, or once a "recently active" thread has gone idle.
    private func currentAgentInput() -> (input: JournalAgentInput, fingerprint: String, expires: Date) {
        let now = Date()
        if let cached = cachedAgentInput, now < cached.expires { return cached }
        var input = JournalAgentInput.build(activities: activities.filter {
            settings.includesProvider($0.source) && settings.includesProject($0.cwd)
        }, drafts: drafts, now: now, limit: Int.max, threads: workflow.threads, feedback: workflow.feedback)
        // Prefer usable notes before applying the existing 40-thread bound. A
        // single older summarized thread must not be hidden by 40 empty ones.
        let ready = input.candidates.filter(Self.hasAdviceSummary)
        let missing = input.candidates.filter { !Self.hasAdviceSummary($0) }
        input.candidates = Array((ready + missing).prefix(40))
        let expires = activities.lazy.map { $0.lastActivity.addingTimeInterval(60) }.filter { $0 > now }.min() ?? .distantFuture
        let value = (input: input, fingerprint: input.fingerprint, expires: expires)
        cachedAgentInput = value
        return value
    }
    var canAnalyzeProgress: Bool { canEdit && canManageWorkflow && (canSaveAgentHistory || isDemo) }
    static func hasAdviceSummary(_ candidate: JournalAgentCandidate) -> Bool {
        candidate.records.contains { !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var adviceReadyThreadCount: Int { agentInput.candidates.filter(Self.hasAdviceSummary).count }
    var canStartProgressAnalysis: Bool {
        canAnalyzeProgress && !isModelBusy && !isLoading && !needsLanguageSetup && !needsOnboarding
            && adviceReadyThreadCount > 0 && (isDemo || remainingCalls > 0)
    }
    var advicePreparationActivities: [JournalActivity] {
        let ids = Set(agentInput.candidates.flatMap { $0.records.map(\.id) })
        return activities.filter { ids.contains($0.id) }.sorted { $0.lastActivity > $1.lastActivity }
    }
    func canGeneratePreparedSummary(_ activity: JournalActivity) -> Bool {
        guard let current = activities.first(where: { $0.id == activity.id }),
              current.fingerprint == activity.fingerprint,
              settings.includesProvider(activity.source), settings.includesProject(activity.cwd) else { return false }
        let draft = draft(for: activity)
        return !isDemo && !isLoading && !isModelBusy && canEdit && canManageWorkflow
            && !needsLanguageSetup && !needsOnboarding && remainingCalls > 0
            && !activity.excerpts.isEmpty && draft.editedSummary == nil && !draft.isConfirmed
            && draft.fingerprint != activity.fingerprint
    }
    func modelAccountNotice(for request: JournalSettings) -> String {
        [l("请求引擎：%@ CLI", request.summaryEngine.label),
         l("请求模型：%@", request.model.isEmpty ? l("CLI 默认（实际模型将在返回后报告）") : request.model),
         l("使用你在这台 Mac 上的 CLI 登录／配置，不是开发者账户。额度和费用归属该 CLI 当前账户及其配置的提供方；AgentJournal 不提供免费模型额度，也无法预报具体费用。"),
         l("本地调用上限不是供应商剩余额度或账单。")].joined(separator: "\n")
    }
    var agentHistoryDays: [String] { Set(agentHistory.map(\.day)).sorted(by: >) }
    func advice(on day: String) -> [JournalAgentResult] { agentHistory.filter { $0.day == day } }
    func hasAdvice(on date: Date) -> Bool {
        let day = clock.key(date)
        return agentHistory.contains { $0.day == day }
    }
    func adviceIsOutdated(_ result: JournalAgentResult) -> Bool {
        guard !isLoading && (lastRefreshed != nil || isDemo) else { return false }
        // Saved snapshots never change, so their fingerprints are computed once.
        let saved = resultFingerprints[result.id] ?? result.input.fingerprint
        resultFingerprints[result.id] = saved
        return saved != currentAgentInput().fingerprint
    }
    var agentResultIsOutdated: Bool {
        guard let result = agentResult else { return false }
        return adviceIsOutdated(result)
    }
    func analyzeProgress() {
        guard !isInitializing, !isModelBusy, !isLoading, canAnalyzeProgress, !needsLanguageSetup, !needsOnboarding else { return }
        let input = agentInput
        guard !input.candidates.isEmpty else { return }
        guard input.candidates.contains(where: Self.hasAdviceSummary) else {
            agentError = "当前候选没有可用摘要。先生成或编辑一条每日摘要，再分析；本次未调用模型。"
            return
        }
        agentError = nil
        if isDemo {
            let result = JournalCLIAgentAdvisor.demo(input, settings: settings)
            let snapshot = JournalAgentResult(response: result.response, input: input, engine: result.engine, model: result.model,
                timeZoneID: settings.timeZoneID, languageCode: settings.summaryLanguage.rawValue)
            agentResult = snapshot
            agentHistory = JournalAgentHistoryFile.sorted([snapshot] + agentHistory)
            return
        }
        let generationSettings = settings.adviceSettings
        isAdvising = true
        adviceStartedAt = Date()
        advicePhase = .preparing
        advisorTask = Task {
            defer { isAdvising = false; advicePhase = .idle; adviceStartedAt = nil; advisorTask = nil }
            var callID: UUID?
            do {
                callID = try reserveCall(.advice, settings: generationSettings, itemCount: input.candidates.count)
                advicePhase = .waitingForCLI
                let result = try await advisor.advise(input, settings: generationSettings)
                guard !Task.isCancelled else { finishCall(callID, outcome: .cancelled); return }
                advicePhase = .checking
                try JournalCLIAgentAdvisor.validate(result.response, input: input)
                // Keep the original input snapshot for inspectable evidence. Never change notes or source threads.
                let snapshot = JournalAgentResult(response: result.response, input: input, engine: result.engine, model: result.model,
                    timeZoneID: generationSettings.timeZoneID, languageCode: generationSettings.summaryLanguage.rawValue)
                agentResult = snapshot
                advicePhase = .saving
                saveAdvice(snapshot)
                finishCall(callID, outcome: .succeeded)
            } catch {
                finishCall(callID, outcome: Task.isCancelled ? .cancelled : .failed)
                if !Task.isCancelled { agentError = error.localizedDescription }
            }
        }
    }
    func cancelAdvice() { advisorTask?.cancel() }
    func retrySavingAdvice() {
        guard !isAdvising, canSaveAgentHistory, !isDemo, let result = agentResult,
              !agentHistory.contains(where: { $0.id == result.id }) else { return }
        saveAdvice(result)
    }
    private func saveAdvice(_ snapshot: JournalAgentResult) {
        do {
            _ = try JournalAgentHistoryFile.save([snapshot], to: agentHistoryURL)
            agentHistory = JournalArchive.advice(live: [snapshot] + agentHistory, archives: [])
            agentHistoryError = nil
        } catch {
            agentHistoryError = "本次建议尚未保存；已有历史未删除，请检查存储空间和权限后重试。"
        }
    }
    func update(_ activity: JournalActivity, summary: String, nextStep: String, category: String, confirmed: Bool) {
        guard canEdit else { return }
        var draft = draft(for: activity)
        draft.editedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.editedNextStep = nextStep.trimmingCharacters(in: .whitespacesAndNewlines)
        // A manual note describes this source snapshot, even without confirmation.
        draft.fingerprint = activity.fingerprint
        draft.category = category
        draft.confirmedAt = confirmed ? Date() : nil
        draft.confirmedFingerprint = confirmed ? activity.fingerprint : nil
        drafts[activity.id] = draft
        save()
    }
    func saveSettings(_ new: JournalSettings) throws {
        guard !isLoading, !isModelBusy else { throw JournalError.message("请等待读取或摘要结束，再修改设置。") }
        guard TimeZone(identifier: new.timeZoneID) != nil else { throw JournalError.message("时区无效，例如 Asia/Shanghai 或 America/New_York。") }
        guard new.codexHome.hasPrefix("/"), new.claudeHome.hasPrefix("/") else { throw JournalError.message("日志目录请填写绝对路径。") }
        if let desktop = new.claudeDesktopSessionsHome, !desktop.isEmpty, !desktop.hasPrefix("/") {
            throw JournalError.message("日志目录请填写绝对路径。")
        }
        guard canEdit else { throw JournalError.message("日志文件损坏，暂时不能保存设置。") }
        if new.timeZoneID != settings.timeZoneID && timeZoneMigrationSource == nil && !isDemo {
            timeZoneMigrationSource = activities
            draftTimeZones[settings.timeZoneID] = drafts
        }
        let previousSettings = settings
        settings = new
        reader = JournalReader(settings: new, indexURL: indexURL, previousSettings: previousSettings)
        lastAttempts = [:]
        save()
    }
    func completeOnboarding(_ choices: JournalSettings) throws {
        // This marks only the tour/language choice. It is not consent to model
        // requests and must not enable automatic generation on a fresh journal.
        var value = choices
        value.languageSetupComplete = true
        value.onboardingVersion = Self.onboardingVersion
        try saveSettings(value)
    }
    /// Day IDs can survive a timezone change while referring to different messages.
    /// Move from an immutable source snapshot in two phases; keep timezone copies
    /// for ambiguous groups and round trips, including across app restarts/backups.
    private func migrateDrafts(from previous: [JournalActivity]) {
        func hasUserText(_ draft: JournalDraft) -> Bool {
            draft.editedSummary != nil || draft.editedNextStep != nil || draft.isConfirmed
        }
        let source = drafts
        let current = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
        let ordered = previous.filter { source[$0.id] != nil }.sorted {
            let left = hasUserText(source[$0.id]!), right = hasUserText(source[$1.id]!)
            return left == right ? $0.id < $1.id : left
        }
        var migrated = draftTimeZones[settings.timeZoneID] ?? source
        if draftTimeZones[settings.timeZoneID] == nil {
            for activity in ordered {
                if let replacement = current[activity.id],
                   !activity.messageIDs.isSubset(of: replacement.messageIDs) {
                    migrated.removeValue(forKey: activity.id)
                }
            }
        }
        var claimed = Set<String>(), unmatched = 0
        for activity in ordered {
            let draft = source[activity.id]!
            let matches = activities.filter {
                $0.threadKey == activity.threadKey && !$0.messageIDs.isDisjoint(with: activity.messageIDs)
            }
            if matches.contains(where: { migrated[$0.id] == draft }) { continue }
            guard matches.count == 1, let destination = matches.first,
                  !activity.messageIDs.isEmpty, activity.messageIDs.isSubset(of: destination.messageIDs) else {
                if hasUserText(draft) { unmatched += 1 }; continue
            }
            let target = destination.id
            if migrated[target] == draft { continue }
            let free = migrated[target].map { !hasUserText($0) && hasUserText(draft) } ?? true
            guard !claimed.contains(target), free else {
                if hasUserText(draft) { unmatched += 1 }
                continue
            }
            migrated[target] = draft
            claimed.insert(target)
        }
        drafts = migrated
        save()
        if unmatched > 0 {
            noticeMessage = l("时区更改后，有 %d 条已编辑或确认的笔记未能自动对应到新日期。原笔记未删除，切回原时区即可看到。", unmatched)
        }
    }
    func markdown(for items: [JournalActivity], title: String) -> String {
        var sections = ["# \(title)", "", l("按线程整理 · AgentJournal"), ""]
        for activity in items.sorted(by: { $0.day == $1.day ? $0.lastActivity > $1.lastActivity : $0.day > $1.day }) {
            let draft = draft(for: activity)
            sections += ["## \(activity.day) · \(activity.source.label) · \(activity.title)", "",
                         draft.displaySummary.isEmpty ? l("尚未生成摘要。") : draft.displaySummary, ""]
            if !draft.displayNextStep.isEmpty { sections += [l("后续：%@", draft.displayNextStep), ""] }
            sections += [l("状态：") + l(draft.isConfirmed ? "已确认" : "草稿") + l(" · 分类：") + l.category(draft.category), ""]
        }
        return sections.joined(separator: "\n")
    }

    private func save() {
        guard !isInitializing, canSave, !isDemo else { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            if let legacyBytes {
                let backup = dataURL.deletingLastPathComponent().appendingPathComponent("journal-v1-backup-\(UUID().uuidString).json")
                try legacyBytes.write(to: backup, options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                self.legacyBytes = nil
            }
            let saved = Saved(drafts: drafts, autoSummarize: autoSummarize, settings: settings,
                              draftTimeZones: draftTimeZones.isEmpty ? nil : draftTimeZones,
                              pendingTimeZoneActivities: migrationMetadata)
            let bytes = try JSONEncoder().encode(saved)
            try JournalFileAccess.saveJournal(bytes, to: dataURL, expected: expectedJournalBytes)
            expectedJournalBytes = bytes
        } catch {
            canSave = false
            errorMessage = "工作日志保存失败：\(error.localizedDescription)"
        }
    }

    private var migrationMetadata: [JournalActivity]? {
        timeZoneMigrationSource?.map { original in var value = original; value.excerpts = []; return value }
    }

    private func mutateWorkflow(_ change: (inout JournalWorkflowState) throws -> Void) throws {
        if isDemo { try change(&workflow); return }
        guard workflowError == nil else { throw JournalError.message(workflowError!) }
        workflow = try JournalWorkflowFile.update(workflowURL, change)
    }
    func threadStatus(_ key: String) -> JournalThreadStatus { workflow.threads[key]?.status ?? .active }
    func setThreadStatus(_ status: JournalThreadStatus, for key: String) {
        guard canManageWorkflow, !isAdvising else { return }
        do {
            try mutateWorkflow { $0.threads[key] = JournalThreadState(status: status) }
            noticeMessage = l("AgentJournal 状态已设为“%@”；历史保留，原客户端会话未修改。", l(status.label))
        }
        catch { errorMessage = error.localizedDescription }
    }
    func setFeedback(_ status: JournalFeedbackStatus, suggestion: JournalAgentSuggestion, result: JournalAgentResult) {
        guard canManageWorkflow, !isAdvising,
              isDemo || agentHistory.contains(where: { $0.id == result.id }),
              let candidate = result.input.candidates.first(where: { $0.id == suggestion.threadKey }) else { return }
        let event = JournalAdviceFeedback(resultID: result.id, threadKey: candidate.id,
                                         progressFingerprint: candidate.progressFingerprint, status: status)
        do { try mutateWorkflow { $0.feedback.append(event) } }
        catch { agentError = error.localizedDescription }
    }
    func configureCalls(daily: Int, automatic: Int, paused: Bool, includeHistory: Bool) throws {
        guard canManageWorkflow, (0...1000).contains(daily), (0...1000).contains(automatic) else { throw JournalError.message("调用控制设置无效。") }
        try mutateWorkflow {
            $0.dailyCallLimit = daily; $0.automaticCallLimit = automatic
            $0.automaticPaused = paused; $0.includeHistoricalAutomaticDrafts = includeHistory
        }
        controlNotice = nil
        if paused { cancelGeneration() }
        else if autoSummarize { generateAutomatic() }
    }
    func pauseAutomaticGeneration() {
        do { try configureCalls(daily: workflow.dailyCallLimit, automatic: workflow.automaticCallLimit,
                                paused: true, includeHistory: workflow.includeHistoricalAutomaticDrafts) }
        catch { errorMessage = error.localizedDescription }
        cancelGeneration()
    }
    private func reserveCall(_ kind: JournalCallKind, settings: JournalSettings, itemCount: Int) throws -> UUID {
        do {
            let (state, call) = try JournalWorkflowFile.reserve(workflowURL, kind: kind, settings: settings, itemCount: itemCount)
            workflow = state; controlNotice = nil
            return call.id
        } catch { controlNotice = error.localizedDescription; throw error }
    }
    private func finishCall(_ id: UUID?, outcome: JournalCallOutcome) {
        guard let id else { return }
        do { try mutateWorkflow { value in
            if let index = value.calls.firstIndex(where: { $0.id == id }) { value.calls[index].outcome = outcome }
        } } catch {
            workflowError = "状态与调用记录保存失败；后续模型调用已停止，请备份后重新打开。"
        }
    }
    func periodInput(start: Date, end: Date) -> JournalPeriodInput {
        JournalPeriodInput.build(activities: activities, drafts: drafts, start: clock.key(start), end: clock.key(end),
                                 threads: workflow.threads, timeZoneID: settings.timeZoneID)
    }
    func generateReport(kind: JournalPeriodKind, start: Date, end: Date) {
        guard !isModelBusy, !isLoading, canManageWorkflow, !needsLanguageSetup, !needsOnboarding else { return }
        let input = periodInput(start: start, end: end)
        guard input.start <= input.end, !input.records.isEmpty else { return }
        reportError = nil
        if isDemo {
            let result = JournalPeriodReporter.demo(input, kind: kind, settings: settings)
            workflow.reports.append(result); reportResult = result; return
        }
        let generationSettings = settings
        isReporting = true
        reportTask = Task {
            defer { isReporting = false; reportTask = nil }
            var callID: UUID?
            do {
                callID = try reserveCall(.report, settings: generationSettings, itemCount: input.records.count)
                var result = try await reporter.report(input, kind: kind, settings: generationSettings)
                guard !Task.isCancelled else { finishCall(callID, outcome: .cancelled); return }
                // Preserve exactly the supplied snapshot, never model-chosen metadata.
                result.input = input; result.kind = kind; result.timeZoneID = generationSettings.timeZoneID
                result.languageCode = generationSettings.summaryLanguage.rawValue
                try JournalPeriodReporter.validate(result)
                reportResult = result
                try mutateWorkflow { $0.reports.append(result) }
                finishCall(callID, outcome: .succeeded)
            } catch {
                finishCall(callID, outcome: Task.isCancelled ? .cancelled : .failed)
                if !Task.isCancelled { reportError = error.localizedDescription }
            }
        }
    }
    func cancelReport() { reportTask?.cancel() }
    func progressInput(for key: String) -> JournalProgressInput {
        JournalProgressInput.build(key: key, activities: activities, drafts: drafts,
            existing: threadProgress.latest(key)?.plan)
    }
    @discardableResult
    func saveThreadPlan(_ plan: JournalThreadPlan, for key: String, expected: UUID?,
                        reason: JournalProgressReason = .edit, now: Date = Date()) throws -> JournalProgressSnapshot {
        guard canManageProgress, !isLoading else { throw JournalError.message("任务树暂时不能保存，请检查存储或等待读取结束。") }
        let snapshot = JournalProgressSnapshot(threadKey: key, createdAt: now, day: clock.key(now),
            timeZoneID: settings.timeZoneID, reason: reason, plan: plan)
        if isDemo {
            guard threadProgress.latest(key)?.id == expected else { throw JournalError.message("任务树已由另一个窗口或实例修改，请重新加载后再保存。") }
            var next = threadProgress; next.snapshots.append(snapshot)
            try JournalProgressFile.validate(next); threadProgress = next
        } else {
            threadProgress = try JournalProgressFile.append(snapshot, expected: expected, to: threadProgressURL)
        }
        taskTreeError = nil
        return snapshot
    }
    func reloadThreadPlans() throws {
        guard !isDraftingTasks else { return }
        if !isDemo { threadProgress = try JournalProgressFile.load(threadProgressURL) }
        progressStorageError = nil; taskTreeError = nil
    }
    func draftThreadPlan(for key: String) {
        guard !isInitializing, !isModelBusy, !isLoading, canManageProgress, !needsLanguageSetup, !needsOnboarding else { return }
        let input = progressInput(for: key)
        guard !input.records.isEmpty else { taskTreeError = "先保存至少一条每日摘要，或手动建立任务树。"; return }
        let expected = threadProgress.latest(key)?.id
        let generationSettings = settings
        taskTreeError = nil
        if isDemo {
            do {
                let result = JournalCLIProgressDrafter.demo(input, settings: settings)
                var plan = try JournalCLIProgressDrafter.merge(result.response, input: input)
                plan.engine = result.engine; plan.generatedAt = Date(); plan.languageCode = settings.summaryLanguage.rawValue
                try saveThreadPlan(plan, for: key, expected: expected, reason: .model)
            } catch { taskTreeError = error.localizedDescription }
            return
        }
        isDraftingTasks = true
        taskTreeTask = Task {
            defer { isDraftingTasks = false; taskTreeTask = nil }
            var callID: UUID?
            do {
                callID = try reserveCall(.taskTree, settings: generationSettings, itemCount: input.records.count)
                let result = try await progressDrafter.draft(input, settings: generationSettings)
                guard !Task.isCancelled else { finishCall(callID, outcome: .cancelled); return }
                guard input.fingerprint == progressInput(for: key).fingerprint else {
                    throw JournalError.message("生成期间摘要已变化，本次任务树未保存，请重新生成。")
                }
                var plan = try JournalCLIProgressDrafter.merge(result.response, input: input)
                plan.engine = result.engine; plan.model = result.model
                plan.generatedAt = Date(); plan.languageCode = generationSettings.summaryLanguage.rawValue
                try saveThreadPlan(plan, for: key, expected: expected, reason: .model)
                finishCall(callID, outcome: .succeeded)
            } catch {
                finishCall(callID, outcome: Task.isCancelled ? .cancelled : .failed)
                if !Task.isCancelled { taskTreeError = error.localizedDescription }
            }
        }
    }
    func cancelTaskTree() { taskTreeTask?.cancel() }
    func retrySavingReport() {
        guard !isModelBusy, let result = reportResult, !workflow.reports.contains(where: { $0.id == result.id }) else { return }
        do { try mutateWorkflow { $0.reports.append(result) }; reportError = nil }
        catch { reportError = error.localizedDescription }
    }
    func backupData() throws -> Data {
        guard !isDemo, !isLoading, !isModelBusy else { throw JournalError.message("请等待读取或生成结束，再备份。") }
        return try JournalFileAccess.withLock(directory: dataURL.deletingLastPathComponent()) {
            var state = try JournalWorkflowFile.load(workflowURL)
            var library = Dictionary(uniqueKeysWithValues: state.library.map { ($0.id, $0) })
            for var activity in activities { activity.excerpts = []; library[activity.id] = activity }
            state.library = library.values.sorted { $0.id < $1.id }
            let advice = try JournalAgentHistoryFile.load(agentHistoryURL)
            let journal = try JSONEncoder().encode(Saved(drafts: drafts, autoSummarize: autoSummarize, settings: settings,
                                                        draftTimeZones: draftTimeZones.isEmpty ? nil : draftTimeZones,
                                                        pendingTimeZoneActivities: migrationMetadata))
            let backup = JournalBackupEnvelope(version: 3, journal: journal, advice: advice, workflow: state,
                                               archives: try JournalArchive.load(in: archiveURL),
                                               progress: try JournalProgressFile.load(threadProgressURL))
            let bytes = try JSONEncoder().encode(backup)
            _ = try JournalBackupFile.decode(bytes)
            return bytes
        }
    }
    @discardableResult
    func restoreBackup(_ data: Data) throws -> URL {
        guard !isDemo, !isLoading, !isModelBusy else { throw JournalError.message("请等待读取或生成结束，再恢复。") }
        let backup = try JournalBackupFile.decode(data)
        let source = try JSONDecoder().decode(Saved.self, from: backup.journal)
        // Local source/auth paths and model choices stay local. Restoring must
        // never enable automatic model requests or erase today's counted calls.
        var restoredWorkflow = backup.workflow
        restoredWorkflow.automaticPaused = true
        let latest = (try? JournalWorkflowFile.load(workflowURL)) ?? workflow
        let ids = Set(restoredWorkflow.calls.map(\.id))
        restoredWorkflow.calls += latest.calls.filter { !ids.contains($0.id) }
        var restoredZones = source.draftTimeZones ?? [:]
        var pendingMigration = source.pendingTimeZoneActivities
        if let zone = source.settings?.timeZoneID, zone != settings.timeZoneID, pendingMigration == nil {
            restoredZones[zone] = source.drafts
            pendingMigration = backup.workflow.library
        }
        let saved = Saved(drafts: source.drafts, autoSummarize: false, settings: settings,
                          draftTimeZones: restoredZones.isEmpty ? nil : restoredZones, pendingTimeZoneActivities: pendingMigration)
        let bytes = try JSONEncoder().encode(saved)
        let adviceBytes = try JournalAgentHistoryFile.encoded(backup.advice)
        let workflowBytes = try JSONEncoder().encode(restoredWorkflow)
        // Legacy backups did not contain task trees. Preserve current trees on legacy restore.
        let restoredProgress = try backup.progress ?? JournalProgressFile.load(threadProgressURL)
        let progressBytes = try JSONEncoder().encode(restoredProgress)
        let existingArchives = try JournalArchive.load(in: archiveURL)
        var adviceIDs = Set(existingArchives.flatMap(\.advice).map(\.id) + backup.advice.map(\.id))
        var reportIDs = Set(existingArchives.flatMap(\.reports).map(\.id) + backup.workflow.reports.map(\.id))
        var callIDs = Set(existingArchives.flatMap(\.calls).map(\.id) + restoredWorkflow.calls.map(\.id))
        let imports = (backup.archives ?? []).compactMap { original -> JournalArchive.Envelope? in
            var value = original
            value.advice = value.advice.filter { adviceIDs.insert($0.id).inserted }
            value.reports = value.reports.filter { reportIDs.insert($0.id).inserted }
            value.calls = value.calls.filter { callIDs.insert($0.id).inserted }
            return value.advice.isEmpty && value.reports.isEmpty && value.calls.isEmpty ? nil : value
        }
        let safety = try JournalBackupFile.replace([(dataURL, bytes), (agentHistoryURL, adviceBytes), (workflowURL, workflowBytes),
                                                   (threadProgressURL, progressBytes)],
                                                   directory: dataURL.deletingLastPathComponent(), library: activities, archives: imports)
        let restoredState = try JournalWorkflowFile.load(workflowURL)
        isInitializing = true
        drafts = source.drafts; autoSummarize = false; workflow = restoredState; threadProgress = restoredProgress
        draftTimeZones = restoredZones
        let allArchives = existingArchives + imports
        agentHistory = JournalArchive.advice(live: backup.advice, archives: allArchives); agentResult = agentHistory.first
        archivedReports = JournalArchive.reports(live: [], archives: allArchives)
        var seenCalls = Set<UUID>()
        archivedCalls = allArchives.flatMap(\.calls).filter { seenCalls.insert($0.id).inserted }
        archiveHistoryLoaded = true; archiveHistoryError = nil
        activities = restoredState.library.filter { settings.includesProject($0.cwd) && settings.includesProvider($0.source) }
        expectedJournalBytes = bytes; legacyBytes = nil; canSave = true; canSaveAgentHistory = true
        workflowError = nil; agentHistoryError = nil; errorMessage = nil; reportError = nil
        progressStorageError = nil; taskTreeError = nil
        reportResult = nil; lastAttempts = [:]; timeZoneMigrationSource = pendingMigration
        reader = JournalReader(settings: settings, indexURL: indexURL)
        isInitializing = false
        return safety
    }

    private func loadDemo() {
        let now = clock.calendar.startOfDay(for: Date())
        let examples: [(JournalProvider, String, String, Int, String)] = settings.uiLanguage == .english ? [
            (.codex, "demo-codex-planner", "Plans with structure, progress in sight", 0, "Completed calendar task editing and deadline changes, and verified that subtasks inherit the previous date. Daily activity tracking is next."),
            (.claude, "demo-claude-research", "Research notes: from questions to conclusions", 0, "Reviewed the literature's main assumptions and recorded three explanations to test against the results. The analysis plan is ready; experiments have not started."),
            (.codex, "demo-codex-reader", "Two tools, one daily work journal", 0, "Connected local Codex and Claude Code history and grouped messages by day. Added source filters and cross-day review while preserving confirmed notes."),
            (.codex, "demo-codex-planner", "Plans with structure, progress in sight", -1, "Implemented subtasks and priority labels, then designed how to create tasks from a selected calendar day."),
            (.claude, "demo-claude-research", "Research notes: from questions to conclusions", -1, "Created a literature-reading outline with key concepts and evidence that needs further verification."),
            (.codex, "demo-codex-planner", "Plans with structure, progress in sight", -2, "Discussed the four planning categories and decided to keep tasks separate from recurring daily activities.")
        ] : [
            (.codex, "demo-codex-planner", "让计划有条理，让进展看得见", 0, "完成月历中的任务编辑与截止日期调整，验证子任务日期会延续上一项。下一步补齐日常工作记录。"),
            (.claude, "demo-claude-research", "研究笔记：从问题到结论", 0, "梳理文献中的核心假设，对照实验结果整理了三条待验证的解释。今天先完成分析方案，尚未开始实验。"),
            (.codex, "demo-codex-reader", "两种工具，一份每日工作日志", 0, "接通 Codex 与 Claude Code 的本地记录，按消息时间分日。完成来源筛选与跨天回看，保留人工确认后的草稿。"),
            (.codex, "demo-codex-planner", "让计划有条理，让进展看得见", -1, "实现任务拆分与优先级标记，为月历选日新增任务确定了交互方案。"),
            (.claude, "demo-claude-research", "研究笔记：从问题到结论", -1, "建立文献阅读提纲，记录关键概念及需要进一步核对的证据。"),
            (.codex, "demo-codex-planner", "让计划有条理，让进展看得见", -2, "讨论了课程、研究、学工和生活四类计划的结构，确定任务与日常工作分开管理。")
        ]
        for (provider, id, title, offset, summary) in examples {
            let date = clock.calendar.date(byAdding: .day, value: offset, to: now)!.addingTimeInterval(12 * 3600)
            var activity = JournalActivity(provider: provider, threadID: id, day: clock.key(date), title: title,
                cwd: "/demo/projects", firstActivity: date, lastActivity: date)
            activity.append(JournalExcerpt(timestamp: date, role: "user", text: title))
            activities.append(activity)
            var draft = JournalDraft()
            draft.summary = summary
            if offset == 0 {
                let en = settings.uiLanguage == .english
                draft.nextStep = provider == .claude
                    ? (en ? "Run the first planned experiment and check the three explanations." : "开展第一组已规划的实验，核对三条解释。")
                    : id == "demo-codex-planner"
                    ? (en ? "Add daily activity tracking and verify the recording flow." : "补齐日常工作记录，并验证记录流程。")
                    : (en ? "Verify the summary editor and cross-day timeline with synthetic records." : "用示例记录验证摘要编辑器与跨天时间线。")
            }
            draft.category = provider == .claude ? "研究" : "生活"
            draft.status = offset == 0 && provider == .claude ? "进行中" : "已完成"
            draft.fingerprint = activity.fingerprint
            draft.summaryEngine = "演示"
            draft.summaryModel = "示例数据 · 未调用模型"
            drafts[activity.id] = draft
        }
    }

    private func loadDemoAdvice() {
        let today = clock.calendar.startOfDay(for: Date())
        for offset in [0, -1, -2] {
            guard let date = clock.calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let generatedAt = date.addingTimeInterval(18 * 3600)
            let day = clock.key(date)
            let input = JournalAgentInput.build(activities: activities.filter { $0.day <= day }, drafts: drafts, now: generatedAt)
            let result = JournalCLIAgentAdvisor.demo(input, settings: settings)
            agentHistory.append(JournalAgentResult(response: result.response, input: input, engine: result.engine, model: result.model,
                generatedAt: generatedAt, timeZoneID: settings.timeZoneID, languageCode: settings.summaryLanguage.rawValue))
        }
        agentHistory = JournalAgentHistoryFile.sorted(agentHistory)
        agentResult = agentHistory.first
    }
    private func loadDemoProgress() {
        let today = clock.calendar.startOfDay(for: Date())
        for key in Set(activities.map(\.threadKey)).sorted() {
            let input = progressInput(for: key)
            guard !input.records.isEmpty else { continue }
            let result = JournalCLIProgressDrafter.demo(input, settings: settings)
            guard var plan = try? JournalCLIProgressDrafter.merge(result.response, input: input) else { continue }
            plan.engine = "演示"; plan.languageCode = settings.summaryLanguage.rawValue
            // Synthetic checkpoints are examples, never inferred confirmations of real work.
            let yesterday = clock.calendar.date(byAdding: .day, value: -1, to: today)!.addingTimeInterval(18 * 3600)
            let previousInput = JournalProgressInput.build(key: key, activities: activities.filter { $0.day <= clock.key(yesterday) },
                drafts: drafts, existing: nil)
            if !previousInput.records.isEmpty {
                let previousResult = JournalCLIProgressDrafter.demo(previousInput, settings: settings)
                if let previousPlan = try? JournalCLIProgressDrafter.merge(previousResult.response, input: previousInput) {
                    _ = try? saveThreadPlan(previousPlan, for: key, expected: nil, reason: .model, now: yesterday)
                }
            }
            if let index = plan.nodes.firstIndex(where: { $0.id == "foundation" }) {
                plan.nodes[index].status = .completed; plan.nodes[index].confirmedAt = Date()
                plan.nodes[index].userEdited = true
            }
            plan.scopeConfirmed = plan.kind == .fixed
            _ = try? saveThreadPlan(plan, for: key, expected: threadProgress.latest(key)?.id, reason: .edit)
        }
    }
}
