import Foundation
import AppKit

/// No resume/import calls: returning to a desktop session must keep its identity.
enum JournalNavigation {
    static func validDesktopID(_ id: String) -> Bool {
        id.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil
    }
    static func url(for activity: JournalActivity) -> URL? {
        guard UUID(uuidString: activity.threadID) != nil else { return nil }
        if activity.source == .codex { return URL(string: "codex://threads/\(activity.threadID)") }
        guard let id = activity.desktopSessionID, validDesktopID(id), activity.desktopSessionArchived != true else { return nil }
        var parts = URLComponents()
        parts.scheme = "claude"; parts.host = "code"; parts.path = "/continue"
        parts.queryItems = [URLQueryItem(name: "session", value: id)]
        return parts.url
    }
    static func resumeCommand(for activity: JournalActivity) -> String? {
        guard UUID(uuidString: activity.threadID) != nil else { return nil }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let resume = "\(activity.source == .codex ? "codex resume" : "claude --resume") \(quote(activity.threadID))"
        return activity.cwd.isEmpty ? resume : "cd \(quote(activity.cwd)) && \(resume)"
    }
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @MainActor
    static func open(_ activity: JournalActivity, language: JournalInterfaceLanguage) -> String? {
        let l = JournalText(language)
        if activity.source == .codex {
            guard let url = url(for: activity) else { return l("此记录没有有效的原线程 ID。") }
            guard NSWorkspace.shared.open(url) else { return l("无法打开客户端，请检查是否已安装。") }
            return nil
        }
        guard UUID(uuidString: activity.threadID) != nil else { return l("此记录没有有效的原线程 ID。") }
        if let url = url(for: activity), NSWorkspace.shared.open(url) {
            // URL acceptance is not proof of in-app navigation; the route is version/feature gated.
            return l("已请求定位 Claude Code 原线程。此功能为实验性；若没有定位，请在 Claude Code 中搜索线程标题。不会导入新会话。")
        }
        copy(activity.title)
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else {
            return l("无法打开客户端，请检查是否已安装。")
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        return l("未找到可定位的桌面会话，已打开 Claude 并复制线程标题；请在 Code 中搜索。终端继续命令可在菜单中复制，不会自动执行。")
    }
}

enum JournalDesktopSessions {
    struct Session: Decodable {
        let sessionId: String
        let cliSessionId: String
        let title: String?
        let isArchived: Bool?
        let lastActivityAt: Double?
    }
    struct Snapshot { var sessions: [String: Session] = [:]; var incomplete = false }
    static func load(_ root: URL?) -> Snapshot {
        var result = Snapshot()
        guard let root, FileManager.default.fileExists(atPath: root.path) else { return result }
        let resolvedRoot = root.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: resolvedRoot, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles], errorHandler: { _, _ in result.incomplete = true; return true }) else {
            result.incomplete = true; return result
        }
        var count = 0
        for case let file as URL in enumerator {
            count += 1
            if count > 4000 { result.incomplete = true; break }
            // Foundation may canonicalize /var to /private/var only on enumerated URLs.
            // Enumerator level measures actual nesting without that path-alias mismatch.
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            guard let values = try? file.resourceValues(forKeys: keys), values.isSymbolicLink != true else {
                enumerator.skipDescendants(); continue
            }
            guard values.isRegularFile == true, file.pathExtension == "json",
                  file.lastPathComponent.hasPrefix("local_") else { continue }
            guard (values.fileSize ?? 0) <= 1024 * 1024,
                  let data = try? Data(contentsOf: file),
                  let session = try? JSONDecoder().decode(Session.self, from: data),
                  JournalNavigation.validDesktopID(session.sessionId),
                  file.deletingPathExtension().lastPathComponent == session.sessionId,
                  let uuid = UUID(uuidString: session.cliSessionId) else { result.incomplete = true; continue }
            let key = uuid.uuidString.lowercased()
            if let old = result.sessions[key] {
                // Deterministic tie-breaking; prefer the non-archived native session.
                let oldRank = old.isArchived == true ? 0 : 1
                let newRank = session.isArchived == true ? 0 : 1
                if newRank < oldRank { continue }
                if newRank == oldRank && (session.lastActivityAt ?? 0) < (old.lastActivityAt ?? 0) { continue }
                if newRank == oldRank && session.lastActivityAt == old.lastActivityAt && session.sessionId > old.sessionId { continue }
            }
            result.sessions[key] = session
        }
        return result
    }
}
