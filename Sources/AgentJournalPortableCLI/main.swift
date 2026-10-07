import Foundation
import AgentJournalCore

@main
struct PortableCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.isEmpty || arguments == ["--demo"] {
                let data = try JSONEncoder().encode(PortableJournal.demoEntries())
                print(String(decoding: data, as: UTF8.self))
                return
            }
            guard arguments.count == 4, arguments[0] == "--scan", arguments[2] == "--storage" else {
                print("Usage: AgentJournalPortableCLI --demo | --scan <transcript-fixture-root> --storage <separate-output-folder>")
                exit(1)
            }
            let journal = try PortableJournal(directory: URL(fileURLWithPath: arguments[3]))
            var configuration = await journal.configuration()
            configuration.codexHome = URL(fileURLWithPath: arguments[1]).appendingPathComponent("codex").path
            configuration.claudeHome = URL(fileURLWithPath: arguments[1]).appendingPathComponent("claude").path
            try await journal.saveConfiguration(configuration)
            let snapshot = try await journal.refresh()
            print(String(decoding: try JSONEncoder().encode(snapshot.entries), as: UTF8.self))
            for warning in snapshot.warnings { print("Warning: " + warning) }
        } catch {
            // CLI diagnostics can contain local paths. Do not use real user data in CI.
            print("AgentJournal prototype error: \(error.localizedDescription)")
            exit(1)
        }
    }
}
