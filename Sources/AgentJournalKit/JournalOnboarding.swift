import SwiftUI

// macOS-only UX copy. The portable/Windows language table stays unchanged.
struct JournalMacText {
    let language: JournalInterfaceLanguage
    init(_ language: JournalInterfaceLanguage) { self.language = language }
    func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        let format = language == .english ? Self.english[key] ?? JournalText.english[key] ?? key : key
        return arguments.isEmpty ? format : String(format: format, locale: language.locale, arguments: arguments)
    }
    func message(_ value: String) -> String {
        if language == .english, let translated = Self.english[value] { return translated }
        return JournalText(language).message(value)
    }
    func category(_ value: String) -> String { self(value) }
    func date(_ date: Date, clock: JournalClock, style: JournalDateStyle) -> String {
        JournalText(language).date(date, clock: clock, style: style)
    }
    var weekdayItems: [JournalWeekday] { JournalText(language).weekdayItems }
    static let english: [String: String] = [
        "继续之前开启的自动草稿": "Continue previously enabled automatic drafts",
        "你之前已允许自动草稿。读取后会按原设置继续生成；取消此选择可只读取本机记录。": "You previously enabled automatic drafts. After reading, generation continues with those settings. Turn this off to read local history only.",
        "跳到读取确认": "Skip to reading consent",
        "先看演示": "Start the demo tour",
        "确认本机读取范围": "Confirm which local history to read",
        "读取所选来源并开始": "Read selected sources and start",
        "确认来源并返回日志": "Confirm sources and return to journal",
        "返回演示": "Back to the demo",
        "本机读取，不等于模型授权": "Local reading is not model consent",
        "将读取本机所选来源的会话记录，并在本机建立索引。没有选择的来源不会扫描；不会读取云端独有或其他电脑的会话。": "Read conversation history from the selected sources on this Mac and build a local index. Unselected sources, cloud-only sessions and other computers are not scanned.",
        "点击下方按钮后才开始读取。此步骤不发送对话、不调用模型，也不会开启自动草稿。": "Reading starts only after you click the button below. This step sends no conversations, calls no model and does not enable automatic drafts.",
        "本次读取：%@": "Read from: %@",
        "第一步：保存一条每日摘要": "First: save one daily summary",
        "先补齐一条每日摘要": "Prepare one daily summary",
        "先生成或编辑摘要": "Generate or edit a summary first",
        "补齐缺少的摘要": "Prepare missing summaries",
        "手动编辑摘要": "Write or edit a summary",
        "生成这条摘要": "Generate this summary",
        "返回继续": "Return and continue",
        "选择一条记录，生成模型草稿或手动写一句进展。保存后再返回原界面继续；不会自动开始分析或批量补齐。": "Choose one entry, generate a model draft or write a short progress note yourself. Save it, then return to continue. No analysis or bulk generation starts automatically.",
        "%d 条记录 · %d 条已保存摘要": "%d entries · %d saved summaries",
        "尚无摘要": "No summary yet",
        "已保存摘要，可以返回继续。": "Summary saved. You can return and continue.",
        "请选择一条每日记录。": "Select a daily entry.",
        "当前范围没有可编辑的记录，请返回调整日期或来源。": "No editable entries in this scope. Go back and change dates or sources.",
        "仅这条记录的有限对话摘录会发送给所选 CLI；生成前会再次确认。手动编辑不调用模型。": "Only bounded excerpts from this entry are sent to the selected CLI, after another confirmation. Manual editing calls no model.",
        "原始摘录已不在本机，可手动补充摘要。": "Original excerpts are no longer available locally. Write a summary manually.",
        "已编辑或确认的笔记不会被模型覆盖；如需调整，请手动编辑。": "Edited or confirmed notes are protected. Edit them manually to make changes.",
        "已有当前模型草稿，可手动核对；不会为相同记录重复调用模型。": "A current draft already exists. Review it manually; no duplicate model request is needed.",
        "演示模式不调用模型，可以手动编辑示例。": "Demo mode calls no models. You can edit the synthetic entry manually.",
        "当前候选没有可用摘要。先生成或编辑一条每日摘要，再分析；本次未调用模型。": "No usable summary in the current candidates. Save a daily summary before analyzing; no model was called.",
        "当前可分析：%d / %d 个候选线程有摘要": "Ready to analyze: %d / %d candidate threads have summaries",
        "零摘要不会调用模型": "No summaries, no model call",
        "当前没有可分析的线程": "No threads are eligible for advice",
        "先读取所选来源的本机记录，或将线程设为进行中／等待中。已搁置和已完成线程的历史仍保留。": "Read local history from the selected sources, or mark a thread active/waiting. Paused and completed threads retain their history.",
        "选择一条记录保存摘要，再返回这里分析；手动编辑不消耗模型额度。": "Save a summary for one entry, then return to analyze. Manual editing uses no model credits.",
        "只有一个线程有摘要：可核对它的下一步，不能比较多个线程的优先顺序。": "Only one thread has a summary: its next step can be reviewed, but multiple threads cannot be compared.",
        "部分候选缺少摘要，建议只代表已提供的有限进展。": "Some candidates lack summaries. Advice reflects only the bounded progress supplied.",
        "正在准备本次分析": "Preparing this analysis",
        "正在等待 CLI 返回分析结果": "Waiting for the CLI analysis result",
        "正在核对结果与摘要依据": "Checking the result against summary evidence",
        "正在保存建议和每日历史": "Saving advice and daily history",
        "已等待 %d 秒 · 可随时停止": "Elapsed: %d seconds · Stop at any time",
        "模型响应时间取决于所选 CLI、模型和网络；这里不显示虚构进度百分比。": "Response time depends on the selected CLI, model and network. No guessed progress percentage is shown.",
        "分析正在进行，完成后会显示结果。历史建议仍可回看，不代表本次分析已完成。": "Analysis is running; its result appears when finished. Historical advice remains available and is not the new result.",
        "工作方式与数据范围": "How it works and data scope",
        "查看补齐路径": "Prepare a summary",
        "核对或补齐当前摘要": "Review or prepare current summaries",
        "任务树还未建立": "No task tree yet",
        "自动草拟需要至少一条已保存摘要；也可以不调用模型，手动建立第一项任务。": "Automatic drafting needs at least one saved summary. Or create your first task manually without a model call.",
        "已有摘要，可自动草拟，也可手动建立任务。完成项始终需要人工确认。": "Saved summaries are available. Draft a tree or create tasks manually; completion always needs human confirmation.",
        "手动新增第一项": "Add the first task manually",
        "从现有摘要草拟任务树": "Draft a tree from saved summaries",
        "草拟与进度规则": "Drafting and progress rules",
        "依据与覆盖详情": "Evidence and coverage details",
        "这段时间还没有摘要": "No summaries in this period yet",
        "期间回顾已经可用，但需要先保存每日摘要。先补一条，再回来生成；不会自动批量调用模型。": "Period reviews are available, but need saved daily summaries first. Prepare one, then return to generate a review. No bulk model requests start automatically.",
        "这段时间没有记录": "No entries in this period",
        "请选择有记录的日期范围；已有历史回顾仍可查看。": "Choose dates with entries. Saved historical reviews remain available.",
        "本日记录 · 仅这一天": "Daily entries · This date only",
        "跨天线程总览": "Threads across dates",
        "%@ — %@ · %d 个记录日": "%@ — %@ · %d days with entries",
        "每个线程只列一张卡片；右侧串起它在不同日期的记录。": "One card per thread; the right-hand timeline shows its entries across dates.",
        "当前筛选没有线程": "No threads match these filters",
        "推进状态": "Journal status",
        "全部状态": "All statuses",
        "状态只影响 AgentJournal，不会关闭或归档原客户端会话。": "This status applies only to AgentJournal. It does not close or archive the source session.",
        "进行中：参与推进分析。等待中：保留等待条件，可核对进展。暂时搁置／已完成：不参与推进分析，历史仍保留。": "Active: eligible for advice. Waiting: retain waiting conditions and review progress. Paused/completed: excluded from advice; history is retained.",
        "AgentJournal 状态已设为“%@”；历史保留，原客户端会话未修改。": "AgentJournal status is now “%@”. History is retained; the source session is unchanged.",
        "分支与同名线程": "Branches and same-name threads",
        "目前按独立会话 ID 保留线程。同名或带编号不代表已确认的 fork 关系，不能直接合并；父子关联仍待可靠元数据支持。": "Threads retain their independent session IDs. A shared title or numbered suffix does not prove a fork relationship. Parent/branch links need reliable metadata; contents are not merged.",
        "请求引擎：%@ CLI": "Request engine: %@ CLI",
        "请求模型：%@": "Requested model: %@",
        "CLI 默认（实际模型将在返回后报告）": "CLI default (actual model reported after the response)",
        "使用你在这台 Mac 上的 CLI 登录／配置，不是开发者账户。额度和费用归属该 CLI 当前账户及其配置的提供方；AgentJournal 不提供免费模型额度，也无法预报具体费用。": "Uses the CLI login/configuration on your Mac, not a developer account. Usage and charges belong to that CLI's current account and configured provider. AgentJournal supplies no free model credits and cannot predict the exact cost.",
        "本地调用上限不是供应商剩余额度或账单。": "Local request limits are not provider credits or billing.",
        "先选一条记录开始": "Start with one entry",
        "记录已读入。先保存一条摘要，再建立任务树、生成回顾或获得推进建议。": "History is loaded. Save one summary first, then build a task tree, generate a review or request advice."
    ]
}

