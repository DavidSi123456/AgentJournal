import SwiftUI

struct JournalThreadProgressSummary: View {
    let plan: JournalThreadPlan
    let language: JournalInterfaceLanguage
    var compact = false
    private var l: JournalText { JournalText(language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if plan.kind == .fixed {
                HStack {
                    Text(l("已确认完成 %d / %d 项", plan.completedCount, plan.leaves.count))
                    Spacer()
                    if let fraction = plan.fraction { Text("\(Int((fraction * 100).rounded()))%").monospacedDigit() }
                    else { Text(l("范围待确认")).foregroundStyle(.secondary) }
                }.font(compact ? .caption : .subheadline.weight(.semibold))
                if let fraction = plan.fraction {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(JournalPalette.purple.opacity(0.13))
                            Capsule().fill(JournalPalette.purple).frame(width: geometry.size.width * fraction)
                        }
                    }.frame(height: compact ? 5 : 7).accessibilityHidden(true)
                }
                if !compact { Text(l("仅统计末级子项；不是时间、工作量或成功概率。")).font(.caption2).foregroundStyle(.secondary) }
            } else {
                Label(plan.stage.isEmpty ? l("阶段未设置") : plan.stage, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(compact ? .caption : .subheadline.weight(.semibold)).foregroundStyle(JournalPalette.purple)
                if !compact { Text(l("开放式研究展示阶段，不计算总体百分比。")).font(.caption2).foregroundStyle(.secondary) }
            }
            if plan.pendingCount > 0 { Text(l("%d 项待确认完成", plan.pendingCount)).font(.caption).foregroundStyle(.orange) }
            if !compact {
                ForEach(plan.generationNotices ?? [], id: \.self) { notice in
                    Text(l(notice.label)).font(.caption2).foregroundStyle(.orange)
                }
            }
        }.accessibilityElement(children: .combine)
    }
}

