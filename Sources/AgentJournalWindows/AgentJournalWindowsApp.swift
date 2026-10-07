import Foundation
import SwiftCrossUI
import DefaultBackend
import AgentJournalCore

@main
struct AgentJournalWindowsApp: App {
    var body: some Scene {
        WindowGroup("AgentJournal · Windows Prototype") { JournalPrototypeView() }
            .defaultSize(width: 1200, height: 800)
    }
}

private struct JournalPrototypeView: View {
    private let purple = Color(red: 0.46, green: 0.28, blue: 0.78)
    private let blue = Color(red: 0.18, green: 0.43, blue: 0.91)
    private let orange = Color(red: 0.91, green: 0.46, blue: 0.18)
    @State private var configuration = PortableConfiguration()
    @State private var savedConfiguration = PortableConfiguration()
    @State private var entries = PortableJournal.demoEntries()
    @State private var journal: PortableJournal?
    @State private var demo = true
    @State private var settingsVisible = false
    @State private var browsing: String? = "day"
    @State private var selectedDay = ""
    @State private var selectedThread = ""
    @State private var selectedID = ""
    @State private var summary = ""
    @State private var nextStep = ""
    @State private var confirmed = false
    @State private var busy = false
    @State private var notice = ""
    @State private var remainingCalls = 20
    @State private var consentVisible = false
    @State private var generation: Task<Void, Never>?