enum JournalTourTarget: Hashable {
    case calendar, daily, timeline, models, advisor, sharing, reports, management
}

enum JournalTourStep: Int, CaseIterable {
    case welcome, calendar, daily, timeline, models, advisor, sharing, reports, management, finish
    var target: JournalTourTarget? {
        switch self {
        case .welcome, .finish: return nil
        case .calendar: return .calendar
        case .daily: return .daily
        case .timeline: return .timeline
        case .models: return .models
        case .advisor: return .advisor
        case .sharing: return .sharing
        case .reports: return .reports
        case .management: return .management
        }
    }
    var title: String {
        switch self {
        case .welcome: return "先看演示，再开始自己的日志"
        case .calendar: return "日历：今天都处理了什么？"
        case .daily: return "每日记录：把讨论变成可回看的进展"
        case .timeline: return "线程时间线：同一个问题，连续看几天"
        case .models: return "模型选择：读取来源和总结模型分开选"
        case .advisor: return "推进助手：下一步推进哪个线程？"
        case .sharing: return "分享图片：挑一段时间，展示自己的进展"
        case .reports: return "周报／月报：从记录提炼阶段成果"
        case .management: return "数据与设置：额度、隐私和历史都由你掌控"
        case .finish: return "准备好了，开始自己的 AgentJournal"
        }
    }
    var detail: String {
        switch self {
        case .welcome: return "先选择语言和本机记录来源。后面的高亮指引使用合成示例，不读取私人日志、不调用模型，也不会混入你的真实记录。"
        case .calendar: return "点击日期，查看当天的线程。蓝点代表 Codex，橙点代表 Claude Code，绿点代表已保存的推进建议。可以切换月份，也可以从有记录的日子快速回看。"
        case .daily: return "中间列按天整理线程。摘要先作为草稿，你可以修改分类、下一步，再确认。确认笔记不会把整个线程标记为完成，也不会修改原会话。"
        case .timeline: return "选中线程后，右侧串起它在不同日期的记录。可以编辑笔记、设置线程状态；回到原线程是定位现有会话，不会自动发消息，Claude 桌面跳转仍是实验性功能。"
        case .models: return "这里选择生成摘要的 CLI 和模型，不是原线程的模型。可以用 Codex 总结 CC，也可以反过来。真实生成需要对应 CLI 安装、登录和可用额度；允许前会说明发送少量摘录。"
        case .advisor: return "绿色入口只根据已记录的线程进展建议下一步，不读取日程的 DDL 或重要度。建议按日期和版本保留，可标记已处理、等待或不采纳；它不会替你执行任务。"
        case .sharing: return "选择日期范围，生成可保存的 PNG 进展卡片，也能导出 Markdown。不会自动上传到任何平台；示例不含私人对话，真实分享前仍需检查敏感内容。"
        case .reports: return "把已保存的笔记汇总成周报、月报或自定义期间回顾，保留依据和多个版本。它不会补造缺失成果；生成需要模型额度，浏览与导出历史不需要。"
        case .management: return "仪表入口管理调用限额、自动暂停、建议反馈和完整备份。旁边的滑杆入口可改来源、排除项目和语言。归档也包含在备份里；备份未加密，请勿上传 GitHub。"
        case .finish: return "当前是 macOS 桌面 Beta，没有网页或手机端，也没有后台守护服务。自动扫描和自动草稿只在窗口打开时运行。仅整理本机可读取的 Codex／CC 日志，不能读取云端独有或其他电脑的线程。"
        }
    }
}

