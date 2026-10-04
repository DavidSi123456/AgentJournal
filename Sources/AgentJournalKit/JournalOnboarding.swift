import SwiftUI

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
    private var l: JournalText { JournalText(choices.uiLanguage) }

    init(store: JournalStore, firstLaunch: Bool) {
        self.store = store
        self.firstLaunch = firstLaunch
        _choices = State(initialValue: store.settings)
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
                Button(l(firstLaunch ? "跳过指引" : "退出指引")) {
                    if firstLaunch { complete() } else { dismiss() }
                }.disabled(store.isLoading || store.isModelBusy)
            }.padding(.horizontal, 22).padding(.vertical, 14)
            Divider()
            JournalView(store: demoStore, embeddedDemo: true)
                .id(ObjectIdentifier(demoStore))
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
                .overlay {
                    if step == .welcome { welcome }
                    else if step == .finish { finishCard }
                }
            Divider()
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
        }.padding(26).frame(width: 610).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(JournalPalette.purple.opacity(0.25)))
            .shadow(color: .black.opacity(0.15), radius: 25)
    }
    private var finishCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(l("准备好了"), systemImage: "checkmark.seal.fill").font(.title2.bold()).foregroundStyle(JournalPalette.green)
            Text(l("演示结束后，示例不会混入你的真实日志。"))
            Text(l("从右上角的问号菜单可再次打开新手指引或体验演示。"))
            Text(l("现阶段安装包面向 Apple Silicon、macOS 14 及以上；仍是未公证的 Beta，其他系统与机器需要额外验证。"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 580).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.15), radius: 25)
    }
    private func change(_ delta: Int) {
        if let next = JournalTourStep(rawValue: step.rawValue + delta) { step = next }
    }
    private func complete() {
        do { try store.completeOnboarding(choices); dismiss() }
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
