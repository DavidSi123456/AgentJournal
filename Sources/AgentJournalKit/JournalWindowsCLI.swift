import Foundation

/// Never pass a transcript, model identifier or user-selected path through
/// cmd.exe/PowerShell. npm wrappers are bypassed via a known Node entry point.
enum JournalWindowsCLI {
    struct Launch { var executable: URL; var arguments: [String] = [] }
    static func environmentValue(_ name: String, in environment: [String: String]) -> String? {
        environment.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    static func candidates(name: String, home: URL, environment: [String: String]) -> [URL] {
        var folders = [home.appendingPathComponent(".local/bin")]
        if let appData = environmentValue("APPDATA", in: environment) {
            folders.append(URL(fileURLWithPath: appData).appendingPathComponent("npm"))
        }
        folders += (environmentValue("PATH", in: environment) ?? "").split(separator: ";")
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            .filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        return folders.map { $0.appendingPathComponent(name + ".exe") }
    }
    static func nativeExecutable(engine: JournalProvider) -> URL? {
        candidates(name: engine == .codex ? "codex" : "claude",
                   home: FileManager.default.homeDirectoryForCurrentUser,
                   environment: ProcessInfo.processInfo.environment).first { isFile($0) }
    }
    static func isFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    static func resolve(engine: JournalProvider, override: URL? = nil,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Launch {
        if let override {
            guard override.pathExtension.lowercased() == "exe", isFile(override) else {
                throw JournalError.message("Windows 摘要引擎必须是现有的 .exe 文件；不执行 .cmd、.bat 或 PowerShell 脚本。")
            }
            return Launch(executable: override)
        }
        if let exe = candidates(name: engine == .codex ? "codex" : "claude", home: home, environment: environment).first(where: isFile) {
            return Launch(executable: exe)
        }
        guard let appData = environmentValue("APPDATA", in: environment),
              let node = candidates(name: "node", home: home, environment: environment).first(where: isFile) else {
            throw JournalError.message("未找到 Windows CLI；请在设置中选择原生 .exe，或安装 Node.js 与 npm 版 CLI。")
        }
        let package = engine == .codex ? "@openai/codex/bin/codex.js" : "@anthropic-ai/claude-code/cli.js"
        let script = URL(fileURLWithPath: appData).appendingPathComponent("npm/node_modules/" + package)
        guard isFile(script) else { throw JournalError.message("未找到标准 npm CLI 入口；请指定原生 .exe。WSL 模型调用暂不支持。") }
        return Launch(executable: node, arguments: [script.path])
    }
}
