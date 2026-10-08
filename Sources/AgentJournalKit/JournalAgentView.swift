import SwiftUI
import AppKit

struct JournalOpenThreadButton: View {
    let activity: JournalActivity
    let language: JournalInterfaceLanguage
    var disabled = false
    var compact = false
    @State private var notice: String?
    @State private var showingNotice = false
    private var l: JournalText { JournalText(language) }
    private var title: String {
        activity.source == .codex ? l("打开 Codex 原线程") : l("返回 Claude Code（实验性）")
    }
    var body: some View {
        Button {
            notice = JournalNavigation.open(activity, language: language)
            showingNotice = notice != nil
        } label: {
            if compact { Image(systemName: "arrow.up.forward.app").accessibilityLabel(title) }
            else { Label(title, systemImage: "arrow.up.forward.app") }
        }
        .help(title).disabled(disabled || UUID(uuidString: activity.threadID) == nil)
        .alert(l("返回原线程"), isPresented: $showingNotice) {
            if activity.source == .claude { Button(l("复制线程标题")) { JournalNavigation.copy(activity.title) } }
            Button(l("关闭"), role: .cancel) {}
        } message: { Text(notice ?? "") }
    }
}

struct JournalAgentView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var catalog: JournalModelCatalog
    var onViewThread: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingConsent = false
    @State private var showingSummaryPreparation = false
    @State private var summaryScope: [JournalActivity] = []
    @State private var selectedDay: String
    @State private var selectedResultID: UUID?
    init(store: JournalStore, catalog: JournalModelCatalog, date: Date, onViewThread: @escaping (String) -> Void) {
        self.store = store; self.catalog = catalog; self.onViewThread = onViewThread
        _selectedDay = State(initialValue: store.clock.key(date))
    }
    private var l: JournalMacText { JournalMacText(store.settings.uiLanguage) }
    private var input: JournalAgentInput { store.agentInput }
    private var dayResults: [JournalAgentResult] {
        let saved = store.advice(on: selectedDay)
        if let latest = store.agentResult, latest.day == selectedDay, !saved.contains(where: { $0.id == latest.id }) {
            return [latest] + saved
        }
        return saved
    }
    private var displayedResult: JournalAgentResult? {
        dayResults.first { $0.id == selectedResultID } ?? dayResults.first
    }
    private var displayedInput: JournalAgentInput { displayedResult?.input ?? input }
    private var busy: Bool { store.isLoading || store.isModelBusy }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "sparkles.rectangle.stack.fill").font(.title).foregroundStyle(JournalPalette.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(l("推进助手")).font(.title2.bold())
                    Text(l("每日建议，保留进展的判断")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(l("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(l("对比已完成的进展、明确的下一步和阻塞。不会读取日程计划的 DDL、重要度，也不会自动发消息或执行任务。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Menu {
                    ForEach(JournalProvider.allCases) { engine in
                        Menu(engine.label) {
                            Button(l("跟随 CLI 默认")) { chooseModel(engine, "") }
                            ForEach(catalog.choices(for: engine, selected: engine == store.settings.adviceSettings.summaryEngine ? store.settings.adviceSettings.model : "")) { choice in
                                Button(l.message(choice.title)) { chooseModel(engine, choice.id) }
                            }
                        }
                    }
                } label: {
                    Label("\(store.settings.adviceSettings.summaryEngine.shortLabel) · \(l.message(catalog.title(provider: store.settings.adviceSettings.summaryEngine, model: store.settings.adviceSettings.model)))", systemImage: "sparkles")
                }.disabled(busy || !store.canEdit)
                Text(store.settings.summaryLanguage.label(store.settings.uiLanguage)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.isAdvising {
                    ProgressView().controlSize(.small)
                    Button(l("停止分析")) { store.cancelAdvice() }
                } else {
                    Button(l(store.isDemo ? "查看演示建议" : "分析当前进展")) {
                        if store.isDemo { store.analyzeProgress() } else { showingConsent = true }
                    }.buttonStyle(.borderedProminent).disabled(busy || !store.canStartProgressAnalysis)
                }
            }
            HStack {
                Text(l("当前可分析：%d / %d 个候选线程有摘要", store.adviceReadyThreadCount, input.candidates.count))
                    .font(.callout.weight(.semibold))
                Spacer()
                if !input.candidates.isEmpty {
                    Button(l("先生成或编辑摘要")) { prepareSummaries() }.disabled(!store.canEdit)
                }
            }
            if store.adviceReadyThreadCount == 0 {
                Label(l("零摘要不会调用模型"), systemImage: "lock.shield").foregroundStyle(JournalPalette.green)
            } else if store.adviceReadyThreadCount == 1 {
                Text(l("只有一个线程有摘要：可核对它的下一步，不能比较多个线程的优先顺序。"))
                    .font(.callout).foregroundStyle(.secondary)
            } else if store.adviceReadyThreadCount < input.candidates.count {
                Text(l("部分候选缺少摘要，建议只代表已提供的有限进展。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !store.isDemo && store.remainingCalls == 0 {
                Text(l("已达到今日模型调用上限；可在调用控制中调整。"))
                    .font(.callout).foregroundStyle(.orange)
            }
            DisclosureGroup(l("工作方式与数据范围")) {
                Text(l("新分析始终使用当前进展，并保存到生成当天；选择历史日期只回看，不调用模型。"))
                Text(l("推进助手可单独选择模型。已处理／不采纳的建议在出现新进展前不再重复推荐。"))
            }.font(.caption).foregroundStyle(.secondary)
            if store.isAdvising {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(l(store.advicePhase.label)).font(.headline)
                    }
                    if let started = store.adviceStartedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(l("已等待 %d 秒 · 可随时停止", max(0, Int(context.date.timeIntervalSince(started)))))
                                .font(.callout.monospacedDigit())
                        }
                    }
                    Text(l("模型响应时间取决于所选 CLI、模型和网络；这里不显示虚构进度百分比。"))
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(JournalPalette.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            if let error = store.agentError { Text(l.message(error)).font(.callout).foregroundStyle(.orange) }
            if let error = store.agentHistoryError {
                HStack {
                    Text(l.message(error)).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    if let result = store.agentResult, !store.agentHistory.contains(where: { $0.id == result.id }) {
                        Button(l("重试保存（不调用模型）")) { store.retrySavingAdvice() }.disabled(store.isAdvising)
                    }
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 20) {
                historySidebar.frame(width: 190)
                Divider()
                ScrollView {
                    adviceContent.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 10)
                }
            }
            Text(l(store.isDemo ? "演示历史仅在内存中，不读取私人记录，不调用模型。" : "建议与依据保存在本机，退出后仍可回看，可能包含私人信息。建议不代表真实优先级；返回客户端不会发送下一步。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(26).frame(width: 1020, height: 760).tint(JournalPalette.green)
        .sheet(isPresented: $showingSummaryPreparation) { JournalSummaryPreparationView(store: store, activities: summaryScope) }
        .alert(l("允许分析线程进展？"), isPresented: $showingConsent) {
            Button(l("取消"), role: .cancel) {}
            Button(l("允许")) { store.analyzeProgress() }
        } message: {
            Text(l("将最多 40 个线程的标题、日期和最近 3 天的摘要与下一步交给 %@ CLI 的模型提供方并消耗额度。摘要也可能包含私人信息；不会使用工具或修改原线程。", store.settings.adviceSettings.summaryEngine.label)
                + "\n\n" + store.modelAccountNotice(for: store.settings.adviceSettings))
        }
        .onChange(of: store.agentResult?.id) { _, _ in
            if let result = store.agentResult { selectedDay = result.day; selectedResultID = result.id }
        }
        .onDisappear { store.cancelAdvice() }
    }
    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(l("每日建议"), systemImage: "clock.arrow.circlepath").font(.headline).foregroundStyle(JournalPalette.green)
            DatePicker(l("查看日期"), selection: Binding(
                get: { store.clock.date(selectedDay) },
                set: { selectedDay = store.clock.key($0); selectedResultID = nil }
            ), displayedComponents: .date)
                .datePickerStyle(.field).environment(\.timeZone, store.clock.calendar.timeZone)
                .environment(\.locale, store.settings.uiLanguage.locale)
            Button(l("今天")) { selectedDay = store.clock.key(Date()); selectedResultID = nil }
            Text(l("%d 天 · %d 次分析", store.agentHistoryDays.count, store.agentHistory.count))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.agentHistoryDays, id: \.self) { day in
                        Button { selectedDay = day; selectedResultID = nil } label: {
                            HStack {
                                Circle().fill(JournalPalette.green).frame(width: 6, height: 6)
                                Text(day).font(.subheadline.monospacedDigit())
                                Spacer()
                                Text("\(store.advice(on: day).count)").font(.caption).foregroundStyle(.secondary)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedDay == day ? JournalPalette.green.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).accessibilityLabel(l("%@，%d 次分析", day, store.advice(on: day).count))
                    }
                    if store.agentHistory.isEmpty { Text(l("还没有保存的建议")).font(.caption).foregroundStyle(.secondary).padding(.top, 12) }
                }
            }
        }
    }
    private var adviceContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(selectedDay).font(.title3.weight(.semibold).monospacedDigit())
                Spacer()
                if let result = displayedResult, dayResults.count > 1 {
                    let index = dayResults.firstIndex { $0.id == result.id } ?? 0
                    Button { selectAdjacentVersion(1) } label: { Image(systemName: "chevron.left") }
                        .disabled(index == dayResults.count - 1).help(l("较早的建议")).accessibilityLabel(l("较早的建议"))
                    Menu {
                        ForEach(dayResults) { saved in
                            Button(versionTitle(saved)) { selectedResultID = saved.id }
                        }
                    } label: { Label(versionTitle(result), systemImage: "clock") }.fixedSize()
                    Button { selectAdjacentVersion(-1) } label: { Image(systemName: "chevron.right") }
                        .disabled(index == 0).help(l("较新的建议")).accessibilityLabel(l("较新的建议"))
                }
            }
            if let result = displayedResult {
                if result.day != store.clock.key(Date()) || store.adviceIsOutdated(result) {
                    Label(l("历史快照：保留当时的判断，继续前请核对当前进展。"), systemImage: "clock.badge.exclamationmark")
                        .font(.callout).foregroundStyle(.orange)
                }
                if !store.isDemo && !store.agentHistory.contains(where: { $0.id == result.id }) {
                    Label(l("尚未保存 · 退出后会丢失"), systemImage: "exclamationmark.triangle").font(.caption.bold()).foregroundStyle(.orange)
                }
                Text(result.response.overview).font(.body).lineSpacing(4)
                Text("\(l.message(result.engine)) · \(result.model ?? l("模型未报告")) · \(JournalClock(timeZoneID: result.timeZoneID).label(result.generatedAt, "yyyy-MM-dd HH:mm:ss"))")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("\(result.timeZoneID) · \(JournalSummaryLanguage(rawValue: result.languageCode)?.label(store.settings.uiLanguage) ?? result.languageCode)")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(l("当时的候选：%d / %d 个线程，每个最多 3 天的摘要。", result.input.candidates.count, result.input.totalThreads))
                    .font(.caption).foregroundStyle(.secondary)
                if result.response.suggestions.isEmpty {
                    Text(l("暂无有依据的推荐；可先补齐或核对最新进展。"))
                    Button(l("核对或补齐当前摘要")) { prepareSummaries() }
                        .disabled(store.advicePreparationActivities.isEmpty || !store.canEdit)
                }
                ForEach(result.response.suggestions) { item in suggestion(item, result: result) }
            } else if store.isAdvising {
                Text(l("分析正在进行，完成后会显示结果。历史建议仍可回看，不代表本次分析已完成。"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(l(input.candidates.isEmpty ? "当前没有可分析的线程" : store.adviceReadyThreadCount == 0 ? "第一步：保存一条每日摘要" : "这一天还没有推进建议")).font(.title3.weight(.semibold))
                    Text(l(input.candidates.isEmpty ? "先读取所选来源的本机记录，或将线程设为进行中／等待中。已搁置和已完成线程的历史仍保留。" : store.adviceReadyThreadCount == 0 ? "选择一条记录保存摘要，再返回这里分析；手动编辑不消耗模型额度。" : "选择左侧已保存的日期回看，或点击分析当前进展。不会为没有记录的过去日期补造建议。"))
                        .foregroundStyle(.secondary)
                    Text(l("先生成或编辑线程的每日摘要，再点击分析。助手只使用这里保存的摘要与下一步，不发送原始对话、项目路径或日程数据。"))
                        .foregroundStyle(.secondary)
                    if !input.candidates.isEmpty {
                        Button(l("先生成或编辑摘要")) { prepareSummaries() }
                            .buttonStyle(.borderedProminent).disabled(!store.canEdit)
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(JournalPalette.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
            DisclosureGroup(l(displayedResult == nil ? "查看当前候选范围" : "查看本次候选范围")) {
                ForEach(displayedInput.candidates) { candidate in
                    HStack(alignment: .top) {
                        Text(candidate.source).font(.caption).foregroundStyle(candidate.source == "Codex" ? JournalPalette.blue : JournalPalette.orange)
                        Text(candidate.title).font(.caption).lineLimit(2)
                        Spacer()
                        Text(candidate.lastDay).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(l(candidate.records.first?.freshness == "current" ? "摘要最新" : candidate.records.first?.freshness == "outdated" ? "摘要已过期" : "尚无摘要"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(l("查看补齐路径")) { prepareSummaries(store.history(for: candidate.id)) }
                            .font(.caption).disabled(store.history(for: candidate.id).isEmpty || !store.canEdit)
                    }.padding(.vertical, 4)
                }
            }.font(.caption).padding(.top, 12)
        }
    }
    private func prepareSummaries(_ items: [JournalActivity]? = nil) {
        summaryScope = items ?? store.advicePreparationActivities
        showingSummaryPreparation = true
    }
    private func versionTitle(_ result: JournalAgentResult) -> String {
        let index = dayResults.firstIndex { $0.id == result.id } ?? 0
        return "\(dayResults.count - index) · \(JournalClock(timeZoneID: result.timeZoneID).label(result.generatedAt, "HH:mm:ss"))"
    }
    private func selectAdjacentVersion(_ offset: Int) {
        guard let result = displayedResult, let index = dayResults.firstIndex(where: { $0.id == result.id }),
              dayResults.indices.contains(index + offset) else { return }
        selectedResultID = dayResults[index + offset].id
    }
    private func chooseModel(_ engine: JournalProvider, _ model: String) {
        var settings = store.settings
        settings.advisorEngine = engine; settings.advisorModel = model
        do { try store.saveSettings(settings) } catch { store.agentError = error.localizedDescription }
    }
    private func suggestion(_ item: JournalAgentSuggestion, result: JournalAgentResult) -> some View {
        let candidate = result.input.candidates.first { $0.id == item.threadKey }
        let activity = store.history(for: item.threadKey).first
        let color = candidate?.source == "Codex" ? JournalPalette.blue : JournalPalette.orange
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(candidate?.source ?? "").font(.caption.weight(.semibold)).foregroundStyle(color)
                Text(l(item.disposition.label)).font(.caption.weight(.medium)).foregroundStyle(JournalPalette.green)
                Spacer()
                Text(l("判断把握：%@", l(item.confidence == "high" ? "较高" : item.confidence == "medium" ? "中等" : "较低")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                onViewThread(item.threadKey); dismiss()
            } label: { Text(candidate?.title ?? "").font(.headline).multilineTextAlignment(.leading) }.buttonStyle(.plain).disabled(activity == nil)
            Text(item.reason).font(.callout).lineSpacing(3)
            Label(item.nextAction, systemImage: "arrow.turn.down.right").font(.callout.weight(.medium))
            HStack {
                Picker(l("建议反馈"), selection: Binding(
                    get: { store.workflow.feedback(resultID: result.id, threadKey: item.threadKey)?.status ?? .pending },
                    set: { store.setFeedback($0, suggestion: item, result: result) })) {
                    ForEach(JournalFeedbackStatus.allCases, id: \.self) { Text(l($0.label)).tag($0) }
                }.frame(maxWidth: 270)
                Spacer()
                if let feedback = store.workflow.feedback(resultID: result.id, threadKey: item.threadKey) {
                    Text(store.clock.label(feedback.createdAt, "MM-dd HH:mm")).foregroundStyle(.secondary)
                }
            }.font(.caption).disabled(!store.canManageWorkflow || store.isAdvising || (!store.isDemo && !store.agentHistory.contains(where: { $0.id == result.id })))
            DisclosureGroup(l("进展依据")) {
                ForEach(candidate?.records.filter { item.evidenceIDs.contains($0.id) } ?? [], id: \.id) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(record.day) · \(l(record.freshness == "current" ? "摘要最新" : record.freshness == "missing" ? "无摘要" : "摘要已过期"))")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if !record.summary.isEmpty { Text(record.summary).font(.caption) }
                        if !record.nextStep.isEmpty { Text(l("后续：%@", record.nextStep)).font(.caption) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }
            }.font(.caption)
            HStack {
                Button(l("查看线程时间线")) { onViewThread(item.threadKey); dismiss() }.disabled(activity == nil)
                Button(l("复制下一步")) { JournalNavigation.copy(item.nextAction) }
                Spacer()
                if let activity {
                    JournalOpenThreadButton(activity: activity, language: store.settings.uiLanguage, disabled: store.isDemo)
                } else {
                    Text(l("原线程未在当前记录中，建议与依据仍保留")).foregroundStyle(.secondary)
                }
            }.font(.caption)
        }.padding(18).background(color.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.2)))
    }
}