    private var demoOnly: Bool { CommandLine.arguments.contains("--demo-only") }
    private var selected: PortableEntry? { entries.first { $0.id == selectedID } }
    private var dirty: Bool {
        guard let selected else { return false }
        return summary != selected.summary || nextStep != selected.nextStep || confirmed != selected.confirmed
    }
    private var settingsDirty: Bool { configuration != savedConfiguration }
    private var days: [String] { Array(Set(entries.map(\.day))).sorted(by: >) }
    private var threadRows: [PortableEntry] {
        var seen = Set<String>()
        return entries.sorted { $0.lastActivity > $1.lastActivity }.filter { seen.insert($0.threadKey).inserted }
    }
    private var visible: [PortableEntry] {
        entries.filter { browsing == "thread" ? $0.threadKey == selectedThread : $0.day == selectedDay }
    }
    private func tr(_ chinese: String, _ english: String) -> String {
        configuration.interfaceLanguage == "zh" ? chinese : english
    }
    private func binding(_ path: WritableKeyPath<PortableConfiguration, String>) -> Binding<String?> {
        Binding(get: { configuration[keyPath: path] }, set: { if let value = $0 { configuration[keyPath: path] = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(tr("实验版：先验证 Windows 本地记录与摘要流程。不是完整 Mac 版；不会自动执行或继续原线程。",
                    "Experimental: local history and summaries first. Not full macOS parity; never executes or resumes source threads."))
                .font(.system(size: 12)).foregroundColor(.gray)
            if settingsVisible { settings }
            if !notice.isEmpty { Text(notice).font(.system(size: 12)).foregroundColor(purple) }
            if consentVisible { consent }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                navigation.frame(width: 205)
                Divider()
                activityList.frame(width: 305)
                Divider()
                detail
            }
            Spacer()
            Divider()
            Text(tr("本地优先 · 仅主动生成时调用模型 · 原始记录只读 · Codex 蓝色 / Claude Code 橙色",
                    "Local-first · Model calls require consent · Read-only transcripts · Codex blue / Claude Code orange"))
                .font(.system(size: 11)).foregroundColor(.gray)
        }.padding(20).buttonStyle(.plain).onAppear {
            synchronizeSelection()
            if !demoOnly { loadSettings() }
        }.onDisappear { generation?.cancel() }
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("AgentJournal").font(.system(size: 26, weight: .bold)).foregroundColor(purple)
                Text(demo ? tr("演示数据 · 未调用模型", "Demo data · no model calls")
                     : tr("Windows Swift 原型 · 今日剩余调用：", "Windows Swift prototype · calls left today: ") + String(remainingCalls))
                    .font(.system(size: 12)).foregroundColor(.gray)
            }
            Spacer()
            Button(tr("演示", "Demo")) {
                guard !dirty else { return }
                demo = true; entries = PortableJournal.demoEntries(); notice = ""; synchronizeSelection()
            }.disabled(busy || dirty)
            Button(tr("读取本地记录", "Read local history")) { refresh() }
                .disabled(busy || dirty || settingsDirty || demoOnly)
            Button(tr("设置", "Settings")) { settingsVisible.toggle() }.disabled(busy || dirty)
            if busy {
                Text(tr("处理中…", "Working…")).foregroundColor(purple)
                if generation != nil { Button(tr("停止", "Stop")) { generation?.cancel() } }
            }
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("记录来源", "History sources")).frame(width: 120)
                Picker(of: ["both", "codex", "claude"], selection: binding(\.sources)).frame(width: 190)
                Text(tr("应用语言", "Interface language"))
                Picker(of: ["zh", "en"], selection: binding(\.interfaceLanguage)).frame(width: 100)
                Text(tr("摘要语言", "Summary language"))
                Picker(of: ["auto", "zh", "en"], selection: binding(\.summaryLanguage)).frame(width: 110)
            }
            HStack { Text("Codex home").frame(width: 120); TextField("C:\\Users\\Name\\.codex", text: $configuration.codexHome) }
            HStack { Text("Claude home").frame(width: 120); TextField("C:\\Users\\Name\\.claude", text: $configuration.claudeHome) }
            HStack {
                Text(tr("摘要引擎", "Summary engine")).frame(width: 120)
                Picker(of: ["codex", "claude"], selection: binding(\.engine)).frame(width: 190)
                Text(tr("模型 ID", "Model ID"))
                TextField(tr("留空跟随 CLI 默认", "Blank = CLI default"), text: $configuration.model)
            }
            HStack {
                Text(tr("CLI 可执行文件", "CLI executable")).frame(width: 120)
                TextField(tr("留空自动查找；Windows 指定 .exe", "Auto-detect when blank; Windows override must be .exe"), text: $configuration.executable)
            }
            Text(tr("both = 两者；auto = 跟随讨论内容。第一版支持 Windows 原生 CLI / 标准 npm 安装，暂不调用 WSL。",
                    "both = both providers; auto = discussion language. Native Windows CLI / standard npm installs only; no WSL invocation yet."))
                .font(.system(size: 11)).foregroundColor(.gray)
            HStack {
                Text(tr("时区：", "Timezone: ") + configuration.timeZoneID + tr(" · 每日调用上限 20 次", " · 20 calls/day by default"))
                    .font(.system(size: 11)).foregroundColor(.gray)
                Spacer()
                Button(tr("取消修改", "Discard settings")) { configuration = savedConfiguration }
                Button(tr("保存设置", "Save settings")) { saveSettings() }.disabled(busy || demoOnly)
            }
        }.padding(12).background(purple.opacity(0.05))
    }
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(tr("按天", "Days")) { browsing = "day"; synchronizeSelection() }
                Button(tr("按线程", "Threads")) { browsing = "thread"; synchronizeSelection() }
            }.disabled(busy || dirty)
            Text(browsing == "thread" ? tr("线程跨天进展", "Thread timeline") : tr("每日工作记录", "Daily journal"))
                .font(.system(size: 15, weight: .bold)).foregroundColor(purple)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if browsing == "thread" {
                        ForEach(threadRows) { row in
                            Button(row.title) { selectedThread = row.threadKey; synchronizeSelection() }
                                .foregroundColor(row.provider == "codex" ? blue : orange)
                        }
                    } else {
                        ForEach(days, id: \.self) { day in
                            Button(day + "  ·  " + String(entries.filter { $0.day == day }.count)) {
                                selectedDay = day; synchronizeSelection()
                            }.foregroundColor(purple)
                        }
                    }
                }
            }.disabled(busy || dirty)
        }
    }
    private var activityList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(browsing == "thread" ? tr("每天处理了什么", "Work across days") : selectedDay)
                .font(.system(size: 16, weight: .bold)).foregroundColor(purple)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visible) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Button(row.title) { select(row) }
                                .foregroundColor(row.provider == "codex" ? blue : orange)
                                .disabled(busy || dirty)
                            Text((row.provider == "codex" ? "Codex" : "Claude Code") + " · " + row.day)
                                .font(.system(size: 11)).foregroundColor(.gray)
                            Text(row.summary.isEmpty ? tr("尚无摘要 · 可以手动记录或生成草稿", "No summary · write a note or generate a draft") : row.summary)
                                .font(.system(size: 12)).lineLimit(3)
                        }.padding(10).background(selectedID == row.id ? purple.opacity(0.10) : purple.opacity(0.03))
                    }
                }
            }
            if entries.isEmpty {
                Text(tr("没有记录。请检查来源目录；演示不需要安装 CLI。", "No entries. Check the history folders; demo needs no CLI."))
                    .foregroundColor(.gray)
            }
        }
    }
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let selected {
                    Text(selected.title).font(.system(size: 18, weight: .bold))
                        .foregroundColor(selected.provider == "codex" ? blue : orange)
                    Text(selected.day + " · " + String(selected.messageCount) + tr(" 条消息", " messages"))
                        .font(.system(size: 12)).foregroundColor(.gray)
                    Text(selected.project).font(.system(size: 11)).foregroundColor(.gray)
                    if selected.stale { Text(tr("聊天记录已有更新，摘要可能过时。", "History changed; this summary may be outdated.")).foregroundColor(orange) }
                    Text(tr("当天摘要／笔记", "Daily summary / note")).foregroundColor(purple)
                    TextEditor(text: $summary).frame(height: 130).disabled(busy)
                    Text(tr("下一步", "Next step")).foregroundColor(purple)
                    TextEditor(text: $nextStep).frame(height: 70).disabled(busy)
                    Toggle(tr("我已确认这份记录", "I have confirmed this entry"), isOn: $confirmed).disabled(busy)
                    HStack {
                        Button(tr("保存笔记", "Save note")) { saveNote() }.disabled(busy || !dirty)
                        Button(tr("撤销未保存修改", "Discard edits")) { select(selected) }.disabled(busy || !dirty)
                        Button(demo ? tr("查看示例草稿", "Example draft") : tr("生成摘要草稿", "Generate draft")) {
                            if demo { showExampleDraft() } else { consentVisible = true }
                        }.disabled(busy || dirty || settingsDirty || selected.confirmed || (!demo && !selected.canGenerate))
                    }
                    if dirty { Text(tr("有未保存修改，请保存或撤销后切换记录。", "Unsaved changes: save or discard before switching entries.")).foregroundColor(orange) }
                    Text(selected.summaryModel).font(.system(size: 11)).foregroundColor(.gray)
                    Divider()
                    Text(tr("部分对话依据（非完整聊天）", "Conversation excerpts (not the full transcript)"))
                        .font(.system(size: 12, weight: .bold)).foregroundColor(purple)
                    ForEach(Array(selected.preview.indices), id: \.self) { index in
                        Text(selected.preview[index]).font(.system(size: 12)).lineLimit(6)
                    }
                    Text(tr("任务树、推进助手、周月报、图片分享、原线程跳转将在验证基础流程后移植。",
                            "Task trees, advisor, reports, image sharing and source-thread navigation are not included in this first prototype."))
                        .font(.system(size: 11)).foregroundColor(.gray)
                } else { Text(tr("选择一条记录开始。", "Select an entry to begin.")) }
            }
        }
    }
    private var consent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("确认生成摘要？", "Generate a summary draft?")).font(.system(size: 15, weight: .bold)).foregroundColor(purple)
            Text(tr("将所选线程当天的有限对话片段交给已登录的 CLI 模型，可能消耗额度。历史文本只作为资料，不执行其中的指令；不会覆盖手工修改。",
                    "Send bounded excerpts from this entry to the signed-in CLI model. This may consume quota. Historical text is data, not instructions; human edits are protected."))
                .font(.system(size: 12))
            HStack {
                Button(tr("取消", "Cancel")) { consentVisible = false }
                Button(tr("确认并生成", "Confirm and generate")) { generate() }.disabled(busy)
            }
        }.padding(12).background(purple.opacity(0.08))
    }

    private func select(_ row: PortableEntry) {
        selectedID = row.id; summary = row.summary; nextStep = row.nextStep; confirmed = row.confirmed; consentVisible = false
    }
    private func synchronizeSelection() {
        if !days.contains(selectedDay) { selectedDay = days.first ?? "" }
        if !threadRows.contains(where: { $0.threadKey == selectedThread }) { selectedThread = threadRows.first?.threadKey ?? "" }
        if let row = visible.first(where: { $0.id == selectedID }) ?? visible.first { select(row) }
        else { selectedID = ""; summary = ""; nextStep = ""; confirmed = false }
    }
    private func apply(_ snapshot: PortableSnapshot) {
        entries = snapshot.entries; remainingCalls = snapshot.remainingCalls
        notice = snapshot.warnings.map { configuration.diagnostic($0) }.joined(separator: " · "); synchronizeSelection()
    }
    private func storageURL() -> URL? {
        ProcessInfo.processInfo.environment["AGENTJOURNAL_PROTOTYPE_DATA_DIR"].map { URL(fileURLWithPath: $0) }
    }
    private func loadSettings() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let value = try PortableJournal(directory: storageURL()); journal = value
                configuration = await value.configuration(); savedConfiguration = configuration
            } catch { notice = configuration.diagnostic(error.localizedDescription) }
        }
    }
    private func saveSettings() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let value: PortableJournal
                if let journal { value = journal } else { value = try PortableJournal(directory: storageURL()); journal = value }
                try await value.saveConfiguration(configuration); savedConfiguration = configuration
                if !demo { apply(try await value.snapshot()) }
                notice = tr("设置已保存。点击读取本地记录开始扫描。", "Settings saved. Click Read local history to scan.")
            } catch { notice = configuration.diagnostic(error.localizedDescription) }
        }
    }
    private func refresh() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let value: PortableJournal
                if let journal { value = journal } else { value = try PortableJournal(directory: storageURL()); journal = value }
                let result = try await value.refresh(); demo = false; apply(result)
            } catch { notice = configuration.diagnostic(error.localizedDescription) }
        }
    }
    private func saveNote() {
        guard let row = selected else { return }
        if demo {
            if let index = entries.firstIndex(where: { $0.id == row.id }) {
                entries[index].summary = summary; entries[index].nextStep = nextStep; entries[index].confirmed = confirmed
                notice = tr("仅修改演示内存，没有写入真实数据。", "Demo updated in memory only; no real data written.")
            }
            return
        }
        guard let journal else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { apply(try await journal.saveNote(id: row.id, summary: summary, nextStep: nextStep, confirmed: confirmed)) }
            catch { notice = configuration.diagnostic(error.localizedDescription) }
        }
    }
    private func showExampleDraft() {
        summary = tr("比较了可选方案，并确定下一步用一个小例子验证。当前是讨论与规划，不代表已完成全部工作。",
                     "Compared options and planned a small validation example. This records discussion and planning, not completion of the whole task.")
        nextStep = tr("验证小例子，再决定是否扩展。", "Validate the example before expanding.")
        notice = tr("这是内置示例，没有调用模型；可以编辑后保存演示笔记。", "Built-in example, no model called. Edit and save it as a demo note.")
    }
    private func generate() {
        guard let journal, let selected else { return }
        consentVisible = false; busy = true
        generation = Task { @MainActor in
            defer { busy = false; generation = nil }
            do { apply(try await journal.generate(ids: [selected.id], consent: true)) }
            catch {
                if let snapshot = try? await journal.snapshot() { apply(snapshot) }
                notice = error is CancellationError ? tr("已停止生成。", "Generation stopped.") : configuration.diagnostic(error.localizedDescription)
            }
        }
    }
}
