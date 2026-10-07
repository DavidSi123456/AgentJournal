import SwiftUI
import AgentJournalKit

@main
struct AgentJournalApp: App {
    @StateObject private var store = JournalStore(demo: CommandLine.arguments.contains("--demo")
        || Bundle.main.object(forInfoDictionaryKey: "AgentJournalDemoOnly") as? Bool == true,
        demoLanguage: CommandLine.arguments.contains("--demo-en") ? "en"
            : Bundle.main.object(forInfoDictionaryKey: "AgentJournalDemoLanguage") as? String,
        demoLanguageSetup: CommandLine.arguments.contains("--demo-setup"))
    var body: some Scene {
        WindowGroup("AgentJournal") {
            JournalView(store: store).frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1420, height: 900)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(store.settingsMenuTitle) { store.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(store.waitingForLanguageSelection)
            }
        }
    }
}
