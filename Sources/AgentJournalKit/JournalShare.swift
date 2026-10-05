import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct JournalShareRow: Identifiable {
    var id: String
    var source: JournalProvider
    var title: String
    var day: String
    var category: String
    var summary: String
    var confirmed: Bool
}

struct JournalShareThread: Identifiable {
    let id: String
    let source: JournalProvider
    let title: String
    let start: String
    let end: String
    let recordCount: Int
}

struct JournalShareReport {
    static let repositoryURL = URL(string: "https://github.com/DavidSi123456/AgentJournal")!
    let language: JournalInterfaceLanguage
    let start: String
    let end: String
    let items: [JournalActivity]
    let threads: [JournalShareThread]
    let rows: [JournalShareRow]
    let pending: [JournalActivity]
    var threadCount: Int { Set(items.map(\.threadKey)).count }
    var activeDays: Int { Set(items.map(\.day)).count }
    var codexCount: Int { Set(items.filter { $0.source == .codex }.map(\.threadKey)).count }
    var claudeCount: Int { Set(items.filter { $0.source == .claude }.map(\.threadKey)).count }
    var pageCount: Int { max(1, (rows.count + 3) / 4) }
    func page(_ number: Int) -> [JournalShareRow] {
        let first = max(0, number) * 4
        guard first < rows.count else { return [] }
        return Array(rows[first..<min(first + 4, rows.count)])
    }

    init(activities: [JournalActivity], drafts: [String: JournalDraft], start: String, end: String,
         provider: String = "all", showTitles: Bool = false, confirmedOnly: Bool = false,
         excludedThreadKeys: Set<String> = [],
         language: JournalInterfaceLanguage = .chinese) {
        self.language = language
        let l = JournalText(language)
        self.start = start; self.end = end
        items = activities.filter {
            $0.day >= start && $0.day <= end && (provider == "all" || $0.source.rawValue == provider)
                && (!confirmedOnly || drafts[$0.id]?.isConfirmed == true)
                && !excludedThreadKeys.contains($0.threadKey)
        }.sorted { $0.lastActivity == $1.lastActivity ? $0.id < $1.id : $0.lastActivity > $1.lastActivity }
        pending = items.filter {
            let draft = drafts[$0.id] ?? JournalDraft()
            return !draft.isConfirmed && draft.editedSummary == nil
                && (draft.summary.isEmpty || draft.fingerprint != $0.fingerprint)
        }
        var orderedKeys: [String] = [], seen = Set<String>()
        for item in items where seen.insert(item.threadKey).inserted { orderedKeys.append(item.threadKey) }
        let grouped = Dictionary(grouping: items, by: \.threadKey)
        threads = orderedKeys.compactMap { key in
            guard let records = grouped[key], let latest = records.first else { return nil }
            let days = records.map(\.day).sorted()
            return JournalShareThread(id: key, source: latest.source, title: latest.title,
                start: days.first!, end: days.last!, recordCount: records.count)
        }
        var output: [JournalShareRow] = []
        for (number, key) in orderedKeys.enumerated() {
            for item in (grouped[key] ?? []).sorted(by: { $0.day < $1.day }) {
                let draft = drafts[item.id] ?? JournalDraft()
                let title = showTitles ? Self.clean(item.title, language: language) : l("线程 %@", String(format: "%02d", number + 1))
                let text = draft.displaySummary.isEmpty
                    ? l("当天有 %d 条对话，尚未生成摘要。", item.messageCount)
                    : Self.clean(draft.displaySummary, language: language)
                let parts = Self.parts(text, limit: 380, language: language)
                for (part, text) in parts.enumerated() {
                    output.append(JournalShareRow(id: "\(item.id):\(part)", source: item.source,
                        title: title + (part > 0 ? l(" · 续") : ""), day: item.day, category: draft.category,
                        summary: text, confirmed: draft.isConfirmed))
                }
            }
        }
        rows = output
    }

    static func clean(_ text: String, language: JournalInterfaceLanguage = .chinese) -> String {
        let normalized = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Source paths are never included. Also redact common local paths in an
        // otherwise human-edited summary; users still review other private content.
        let pattern = "(?:/Users/|/private/|/Volumes/|/var/|/tmp/|~/)[^\\s，。；、\\)\\]）]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return normalized }
        return regex.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized),
                                               withTemplate: JournalText(language)("[本地路径]"))
    }
    static func parts(_ text: String, limit: Int, language: JournalInterfaceLanguage = .chinese) -> [String] {
        guard !text.isEmpty else { return [JournalText(language)("尚未生成摘要。")] }
        var remaining = text, values: [String] = []
        while remaining.count > limit {
            let boundary = remaining.index(remaining.startIndex, offsetBy: limit)
            values.append(String(remaining[..<boundary]))
            remaining = String(remaining[boundary...])
        }
        if !remaining.isEmpty { values.append(remaining) }
        return values
    }
}

