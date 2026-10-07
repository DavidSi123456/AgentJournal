// swift-tools-version: 6.0
import PackageDescription

// The normal macOS build remains dependency-free. The portable target selects
// the same parser/model sources, without compiling SwiftUI, AppKit or Combine.
#if os(Windows)
let portable = true
#else
let portable = false
#endif
let desktopPrototype = portable
let coreSources = [
    "JournalModels.swift", "JournalReader.swift", "JournalLanguage.swift",
    "JournalSummarizer.swift", "JournalNavigation.swift", "JournalWorkflow.swift",
    "JournalAgent.swift", "JournalReports.swift", "JournalThreadProgress.swift",
    "JournalPlatform.swift", "JournalPortableHash.swift", "JournalWindowsCLI.swift", "PortableJournal.swift"
]
let macOnlySources = [
    "JournalStore.swift", "JournalView.swift", "JournalModelCatalog.swift", "JournalShare.swift",
    "JournalAgentView.swift", "JournalDiagnostics.swift", "JournalDiagnosticsView.swift",
    "JournalManagementView.swift", "JournalReportsView.swift", "JournalAppearance.swift",
    "JournalOnboarding.swift", "JournalThreadProgressView.swift"
]
let package: Package
if portable {
    var products: [Product] = [
        .library(name: "AgentJournalCore", targets: ["AgentJournalCore"]),
        .executable(name: "AgentJournalPortableCLI", targets: ["AgentJournalPortableCLI"]),
        .executable(name: "AgentJournalPortableChecks", targets: ["AgentJournalPortableChecks"])
    ]
    var dependencies: [Package.Dependency] = []
    var targets: [Target] = [
        .target(name: "AgentJournalCore", path: "Sources/AgentJournalKit", exclude: macOnlySources, sources: coreSources,
                swiftSettings: [.define("AGENTJOURNAL_PORTABLE_HASH")],
                linkerSettings: [.linkedLibrary("kernel32", .when(platforms: [.windows]))]),
        .executableTarget(name: "AgentJournalPortableCLI", dependencies: ["AgentJournalCore"]),
        .executableTarget(name: "AgentJournalPortableChecks", dependencies: ["AgentJournalCore"],
                          path: "Tests/AgentJournalPortableTests")
    ]
    if desktopPrototype {
        dependencies.append(.package(url: "https://github.com/moreSwift/swift-cross-ui", exact: "0.10.0"))
        products.append(.executable(name: "AgentJournalWindows", targets: ["AgentJournalWindows"]))
        targets.append(.executableTarget(name: "AgentJournalWindows", dependencies: [
            "AgentJournalCore", .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
            .product(name: "DefaultBackend", package: "swift-cross-ui")
        ]))
    }
    package = Package(name: "AgentJournal", platforms: [.macOS(.v14)], products: products,
                      dependencies: dependencies, targets: targets, swiftLanguageModes: [.v5])
} else {
package = Package(
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
            "JournalThreadProgress.swift", "JournalThreadProgressView.swift",
            "JournalPlatform.swift", "JournalPortableHash.swift", "JournalWindowsCLI.swift", "PortableJournal.swift"
        ]),
        .executableTarget(name: "AgentJournal", dependencies: ["AgentJournalKit"])
    ],
    swiftLanguageModes: [.v5]
)
}
