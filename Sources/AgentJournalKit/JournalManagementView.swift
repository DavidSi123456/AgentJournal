import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct JournalManagementView: View {
    @ObservedObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var daily: Int
    @State private var automatic: Int
    @State private var paused: Bool
    @State private var includeHistory: Bool
    @State private var message: String?
    @State private var pendingBackup: Data?
    @State private var restoreDescription = ""
    @State private var confirmingRestore = false
    @State private var safetyURL: URL?
    @State private var archive: JournalArchive.Summary?
    private var l: JournalText { JournalText(store.settings.uiLanguage) }
    init(store: JournalStore) {
        self.store = store
        _daily = State(initialValue: store.workflow.dailyCallLimit)
        _automatic = State(initialValue: store.workflow.automaticCallLimit)
        _paused = State(initialValue: store.workflow.automaticPaused)
        _includeHistory = State(initialValue: store.workflow.includeHistoricalAutomaticDrafts)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(l("数据与调用"), systemImage: "externaldrive.badge.checkmark").font(.title2.bold())
                Spacer()
                Button(l("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TabView {
                ScrollView { controls.padding(14) }.tabItem { Label(l("调用控制"), systemImage: "gauge.with.dots.needle.50percent") }
                backup.padding(14).tabItem { Label(l("备份恢复"), systemImage: "externaldrive") }
            }
            if let message { Text(l.message(message)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(24).frame(width: 780, height: 640).tint(JournalPalette.purple)
            .alert(l("确认恢复备份？"), isPresented: $confirmingRestore) {
                Button(l("取消"), role: .cancel) { pendingBackup = nil }
                Button(l("恢复"), role: .destructive) { restore() }
            } message: { Text(restoreDescription + "\n\n" + l("将替换现有日志、建议历史、线程状态与任务树历史，并自动保留恢复前原文件。旧备份不含任务树时保留本机任务树。保留当前来源目录与设置，关闭自动草稿；不会调用模型。")) }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l("今日 %d / %d 次 · 自动 %d / %d 次", store.todayCalls.count, store.workflow.dailyCallLimit,
                   store.todayCalls.filter { $0.kind == .automatic }.count, store.workflow.automaticCallLimit)).font(.headline)
            Text(l("一次摘要请求最多整理 4 条记录。失败、取消和已开始的请求也计入上限；这是本地请求次数，不是 token、费用或账号剩余额度。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(l("这里计数的是 CLI 生成任务；CLI 内部可能有多轮模型请求，其他应用的调用不在统计中。"))
                .font(.caption).foregroundStyle(.secondary)
            Stepper(l("每日全部请求上限：%d", daily), value: $daily, in: 0...1000)
            Stepper(l("其中自动草稿上限：%d", automatic), value: $automatic, in: 0...1000)
            Toggle(l("暂停自动草稿"), isOn: $paused)
            Toggle(l("自动补齐选中线程的历史草稿"), isOn: $includeHistory)
            Text(l("默认只处理选中日期的记录；浏览旧线程不会自动补齐整段历史。上限 0 表示禁用。额度按应用时区的自然日重置。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(l("保存设置")) {
                    do { try store.configureCalls(daily: daily, automatic: automatic, paused: paused, includeHistory: includeHistory); message = l("调用控制已保存。") }
                    catch { message = error.localizedDescription }
                }.disabled(!store.canManageWorkflow)
                Button(l("立即暂停并停止")) { store.pauseAutomaticGeneration(); paused = true }
                    .disabled(!store.canManageWorkflow)
            }
            if let notice = store.controlNotice { Text(l.message(notice)).font(.caption).foregroundStyle(.orange) }
            if let error = store.workflowError { Text(l.message(error)).font(.caption).foregroundStyle(.orange) }
            Divider()
            Label(l("待生成列表：%d 条", store.automaticPending.count), systemImage: "list.bullet.rectangle").font(.headline)
            Text(l("仅预览，不调用模型；仍会等待线程静置一分钟，并跳过已编辑或确认的记录。"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(store.automaticPending.prefix(30)) { activity in
                HStack {
                    Circle().fill(JournalPalette.source(activity.source)).frame(width: 6, height: 6)
                    Text(activity.title).lineLimit(1)
                    Spacer()
                    Text(activity.day).foregroundStyle(.secondary)
                }.font(.caption)
            }
            if store.automaticPending.count > 30 { Text(l("仅显示前 30 条；不会自动扩大生成范围。")).font(.caption).foregroundStyle(.secondary) }
            Divider()
            Text(l("今日请求记录")).font(.headline)
            ForEach(store.todayCalls) { call in
                HStack {
                    Text(store.clock.label(call.createdAt, "HH:mm:ss"))
                    Text(l(call.kind.label))
                    Text(call.engine.shortLabel).foregroundStyle(JournalPalette.source(call.engine))
                    Text(call.model.isEmpty ? l("跟随 CLI 默认") : call.model).lineLimit(1)
                    Spacer()
                    Text(l(call.outcome.label)).foregroundStyle(.secondary)
                }.font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var backup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(l("备份包含人工记录、线程状态、任务树与每日历史、建议与反馈、调用记录、周报／月报，以及线程标题和日期。不包含原始对话摘录、CLI 凭据文件或账号配置。"))
            Text(l("备份未加密，可能含私人文字和本地路径。请保存到安全位置，不要提交到 GitHub。"))
                .font(.callout).foregroundStyle(.orange)
            HStack(spacing: 18) {
                Button(l("导出完整备份")) { exportBackup() }.buttonStyle(.borderedProminent)
                Button(l("选择备份恢复…")) { chooseBackup() }
            }.disabled(store.isDemo || store.isLoading || store.isModelBusy)
            Text(l("恢复前会校验格式，并在本机保留原文件。恢复不会打开原线程、发送消息或启动模型；当前来源目录和设置不变。"))
                .font(.caption).foregroundStyle(.secondary)
            if let safetyURL { Button(l("打开恢复前备份")) { NSWorkspace.shared.open(safetyURL) } }
            if store.isDemo { Text(l("演示模式不读取或写入备份。")).foregroundStyle(.secondary) }
            Divider()
            Text(l("历史归档")).font(.headline)
            if let error = store.archiveHistoryError { Text(l.message(error)).font(.caption).foregroundStyle(.orange) }
            Text(l("推进建议历史或状态文件超过 32MB 时，最早的建议、周报／月报和 30 天前的调用记录会移到 Archive 文件夹，不会删除。历史建议和回顾仍可浏览，完整备份包含归档；恢复时合并归档并保留本机已有历史。"))
                .font(.caption).foregroundStyle(.secondary)
            if let archive, archive.files > 0 {
                Text(l("已归档 %d 次建议 · %d 份期间回顾 · %d 条调用记录（%d 个文件）",
                       archive.advice, archive.reports, archive.calls, archive.files)).font(.callout)
                Button(l("打开归档文件夹")) { NSWorkspace.shared.open(store.archiveURL) }
            } else if archive != nil {
                Text(l("暂无归档。")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task {
            guard !store.isDemo else { return }
            let folder = store.archiveURL
            archive = await Task.detached(priority: .utility) { JournalArchive.summary(in: folder) }.value
        }
    }
    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AgentJournal-Backup-\(store.clock.label(Date(), "yyyyMMdd-HHmmss")).json"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try store.backupData()
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            message = l("备份已保存，请妥善保管。")
        } catch { message = error.localizedDescription }
    }
    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = try JournalFileAccess.read(url, maximum: 128 * 1024 * 1024) else { return }
            let value = try JournalBackupFile.decode(data)
            let journal = try JSONDecoder().decode(JournalStore.Saved.self, from: value.journal)
            restoreDescription = l("%d 条日志 · %d 次建议 · %d 份期间回顾", journal.drafts.count, value.advice.count, value.workflow.reports.count)
            pendingBackup = data; confirmingRestore = true
        } catch { message = error.localizedDescription }
    }
    private func restore() {
        guard let pendingBackup else { return }
        do {
            safetyURL = try store.restoreBackup(pendingBackup)
            message = l("恢复完成，原文件已备份。自动草稿已关闭。")
        } catch { message = error.localizedDescription }
        self.pendingBackup = nil
    }
}
