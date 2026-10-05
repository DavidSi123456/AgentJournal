// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentJournal",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentJournalKit", targets: ["AgentJournalKit"]),
        .executable(name: "AgentJournal", targets: ["AgentJournal"])
    ],
    targets: [
        .target(name: "AgentJournalKit", sources: [
            "JournalModels.swift", "JournalReader.swift", "JournalSummarizer.swift",
            "JournalStore.swift", "JournalView.swift", "JournalModelCatalog.swift", "JournalShare.swift", "JournalLanguage.swift",
            "JournalAgent.swift", "JournalAgentView.swift", "JournalNavigation.swift",
            "JournalDiagnostics.swift", "JournalDiagnosticsView.swift",
            "JournalWorkflow.swift", "JournalManagementView.swift", "JournalReports.swift", "JournalReportsView.swift", "JournalAppearance.swift", "JournalOnboarding.swift",
            "JournalThreadProgress.swift", "JournalThreadProgressView.swift"
        ]),
        .executableTarget(name: "AgentJournal", dependencies: ["AgentJournalKit"])
    ],
    swiftLanguageModes: [.v5]
)
