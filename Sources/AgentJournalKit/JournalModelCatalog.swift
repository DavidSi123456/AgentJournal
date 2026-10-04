import Foundation
import Combine
import Darwin

struct JournalModelChoice: Identifiable, Equatable {
    var id: String
    var title: String
}

@MainActor
final class JournalModelCatalog: ObservableObject {
    @Published private(set) var codex: [JournalModelChoice] = []
    @Published private(set) var note = ""
    @Published private(set) var isRefreshing = false

    init(settings: JournalSettings) { loadCache(settings) }

    func choices(for provider: JournalProvider, selected: String = "") -> [JournalModelChoice] {
        var values = provider == .codex ? codex : [
            JournalModelChoice(id: "sonnet", title: "Sonnet"),
            JournalModelChoice(id: "opus", title: "Opus"),
            JournalModelChoice(id: "haiku", title: "Haiku")
        ]
        if !selected.isEmpty && !values.contains(where: { $0.id == selected }) {
            values.append(JournalModelChoice(id: selected, title: "\(selected) · 已保存"))
        }
        return values
    }

    func title(provider: JournalProvider, model: String) -> String {
        if model.isEmpty { return "跟随 CLI 默认" }
        return choices(for: provider).first(where: { $0.id == model })?.title ?? model
    }

    func loadCache(_ settings: JournalSettings) {
        let file = URL(fileURLWithPath: settings.codexHome).appendingPathComponent("models_cache.json")
        codex = (try? Data(contentsOf: file)).map(Self.parseCache) ?? []
        note = codex.isEmpty ? "没有本地目录，请刷新 Codex 列表或输入自定义模型。" : "来自 Codex 本地模型目录；可刷新列表。"
    }

    func refresh(_ settings: JournalSettings) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let choices = try await Task.detached { try Self.requestCodexModels(settings) }.value
            guard !choices.isEmpty else { throw JournalError.message("empty catalog") }
            codex = choices
            note = "已通过 Codex model/list 更新；实际访问权限由 CLI 账号决定。"
        } catch {
            note = "未能刷新，仍可使用本地列表、CLI 默认或自定义模型。请检查 CLI 版本和登录。"
        }
    }

    nonisolated static func parseCache(_ data: Data) -> [JournalModelChoice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["models"] as? [[String: Any]] else { return [] }
        return unique(rows.compactMap { row in
            guard row["visibility"] as? String == "list", let id = row["slug"] as? String,
                  !id.isEmpty else { return nil }
            return JournalModelChoice(id: id, title: row["display_name"] as? String ?? id)
        })
    }

    nonisolated static func parseRPC(_ root: [String: Any]) -> [JournalModelChoice] {
        guard let result = root["result"] as? [String: Any], let rows = result["data"] as? [[String: Any]] else { return [] }
        return unique(rows.compactMap { row in
            guard row["hidden"] as? Bool != true,
                  let id = (row["model"] ?? row["id"]) as? String, !id.isEmpty else { return nil }
            return JournalModelChoice(id: id, title: row["displayName"] as? String ?? id)
        })
    }

    nonisolated private static func unique(_ values: [JournalModelChoice]) -> [JournalModelChoice] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }

    nonisolated static func requestCodexModels(_ settings: JournalSettings) throws -> [JournalModelChoice] {
        guard let executable = JournalCLISummarizer.executable(for: .codex) else { throw JournalError.message("CLI not installed") }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("agentjournal-models-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let process = Process(), input = Pipe(), output = Pipe()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = executable
        process.arguments = ["--disable", "plugins", "--disable", "hooks", "--disable", "multi_agent",
                             "-c", "analytics.enabled=false", "-c", "mcp_servers={}", "app-server", "--stdio"]
        process.currentDirectoryURL = directory
        process.environment = JournalCLISummarizer.environment(settings: settings, inherited: ProcessInfo.processInfo.environment,
                                                              home: manager.homeDirectoryForCurrentUser)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let control = JournalProcessControl()
        try control.start(process)
        let timeout = DispatchWorkItem { control.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer {
            timeout.cancel(); control.cancel()
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        }
        func send(_ request: [String: Any]) throws {
            guard process.isRunning else { throw JournalError.message("model service stopped") }
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "agentjournal", "version": "0.3.1"]]])
        var pending = Data(), totalBytes = 0
        // availableData returns the current pipe chunk. read(upToCount:) can wait
        // to fill its buffer, deadlocking a request/response stdio handshake.
        while true {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            totalBytes += chunk.count
            guard totalBytes < 4 * 1024 * 1024 else { throw JournalError.message("catalog too large") }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending.subdata(in: 0..<newline)
                pending.removeSubrange(0...newline)
                guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if root["id"] as? Int == 1 {
                    guard root["error"] == nil else { throw JournalError.message("initialize failed") }
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "model/list", "params": ["limit": 100, "includeHidden": false]])
                } else if root["id"] as? Int == 2 { return parseRPC(root) }
            }
        }
        throw JournalError.message("model/list failed")
    }
}