struct JournalThreadProgressView: View {
    @ObservedObject var store: JournalStore
    let activity: JournalActivity
    @Environment(\.dismiss) private var dismiss
    @State private var plan: JournalThreadPlan
    @State private var baseline: JournalThreadPlan
    @State private var revision: UUID?
    @State private var editingNode: JournalTaskNode?
    @State private var deletingNode: JournalTaskNode?
    @State private var showingConsent = false
    @State private var showingDiscard = false
    @State private var showingReload = false
    @State private var restoring: JournalProgressSnapshot?
    @State private var selectedSnapshotID: UUID?
    @State private var tab = "tree"
    @State private var message: String?
    private var l: JournalText { JournalText(store.settings.uiLanguage) }
    private var dirty: Bool { plan != baseline }
    private var input: JournalProgressInput { store.progressInput(for: activity.threadKey) }
    private var history: [JournalProgressSnapshot] { store.threadProgress.history(activity.threadKey) }
    private var scopeSignature: String {
        ([plan.goal, plan.kind.rawValue] + plan.nodes.map { "\($0.id)|\($0.parentID ?? "")|\($0.title)" }.sorted()).joined(separator: "\n")
    }
    init(store: JournalStore, activity: JournalActivity) {
        self.store = store; self.activity = activity
        let saved = store.threadProgress.latest(activity.threadKey)
        let value = saved?.plan ?? JournalThreadPlan(goal: String(activity.title.prefix(600)))
        _plan = State(initialValue: value); _baseline = State(initialValue: value)
        _revision = State(initialValue: saved?.id)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(l("线程任务树"), systemImage: "list.bullet.indent").font(.title2.bold()).foregroundStyle(JournalPalette.purple)
                Text(activity.source.shortLabel).font(.caption).foregroundStyle(JournalPalette.source(activity.source))
                Spacer()
                Button(l("关闭")) { if dirty { showingDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
            }
            Text(activity.title).font(.subheadline).lineLimit(2)
            HStack {
                Text(l("使用摘要模型：%@ · %@", store.settings.summaryEngine.shortLabel,
                    store.settings.model.isEmpty ? l("跟随 CLI 默认") : store.settings.model)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.isDraftingTasks {
                    ProgressView().controlSize(.small)
                    Button(l("停止生成")) { store.cancelTaskTree() }
                } else {
                    Button(l(revision == nil ? "自动草拟任务树" : "更新模型草稿")) {
                        if store.isDemo { store.draftThreadPlan(for: activity.threadKey) } else { showingConsent = true }
                    }.disabled(dirty || !store.canDraftThreadPlan || input.records.isEmpty)
                }
            }
            Text(l("仅点击生成时调用模型。完成项必须人工确认；模型不会覆盖人工修改的节点，也不会执行原线程。"))
                .font(.caption).foregroundStyle(.secondary)
            if let status = store.threadPlanBackgroundMessage {
                HStack {
                    Text(l(status)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if store.isModelBusy && !store.isDraftingTasks {
                        Button(l("停止后台生成")) { store.cancelBackgroundModelWork() }
                            .font(.caption)
                    }
                }
            }
            if let error = store.threadPlanStorageMessage { Text(l.message(error)).font(.caption).foregroundStyle(.orange) }
            if let error = store.taskTreeError { Text(l.message(error)).font(.caption).foregroundStyle(.orange) }
            if let message { Text(l.message(message)).font(.caption).foregroundStyle(.orange) }
            Picker(l("浏览方式"), selection: $tab) {
                Text(l("任务树")).tag("tree"); Text(l("每日历史")).tag("history")
            }.pickerStyle(.segmented)
            if tab == "tree" {
                ScrollView { editor.padding(.trailing, 8) }
                Divider()
                HStack {
                    Text(l(dirty ? "有未保存修改，保存后才计入线程进度。" : "修改会保存为今天的新版本；浏览历史不调用模型。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(l("重新加载")) { reload() }.disabled(store.isLoading || store.isDraftingTasks)
                    Button(l("记录今日快照")) { save(.checkpoint) }.disabled(dirty || revision == nil || !store.canEditThreadPlan)
                    Button(l("保存修改")) { save(.edit) }.buttonStyle(.borderedProminent)
                        .disabled(!dirty || !store.canEditThreadPlan || plan.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else { historyView }
        }.padding(24).frame(width: 1000, height: 760).tint(JournalPalette.purple)
            .environment(\.locale, store.settings.uiLanguage.locale)
            .interactiveDismissDisabled(dirty)
            .sheet(item: $editingNode) { node in
                JournalTaskNodeEditor(node: node, plan: plan, language: store.settings.uiLanguage) { edited in
                    if let index = plan.nodes.firstIndex(where: { $0.id == edited.id }) { plan.nodes[index] = edited }
                    else { plan.nodes.append(edited) }
                }
            }
            .alert(l("允许草拟线程任务树？"), isPresented: $showingConsent) {
                Button(l("取消"), role: .cancel) {}
                Button(l("允许")) { store.draftThreadPlan(for: activity.threadKey) }
            } message: {
                Text(l("仅将这个线程的标题、现有任务树、最多 60 条已保存每日摘要与下一步交给 %@ CLI 的模型提供方并消耗额度。不发送原始聊天摘录；任务树及摘要仍可能含私人信息。", store.settings.summaryEngine.label))
            }
            .alert(l("放弃未保存修改？"), isPresented: $showingDiscard) {
                Button(l("取消"), role: .cancel) {}
                Button(l("放弃修改"), role: .destructive) { dismiss() }
            }
            .alert(l("重新加载会放弃未保存修改，继续？"), isPresented: $showingReload) {
                Button(l("取消"), role: .cancel) {}
                Button(l("重新加载"), role: .destructive) { reloadConfirmed() }
            }
            .alert(l("删除这项及所有子项？"), isPresented: Binding(get: { deletingNode != nil }, set: { if !$0 { deletingNode = nil } })) {
                Button(l("取消"), role: .cancel) { deletingNode = nil }
                Button(l("删除"), role: .destructive) {
                    if let node = deletingNode { let ids = plan.descendants(of: node.id); plan.nodes.removeAll { ids.contains($0.id) } }
                    deletingNode = nil
                }
            } message: { Text(l("保存后改变目标范围；此前的任务树仍保留在每日历史中。")) }
            .alert(l("恢复这个历史版本？"), isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
                Button(l("取消"), role: .cancel) { restoring = nil }
                Button(l("恢复")) {
                    if let snapshot = restoring {
                        do {
                            try store.saveThreadPlan(snapshot.plan, for: activity.threadKey, expected: revision, reason: .restore)
                            sync(); tab = "tree"
                        } catch { message = error.localizedDescription }
                    }
                    restoring = nil
                }
            } message: { Text(l("会保存为今天的新版本，不会删除已有历史或调用模型。")) }
            .onChange(of: store.threadProgress.latest(activity.threadKey)?.id) { _, _ in
                if !dirty { sync() } else { message = l("任务树已有新版本，请先保存或重新加载。"); }
            }
            .onChange(of: scopeSignature) { _, _ in
                if !plan.hasSameScope(as: baseline) { plan.scopeConfirmed = false }
            }
            .onDisappear { store.cancelTaskTree() }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(l("线程目标"), text: $plan.goal).textFieldStyle(.roundedBorder)
                .onChange(of: plan.goal) { _, _ in if plan.goal != baseline.goal { plan.goalEdited = true } }
            HStack {
                Picker(l("目标类型"), selection: $plan.kind) {
                    ForEach(JournalProgressKind.allCases, id: \.self) { Text(l($0.label)).tag($0) }
                }.frame(width: 290)
                    .onChange(of: plan.kind) { _, _ in if plan.kind != baseline.kind { plan.kindEdited = true } }
                if plan.kind == .research {
                    TextField(l("当前阶段"), text: $plan.stage).textFieldStyle(.roundedBorder)
                        .onChange(of: plan.stage) { _, _ in if plan.stage != baseline.stage { plan.stageEdited = true } }
                }
            }
            if plan.kind == .fixed {
                Toggle(l("确认这棵树代表当前目标范围"), isOn: $plan.scopeConfirmed).disabled(plan.nodes.isEmpty)
                Text(l("新增、删除、改名或调整层级后需重新确认范围。百分比仅反映已确认完成的子项数。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            JournalThreadProgressSummary(plan: plan, language: store.settings.uiLanguage)
                .padding(14).background(JournalPalette.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text(l("任务与子项")).font(.headline)
                Spacer()
                Button(l("新增任务")) { editingNode = JournalTaskNode(title: "", userEdited: true) }
                    .disabled(plan.nodes.count >= 80 || !store.canEditThreadPlan)
            }
            if plan.nodes.isEmpty {
                Text(l("可自动草拟，也可手动建立。没有已保存摘要时，不会凭聊天数量推算进度。"))
                    .foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(plan.orderedNodes, id: \.node.id) { row in
                nodeRow(row.node, depth: row.depth, tree: plan, editable: true)
            }
            Divider()
            let coverage = plan.inputFingerprint == nil ? input.coverage : plan.coverage
            Text(l("依据覆盖：共 %d 天记录 · 提供 %d 条摘要 · %d 天缺摘要 · %d 条已过时", coverage.total,
                coverage.supplied, coverage.missing, coverage.outdated)).font(.caption).foregroundStyle(.secondary)
            Text(l("历史较长时使用最早 8 条和最新 52 条摘要，文字可能截断；不代表掌握完整对话或全部工作。"))
                .font(.caption2).foregroundStyle(.secondary)
            if let fingerprint = plan.inputFingerprint, fingerprint != input.fingerprint {
                Text(l("摘要有变化，可更新任务树；现有确认与历史不会自动改变。")).font(.caption).foregroundStyle(.orange)
            }
            if let engine = plan.engine {
                Text("\(l.message(engine)) · \(store.isDemo ? l("示例数据 · 未调用模型") : plan.model ?? l("模型未报告"))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.disabled(!store.canEditThreadPlan)
    }
    private func nodeRow(_ node: JournalTaskNode, depth: Int, tree: JournalThreadPlan, editable: Bool) -> some View {
        let isParent = tree.nodes.contains { $0.parentID == node.id }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Image(systemName: isParent ? "folder" : node.status == .completed ? "checkmark.circle.fill" : node.status == .blocked ? "exclamationmark.circle" : "circle")
                    .foregroundStyle(!isParent && node.status == .completed ? JournalPalette.green : JournalPalette.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.title).font(.subheadline.weight(.semibold))
                    Text(l(isParent ? "父项不计入百分比" : node.status.label)).font(.caption).foregroundStyle(.secondary)
                    if !node.detail.isEmpty { Text(node.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Spacer()
                if editable {
                    if !isParent && node.status != .completed {
                        Button(l("确认完成")) { confirm(node) }.font(.caption)
                    }
                    Menu {
                        Button(l("编辑")) { editingNode = node }
                        Button(l("新增子项")) { editingNode = JournalTaskNode(parentID: node.id, title: "", userEdited: true) }
                            .disabled(depth >= 4 || plan.nodes.count >= 80)
                        Button(l("删除"), role: .destructive) { deletingNode = node }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            if node.userEdited { Text(l("人工修改已保护")).font(.caption2).foregroundStyle(JournalPalette.green) }
            if !node.evidence.isEmpty {
                DisclosureGroup(l("查看依据（%d 条）", node.evidence.count)) {
                    ForEach(node.evidence) { evidence in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(evidence.day + " · " + l(evidence.freshness == "current" ? "生成时有效" : "生成时已过时"))
                                .font(.caption2).foregroundStyle(.secondary)
                            if !evidence.summary.isEmpty { Text(evidence.summary).font(.caption).textSelection(.enabled) }
                            if !evidence.nextStep.isEmpty { Text(l("后续：%@", evidence.nextStep)).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 4)
                    }
                }.font(.caption).padding(.leading, 22)
            }
        }.padding(12).background(JournalPalette.purple.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .padding(.leading, CGFloat(depth) * 22)
    }
    private var historyView: some View {
        HStack(alignment: .top, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Set(history.map(\.day)).sorted(by: >), id: \.self) { day in
                        Text(day).font(.headline).padding(.top, 6)
                        ForEach(history.filter { $0.day == day }) { snapshot in
                            Button { selectedSnapshotID = snapshot.id } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(l(snapshot.reason.label) + " · " + JournalClock(timeZoneID: snapshot.timeZoneID).label(snapshot.createdAt, "HH:mm:ss"))
                                    Text(l("已确认完成 %d / %d 项", snapshot.plan.completedCount, snapshot.plan.leaves.count)).font(.caption)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                    .background(((selectedSnapshotID ?? history.first?.id) == snapshot.id ? JournalPalette.purple.opacity(0.14) : .clear), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.frame(width: 235)
            Divider()
            ScrollView {
                if let snapshot = history.first(where: { $0.id == selectedSnapshotID }) ?? history.first {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(snapshot.plan.goal).font(.headline)
                        Text(snapshot.day + " · " + snapshot.timeZoneID + " · " + l(snapshot.reason.label)).font(.caption).foregroundStyle(.secondary)
                        if let engine = snapshot.plan.engine {
                            Text("\(l.message(engine)) · \(store.isDemo ? l("示例数据 · 未调用模型") : snapshot.plan.model ?? l("模型未报告"))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        JournalThreadProgressSummary(plan: snapshot.plan, language: store.settings.uiLanguage)
                        Button(l("恢复为当前版本")) { restoring = snapshot }.disabled(dirty || !store.canEditThreadPlan)
                        ForEach(snapshot.plan.orderedNodes, id: \.node.id) { row in nodeRow(row.node, depth: row.depth, tree: snapshot.plan, editable: false) }
                    }.padding(.trailing, 8)
                } else { Text(l("尚无历史。保存修改或生成草稿后，会记录当天的版本。")) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func confirm(_ node: JournalTaskNode) {
        guard let index = plan.nodes.firstIndex(where: { $0.id == node.id }) else { return }
        plan.nodes[index].status = .completed; plan.nodes[index].confirmedAt = Date(); plan.nodes[index].userEdited = true
    }
    private func save(_ reason: JournalProgressReason) {
        do { try store.saveThreadPlan(plan, for: activity.threadKey, expected: revision, reason: reason); sync() }
        catch { message = error.localizedDescription }
    }
    private func sync() {
        let saved = store.threadProgress.latest(activity.threadKey)
        plan = saved?.plan ?? JournalThreadPlan(goal: String(activity.title.prefix(600)))
        baseline = plan; revision = saved?.id; message = nil
    }
    private func reload() {
        if dirty { showingReload = true } else { reloadConfirmed() }
    }
    private func reloadConfirmed() {
        do { try store.reloadThreadPlans(); sync() }
        catch { message = error.localizedDescription }
    }
}

private struct JournalTaskNodeEditor: View {
    @State var node: JournalTaskNode
    let plan: JournalThreadPlan
    let language: JournalInterfaceLanguage
    var onSave: (JournalTaskNode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    private var l: JournalText { JournalText(language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l("编辑任务项")).font(.title2.bold())
            TextField(l("任务名称"), text: $node.title).textFieldStyle(.roundedBorder)
            Text(l("说明")).font(.caption)
            TextEditor(text: $node.detail).frame(height: 110).border(.secondary.opacity(0.2))
            Picker(l("上级任务"), selection: Binding(get: { node.parentID ?? "" }, set: { node.parentID = $0.isEmpty ? nil : $0 })) {
                Text(l("顶级任务")).tag("")
                ForEach(plan.nodes.filter { !plan.descendants(of: node.id).contains($0.id) }) { item in Text(item.title).tag(item.id) }
            }
            Picker(l("任务状态"), selection: $node.status) {
                ForEach(JournalTaskStatus.allCases, id: \.self) { Text(l($0.label)).tag($0) }
            }.disabled(plan.nodes.contains { $0.parentID == node.id })
            Text(l("选择已确认完成属于人工确认；保存主界面修改后才计入进度。"))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(l.message(error)).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(l("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(l("应用修改")) {
                    var value = node; value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    value.userEdited = true; value.confirmedAt = value.status == .completed ? value.confirmedAt ?? Date() : nil
                    var next = plan
                    if let index = next.nodes.firstIndex(where: { $0.id == value.id }) { next.nodes[index] = value }
                    else { next.nodes.append(value) }
                    // Validate topology here; persisted evidence is already validated by the store.
                    let evidenceKey = next.nodes.flatMap(\.evidence).first.map { String($0.id.dropLast($0.day.count + 1)) } ?? "manual"
                    do { try JournalProgressFile.validate(next, threadKey: evidenceKey); onSave(value); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 580, height: 470).tint(JournalPalette.purple)
    }
}
