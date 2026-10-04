import Foundation

extension JournalTests {
    func testMissingCLIDiagnosticsStillAllowBrowsing() {
        var directories: [String] = []
        var tools: [JournalProvider] = []
        let probe = JournalEnvironmentProbe(directory: { directories.append($0); return .missing },
            executable: { tools.append($0); return nil })
        let checks = JournalDiagnostics.checks(settings: settings, probe: probe)
        XCTAssertEqual(checks.count, 6)
        XCTAssertEqual(Set(tools), Set(JournalProvider.allCases))
        XCTAssertEqual(directories, [settings.codexHome, settings.claudeHome])
        XCTAssertTrue(checks.filter { $0.id.hasPrefix("cli-") }.allSatisfy { $0.detail.contains("仍可浏览") })
        XCTAssertTrue(checks.last!.detail.contains("不发送模型请求"))
    }

    func testDiagnosticsDirectoryFailuresAndTranslation() {
        let probe = JournalEnvironmentProbe(directory: { $0 == self.settings.codexHome ? .unreadable : .notDirectory },
            executable: { _ in URL(fileURLWithPath: "/demo/cli") })
        let checks = JournalDiagnostics.checks(settings: settings, probe: probe)
        XCTAssertTrue(checks.first!.detail.contains("目录不可读取"))
        XCTAssertTrue(checks.first { $0.id == "history-claude" }!.detail.contains("文件而不是目录"))
        XCTAssertTrue(checks.filter { $0.id.hasPrefix("cli-") }.allSatisfy { $0.level == .information })
        let english = JournalText(.english)
        for check in checks {
            XCTAssertFalse(english(check.detail) == check.detail)
            XCTAssertFalse(english.message(check.title).contains("本地记录"))
        }
    }

    func testDiagnosticsArchivedOnlyAndNoCredentialPaths() {
        var directories: [String] = []
        let probe = JournalEnvironmentProbe(directory: { path in
            directories.append(path)
            return path.hasSuffix("/sessions") ? .missing : .readable
        }, executable: { _ in nil })
        let checks = JournalDiagnostics.checks(settings: settings, probe: probe)
        XCTAssertEqual(checks.first!.level, .available)
        XCTAssertTrue(directories.contains(settings.codexHome + "/archived_sessions"))
        XCTAssertFalse(directories.contains { $0.contains("auth.json") || $0.contains("journal.json") })
        XCTAssertTrue(checks.first { $0.id == "desktop" }!.detail.contains("未启用"))
    }

    func testDiagnosticsDemoNeverProbesPrivateEnvironment() {
        let probe = JournalEnvironmentProbe(directory: { _ in XCTFail("Demo probed a folder") },
            executable: { _ in XCTFail("Demo resolved a CLI") })
        let checks = JournalDiagnostics.checks(settings: settings, demo: true, probe: probe)
        XCTAssertEqual(checks.map(\.id), ["demo"])
    }

    func testLocalDiagnosticsMetadataAndInvalidPaths() throws {
        XCTAssertEqual(JournalEnvironmentProbe.local.directory("~/.codex"), .invalidPath)
        XCTAssertEqual(JournalEnvironmentProbe.local.directory(root.path), .readable)
        XCTAssertEqual(JournalEnvironmentProbe.local.directory(root.appendingPathComponent("missing").path), .missing)
        let file = root.appendingPathComponent("synthetic.txt")
        try Data("Synthetic, not a transcript".utf8).write(to: file)
        XCTAssertEqual(JournalEnvironmentProbe.local.directory(file.path), .notDirectory)
        XCTAssertEqual(try Data(contentsOf: file), Data("Synthetic, not a transcript".utf8))
    }

    func testCLIFailureMessagesWithoutAccountsOrModelCalls() async throws {
        // Stub processes only drain stdin and emit synthetic diagnostics. They never
        // inspect accounts, credentials, source history or the network.
        let cases = [("not logged in", "登录已失效", "login expired"),
                     ("unknown option", "不支持摘要所需参数", "does not support the required options"),
                     ("rate_limit", "额度暂时不足", "usage is temporarily exhausted"),
                     ("authentication failed", "认证失败", "authentication failed"),
                     ("synthetic offline network", "登录和网络", "login and network")]
        let original = sample()
        for (diagnostic, chinese, english) in cases {
            let executable = root.appendingPathComponent("synthetic-cli.sh")
            let script = """
            #!/bin/sh
            /bin/cat > /dev/null
            printf '%s\\n' '\(diagnostic)'
            exit 1
            """
            try Data(script.utf8).write(to: executable)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            for language in JournalInterfaceLanguage.allCases {
                settings.uiLanguage = language
                do {
                    _ = try await JournalCLISummarizer(executableOverride: executable).summarize([original], settings: settings)
                    XCTFail("Stub CLI failure should not return a draft")
                } catch {
                    // Match the same diagnostic translation used by the UI. Some
                    // classified errors retain their stable Chinese storage keys;
                    // the provider-formatted fallback is already localized.
                    let displayed = JournalText(language).message(error.localizedDescription)
                    let expected = language == .chinese ? chinese : english
                    guard displayed.contains(expected) else {
                        XCTFail("Wrong CLI diagnostic for \(language.rawValue): \(diagnostic)")
                    }
                    if language == .english { XCTAssertFalse(displayed.contains(chinese)) }
                }
            }
        }
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("journal.json").path))
    }
}
