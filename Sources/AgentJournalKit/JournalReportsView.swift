import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct JournalReportsView: View {
    @ObservedObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: JournalPeriodKind = .week
    @State private var start: Date
    @State private var end: Date
    @State private var selectedID: UUID?
    @State private var showingConsent = false
    @State private var message: String?
    @State private var page = 0
    private var l: JournalText { JournalText(store.settings.uiLanguage) }
    init(store: JournalStore, date: Date) {
        self.store = store
        let interval = store.clock.calendar.dateInterval(of: .weekOfYear, for: min(date, Date()))!
        _start = State(initialValue: interval.start)
        _end = State(initialValue: min(Date(), interval.end.addingTimeInterval(-1)))
    }
    private var input: JournalPeriodInput { store.periodInput(start: start, end: end) }
    private var reports: [JournalPeriodReport] { store.savedReports }
    private var selected: JournalPeriodReport? {
        if let latest = store.reportResult, latest.id == selectedID { return latest }
        return reports.first { $0.id == selectedID }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(l("周报／月报"), systemImage: "calendar.badge.checkmark").font(.title2.bold())
                Spacer()
                Button(l("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker(l("期间"), selection: Binding(get: { kind }, set: { kind = $0; choosePeriod($0, anchor: end) })) {
                    ForEach(JournalPeriodKind.allCases, id: \.self) { Text(l($0.label)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel(l("期间"))
                    .frame(width: store.settings.uiLanguage == .english ? 340 : 260)
                Spacer(minLength: 16)
                DatePicker(l("开始"), selection: $start, displayedComponents: .date).fixedSize()
                DatePicker(l("结束"), selection: $end, displayedComponents: .date).fixedSize()
            }.disabled(store.isModelBusy).environment(\.timeZone, store.clock.calendar.timeZone)
            HStack {
                Button(l("上一期间")) { choosePeriod(kind, anchor: start.addingTimeInterval(-1)) }.disabled(kind == .custom || store.isModelBusy)
                Button(l("当前期间")) { choosePeriod(kind, anchor: Date()) }.disabled(kind == .custom || store.isModelBusy)
                Text(l("%d 条记录 · %d 条有摘要 · %d 条缺少摘要", input.totalRecords, input.totalRecords - input.missingRecords, input.missingRecords))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.isReporting {
                    ProgressView().controlSize(.small)
                    Button(l("停止生成")) { store.cancelReport() }
                } else {
                    Button(l(store.isDemo ? "生成演示回顾" : "生成期间回顾")) {
                        if store.isDemo { store.generateReport(kind: kind, start: start, end: end) }
                        else { showingConsent = true }
                    }.buttonStyle(.borderedProminent)
                        .disabled(store.isModelBusy || store.isLoading || !store.canManageWorkflow || input.records.isEmpty || input.start > input.end)
                }
            }
            Text(l("只使用期间内已保存的摘要，不自动补齐缺失草稿。最多对比最近 120 条记录，结论可展开核对；历史回顾保留原始版本。"))
                .font(.caption).foregroundStyle(.secondary)
            if input.start > input.end { Text(l("开始日期不能晚于结束日期。")).font(.caption).foregroundStyle(.orange) }
            if let error = store.reportError {
                HStack {
                    Text(l.message(error)).font(.caption).foregroundStyle(.orange)
                    if let result = store.reportResult, !reports.contains(where: { $0.id == result.id }) {
                        Button(l("重试保存（不调用模型）")) { store.retrySavingReport() }.disabled(store.isModelBusy)
                    }
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Text(l("历史回顾")).font(.headline)
                        ForEach(reports) { report in
                            Button {
                                selectedID = report.id; page = 0; kind = report.kind
                                start = store.clock.date(report.input.start); end = store.clock.date(report.input.end)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(l(report.kind.label)).font(.subheadline.bold())
                                    Text("\(report.input.start) — \(report.input.end)").font(.caption2)
                                    Text(JournalClock(timeZoneID: report.timeZoneID).label(report.createdAt, "MM-dd HH:mm"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selectedID == report.id ? JournalPalette.purple.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(width: 205)
                Divider()
                ScrollView {
                    if let selected { reportContent(selected) }
                    else { Text(l("生成一份回顾，或选择已保存的版本。浏览历史不会调用模型。")).foregroundStyle(.secondary).padding(30) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message { Text(l.message(message)).font(.caption).foregroundStyle(.secondary) }
            if let selected {
                HStack {
                    Button(l("复制 Markdown")) { JournalNavigation.copy(markdown(selected)); message = l("已复制，请检查私人内容后分享。") }
                    Button(l("保存 Markdown")) { saveMarkdown(selected) }
                    Spacer()
                    Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
                    Text(l("第 %d / %d 张", page + 1, JournalPeriodCard.pageCount(selected))).font(.caption)
                    Button { page += 1 } label: { Image(systemName: "chevron.right") }.disabled(page + 1 >= JournalPeriodCard.pageCount(selected))
                    Button(l("保存 PNG")) { savePNG(selected) }
                }
            }
            Text(l("回顾是模型草稿，不代表已核实的成果。分享前检查私人信息；不会自动上传。"))
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(24).frame(width: 1000, height: 690).tint(JournalPalette.purple)
            .environment(\.locale, store.settings.uiLanguage.locale)
            .onChange(of: store.reportResult?.id) { _, id in selectedID = id; page = 0 }
            .onDisappear { store.cancelReport() }
            .alert(l("允许生成期间回顾？"), isPresented: $showingConsent) {
                Button(l("取消"), role: .cancel) {}
                Button(l("允许")) { store.generateReport(kind: kind, start: start, end: end) }
            } message: {
                Text(l("将选定期间最多 120 条已保存摘要、标题和后续事项发送到 %@ CLI 的模型提供方，消耗 1 次本地调用额度。可能包含私人文字；不发送原始对话，不使用工具。", store.settings.summaryEngine.label))
            }
    }
    private func choosePeriod(_ value: JournalPeriodKind, anchor: Date) {
        guard value != .custom, let interval = store.clock.calendar.dateInterval(of: value == .week ? .weekOfYear : .month, for: anchor) else { return }
        start = interval.start; end = min(Date(), interval.end.addingTimeInterval(-1))
    }
    private func reportContent(_ report: JournalPeriodReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(l(report.kind.label)) · \(report.input.start) — \(report.input.end)").font(.headline)
            Text(report.model ?? (report.engine == "演示" ? l("演示模式") : report.engine)).font(.caption).foregroundStyle(.secondary)
            if !reports.contains(where: { $0.id == report.id }) { Text(l("本次回顾尚未保存，请重试保存。")).foregroundStyle(.orange) }
            Text(l("使用 %d / %d 条记录；%d 条缺少摘要", report.input.records.count, report.input.totalRecords, report.input.missingRecords))
                .font(.caption).foregroundStyle(.secondary)
            Text(report.response.overview).lineSpacing(4).textSelection(.enabled)
            ForEach(Array(sections(report).enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 12) {
                    Text(l(section.0)).font(.headline).foregroundStyle(JournalPalette.purple)
                    if section.1.isEmpty { Text(l("没有足够记录支持此项。")).font(.caption).foregroundStyle(.secondary) }
                    ForEach(section.1) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.text).textSelection(.enabled)
                            DisclosureGroup(l("进展依据")) {
                                ForEach(report.input.records.filter { item.evidenceIDs.contains($0.id) }) { record in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(record.day) · \(record.source.shortLabel) · \(record.title)").foregroundStyle(JournalPalette.source(record.source))
                                        Text(l(record.freshness == "current" ? "摘要最新" : "摘要已过期")).foregroundStyle(.secondary)
                                        if let status = record.userThreadStatus, let day = record.statusDay {
                                            Text("\(l("线程状态")) · \(l(status.label)) · \(day)").foregroundStyle(.secondary)
                                        }
                                        Text(record.summary)
                                        if !record.nextStep.isEmpty { Text(l("后续：%@", record.nextStep)) }
                                    }.font(.caption).padding(.vertical, 5)
                                }
                            }.font(.caption)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(JournalPalette.purple.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }.padding(.trailing, 10).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func sections(_ report: JournalPeriodReport) -> [(String, [JournalPeriodItem])] {
        [("已完成成果", report.response.completed), ("仍在推进", report.response.ongoing),
         ("明确阻塞", report.response.blockers), ("下一期间", report.response.nextSteps)]
    }
    private func markdown(_ report: JournalPeriodReport) -> String {
        var lines = ["# \(l(report.kind.label)) · \(report.input.start) — \(report.input.end)", "", report.response.overview, ""]
        for (title, items) in sections(report) {
            lines += ["## \(l(title))", ""]
            for item in items { lines += ["- \(item.text)", "  \(l("依据：")) \(item.evidenceIDs.joined(separator: ", "))"] }
            lines.append("")
        }
        lines += [l("使用 %d / %d 条记录；%d 条缺少摘要", report.input.records.count, report.input.totalRecords, report.input.missingRecords), "AgentJournal · \(report.model ?? report.engine)"]
        return lines.joined(separator: "\n")
    }
    private func saveMarkdown(_ report: JournalPeriodReport) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "AgentJournal-\(report.kind.rawValue)-\(report.input.end).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(markdown(report).utf8).write(to: url, options: .atomic); message = l("回顾已保存，请检查私人内容后分享。") }
        catch { message = error.localizedDescription }
    }
    private func savePNG(_ report: JournalPeriodReport) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "AgentJournal-\(report.kind.rawValue)-\(report.input.end)-\(page + 1).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JournalPeriodRenderer.png(report, page: page, language: store.settings.uiLanguage)
            try data.write(to: url, options: .atomic); message = l("回顾已保存，请检查私人内容后分享。")
        } catch { message = error.localizedDescription }
    }
}

struct JournalPeriodCard: View {
    let report: JournalPeriodReport
    let page: Int
    let language: JournalInterfaceLanguage
    private var l: JournalText { JournalText(language) }
    private static func rows(_ report: JournalPeriodReport) -> [(String, String)] {
        var result = JournalShareReport.parts(report.response.overview, limit: 600).map { ("期间综述", $0) }
        for (title, items) in [("已完成成果", report.response.completed), ("仍在推进", report.response.ongoing),
                                ("明确阻塞", report.response.blockers), ("下一期间", report.response.nextSteps)] {
            for item in items { result += JournalShareReport.parts(item.text, limit: 600).map { (title, $0) } }
        }
        return result
    }
    static func pageCount(_ report: JournalPeriodReport) -> Int { max(1, (rows(report).count + 3) / 4) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("AgentJournal · \(l(report.kind.label))").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(JournalPalette.purple)
            Text("\(report.input.start) — \(report.input.end)").font(.title3)
            ForEach(Array(Self.rows(report).dropFirst(page * 4).prefix(4).enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 10) {
                    Text(l(row.0)).font(.headline).foregroundStyle(JournalPalette.green)
                    Text(JournalShareReport.clean(row.1, language: language)).font(.system(size: 18)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(JournalPalette.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            }
            Text(l("使用 %d / %d 条记录；%d 条缺少摘要", report.input.records.count, report.input.totalRecords, report.input.missingRecords)).font(.caption)
            HStack { Text(l("模型草稿 · 分享前请核对")); Spacer(); Text("\(page + 1) / \(Self.pageCount(report))") }.font(.caption).foregroundStyle(.secondary)
        }.padding(36).frame(width: 720, alignment: .leading).background(.white).environment(\.colorScheme, .light)
    }
}

@MainActor
enum JournalPeriodRenderer {
    static func png(_ report: JournalPeriodReport, page: Int, language: JournalInterfaceLanguage) throws -> Data {
        guard (0..<JournalPeriodCard.pageCount(report)).contains(page) else { throw JournalError.message("图片页码无效。") }
        let renderer = ImageRenderer(content: JournalPeriodCard(report: report, page: page, language: language))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else {
            throw JournalError.message(JournalText(language)("图片生成失败，请重试。"))
        }
        return data
    }
}
