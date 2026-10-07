import Foundation

public struct PortableConfiguration: Codable, Equatable, Sendable {
    public var codexHome: String
    public var claudeHome: String
    public var sources = "both"
    public var engine = "codex"
    public var model = ""
    public var interfaceLanguage = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
    public var summaryLanguage = "auto"
    public var timeZoneID = TimeZone.current.identifier
    public var executable = ""
    public var dailyCallLimit = 20

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path
        claudeHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? home.appendingPathComponent(".claude").path
    }
    public func diagnostic(_ message: String) -> String {
        guard interfaceLanguage == "en" else { return message }
        let translations = [
            "设置无效：请填写绝对目录，并检查来源、语言、时区和调用上限。": "Invalid settings: use absolute folders and check provider, language, timezone and call limit.",
            "原型数据格式无效；原文件已保留。": "Invalid prototype data; the original file was preserved.",
            "正在读取记录或生成摘要，请等待完成或停止后再操作。": "History or a summary is being processed. Wait for completion or stop generation first.",
            "记录不存在或笔记过长，本次未保存。": "Entry not found or note too long; nothing was saved.",
            "需要先确认将选中记录的片段交给摘要模型。": "Confirm consent before sending selected excerpts to the summary model.",
            "每次最多生成 10 条有对话依据、且未经人工编辑或确认的记录；不会覆盖手工笔记。": "Select at most 10 entries with conversation evidence, without human edits or confirmation. Handwritten notes are protected.",
            "摘要格式无效，本次未保存。": "Invalid summary format; nothing was saved.",
            "日志正在被另一个实例使用，或存储目录无法写入。": "Another instance is using the journal, or the storage folder cannot be written.",
            "Windows 摘要引擎必须是现有的 .exe 文件；不执行 .cmd、.bat 或 PowerShell 脚本。": "Choose an existing Windows .exe. The app never executes .cmd, .bat or PowerShell scripts.",
            "未找到 Windows CLI；请在设置中选择原生 .exe，或安装 Node.js 与 npm 版 CLI。": "Windows CLI not found. Choose a native .exe, or install Node.js and the npm CLI.",
            "未找到标准 npm CLI 入口；请指定原生 .exe。WSL 模型调用暂不支持。": "Standard npm CLI entry point not found. Choose a native .exe; WSL model invocation is not supported yet."
        ]
        return translations[message] ?? JournalText(.english).message(message)
    }
    func validated() throws -> Self {
        var copy = self
        copy.codexHome = codexHome.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.claudeHome = claudeHome.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["both", "codex", "claude"].contains(sources), ["codex", "claude"].contains(engine),
              ["zh", "en"].contains(interfaceLanguage), ["zh", "en", "auto"].contains(summaryLanguage),
              TimeZone(identifier: timeZoneID) != nil, (0...1000).contains(dailyCallLimit), copy.model.count <= 300,
              Self.absolute(copy.codexHome), Self.absolute(copy.claudeHome),
              copy.executable.isEmpty || Self.absolute(copy.executable) else {
            throw JournalError.message("设置无效：请填写绝对目录，并检查来源、语言、时区和调用上限。")
        }
        return copy
    }
    private static func absolute(_ path: String) -> Bool {
        guard !path.isEmpty, !path.contains("\0") else { return false }
        #if os(Windows)
        return path.hasPrefix("\\\\") || path.range(of: "^[A-Za-z]:[\\\\/]", options: .regularExpression) != nil
        #else
        return path.hasPrefix("/")
        #endif
    }
    var settings: JournalSettings {
        var value = JournalSettings()
        value.codexHome = codexHome; value.claudeHome = claudeHome
        // Desktop metadata paths/deep links are not yet verified on Windows.
        value.claudeDesktopSessionsHome = ""
        value.sourceSelection = JournalSourceSelection(rawValue: sources) ?? .both
        value.summaryEngine = JournalProvider(rawValue: engine) ?? .codex
        value.model = model; value.timeZoneID = timeZoneID
        value.uiLanguage = JournalInterfaceLanguage(rawValue: interfaceLanguage) ?? .english
        value.summaryLanguage = JournalSummaryLanguage(rawValue: summaryLanguage) ?? .automatic
        return value
    }
    // Changing folders/timezone creates a distinct note namespace, rather than
    // attaching old notes to a different day's messages. Switching back restores it.
    var scope: String { JournalClock.hash("\(codexHome)|\(claudeHome)|\(timeZoneID)") }
}

