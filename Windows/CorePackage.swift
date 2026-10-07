// swift-tools-version: 6.0
import PackageDescription
// Build-only staging manifest. Sources are copied from their canonical files;
// no forked copy of the parser is maintained in the repository.
let package = Package(
    name: "AgentJournalPortableCore",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentJournalPortableChecks", targets: ["AgentJournalPortableChecks"]),
        .executable(name: "AgentJournalPortableCLI", targets: ["AgentJournalPortableCLI"])
    ],
    targets: [
        .target(name: "AgentJournalCore", swiftSettings: [.define("AGENTJOURNAL_PORTABLE_HASH")],
                linkerSettings: [.linkedLibrary("kernel32", .when(platforms: [.windows]))]),
        .executableTarget(name: "AgentJournalPortableChecks", dependencies: ["AgentJournalCore"]),
        .executableTarget(name: "AgentJournalPortableCLI", dependencies: ["AgentJournalCore"])
    ],
    swiftLanguageModes: [.v5]
)