private struct JournalShareCard: View {
    let report: JournalShareReport
    let page: Int
    var interactive = false
    private var l: JournalText { JournalText(report.language) }
    private let purple = Color(red: 0.48, green: 0.30, blue: 0.80)
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(l("这段时间，我做了什么")).font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(report.start == report.end ? report.start : "\(report.start) — \(report.end)")
                        .font(.system(size: 17, weight: .medium)).foregroundStyle(purple)
                }
                Spacer()
                Image(systemName: "text.book.closed.fill").font(.system(size: 38)).foregroundStyle(purple)
            }
            HStack(spacing: 12) {
                stat(l("%d 个活跃日", report.activeDays), purple)
                stat(l("%d 个线程", report.threadCount), purple)
                stat("\(report.codexCount) Codex", color(.codex))
                stat("\(report.claudeCount) CC", color(.claude))
            }
            Rectangle().fill(purple.opacity(0.14)).frame(height: 1)
            if report.rows.isEmpty {
                Text(l("这段时间没有符合条件的记录。")).font(.system(size: 18)).foregroundStyle(.secondary).padding(.vertical, 38)
            }
            ForEach(report.page(page)) { row in
                HStack(alignment: .top, spacing: 14) {
                    RoundedRectangle(cornerRadius: 3).fill(color(row.source)).frame(width: 4)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(row.source.shortLabel).font(.system(size: 13, weight: .bold)).foregroundStyle(color(row.source))
                            Text(l.category(row.category)).font(.system(size: 13)).foregroundStyle(purple)
                            Spacer()
                            Text(row.day).font(.system(size: 13)).foregroundStyle(.secondary)
                            Text(l(row.confirmed ? "已确认" : "草稿")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(row.title).font(.system(size: 21, weight: .semibold)).lineLimit(2)
                        Text(row.summary).font(.system(size: 18)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(18).fixedSize(horizontal: false, vertical: true)
                    .background(color(row.source).opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(color(row.source).opacity(0.14)))
            }
            HStack {
                Text(l("AgentJournal · 两种工具，一份进展")).font(.system(size: 12)).foregroundStyle(purple)
                Spacer()
                Text("\(page + 1) / \(report.pageCount)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            // ImageRenderer cannot rasterize Link controls. Export plain text;
            // enable the clickable version only in the on-screen preview.
            if interactive {
                Link(l("来自 %@", JournalShareReport.repositoryURL.absoluteString), destination: JournalShareReport.repositoryURL)
                    .font(.system(size: 12)).foregroundStyle(purple)
            } else {
                Text(l("来自 %@", JournalShareReport.repositoryURL.absoluteString))
                    .font(.system(size: 12)).foregroundStyle(purple)
            }
        }
        .padding(36).frame(width: 720, alignment: .leading)
        .background(LinearGradient(colors: [Color(red: 0.96, green: 0.94, blue: 1), .white],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .light)
    }
    private func color(_ provider: JournalProvider) -> Color {
        provider == .codex ? Color(red: 0.20, green: 0.46, blue: 0.91) : Color(red: 0.91, green: 0.45, blue: 0.13)
    }
    private func stat(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 11).padding(.vertical, 7).background(color.opacity(0.08), in: Capsule())
    }
}

@MainActor
enum JournalShareRenderer {
    static func png(_ report: JournalShareReport, page: Int) throws -> Data {
        let renderer = ImageRenderer(content: JournalShareCard(report: report, page: page))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else {
            throw JournalError.message(JournalText(report.language)("图片生成失败，请重试。"))
        }
        return data
    }
}

struct JournalShareView: View {
    @ObservedObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var provider = "all"
    @State private var showTitles = false
    @State private var confirmedOnly = false
    // Exclusions are scoped to this sheet. New threads default to included, and
    // changing the date/source filter does not forget an earlier opt-out.
    @State private var excludedThreadKeys = Set<String>()
    @State private var previewing = false
    @State private var page = 0
    @State private var askingConsent = false
    @State private var initiatedGeneration = false
    @State private var message: String?
    private var l: JournalText { JournalText(store.settings.uiLanguage) }

    init(store: JournalStore, date: Date) {
        self.store = store
        _start = State(initialValue: store.clock.calendar.date(byAdding: .day, value: -6, to: date)!)
        _end = State(initialValue: date)
    }
    private var report: JournalShareReport {
        makeReport(excluding: excludedThreadKeys)
    }
    private var availableReport: JournalShareReport { makeReport(excluding: []) }
    private func makeReport(excluding keys: Set<String>) -> JournalShareReport {
        JournalShareReport(activities: store.activities, drafts: store.drafts,
            start: store.clock.key(start), end: store.clock.key(end), provider: provider,
            showTitles: showTitles, confirmedOnly: confirmedOnly, excludedThreadKeys: keys,
            language: store.settings.uiLanguage)
    }
    private var currentPage: Int { min(page, report.pageCount - 1) }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l("分享这段时间的进展")).font(.title2.weight(.semibold))
                    Text(l(previewing ? "按线程归并每日摘要 · 长内容自动分页，不丢记录" : "先选择要分享的线程，再预览图片"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(l("关闭")) { dismiss() }
            }
            HStack {
                Label(l("1 · 选择内容"), systemImage: previewing ? "checkmark.circle.fill" : "1.circle.fill")
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                Label(l("2 · 预览图片"), systemImage: previewing ? "2.circle.fill" : "2.circle")
                    .foregroundStyle(previewing ? Color.purple : .secondary)
                Spacer()
            }.font(.caption.weight(.medium))
            if !previewing {
                HStack {
                    DatePicker(l("开始"), selection: $start, displayedComponents: .date)
                    DatePicker(l("结束"), selection: $end, displayedComponents: .date)
                    Picker(l("来源"), selection: $provider) {
                        Text(l("全部")).tag("all"); Text("Codex").tag("codex"); Text("Claude Code").tag("claude")
                    }.frame(width: 170)
                }.disabled(store.isSummarizing).environment(\.timeZone, store.clock.calendar.timeZone)
                HStack {
                    Button(l("当天")) { start = end }
                    Button(l("最近 7 天")) { start = store.clock.calendar.date(byAdding: .day, value: -6, to: end)! }
                    Button(l("本月")) { start = store.clock.calendar.date(from: store.clock.calendar.dateComponents([.year, .month], from: end))! }
                    Spacer()
                    Toggle(l("显示线程标题"), isOn: $showTitles)
                        .help(l("关闭后使用线程编号，不显示原始名字。"))
                    Toggle(l("仅已确认"), isOn: $confirmedOnly)
                }.font(.caption).disabled(store.isSummarizing)
            }
            if report.start > report.end { Text(l("开始日期不能晚于结束日期。")).font(.caption).foregroundStyle(.orange) }
            HStack {
                Text(l("%d 个线程 · %d 条每日记录 · %d 条可生成／更新", report.threadCount, report.items.count, report.pending.count))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.isSummarizing {
                    ProgressView().controlSize(.small)
                    Text(l.message(store.progressText)).font(.caption)
                    Button(l("停止生成")) { store.pauseAutomaticGeneration() }
                } else {
                    Button(l("生成所选线程草稿")) { askingConsent = true }
                        .disabled(report.pending.isEmpty || store.isDemo || store.isLoading || store.isModelBusy || !store.canEdit)
                }
            }
            if previewing {
                ScrollView {
                    JournalShareCard(report: report, page: currentPage, interactive: true)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(.purple.opacity(0.12)))
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .underPageBackgroundColor))
            } else {
                threadSelection
            }
            if let error = store.errorMessage { Text(l.message(error)).font(.caption).foregroundStyle(.orange).lineLimit(2) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text(l("仅分享整理后的文字，不带原始对话、路径字段或账号信息。仍请检查摘要中的个人信息；不会自动上传。"))
                .font(.caption2).foregroundStyle(.secondary)
            if previewing {
                HStack {
                    Button(l("返回选择")) { previewing = false; message = nil }.disabled(store.isSummarizing)
                    Button { page = max(0, currentPage - 1) } label: { Image(systemName: "chevron.left") }.disabled(currentPage == 0)
                    Text(l("第 %d / %d 张", currentPage + 1, report.pageCount)).font(.caption.monospacedDigit())
                    Button { page = min(report.pageCount - 1, currentPage + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(currentPage + 1 >= report.pageCount)
                    Spacer()
                    Button(l("复制图片")) { copyImage() }.disabled(report.items.isEmpty)
                    Button(l("保存 PNG")) { saveImage() }.disabled(report.items.isEmpty)
                    if report.pageCount > 1 { Button(l("保存全部")) { saveAllImages() } }
                    JournalNativeShareButton(title: l("分享图片"), enabled: !report.items.isEmpty) {
                        let data = try JournalShareRenderer.png(report, page: currentPage)
                        guard let image = NSImage(data: data) else { throw JournalError.message(l("图片无法读取")) }
                        return image
                    }.frame(width: store.settings.uiLanguage == .english ? 110 : 82, height: 24)
                }
            } else {
                HStack {
                    Text(l("%d / %d 个线程已选择", report.threadCount, availableReport.threadCount))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(l("预览图片")) { page = 0; message = nil; previewing = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(report.items.isEmpty || store.isLoading || store.isSummarizing)
                }
            }
        }.padding(24).frame(width: 920, height: 830).tint(.purple)
        .environment(\.locale, store.settings.uiLanguage.locale)
        .onChange(of: start) { _, _ in page = 0 }
        .onChange(of: end) { _, _ in page = 0 }
        .onChange(of: provider) { _, _ in page = 0 }
        .onChange(of: confirmedOnly) { _, _ in page = 0 }
        .onChange(of: excludedThreadKeys) { _, _ in page = 0 }
        .onChange(of: showTitles) { _, _ in page = 0 }
        .onDisappear { if initiatedGeneration { store.cancelGeneration() } }
        .alert(l("生成所选日期的摘要？"), isPresented: $askingConsent) {
            Button(l("取消"), role: .cancel) { }
            Button(l("允许生成")) { initiatedGeneration = true; store.generate(report.pending) }
        } message: {
            Text(l("将通过 %@ 生成／更新 %d 条每日草稿。少量对话摘录会发送给该 CLI 的模型提供方，并消耗额度；你编辑或确认过的文字不会被覆盖。", store.settings.summaryEngine.label, report.pending.count))
        }
    }
    private var threadSelection: some View {
        let options = availableReport
        let visibleKeys = Set(options.threads.map(\.id))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l("选择要分享的线程")).font(.headline)
                Spacer()
                Button(l("全部选中")) { excludedThreadKeys.subtract(visibleKeys) }
                Button(l("全部取消")) { excludedThreadKeys.formUnion(visibleKeys) }
            }.disabled(store.isSummarizing || options.threads.isEmpty)
            Text(l("默认全部包含；取消一个线程会排除它在所选期间的所有记录。这里只影响本次分享，不会删除日志。"))
                .font(.caption).foregroundStyle(.secondary)
            if options.threads.isEmpty {
                Text(l("所选日期没有符合条件的线程。"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(options.threads) { thread in
                            Toggle(isOn: Binding(get: { !excludedThreadKeys.contains(thread.id) }, set: { included in
                                if included { excludedThreadKeys.remove(thread.id) }
                                else { excludedThreadKeys.insert(thread.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(thread.title).font(.body.weight(.medium)).lineLimit(2)
                                    HStack {
                                        Text(thread.source.label).foregroundStyle(thread.source == .codex ? Color.blue : Color.orange)
                                        Text(l("%d 条每日记录", thread.recordCount))
                                        Text(thread.start == thread.end ? thread.start : "\(thread.start) — \(thread.end)")
                                    }.font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.toggleStyle(.checkbox).padding(14)
                                .background(Color.purple.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if report.items.isEmpty && !options.threads.isEmpty {
                Text(l("至少选择一个线程，才能预览图片。")).font(.caption).foregroundStyle(.orange)
            }
        }.disabled(store.isSummarizing)
    }
    private func copyImage() {
        do {
            let data = try JournalShareRenderer.png(report, page: currentPage)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
            message = l("图片已复制，可粘贴到微信等应用。")
        } catch { message = error.localizedDescription }
    }
    private func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "AgentJournal-\(report.start)-\(report.end)-\(currentPage + 1).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JournalShareRenderer.png(report, page: currentPage).write(to: url, options: .atomic); message = l("图片已保存。") }
        catch { message = error.localizedDescription }
    }
    private func saveAllImages() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = l("保存图片"); panel.message = l("选择文件夹，将创建独立子文件夹保存所有分页图片。")
        guard panel.runModal() == .OK, let base = panel.url else { return }
        let folder = base.appendingPathComponent("AgentJournal-\(report.start)-\(report.end)-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for number in 0..<report.pageCount {
                let target = folder.appendingPathComponent(String(format: "%03d.png", number + 1))
                try JournalShareRenderer.png(report, page: number).write(to: target, options: .atomic)
            }
            message = l("已保存 %d 张图片。", report.pageCount)
        } catch { message = l("部分图片可能已保存，请检查所选文件夹。") + error.localizedDescription }
    }
}

private struct JournalNativeShareButton: NSViewRepresentable {
    var title: String
    var enabled: Bool
    var image: () throws -> NSImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.isEnabled = enabled
        context.coordinator.image = image
    }
    final class Coordinator: NSObject {
        var image: (() throws -> NSImage)?
        var picker: NSSharingServicePicker?
        @objc func share(_ sender: NSButton) {
            do {
                guard let image = try image?() else { return }
                picker = NSSharingServicePicker(items: [image])
                picker?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            } catch { NSSound.beep() }
        }
    }
}