public struct PortableEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var threadKey: String
    public var day: String
    public var title: String
    public var provider: String
    public var project: String
    public var messageCount: Int
    public var lastActivity: Date
    public var summary: String
    public var nextStep: String
    public var status: String
    public var category: String
    public var confirmed: Bool
    public var stale: Bool
    public var summaryModel: String
    public var preview: [String]
    public var canGenerate: Bool
}

public struct PortableSnapshot: Sendable {
    public var entries: [PortableEntry]
    public var warnings: [String]
    public var remainingCalls: Int
}

/// Public, Foundation-only boundary for the Windows UI. It shares the existing
/// reader, prompt, response validation and file locks with the macOS app.
public actor PortableJournal {
    private struct Document: Codable {
        var format = "AgentJournal Windows Prototype"
        var version = 1
        var configuration = PortableConfiguration()
        var drafts: [String: JournalDraft] = [:]
        var library: [String: [JournalActivity]] = [:]
    }
    private let directory: URL
    private let documentURL: URL
    private let workflowURL: URL
    private var document: Document
    private var expected: Data?
    private var reader: JournalReader
    private var activities: [JournalActivity] = []
    private var warnings: [String] = []
    private var busy = false
    var summarizer: JournalSummarizing = JournalCLISummarizer()

    public static var defaultDirectory: URL {
        #if os(Windows)
        let root = JournalWindowsCLI.environmentValue("LOCALAPPDATA", in: ProcessInfo.processInfo.environment)
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local")
        return root.appendingPathComponent("AgentJournal/WindowsPrototype")
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentJournal/WindowsPrototype")
        #endif
    }
    public init(directory: URL? = nil) throws {
        let directory = directory ?? Self.defaultDirectory
        self.directory = directory
        documentURL = directory.appendingPathComponent("prototype-journal.json")
        workflowURL = directory.appendingPathComponent("prototype-workflow.json")
        expected = try JournalFileAccess.read(documentURL)
        if let expected {
            let saved = try JSONDecoder().decode(Document.self, from: expected)
            try Self.validate(saved)
            document = saved
        } else { document = Document() }
        document.configuration = try document.configuration.validated()
        reader = JournalReader(settings: document.configuration.settings,
                               indexURL: directory.appendingPathComponent("index-\(document.configuration.scope).json"))
        activities = document.library[document.configuration.scope] ?? []
    }
    private static func validate(_ document: Document) throws {
        guard document.format == "AgentJournal Windows Prototype", document.version == 1,
              document.drafts.count <= 100000, document.library.count <= 1000,
              document.drafts.allSatisfy({ key, draft in
                  key.count <= 600 && draft.displaySummary.count <= 20000 && draft.displayNextStep.count <= 10000
                    && (draft.fingerprint.isEmpty || draft.fingerprint.count == 64)
                    && (draft.generatedAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
                    && (draft.confirmedAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
              }) else { throw JournalError.message("原型数据格式无效；原文件已保留。") }
        for (scope, activities) in document.library {
            guard scope.count == 64, activities.count <= 100000 else {
                throw JournalError.message("原型数据格式无效；原文件已保留。")
            }
            // In particular, reject duplicate IDs before constructing a Dictionary.
            try JournalWorkflowFile.validate(JournalWorkflowState(library: activities))
        }
    }
    public func configuration() -> PortableConfiguration { document.configuration }
    private func requireIdle() throws {
        guard !busy else { throw JournalError.message("正在读取记录或生成摘要，请等待完成或停止后再操作。") }
    }
    private func persist(_ value: Document) throws {
        let bytes = try JSONEncoder().encode(value)
        try JournalFileAccess.saveJournal(bytes, to: documentURL, expected: expected)
        expected = bytes; document = value
    }
    public func saveConfiguration(_ configuration: PortableConfiguration) throws {
        try requireIdle()
        let configuration = try configuration.validated()
        var next = document
        next.configuration = configuration
        try persist(next)
        reader = JournalReader(settings: configuration.settings,
                               indexURL: directory.appendingPathComponent("index-\(configuration.scope).json"))
        activities = document.library[configuration.scope] ?? []
    }
    public func refresh() async throws -> PortableSnapshot {
        try requireIdle(); busy = true; defer { busy = false }
        let result = try await reader.scan()
        try Task.checkCancellation()
        let scope = document.configuration.scope
        var combined = Dictionary(uniqueKeysWithValues: (document.library[scope] ?? []).map { ($0.id, $0) })
        for activity in result.activities { combined[activity.id] = activity }
        activities = Array(combined.values)
        warnings = result.warnings
        var next = document
        next.library[scope] = activities.map { activity in
            var metadata = activity; metadata.excerpts = []; return metadata
        }
        try persist(next)
        return try snapshot()
    }
    public func snapshot() throws -> PortableSnapshot {
        let settings = document.configuration.settings
        var entries: [PortableEntry] = []
        for activity in activities where settings.includesProvider(activity.source) {
            let draft = document.drafts[noteKey(activity.id)] ?? JournalDraft()
            let preview: [String] = activity.excerpts.suffix(4).map { $0.role + ": " + String($0.text.prefix(500)) }
            let row = PortableEntry(id: activity.id, threadKey: activity.threadKey, day: activity.day,
                title: activity.title, provider: activity.source.rawValue, project: activity.cwd,
                messageCount: activity.messageCount, lastActivity: activity.lastActivity,
                summary: draft.displaySummary, nextStep: draft.displayNextStep, status: draft.status,
                category: draft.category, confirmed: draft.isConfirmed && draft.confirmedFingerprint == activity.fingerprint,
                stale: !draft.fingerprint.isEmpty && draft.fingerprint != activity.fingerprint,
                summaryModel: draft.summaryModel ?? draft.summaryEngine ?? "",
                preview: preview, canGenerate: !activity.excerpts.isEmpty && draft.editedSummary == nil && !draft.isConfirmed)
            entries.append(row)
        }
        entries.sort { $0.day == $1.day ? $0.lastActivity > $1.lastActivity : $0.day > $1.day }
        let workflow = try JournalWorkflowFile.load(workflowURL)
        let calls = workflow.calls(on: Date(), clock: JournalClock(timeZoneID: settings.timeZoneID)).count
        return PortableSnapshot(entries: entries, warnings: warnings,
                                remainingCalls: max(0, document.configuration.dailyCallLimit - calls))
    }
    private func noteKey(_ id: String) -> String { document.configuration.scope + ":" + id }
    public func saveNote(id: String, summary: String, nextStep: String, confirmed: Bool) throws -> PortableSnapshot {
        try requireIdle()
        guard let activity = activities.first(where: { $0.id == id }),
              summary.count <= 20000, nextStep.count <= 10000 else {
            throw JournalError.message("记录不存在或笔记过长，本次未保存。")
        }
        let key = noteKey(id)
        var next = document
        var draft = next.drafts[key] ?? JournalDraft()
        draft.editedSummary = summary; draft.editedNextStep = nextStep; draft.fingerprint = activity.fingerprint
        draft.confirmedAt = confirmed ? Date() : nil
        draft.confirmedFingerprint = confirmed ? activity.fingerprint : nil
        next.drafts[key] = draft
        try persist(next)
        return try snapshot()
    }
    /// Explicit consent is required even when called outside the desktop UI.
    public func generate(ids: [String], consent: Bool) async throws -> PortableSnapshot {
        try requireIdle()
        guard consent else { throw JournalError.message("需要先确认将选中记录的片段交给摘要模型。") }
        let ids = Set(ids)
        let selected = activities.filter { ids.contains($0.id) && document.configuration.settings.includesProvider($0.source) }
        guard !ids.isEmpty, selected.count == ids.count, selected.count <= 10,
              selected.allSatisfy({ !$0.excerpts.isEmpty }),
              selected.allSatisfy({ let draft = document.drafts[noteKey($0.id)]; return draft?.editedSummary == nil && draft?.confirmedAt == nil }) else {
            throw JournalError.message("每次最多生成 10 条有对话依据、且未经人工编辑或确认的记录；不会覆盖手工笔记。")
        }
        busy = true; defer { busy = false }
        let configuration = document.configuration
        let settings = configuration.settings
        _ = try JournalWorkflowFile.update(workflowURL) { $0.dailyCallLimit = configuration.dailyCallLimit }
        let (_, call) = try JournalWorkflowFile.reserve(workflowURL, kind: .summary, settings: settings, itemCount: selected.count)
        do {
            try Task.checkCancellation()
            let batch: JournalSummaryBatch
            if configuration.executable.isEmpty { batch = try await summarizer.summarize(selected, settings: settings) }
            else { batch = try await JournalCLISummarizer(executableOverride: URL(fileURLWithPath: configuration.executable)).summarize(selected, settings: settings) }
            try Task.checkCancellation()
            try JournalCLISummarizer.validate(batch.entries, for: selected)
            var next = document
            for row in batch.entries {
                guard row.summary.count <= 20000, row.nextStep.count <= 10000,
                      let activity = selected.first(where: { $0.id == row.id }) else {
                    throw JournalError.message("摘要格式无效，本次未保存。")
                }
                next.drafts[noteKey(row.id)] = JournalDraft(summary: row.summary, nextStep: row.nextStep,
                    status: row.status, category: row.category, fingerprint: activity.fingerprint,
                    generatedAt: Date(), summaryEngine: batch.engine, summaryModel: batch.model)
            }
            try persist(next)
            try finish(call.id, outcome: .succeeded)
            return try snapshot()
        } catch {
            try? finish(call.id, outcome: error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }
    private func finish(_ id: UUID, outcome: JournalCallOutcome) throws {
        _ = try JournalWorkflowFile.update(workflowURL) { state in
            if let index = state.calls.firstIndex(where: { $0.id == id }) { state.calls[index].outcome = outcome }
        }
    }
    // Test seam is internal; production callers never receive an executable shell.
    func useTestSummarizer(_ summarizer: JournalSummarizing) { self.summarizer = summarizer }

    public static func demoEntries(now: Date = Date()) -> [PortableEntry] {
        let clock = JournalClock(timeZoneID: "UTC")
        return (0..<6).map { index in
            let date = now.addingTimeInterval(-Double(index / 2) * 86400)
            let provider = index % 2 == 0 ? "codex" : "claude"
            let day = clock.key(date), thread = provider == "codex" ? "demo-codex" : "claude:demo-claude"
            return PortableEntry(id: thread + "|" + day, threadKey: thread, day: day,
                title: provider == "codex" ? "Build a literature review workflow" : "Improve a research notebook",
                provider: provider, project: "Synthetic demo · no real conversations", messageCount: 4 + index,
                lastActivity: date, summary: index < 2 ? "Compared implementation options and identified the next validation step." : "",
                nextStep: "Validate the approach with a small example.", status: "待确认", category: "研究",
                confirmed: false, stale: false, summaryModel: "Demo · no model called",
                preview: ["user: Please compare the options.", "assistant: We can validate this with a small prototype."], canGenerate: true)
        }
    }
}
