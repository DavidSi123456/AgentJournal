import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct JournalView: View {
    @ObservedObject private var store: JournalStore
    @State private var selectedDate: Date
    @State private var month: Date
    @State private var selectedThreadKey: String?
    @State private var search = ""
    @State private var sourceFilter = "all"
    @State private var category = "全部"
    @State private var statusFilter = "all"
    @State private var viewMode = "day"
    @State private var editing: JournalActivity?
    @State private var showingSettings = false
    @State private var showingShare = false
    @State private var showingAgent = false
    @State private var showingManagement = false
    @State private var showingReports = false
    @State private var showingSummaryPreparation = false
    @State private var progressActivity: JournalActivity?
    @State private var showingOnboarding: Bool
    @State private var showingDemo = false
    private let embeddedDemo: Bool
    @StateObject private var modelCatalog: JournalModelCatalog
    @State private var showingConsent = false
    @State private var enableAfterConsent = false
    @State private var pendingSummary: [JournalActivity] = []
    @State private var hasConsent: Bool

    public init(store: JournalStore, embeddedDemo: Bool = false) {
        self.store = store
        self.embeddedDemo = embeddedDemo
        _modelCatalog = StateObject(wrappedValue: JournalModelCatalog(settings: store.settings))
        let today = store.clock.calendar.startOfDay(for: Date())
        _selectedDate = State(initialValue: today)
        _month = State(initialValue: today)
        _hasConsent = State(initialValue: store.autoSummarize)
        _showingOnboarding = State(initialValue: !embeddedDemo && store.needsOnboarding)
    }
    private var filtered: [JournalActivity] {
        store.activities.filter { activity in
            let draft = store.draft(for: activity)
            return store.settings.includesProvider(activity.source) && (sourceFilter == "all" || activity.source.rawValue == sourceFilter)
                && (category == "全部" || draft.category == category)
                && (statusFilter == "all" || store.threadStatus(activity.threadKey).rawValue == statusFilter)
                && (search.isEmpty || (activity.title + draft.displaySummary + activity.cwd)
                    .localizedCaseInsensitiveContains(search))
        }
    }
    private var dayItems: [JournalActivity] {
        let day = store.clock.key(selectedDate)
        return filtered.filter { $0.day == day }.sorted { $0.lastActivity > $1.lastActivity }
    }
    private var threadItems: [JournalActivity] {
        var seen = Set<String>()
        return filtered.sorted { $0.lastActivity > $1.lastActivity }.filter { seen.insert($0.threadKey).inserted }
    }
    private var listItems: [JournalActivity] { viewMode == "day" ? dayItems : threadItems }
    private var history: [JournalActivity] { selectedThreadKey.map { store.history(for: $0) } ?? [] }
    private var purple: Color { JournalPalette.purple }
    private var l: JournalMacText { JournalMacText(store.settings.uiLanguage) }

    public var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(LinearGradient(colors: [purple, .purple.opacity(0.65), purple.opacity(0.5)],
                                           startPoint: .leading, endPoint: .trailing)).frame(height: 4)
            header
            Divider()
            if let error = store.errorMessage { messageBar(l.message(error), error: true) { store.errorMessage = nil } }
            if let warning = store.warningMessage { messageBar(l.message(warning), error: false) }
            if let error = store.workflowError { messageBar(l.message(error), error: false) }
            if let notice = store.noticeMessage { messageBar(l.message(notice), error: false) { store.noticeMessage = nil } }
            HSplitView {
                sidebar.frame(minWidth: 228, idealWidth: 244, maxWidth: 270).journalTourTarget(.calendar)
                dailyPanel.frame(minWidth: 400, idealWidth: 490, maxWidth: .infinity).journalTourTarget(.daily)
                threadPanel.frame(minWidth: 370, idealWidth: 490, maxWidth: .infinity).journalTourTarget(.timeline)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(purple)
        .environment(\.locale, store.settings.uiLanguage.locale)
        .sheet(isPresented: $showingOnboarding) { JournalOnboardingView(store: store, firstLaunch: store.needsOnboarding) }
        .sheet(isPresented: $showingDemo) { JournalDemoView(settings: store.settings) }
        .sheet(item: $editing) { JournalDraftEditor(store: store, activity: $0) }
        .sheet(isPresented: $showingSettings) { JournalSettingsEditor(store: store, catalog: modelCatalog) }
        .sheet(isPresented: $showingShare) { JournalShareView(store: store, date: selectedDate) }
        .sheet(isPresented: $showingManagement) { JournalManagementView(store: store) }
        .sheet(isPresented: $showingReports) { JournalReportsView(store: store, date: selectedDate) }
        .sheet(isPresented: $showingSummaryPreparation) { JournalSummaryPreparationView(store: store, activities: listItems) }
        .sheet(item: $progressActivity) { JournalThreadProgressView(store: store, activity: $0) }
        .sheet(isPresented: $showingAgent) {
            JournalAgentView(store: store, catalog: modelCatalog, date: selectedDate) { key in
                search = ""; category = "全部"; sourceFilter = "all"; statusFilter = "all"; viewMode = "thread"
                selectedThreadKey = key
            }
        }
        .alert(l("允许生成模型摘要？"), isPresented: $showingConsent) {
            Button(l("取消"), role: .cancel) { pendingSummary = []; enableAfterConsent = false }
            Button(l("允许")) {
                hasConsent = true
                if enableAfterConsent { store.autoSummarize = true }
                else { store.generate(pendingSummary, force: forceAfterConsent) }
                pendingSummary = []
                enableAfterConsent = false
                forceAfterConsent = false
            }
        } message: {
            Text(l("选中线程的少量对话摘录会交给 %@ CLI，发送到其配置的模型提供方并消耗额度。原始日志只读，生成任务不能使用工具。", store.settings.summaryEngine.label)
                + "\n\n" + store.modelAccountNotice(for: store.settings))
        }
        .task(id: store.clock.key(selectedDate)) {
            await store.refresh(on: selectedDate)
            selectFirstIfNeeded()
            // Periodic refresh lives in this task, so ordinary view updates cannot restart it.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                await store.refresh(on: selectedDate)
            }
        }
        .onChange(of: store.lastRefreshed) { _, _ in selectFirstIfNeeded() }
        .onChange(of: selectedThreadKey) { _, key in store.followThread(key) }
        .onChange(of: sourceFilter) { _, _ in selectFirstIfNeeded() }
        .onChange(of: category) { _, _ in selectFirstIfNeeded() }
        .onChange(of: statusFilter) { _, _ in selectFirstIfNeeded() }
        .onChange(of: listItems.map(\.id)) { _, _ in selectFirstIfNeeded() }
        .onChange(of: search) { _, _ in selectFirstIfNeeded() }
        .onChange(of: viewMode) { _, _ in selectFirstIfNeeded() }
        .onChange(of: store.settingsRequest) { _, _ in if !showingOnboarding { showingSettings = true } }
        .onChange(of: store.settings) { old, new in
            if old.sourceSelection != new.sourceSelection { selectFirstIfNeeded() }
            if old.codexHome != new.codexHome { modelCatalog.loadCache(new) }
            if (old.languageSetupComplete != new.languageSetupComplete && new.languageSetupComplete == true)
                || old.onboardingVersion != new.onboardingVersion {
                Task { await store.refresh(on: selectedDate) }
            }
            if old.uiLanguage != new.uiLanguage || old.codexHome != new.codexHome || old.claudeHome != new.claudeHome
                || old.claudeDesktopSessionsHome != new.claudeDesktopSessionsHome
                || old.sourceSelection != new.sourceSelection
                || old.timeZoneID != new.timeZoneID || old.excludedProjects != new.excludedProjects {
                if old.timeZoneID != new.timeZoneID { choose(Date()) }
                Task { await store.refresh(on: selectedDate) }
            }
        }
        .onDisappear { store.cancelGeneration(); store.cancelAdvice(); store.cancelReport() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.cancelGeneration()
            store.cancelAdvice()
            store.cancelReport()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "text.book.closed.fill").font(.system(size: 27)).foregroundStyle(purple)
            VStack(alignment: .leading, spacing: 3) {
                Text("AgentJournal").font(.system(size: 21, weight: .bold, design: .rounded))
                Text(l("两种工具 · 一份工作日志")).font(.caption).foregroundStyle(.secondary)
            }
            if store.isDemo { badge(l("演示 · 不读取私人记录"), color: purple) }
            Spacer()
            if store.isLoading || store.isSummarizing {
                ProgressView().controlSize(.small)
                Text(l.message(store.progressText)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            modelMenu.journalTourTarget(.models)
            Button { showingAgent = true } label: { Label(l("推进助手"), systemImage: "sparkles.rectangle.stack") }
                .foregroundStyle(JournalPalette.green).tint(JournalPalette.green)
                .help(l("只根据线程进展判断下一步，不读取日程计划"))
                .journalTourTarget(.advisor)
            Toggle(l("自动草稿"), isOn: Binding(get: { store.autoSummarize }, set: { value in
                if value && !hasConsent { enableAfterConsent = true; showingConsent = true }
                else { store.autoSummarize = value }
            })).toggleStyle(.switch).controlSize(.small).disabled(store.isDemo || !store.canEdit)
                .help(l("线程静置一分钟后生成草稿；不会覆盖你编辑或确认过的文字"))
            Button { Task { await store.refresh(on: selectedDate) } } label: {
                Image(systemName: "arrow.clockwise")
            }.help(l("刷新本地记录")).disabled(store.isLoading || store.isDemo)
            Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .help(l("来源目录、摘要引擎和模型设置"))
            Button { showingShare = true } label: { Label(l("分享图片"), systemImage: "photo.on.rectangle.angled") }
                .help(l("选择日期范围，生成可保存或分享的进展卡片"))
                .journalTourTarget(.sharing)
            Button { showingReports = true } label: { Image(systemName: "calendar.badge.checkmark") }
                .help(l("周报／月报")).accessibilityLabel(l("周报／月报"))
                .journalTourTarget(.reports)
            Button { showingManagement = true } label: { Image(systemName: "gauge.with.dots.needle.50percent") }
                .help(l("数据与调用")).accessibilityLabel(l("数据与调用"))
                .journalTourTarget(.management)
            if !embeddedDemo {
                Menu {
                    Button(l("新手指引")) { showingOnboarding = true }
                    Button(l("体验演示")) { showingDemo = true }
                } label: { Image(systemName: "questionmark.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help(l("新手指引与安全演示"))
                    .accessibilityLabel(l("新手指引与安全演示"))
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 17)
        .background(purple.opacity(0.055))
    }

    private var modelMenu: some View {
        Menu {
            ForEach(JournalProvider.allCases) { engine in
                Menu(engine.label) {
                    Button(l("跟随 CLI 默认")) { chooseModel(engine, "") }
                    ForEach(modelCatalog.choices(for: engine, selected: engine == store.settings.summaryEngine ? store.settings.model : "")) { choice in
                        Button(l.message(choice.title)) { chooseModel(engine, choice.id) }
                    }
                }
            }
            Divider()
            Button(l("更多模型与自定义…")) { showingSettings = true }
        } label: {
            Label("\(store.settings.summaryEngine.shortLabel) · \(l.message(modelCatalog.title(provider: store.settings.summaryEngine, model: store.settings.model)))",
                  systemImage: "sparkles").font(.caption).lineLimit(1)
        }.menuStyle(.borderlessButton).fixedSize()
            .disabled(store.isLoading || store.isModelBusy || !store.canEdit)
            .help(l("选择写摘要的引擎与模型，不改变原线程使用的模型"))
    }
    private func chooseModel(_ engine: JournalProvider, _ model: String) {
        var settings = store.settings
        settings.selectEngine(engine)
        settings.selectModel(model)
        do { try store.saveSettings(settings) }
        catch { store.errorMessage = error.localizedDescription }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(l("日历"), systemImage: "calendar").font(.headline).foregroundStyle(purple)
                Spacer()
                Button(l("今天")) { viewMode = "day"; choose(Date()) }.buttonStyle(.borderless).font(.caption)
            }
            calendar
            Divider().overlay(purple.opacity(0.1))
            HStack {
                Text(l("有记录的日子")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Set(filtered.map(\.day)).count)").font(.caption.monospacedDigit()).foregroundStyle(purple)
            }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(Array(Set(filtered.map(\.day))).sorted(by: >), id: \.self) { day in
                        Button { viewMode = "day"; choose(store.clock.date(day)) } label: {
                            HStack {
                                Text(l.date(store.clock.date(day), clock: store.clock, style: .shortDay)).font(.subheadline)
                                Spacer()
                                sourceDots(filtered.filter { $0.day == day })
                                Text("\(filtered.filter { $0.day == day }.count)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .background(day == store.clock.key(selectedDate) ? purple.opacity(0.14) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    badge("Codex", color: JournalPalette.blue)
                    badge("Claude Code", color: JournalPalette.orange)
                }
                Label(l("推进建议"), systemImage: "circle.fill").font(.caption2).foregroundStyle(JournalPalette.green)
                Text(store.clock.timeZoneID).font(.caption2).foregroundStyle(.secondary)
                Text(l("本地读取 · 摘要需模型额度")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(18).frame(maxHeight: .infinity, alignment: .top)
        .background(LinearGradient(colors: [purple.opacity(0.11), purple.opacity(0.035)], startPoint: .top, endPoint: .bottom))
    }

    private var calendar: some View {
        let cal = store.clock.calendar
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let offset = (cal.component(.weekday, from: first) + 5) % 7
        let itemsByDay = Dictionary(grouping: filtered, by: \.day)
        return VStack(spacing: 12) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(l.date(month, clock: store.clock, style: .month)).font(.subheadline.weight(.semibold))
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
            }.buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 5) {
                ForEach(l.weekdayItems) { weekday in
                    Text(weekday.label).font(.caption2).foregroundStyle(.secondary).frame(height: 18)
                }
                ForEach(0..<42, id: \.self) { index in
                    let date = cal.date(byAdding: .day, value: index - offset, to: first)!
                    let items = itemsByDay[store.clock.key(date)] ?? []
                    let selected = cal.isDate(date, inSameDayAs: selectedDate)
                    let inMonth = cal.component(.month, from: date) == cal.component(.month, from: month)
                    Button { viewMode = "day"; choose(date) } label: {
                        VStack(spacing: 3) {
                            Text("\(cal.component(.day, from: date))").font(.system(size: 12, weight: selected ? .bold : .regular))
                            HStack(spacing: 3) {
                                sourceDots(items)
                                if store.hasAdvice(on: date) { Circle().fill(JournalPalette.green).frame(width: 4, height: 4) }
                            }.frame(height: 4)
                        }
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .foregroundStyle(selected ? Color.white : (inMonth ? Color.primary : .secondary.opacity(0.4)))
                        .background(selected ? purple : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(cal.isDateInToday(date) && !selected ? purple.opacity(0.6) : .clear))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(l("%@，%d 个线程", l.date(date, clock: store.clock, style: .calendarDay), items.count))
                }
            }
        }
    }

    private var dailyPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(viewMode == "day" ? l.date(selectedDate, clock: store.clock, style: .dayWithWeekday) : l("跨天线程总览"))
                            .font(.title2.weight(.bold))
                        Text(l(viewMode == "day" ? "本日记录 · 仅这一天" : "每个线程只列一张卡片；右侧串起它在不同日期的记录。"))
                            .font(.subheadline).foregroundStyle(.secondary)
                        if viewMode == "thread", let first = filtered.map(\.day).min(), let last = filtered.map(\.day).max() {
                            Text(l("%@ — %@ · %d 个记录日", first, last, Set(filtered.map(\.day)).count))
                                .font(.caption).foregroundStyle(purple)
                        }
                    }
                    Spacer()
                    Picker(l("浏览方式"), selection: $viewMode) {
                        Text(l("按天")).tag("day"); Text(l("按线程")).tag("thread")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: store.settings.uiLanguage == .english ? 180 : 132)
                }
                HStack(spacing: 9) {
                    badge(l("%d 个线程", listItems.count), color: purple)
                    badge("\(listItems.filter { $0.source == .codex }.count) Codex", color: JournalPalette.blue)
                    badge("\(listItems.filter { $0.source == .claude }.count) CC", color: JournalPalette.orange)
                    Spacer()
                    if viewMode == "day", store.hasAdvice(on: selectedDate) {
                        Button { showingAgent = true } label: { Label(l("当天推进建议"), systemImage: "sparkles") }
                            .foregroundStyle(JournalPalette.green).tint(JournalPalette.green)
                    }
                    Button { export(listItems, title: viewMode == "day" ? store.clock.key(selectedDate) : l("全部线程")) } label: {
                        Image(systemName: "square.and.arrow.up")
                    }.help(l("导出当前摘要为 Markdown")).disabled(listItems.isEmpty)
                }
                HStack {
                    TextField(l("搜索线程或进展"), text: $search).textFieldStyle(.roundedBorder)
                    Picker(l("分类"), selection: $category) {
                        ForEach(["全部", "未分类", "课程", "研究", "学工", "生活"], id: \.self) { Text(l.category($0)).tag($0) }
                    }.labelsHidden().frame(width: store.settings.uiLanguage == .english ? 150 : 92)
                }
                Picker(l("来源"), selection: $sourceFilter) {
                    Text(l("全部来源")).tag("all")
                    Text("Codex").tag("codex")
                    Text("Claude Code").tag("claude")
                }.pickerStyle(.segmented)
                Picker(l("推进状态"), selection: $statusFilter) {
                    Text(l("全部状态")).tag("all")
                    ForEach(JournalThreadStatus.allCases, id: \.self) { Text(l($0.label)).tag($0.rawValue) }
                }.frame(maxWidth: 260, alignment: .leading)
                if viewMode == "thread" {
                    DisclosureGroup(l("分支与同名线程")) {
                        Text(l("目前按独立会话 ID 保留线程。同名或带编号不代表已确认的 fork 关系，不能直接合并；父子关联仍待可靠元数据支持。"))
                            .fixedSize(horizontal: false, vertical: true)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
            Divider()
            if !listItems.isEmpty && listItems.allSatisfy({ store.draft(for: $0).displaySummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(l("第一步：保存一条每日摘要")).font(.headline)
                    Text(l("记录已读入。先保存一条摘要，再建立任务树、生成回顾或获得推进建议。"))
                        .font(.callout).foregroundStyle(.secondary)
                    Button(l("先选一条记录开始")) { showingSummaryPreparation = true }
                        .buttonStyle(.borderedProminent).disabled(!store.canEdit)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(purple.opacity(0.06))
            }
            ScrollView {
                LazyVStack(spacing: 13) {
                    if listItems.isEmpty {
                        emptyState(l(viewMode == "day" ? "这一天，留一点空白" : "当前筛选没有线程"), detail: l("没有符合条件的线程。\n可以选择有记录的日期，或切换到“按线程”。"), icon: "sparkles")
                    } else { ForEach(listItems) { activityCard($0) } }
                }.padding(18)
            }
            HStack {
                if store.isSummarizing {
                    Text(l.message(store.progressText)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(l("停止生成")) { store.pauseAutomaticGeneration() }
                } else {
                    Text(l("草稿可编辑 · 已确认文字不会被自动覆盖")).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(l("生成草稿")) { requestSummary(listItems) }
                        .disabled(listItems.isEmpty || store.isDemo || store.isAdvising || !store.canEdit)
                }
            }.padding(14).background(purple.opacity(0.045))
        }.background(purple.opacity(0.025))
    }

    private func activityCard(_ activity: JournalActivity) -> some View {
        let draft = store.draft(for: activity)
        let color = JournalPalette.source(activity.source)
        let selected = activity.threadKey == selectedThreadKey
        return VStack(alignment: .leading, spacing: 11) {
            Button { selectedThreadKey = activity.threadKey } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        badge(activity.source.label, color: color)
                        badge(l.category(draft.category), color: purple)
                        if store.threadStatus(activity.threadKey) != .active {
                            badge(l(store.threadStatus(activity.threadKey).label), color: JournalPalette.green)
                        }
                        Spacer()
                        if draft.isConfirmed { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                        Text(viewMode == "day" ? store.clock.label(activity.lastActivity, "HH:mm") : l.date(activity.lastActivity, clock: store.clock, style: .calendarDay))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(activity.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    if let plan = store.threadProgress.latest(activity.threadKey)?.plan {
                        JournalThreadProgressSummary(plan: plan, language: store.settings.uiLanguage, compact: true)
                    }
                    if draft.displaySummary.isEmpty {
                        Text(store.summarizingIDs.contains(activity.id) ? l("正在整理这一天的进展…") : l("%d 条对话 · 等待生成草稿", activity.messageCount))
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text(draft.displaySummary).font(.subheadline).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !draft.displayNextStep.isEmpty {
                        Label(draft.displayNextStep, systemImage: "arrow.turn.down.right")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(spacing: 10) {
                Text(l(draft.isConfirmed ? "已确认" : "可编辑草稿")).font(.caption2).foregroundStyle(.secondary)
                if hasNewActivity(activity, draft) { Text(l("有新进展")).font(.caption2).foregroundStyle(color) }
                Spacer()
                Button(l("编辑")) { editing = activity }.disabled(!store.canEdit)
                Menu {
                    Button(l("复制继续命令")) { copyResume(activity) }
                    JournalOpenThreadButton(activity: activity, language: store.settings.uiLanguage, disabled: store.isDemo)
                    Button(l("重新生成模型草稿")) { requestSummary([activity], force: true) }.disabled(store.isDemo || store.isModelBusy || activity.excerpts.isEmpty)
                } label: { Image(systemName: "ellipsis") }
                JournalOpenThreadButton(activity: activity, language: store.settings.uiLanguage, disabled: store.isDemo, compact: true)
            }.font(.caption).buttonStyle(.borderless)
        }
        .padding(16)
        .background(color.opacity(selected ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 13))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 16) }
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? color.opacity(0.55) : color.opacity(0.14), lineWidth: selected ? 1.5 : 1))
    }

    private var threadPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(l("一个线程的每一天"), systemImage: "clock.arrow.circlepath")
                        .font(.headline).foregroundStyle(purple)
                    Spacer()
                    if let activity = history.first {
                        Menu {
                            Button(l("复制继续命令")) { copyResume(activity) }
                            JournalOpenThreadButton(activity: activity, language: store.settings.uiLanguage, disabled: store.isDemo)
                            Button(l("导出此线程摘要")) { export(history, title: activity.title) }
                        } label: { Image(systemName: "arrow.up.forward.app") }
                        .menuStyle(.borderlessButton).fixedSize().help(l("打开、继续或导出此线程"))
                    }
                }
                if let activity = history.first {
                    HStack {
                        badge(activity.source.label, color: JournalPalette.source(activity.source))
                        Text(l("%d 天的记录", history.count)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(activity.title).font(.title3.weight(.semibold)).lineLimit(3)
                    Picker(l("线程状态"), selection: Binding(
                        get: { store.threadStatus(activity.threadKey) },
                        set: { store.setThreadStatus($0, for: activity.threadKey) })) {
                        ForEach(JournalThreadStatus.allCases, id: \.self) { Text(l($0.label)).tag($0) }
                    }.font(.caption).disabled(!store.canManageWorkflow || store.isAdvising)
                    Text(l("状态只影响 AgentJournal，不会关闭或归档原客户端会话。"))
                        .font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup(l("推进状态")) {
                        Text(l("进行中：参与推进分析。等待中：保留等待条件，可核对进展。暂时搁置／已完成：不参与推进分析，历史仍保留。"))
                            .fixedSize(horizontal: false, vertical: true)
                    }.font(.caption).foregroundStyle(.secondary)
                    JournalOpenThreadButton(activity: activity, language: store.settings.uiLanguage, disabled: store.isDemo)
                        .font(.caption)
                    Button { progressActivity = activity } label: {
                        Label(l("任务树与每日进度"), systemImage: "list.bullet.indent")
                    }.font(.caption).disabled(!store.canEdit)
                    if let plan = store.threadProgress.latest(activity.threadKey)?.plan {
                        JournalThreadProgressSummary(plan: plan, language: store.settings.uiLanguage, compact: true)
                    }
                    if let error = store.progressStorageError { Text(l.message(error)).font(.caption2).foregroundStyle(.orange) }
                    if !activity.cwd.isEmpty {
                        Text(URL(fileURLWithPath: activity.cwd).lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(activity.cwd)
                    }
                } else { Text(l("选择左侧的线程卡片")).font(.subheadline).foregroundStyle(.secondary) }
            }.padding(22)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if history.isEmpty {
                        emptyState(l("进展，有迹可循"), detail: l("同一个线程在不同日期做的事，\n会在这里连成一条时间线。"), icon: "point.3.connected.trianglepath.dotted")
                    } else { ForEach(history) { timelineRow($0) } }
                }.padding(22)
            }
        }.background(purple.opacity(0.035))
    }

    private func timelineRow(_ activity: JournalActivity) -> some View {
        let draft = store.draft(for: activity)
        let color = JournalPalette.source(activity.source)
        let selected = activity.day == store.clock.key(selectedDate)
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Circle().fill(selected ? color : color.opacity(0.4)).frame(width: 10, height: 10).padding(.top, 6)
                Rectangle().fill(color.opacity(0.18)).frame(width: 1).frame(minHeight: 145)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button { viewMode = "day"; choose(store.clock.date(activity.day)) } label: {
                        Text(l.date(store.clock.date(activity.day), clock: store.clock, style: .fullDay))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(selected ? color : .primary)
                    }.buttonStyle(.plain)
                    Spacer()
                    if draft.isConfirmed { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.green) }
                }
                Text(draft.displaySummary.isEmpty ? l("这一天有 %d 条对话，尚未生成草稿。", activity.messageCount) : draft.displaySummary)
                    .font(.subheadline).lineSpacing(5).textSelection(.enabled)
                if !draft.displayNextStep.isEmpty {
                    Text(l("后续：%@", draft.displayNextStep)).font(.caption).foregroundStyle(.secondary)
                }
                if draft.generatedAt != nil || !draft.summary.isEmpty {
                    Text(l.message(draft.modelLabel)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack {
                    Text(l(draft.isConfirmed ? "已确认" : "草稿")).font(.caption2).foregroundStyle(.secondary)
                    if hasNewActivity(activity, draft) { Text(l("有新进展")).font(.caption2).foregroundStyle(color) }
                    Spacer()
                    Button(l("编辑")) { editing = activity }.disabled(!store.canEdit)
                    if draft.summary.isEmpty {
                        Button(l("生成")) { requestSummary([activity]) }.disabled(store.isSummarizing || store.isDemo)
                    }
                }.font(.caption).buttonStyle(.borderless)
            }.padding(.bottom, 28)
        }
    }

    private func messageBar(_ text: String, error: Bool, dismiss: (() -> Void)? = nil) -> some View {
        HStack {
            Image(systemName: error ? "exclamationmark.triangle" : "info.circle")
            Text(text).font(.caption)
            Spacer()
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless) }
        }.padding(10).foregroundStyle(error ? Color.orange : purple).background(purple.opacity(0.06))
    }
    private func badge(_ title: String, color: Color) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.11), in: Capsule())
    }
    private func sourceDots(_ items: [JournalActivity]) -> some View {
        HStack(spacing: 3) {
            if items.contains(where: { $0.source == .codex }) { Circle().fill(JournalPalette.blue).frame(width: 4, height: 4) }
            if items.contains(where: { $0.source == .claude }) { Circle().fill(JournalPalette.orange).frame(width: 4, height: 4) }
        }
    }
    private func emptyState(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(purple.opacity(0.55))
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
        }.frame(maxWidth: .infinity).padding(.vertical, 65)
    }
    private func hasNewActivity(_ activity: JournalActivity, _ draft: JournalDraft) -> Bool {
        let fingerprint = draft.isConfirmed ? draft.confirmedFingerprint : draft.fingerprint
        return fingerprint != nil && fingerprint != "" && fingerprint != activity.fingerprint
    }
    private func choose(_ date: Date) {
        selectedDate = store.clock.calendar.startOfDay(for: date)
        month = date
    }
    private func shiftMonth(_ amount: Int) {
        let cal = store.clock.calendar
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        if let date = cal.date(byAdding: .month, value: amount, to: first) { choose(date) }
    }
    private func selectFirstIfNeeded() {
        if selectedThreadKey == nil || !listItems.contains(where: { $0.threadKey == selectedThreadKey }) {
            selectedThreadKey = listItems.first?.threadKey
        }
    }
    @State private var forceAfterConsent = false
    private func requestSummary(_ items: [JournalActivity], force: Bool = false) {
        if hasConsent { store.generate(items, force: force) }
        else { pendingSummary = items; enableAfterConsent = false; forceAfterConsent = force; showingConsent = true }
    }
    private func copyResume(_ activity: JournalActivity) {
        if let command = JournalNavigation.resumeCommand(for: activity) { JournalNavigation.copy(command) }
    }
    private func export(_ items: [JournalActivity], title: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "AgentJournal-\(store.clock.key(selectedDate)).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.markdown(for: items, title: title).write(to: url, atomically: true, encoding: .utf8) }
        catch { store.errorMessage = l("导出失败：") + error.localizedDescription }
    }
}

