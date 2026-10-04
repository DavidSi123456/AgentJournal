import Foundation
import Darwin

enum JournalDirectoryState: Equatable {
    case readable, missing, notDirectory, unreadable, invalidPath
}

struct JournalEnvironmentProbe {
    var directory: (String) -> JournalDirectoryState
    var executable: (JournalProvider) -> URL?

    static let local = Self(directory: { path in
        guard path.hasPrefix("/") else { return .invalidPath }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .notDirectory }
        return access(path, R_OK | X_OK) == 0 ? .readable : .unreadable
    }, executable: { JournalCLISummarizer.executable(for: $0) })
}

struct JournalEnvironmentCheck: Identifiable {
    enum Level { case available, attention, information }
    var id: String
    var title: String
    var detail: String
    var level: Level
}

/// Local metadata only: no process launches, transcript reads, credentials or network.
enum JournalDiagnostics {
    static func checks(settings: JournalSettings, demo: Bool = false,
                       probe: JournalEnvironmentProbe = .local) -> [JournalEnvironmentCheck] {
        guard !demo else {
            return [.init(id: "demo", title: "演示模式", detail: "演示不检查真实环境，也不读取私人目录或调用模型。", level: .information)]
        }
        var result: [JournalEnvironmentCheck] = []
        for source in JournalProvider.allCases {
            let root = source == .codex ? settings.codexHome : settings.claudeHome
            let rootState = probe.directory(root)
            let children = source == .codex ? ["sessions", "archived_sessions"] : ["projects"]
            let states = rootState == .readable ? children.map {
                probe.directory(URL(fileURLWithPath: root).appendingPathComponent($0).path)
            } : [rootState]
            let state = states.contains(.readable) ? JournalDirectoryState.readable
                : states.first(where: { $0 != .missing }) ?? .missing
            result.append(directoryCheck(id: "history-\(source.rawValue)", title: "\(source.label) · 本地记录", state: state))
            let found = probe.executable(source) != nil
            result.append(.init(id: "cli-\(source.rawValue)", title: "\(source.label) CLI",
                detail: found ? "已找到可执行程序；尚未验证版本、登录或模型权限。"
                    : "未找到 CLI；仍可浏览本地记录。需要模型功能时，请在终端安装并登录，或切换摘要引擎。",
                level: found ? .information : .attention))
        }
        if let desktop = settings.desktopSessionsURL {
            result.append(directoryCheck(id: "desktop", title: "Claude Desktop · 会话映射", state: probe.directory(desktop.path)))
        } else {
            result.append(.init(id: "desktop", title: "Claude Desktop · 会话映射",
                detail: "未启用桌面映射；自定义 CC 主目录不会自动读取默认桌面数据。可在设置中指定会话目录。", level: .information))
        }
        result.append(.init(id: "authentication", title: "登录、网络与额度",
            detail: "这里只检查本地目录和 CLI 是否存在，不读取密钥，不验证账号，不发送模型请求。登录与额度请在对应 CLI 中自行确认。", level: .information))
        return result
    }

    private static func directoryCheck(id: String, title: String, state: JournalDirectoryState) -> JournalEnvironmentCheck {
        let detail: String
        switch state {
        case .readable: detail = "目录可访问；未检查日志内容，空目录也会显示为可访问。"
        case .missing: detail = "未发现目录；没有使用过该工具时这是正常的。请检查主目录设置，之后再刷新本地记录。"
        case .notDirectory: detail = "这里是文件而不是目录；请填写主目录，不要选择单个日志文件。"
        case .unreadable: detail = "目录不可读取；请检查所选目录的权限和系统隐私设置，不需要关闭 Gatekeeper。"
        case .invalidPath: detail = "请填写以 / 开头的绝对目录路径；不要使用 ~ 或 sessions/projects 子目录。"
        }
        return .init(id: id, title: title, detail: detail, level: state == .readable ? .available : .attention)
    }
}