struct JournalTourAnchors: PreferenceKey {
    static var defaultValue: [JournalTourTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [JournalTourTarget: Anchor<CGRect>], nextValue: () -> [JournalTourTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
extension View {
    func journalTourTarget(_ target: JournalTourTarget) -> some View {
        anchorPreference(key: JournalTourAnchors.self, value: .bounds) { [target: $0] }
    }
}

@MainActor
struct JournalOnboardingView: View {
    @ObservedObject var store: JournalStore
    let firstLaunch: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var choices: JournalSettings
    @State private var demoStore: JournalStore
    @State private var step: JournalTourStep = .welcome
    @State private var error: String?
    @State private var resumeAutomatic: Bool
    private var l: JournalMacText { JournalMacText(choices.uiLanguage) }

    init(store: JournalStore, firstLaunch: Bool) {
        self.store = store
        self.firstLaunch = firstLaunch
        _choices = State(initialValue: store.settings)
        _resumeAutomatic = State(initialValue: store.autoSummarize)
        _demoStore = State(initialValue: Self.makeDemo(store.settings))
    }
    static func makeDemo(_ choices: JournalSettings) -> JournalStore {
        var value = choices
        value.codexHome = "/demo/codex"
        value.claudeHome = "/demo/claude"
        value.claudeDesktopSessionsHome = ""
        value.excludedProjects = ""
        value.languageSetupComplete = true
        value.onboardingVersion = JournalStore.onboardingVersion
        return JournalStore(directory: URL(fileURLWithPath: "/demo/AgentJournal"), settings: value, demo: true)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(l("新手指引"), systemImage: "flag.checkered").font(.title3.bold())
                Text("AgentJournal").foregroundStyle(.secondary)
                Spacer()
                Text(l("演示 · 不读取私人记录")).font(.caption).foregroundStyle(JournalPalette.purple)
                Button(l(firstLaunch ? "跳到读取确认" : "退出指引")) {
                    if firstLaunch { step = .finish } else { dismiss() }
                }.disabled(store.isLoading || store.isModelBusy)
            }.padding(.horizontal, 22).padding(.vertical, 14)
            Divider()
            if step == .welcome {
                welcome.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            } else if step == .finish {
                finishCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            } else {
                JournalView(store: demoStore, embeddedDemo: true)
                .id(ObjectIdentifier(demoStore))
                .disabled(true)
                .allowsHitTesting(false)
                .overlayPreferenceValue(JournalTourAnchors.self) { anchors in
                    GeometryReader { geometry in
                        if let target = step.target, let anchor = anchors[target] {
                            let bounds = geometry[anchor].insetBy(dx: -3, dy: -3)
                            Path { path in
                                path.addRect(CGRect(origin: .zero, size: geometry.size))
                                path.addRoundedRect(in: bounds, cornerSize: CGSize(width: 10, height: 10))
                            }.fill(.black.opacity(0.32), style: FillStyle(eoFill: true))
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(step == .advisor ? JournalPalette.green : JournalPalette.purple, lineWidth: 4)
                                .frame(width: bounds.width, height: bounds.height)
                                .position(x: bounds.midX, y: bounds.midY)
                        }
                    }.allowsHitTesting(false)
                }
            }
            Divider()
            if step.target != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(l(step.title)).font(.headline)
                    Spacer()
                    Text(l("第 %d / %d 步", step.rawValue + 1, JournalTourStep.allCases.count)).font(.caption).foregroundStyle(.secondary)
                }
                Text(l(step.detail)).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).frame(minHeight: 38, alignment: .top)
                if let error { Text(l.message(error)).font(.caption).foregroundStyle(.orange) }
                HStack {
                    ForEach(JournalTourStep.allCases, id: \.rawValue) { item in
                        Circle().fill(item == step ? JournalPalette.purple : JournalPalette.purple.opacity(0.18)).frame(width: 6, height: 6)
                    }
                    Spacer()
                    Button(l("上一步")) { change(-1) }.disabled(step == .welcome)
                    Button(l(step == .finish ? "开始使用" : "下一步")) {
                        if step == .finish { complete() } else { change(1) }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(store.isLoading || store.isModelBusy || !store.canEdit)
                }
            }.padding(20)
            }
        }.frame(width: 1220, height: 780).tint(JournalPalette.purple)
            .environment(\.locale, choices.uiLanguage.locale)
            .interactiveDismissDisabled(firstLaunch)
            .onChange(of: choices.uiLanguage) { _, _ in demoStore = Self.makeDemo(choices) }
            .onChange(of: choices.sourceSelection) { _, _ in demoStore = Self.makeDemo(choices) }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome / 欢迎").font(.title.bold())
            Text(l("先看演示，再开始自己的日志")).font(.headline)
            Form {
                Picker("App language / 应用语言", selection: $choices.uiLanguage) {
                    ForEach(JournalInterfaceLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
                Picker(l("生成内容语言"), selection: $choices.summaryLanguage) {
                    ForEach(JournalSummaryLanguage.allCases) { Text($0.label(choices.uiLanguage)).tag($0) }
                }
                Picker(l("你使用哪些工具？"), selection: $choices.sourceSelection) {
                    ForEach(JournalSourceSelection.allCases) { Text(l($0.label)).tag($0) }
                }
            }
            Text(l("未选择的来源不会扫描；以后可以在设置里修改。读取来源与总结模型相互独立。"))
                .font(.caption).foregroundStyle(.secondary)
            Label(l("macOS 桌面 Beta · 无网页／手机端 · 自动任务仅在窗口打开时运行"), systemImage: "desktopcomputer")
                .font(.caption).foregroundStyle(JournalPalette.purple)
            Text(l("这是一段安全演示，不会开启自动草稿。生成真实总结时，仍会单独征求允许并说明额度使用。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(l("跳到读取确认")) { step = .finish }
                Spacer()
                Button(l("先看演示")) { change(1) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 650).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(JournalPalette.purple.opacity(0.25)))
            .shadow(color: .black.opacity(0.15), radius: 25)
    }
    private var finishCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(l("确认本机读取范围"), systemImage: "externaldrive.badge.checkmark").font(.title2.bold()).foregroundStyle(JournalPalette.green)
            Picker(l("你使用哪些工具？"), selection: $choices.sourceSelection) {
                ForEach(JournalSourceSelection.allCases) { Text(l($0.label)).tag($0) }
            }
            Label(l("本机读取，不等于模型授权"), systemImage: "lock.shield").font(.headline)
            Text(l("将读取本机所选来源的会话记录，并在本机建立索引。没有选择的来源不会扫描；不会读取云端独有或其他电脑的会话。"))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(l("本次读取：%@", l(choices.sourceSelection.label))).font(.callout.bold()).foregroundStyle(JournalPalette.purple)
            if store.autoSummarize {
                Toggle(l("继续之前开启的自动草稿"), isOn: $resumeAutomatic)
                if resumeAutomatic {
                    Text(l("你之前已允许自动草稿。读取后会按原设置继续生成；取消此选择可只读取本机记录。"))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(store.modelAccountNotice(for: choices)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !resumeAutomatic {
                Text(l("点击下方按钮后才开始读取。此步骤不发送对话、不调用模型，也不会开启自动草稿。"))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text(l("演示结束后，示例不会混入你的真实日志。"))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(l.message(error)).foregroundStyle(.orange) }
            HStack {
                Button(l("返回演示")) { step = .welcome }
                Spacer()
                Button(l(firstLaunch ? "读取所选来源并开始" : "确认来源并返回日志")) { complete() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(store.isLoading || store.isModelBusy || !store.canEdit)
            }
        }.padding(28).frame(width: 690).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.15), radius: 25)
    }
    private func change(_ delta: Int) {
        if let next = JournalTourStep(rawValue: step.rawValue + delta) { step = next }
    }
    private func complete() {
        do {
            try store.completeOnboarding(choices)
            if store.autoSummarize && !resumeAutomatic { store.autoSummarize = false }
            dismiss()
        }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct JournalDemoView: View {
    @State private var demoStore: JournalStore
    @Environment(\.dismiss) private var dismiss
    private var l: JournalText { JournalText(demoStore.settings.uiLanguage) }
    init(settings: JournalSettings) {
        _demoStore = State(initialValue: JournalOnboardingView.makeDemo(settings))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(l("体验演示")).font(.headline)
                Text(l("仅合成示例 · 不调用模型 · 不写入真实日志")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(l("返回自己的日志")) { dismiss() }
            }.padding(16)
            JournalView(store: demoStore, embeddedDemo: true)
        }.frame(width: 1220, height: 760)
    }
}