/// One-entry preparation shared by the macOS tree, report and advisor sheets.
/// Opening it never scans sources or starts a model request.
struct JournalSummaryPreparationView: View {
    @ObservedObject var store: JournalStore
    let activities: [JournalActivity]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var editing: JournalActivity?
    @State private var showingConsent = false
    @State private var pending: JournalActivity?
    private var l: JournalMacText { JournalMacText(store.settings.uiLanguage) }
    init(store: JournalStore, activities: [JournalActivity]) {
        self.store = store; self.activities = activities
        let sorted = activities.sorted { $0.lastActivity > $1.lastActivity }
        _selectedID = State(initialValue: (sorted.first {
            store.draft(for: $0).displaySummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? sorted.first)?.id)
    }
    private var items: [JournalActivity] {
        let ids = Set(activities.map(\.id))
        return store.activities.filter { ids.contains($0.id) }.sorted {
            $0.lastActivity == $1.lastActivity ? $0.id < $1.id : $0.lastActivity > $1.lastActivity
        }
    }
    private var selected: JournalActivity? { items.first { $0.id == selectedID } ?? items.first }
    private var savedCount: Int {
        items.filter { !store.draft(for: $0).displaySummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(l("先补齐一条每日摘要"), systemImage: "square.and.pencil").font(.title2.bold())
                Spacer()
                Button(l("返回继续")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(l("选择一条记录，生成模型草稿或手动写一句进展。保存后再返回原界面继续；不会自动开始分析或批量补齐。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(l("%d 条记录 · %d 条已保存摘要", items.count, savedCount)).font(.callout.bold()).foregroundStyle(JournalPalette.purple)
            Divider()
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            Button { selectedID = item.id } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(item.source.shortLabel) · \(item.day)").font(.caption).foregroundStyle(JournalPalette.source(item.source))
                                    Text(item.title).font(.subheadline.bold()).lineLimit(2)
                                    Text(l(store.draft(for: item).displaySummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "尚无摘要" : "已保存摘要，可以返回继续。"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected?.id == item.id ? JournalPalette.purple.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(width: 285)
                Divider()
                ScrollView {
                    if let item = selected { entry(item) }
                    else { Text(l("当前范围没有可编辑的记录，请返回调整日期或来源。")).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            if let error = store.errorMessage { Text(l.message(error)).foregroundStyle(.orange) }
        }.padding(24).frame(width: 880, height: 610).tint(JournalPalette.purple)
            .environment(\.locale, store.settings.uiLanguage.locale)
            .sheet(item: $editing) { JournalDraftEditor(store: store, activity: $0) }
            .alert(l("允许生成模型摘要？"), isPresented: $showingConsent) {
                Button(l("取消"), role: .cancel) { pending = nil }
                Button(l("允许")) {
                    if let item = pending, store.canGeneratePreparedSummary(item) { store.generate([item]) }
                    pending = nil
                }
            } message: {
                Text(l("仅这条记录的有限对话摘录会发送给所选 CLI；生成前会再次确认。手动编辑不调用模型。")
                    + "\n\n" + store.modelAccountNotice(for: store.settings))
            }
    }
    private func entry(_ item: JournalActivity) -> some View {
        let draft = store.draft(for: item)
        return VStack(alignment: .leading, spacing: 16) {
            Text(item.title).font(.headline)
            Text("\(item.day) · \(item.source.label)").font(.callout).foregroundStyle(.secondary)
            if !draft.displaySummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(l("已保存摘要，可以返回继续。"), systemImage: "checkmark.seal.fill").foregroundStyle(JournalPalette.green)
                Text(draft.displaySummary).lineSpacing(4).textSelection(.enabled)
                if !draft.displayNextStep.isEmpty { Text(l("后续：%@", draft.displayNextStep)).foregroundStyle(.secondary) }
            } else { Text(l("第一步：保存一条每日摘要")).font(.title3.bold()) }
            if store.isSummarizing {
                ProgressView(l.message(store.progressText))
                Button(l("停止生成")) { store.cancelGeneration() }
            } else {
                Button(l("生成这条摘要")) { pending = item; showingConsent = true }
                    .buttonStyle(.borderedProminent).disabled(!store.canGeneratePreparedSummary(item))
            }
            Button(l("手动编辑摘要")) { editing = item }.disabled(!store.canEdit || store.isLoading)
            if store.isDemo { Text(l("演示模式不调用模型，可以手动编辑示例。")) }
            else if item.excerpts.isEmpty { Text(l("原始摘录已不在本机，可手动补充摘要。")) }
            else if draft.editedSummary != nil || draft.isConfirmed {
                Text(l("已编辑或确认的笔记不会被模型覆盖；如需调整，请手动编辑。"))
            } else if draft.fingerprint == item.fingerprint {
                Text(l("已有当前模型草稿，可手动核对；不会为相同记录重复调用模型。"))
            }
            if !store.isDemo && store.remainingCalls == 0 {
                Text(l("已达到今日模型调用上限；可在调用控制中调整。")).foregroundStyle(.orange)
            }
            Text(l("仅这条记录的有限对话摘录会发送给所选 CLI；生成前会再次确认。手动编辑不调用模型。"))
                .font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct JournalLanguageSetup: View {
    @ObservedObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var settings: JournalSettings
    @State private var error: String?
    @State private var showingDiagnostics = false
    private var l: JournalText { JournalText(settings.uiLanguage) }
    init(store: JournalStore) {
        self.store = store
        _settings = State(initialValue: store.settings)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(systemName: "text.book.closed.fill").font(.system(size: 38)).foregroundStyle(JournalPalette.purple)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to AgentJournal / 欢迎").font(.title2.weight(.bold))
                    Text("Choose your languages / 选择语言").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Form {
                Picker("App language / 应用语言", selection: $settings.uiLanguage) {
                    ForEach(JournalInterfaceLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
                Picker("Summary language / 生成内容语言", selection: $settings.summaryLanguage) {
                    ForEach(JournalSummaryLanguage.allCases) { Text($0.label(settings.uiLanguage)).tag($0) }
                }
            }
            Text(l("界面语言与摘要语言相互独立。自动模式逐条判断用户讨论的主要语言；修改设置不会翻译已有记录。"))
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("You can change both later in Settings. / 以后可在设置中修改。")
                .font(.caption).foregroundStyle(.secondary)
            Text(l("浏览记录不需要模型或 CLI 登录。新日志的自动草稿默认关闭；升级保留原有设置。生成内容会说明发送内容与额度使用。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(l.message(error)).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(l("环境检查")) { showingDiagnostics = true }
                Spacer()
                Button(settings.uiLanguage == .english ? "Continue" : "开始使用") {
                    do {
                        settings.languageSetupComplete = true
                        try store.saveSettings(settings)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(store.isLoading || !store.canEdit)
            }
        }.padding(30).frame(width: 590).tint(JournalPalette.purple)
            .environment(\.locale, settings.uiLanguage.locale)
            .interactiveDismissDisabled()
            .sheet(isPresented: $showingDiagnostics) { JournalDiagnosticsView(settings: settings, demo: store.isDemo) }
    }
}

private struct JournalDraftEditor: View {
    @ObservedObject var store: JournalStore
    let activity: JournalActivity
    @Environment(\.dismiss) private var dismiss
    @State private var summary: String
    @State private var nextStep: String
    @State private var category: String
    @State private var confirmed: Bool
    private var l: JournalText { JournalText(store.settings.uiLanguage) }
    init(store: JournalStore, activity: JournalActivity) {
        self.store = store; self.activity = activity
        let draft = store.draft(for: activity)
        _summary = State(initialValue: draft.displaySummary)
        _nextStep = State(initialValue: draft.displayNextStep)
        _category = State(initialValue: draft.category)
        _confirmed = State(initialValue: draft.isConfirmed)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(l("编辑当天记录")).font(.title2.weight(.semibold))
            Text("\(activity.source.label) · \(activity.title) · \(activity.day)").foregroundStyle(.secondary).lineLimit(2)
            TextEditor(text: $summary).font(.body).frame(height: 175).padding(7)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(JournalPalette.purple.opacity(0.3)))
            TextField(l("后续事项（可留空）"), text: $nextStep)
            Picker(l("分类"), selection: $category) {
                ForEach(["未分类", "课程", "研究", "学工", "生活"], id: \.self) { Text(l.category($0)).tag($0) }
            }
            Toggle(l("确认这条记录"), isOn: $confirmed)
            Text(l("保存后的文字会保留；线程有新进展时会提示，不会自动改写。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(l("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(l("保存")) {
                    store.update(activity, summary: summary, nextStep: nextStep, category: category, confirmed: confirmed)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
                    .disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 600).tint(JournalPalette.purple)
    }
}

private struct JournalSettingsEditor: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var catalog: JournalModelCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var settings: JournalSettings
    @State private var error: String?
    @State private var customModel = false
    @State private var showingDiagnostics = false
    private var l: JournalText { JournalText(settings.uiLanguage) }
    init(store: JournalStore, catalog: JournalModelCatalog) {
        self.store = store
        self.catalog = catalog
        _settings = State(initialValue: store.settings)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(l("来源与摘要设置")).font(.title2.weight(.semibold))
            Text(l("只读本机日志，不修改会话，也不需要把 API 密钥交给本软件。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
            VStack(alignment: .leading, spacing: 17) {
            Form {
                Picker(l("读取哪些来源"), selection: $settings.sourceSelection) {
                    ForEach(JournalSourceSelection.allCases) { Text(l($0.label)).tag($0) }
                }
                TextField(l("Codex 主目录"), text: $settings.codexHome)
                TextField(l("Claude Code 主目录"), text: $settings.claudeHome)
                TextField(l("Claude 桌面会话目录（留空自动）"), text: Binding(
                    get: { settings.claudeDesktopSessionsHome ?? "" },
                    set: { settings.claudeDesktopSessionsHome = $0.isEmpty ? nil : $0 }))
                TextField(l("时区"), text: $settings.timeZoneID)
                Picker(l("摘要引擎"), selection: Binding(get: { settings.summaryEngine }, set: {
                    settings.selectEngine($0); customModel = false
                })) {
                    ForEach(JournalProvider.allCases) { Text($0.label).tag($0) }
                }
                Picker(l("摘要模型"), selection: Binding(get: { customModel ? "__custom__" : settings.model }, set: { value in
                    customModel = value == "__custom__"
                    if !customModel { settings.selectModel(value) }
                })) {
                    Text(l("跟随 CLI 默认")).tag("")
                    ForEach(catalog.choices(for: settings.summaryEngine, selected: settings.model)) { choice in
                        Text(l.message(choice.title)).tag(choice.id)
                    }
                    Text(l("自定义模型…")).tag("__custom__")
                }
                if customModel { TextField(l("自定义模型名"), text: $settings.model) }
                if settings.summaryEngine == .codex {
                    HStack {
                        Text(l.message(catalog.note)).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button(l(catalog.isRefreshing ? "刷新中…" : "刷新模型列表")) { Task { await catalog.refresh(settings) } }
                            .disabled(catalog.isRefreshing || store.isDemo)
                    }
                } else {
                    Text(l("Sonnet / Opus / Haiku 会由 Claude CLI 解析到对应模型；可选范围与账号、提供方有关。"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Picker(l("应用语言"), selection: $settings.uiLanguage) {
                    ForEach(JournalInterfaceLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
                Picker(l("生成内容语言"), selection: $settings.summaryLanguage) {
                    ForEach(JournalSummaryLanguage.allCases) { Text($0.label(settings.uiLanguage)).tag($0) }
                }
            }
            Text(l("界面语言与摘要语言相互独立。自动模式逐条判断用户讨论的主要语言；修改设置不会翻译已有记录。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(l("读取来源与摘要引擎相互独立：可以用 Codex 总结 CC，也可以反过来。实际模型会记录在草稿旁。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(l("排除项目（每行一个路径片段）")).font(.subheadline.weight(.medium))
            TextEditor(text: $settings.excludedProjects).font(.system(.caption, design: .monospaced)).frame(height: 65)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.2)))
            Text(l("Claude Code 原始日志可能定期清理；本软件保留已扫描的少量摘录与草稿。改时区或排除规则会重建索引，但保留原日志已清理的历史（被排除的项目除外）；已有笔记会对应到新日期，原笔记不删除。更换来源目录会重新建立索引。"))
                .font(.caption).foregroundStyle(.secondary)
            }
            }.frame(maxHeight: 580)
            if let error { Text(l.message(error)).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(l("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(l("环境检查")) { showingDiagnostics = true }
                Spacer()
                Button(l("保存设置")) {
                    do {
                        if customModel && settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            throw JournalError.message(l("请输入自定义模型名，或选择“跟随 CLI 默认”。"))
                        }
                        settings.selectModel(settings.model)
                        settings.languageSetupComplete = true
                        try store.saveSettings(settings); dismiss()
                    }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(store.isLoading || store.isModelBusy || !store.canEdit)
            }
        }.padding(26).frame(width: 640).tint(JournalPalette.purple)
        .onChange(of: settings.codexHome) { _, _ in catalog.loadCache(settings) }
        .sheet(isPresented: $showingDiagnostics) { JournalDiagnosticsView(settings: settings, demo: store.isDemo) }
    }
}
