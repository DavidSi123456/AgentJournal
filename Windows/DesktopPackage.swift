// swift-tools-version: 6.0
import PackageDescription
// Separate manifest/cache identity from the dependency-free core checks.
let package = Package(
    name: "AgentJournalWindowsPreview",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentJournalWindows", targets: ["AgentJournalWindows"])],
    dependencies: [.package(url: "https://github.com/moreSwift/swift-cross-ui", exact: "0.10.0")],
    targets: [
        .target(name: "AgentJournalCore", swiftSettings: [.define("AGENTJOURNAL_PORTABLE_HASH")],
                linkerSettings: [.linkedLibrary("kernel32", .when(platforms: [.windows]))]),
        .executableTarget(name: "AgentJournalWindows", dependencies: [
            "AgentJournalCore", .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
            .product(name: "DefaultBackend", package: "swift-cross-ui")
        ])
    ],
    swiftLanguageModes: [.v5]
)
