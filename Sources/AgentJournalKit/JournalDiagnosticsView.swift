import SwiftUI

struct JournalDiagnosticsView: View {
    let settings: JournalSettings
    let demo: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var checks: [JournalEnvironmentCheck] = []
    private var l: JournalText { JournalText(settings.uiLanguage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(l("环境检查"), systemImage: "checklist").font(.title2.weight(.semibold))
                Spacer()
                Button(l("重新检查")) { refresh() }
            }
            Text(l("不启动 CLI、不读取聊天或密钥、不联网；结果只在此窗口显示，不导出个人路径。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(checks) { check in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon(check.level)).foregroundStyle(color(check.level)).frame(width: 20)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(l.message(check.title)).font(.subheadline.weight(.semibold))
                                Text(l(check.detail)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(JournalPalette.purple.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            Text(l("兼容性说明：仅本地 Codex / CC 记录；Claude Desktop 原线程跳转仍是实验性功能。缺少 CLI 不影响浏览，生成内容需另行授权并消耗模型额度。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(l("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 600, height: 600).tint(JournalPalette.purple)
            .task { refresh() }
    }
    private func refresh() { checks = JournalDiagnostics.checks(settings: settings, demo: demo) }
    private func icon(_ level: JournalEnvironmentCheck.Level) -> String {
        switch level {
        case .available: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .information: return "info.circle.fill"
        }
    }
    private func color(_ level: JournalEnvironmentCheck.Level) -> Color {
        level == .attention ? .orange : JournalPalette.purple
    }
}
