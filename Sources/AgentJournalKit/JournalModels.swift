import Foundation
import CryptoKit

enum JournalProvider: String, Codable, CaseIterable, Identifiable {
    case codex, claude
    var id: String { rawValue }
    var label: String { self == .codex ? "Codex" : "Claude Code" }
    var shortLabel: String { self == .codex ? "Codex" : "CC" }
}

struct JournalClock: Equatable {
    var timeZoneID: String = TimeZone.current.identifier
    var calendar: Calendar { Self.cache.calendar(timeZoneID) }
    func key(_ date: Date) -> String { label(date, "yyyy-MM-dd") }
    func date(_ key: String) -> Date {
        Self.cache.formatter(timeZoneID, "yyyy-MM-dd", locale: nil).date(from: key) ?? calendar.startOfDay(for: Date())
    }
    func label(_ date: Date, _ format: String, locale: Locale? = nil) -> String {
        Self.cache.formatter(timeZoneID, format, locale: locale).string(from: date)
    }
    /// The stored "yyyy-MM-dd" shape, without compiling a regular expression per record.
    static func isDayKey(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10 else { return false }
        return bytes.enumerated().allSatisfy { index, byte in index == 4 || index == 7 ? byte == 45 : (48...57).contains(byte) }
    }
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // Day keys are computed for every record on every refresh and render. Calendars and
    // formatters are expensive to create but thread-safe to share once configured.
    private static let cache = Cache()
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var calendars: [String: Calendar] = [:]
        private var formatters: [String: DateFormatter] = [:]
        func calendar(_ timeZoneID: String) -> Calendar {
            lock.lock(); defer { lock.unlock() }
            if let value = calendars[timeZoneID] { return value }
            var value = Calendar(identifier: .gregorian)
            value.timeZone = TimeZone(identifier: timeZoneID) ?? .current
            value.locale = Locale(identifier: "zh_CN")
            value.firstWeekday = 2
            calendars[timeZoneID] = value
            return value
        }
        func formatter(_ timeZoneID: String, _ format: String, locale: Locale?) -> DateFormatter {
            let calendar = calendar(timeZoneID)
            let key = "\(timeZoneID)|\(format)|\(locale?.identifier ?? "")"
            lock.lock(); defer { lock.unlock() }
            if let value = formatters[key] { return value }
            let value = DateFormatter()
            value.locale = locale ?? calendar.locale
            value.calendar = calendar
            value.timeZone = calendar.timeZone
            value.dateFormat = format
            formatters[key] = value
            return value
        }
    }
}

struct JournalExcerpt: Codable, Hashable {
    var timestamp: Date
    var role: String
    var text: String
}

struct JournalActivity: Codable, Identifiable {
    // Optional additions keep the original PlanDesk v1 index readable.
    var provider: JournalProvider? = nil
    var threadID: String
    var day: String
    var title: String
    var cwd: String
    var firstActivity: Date
    var lastActivity: Date
    var sourceModel: String? = nil
    var desktopSessionID: String? = nil
    var desktopSessionArchived: Bool? = nil
    var messageIDs: Set<String> = []
    var excerpts: [JournalExcerpt] = []
    var source: JournalProvider { provider ?? .codex }
    // Preserve Codex keys so existing edited/confirmed drafts survive the upgrade.
    var threadKey: String { source == .codex ? threadID : "claude:\(threadID)" }
    var id: String { "\(threadKey)|\(day)" }
    var fingerprint: String { JournalClock.hash(messageIDs.sorted().joined(separator: ":")) }
    var messageCount: Int { messageIDs.count }

    mutating func append(_ excerpt: JournalExcerpt, messageID: String? = nil) {
        let identity = messageID ?? JournalClock.hash("\(excerpt.timestamp.timeIntervalSince1970)|\(excerpt.role)|\(excerpt.text)")
        guard messageIDs.insert(identity).inserted else { return }
        firstActivity = min(firstActivity, excerpt.timestamp)
        lastActivity = max(lastActivity, excerpt.timestamp)
        excerpts.append(excerpt)
        // Retain bounded initial questions and recent outcomes, never full transcripts.
        if excerpts.count > 32 { excerpts.remove(at: 8) }
    }

    mutating func merge(_ other: JournalActivity) {
        messageIDs.formUnion(other.messageIDs)
        firstActivity = min(firstActivity, other.firstActivity)
        lastActivity = max(lastActivity, other.lastActivity)
        let samples = Set(excerpts + other.excerpts).sorted { $0.timestamp < $1.timestamp }
        excerpts = samples.count > 32 ? Array(samples.prefix(8)) + Array(samples.suffix(24)) : samples
        if other.lastActivity >= lastActivity { sourceModel = other.sourceModel ?? sourceModel }
    }
}

struct JournalDraft: Codable, Equatable {
    var summary: String = ""
    var nextStep: String = ""
    var status: String = "待整理"
    var category: String = "未分类"
    var fingerprint: String = ""
    var generatedAt: Date?
    var editedSummary: String?
    var editedNextStep: String?
    var confirmedAt: Date?
    var confirmedFingerprint: String?
    var summaryEngine: String?
    var summaryModel: String?
    var displaySummary: String { editedSummary ?? summary }
    var displayNextStep: String { editedNextStep ?? nextStep }
    var isConfirmed: Bool { confirmedAt != nil }
    var modelLabel: String {
        if let summaryModel, !summaryModel.isEmpty { return summaryModel }
        return summaryEngine.map { "\($0) · 模型未报告" } ?? "旧草稿 · 模型未记录"
    }
}

struct JournalSummaryRow: Codable {
    var id: String
    var summary: String
    var nextStep: String
    var status: String
    var category: String
}

struct JournalSummaryResponse: Codable { var entries: [JournalSummaryRow] }
struct JournalSummaryBatch {
    var entries: [JournalSummaryRow]
    var engine: String
    var model: String?
}
struct JournalSnapshot { var activities: [JournalActivity]; var warnings: [String] }

enum JournalSourceSelection: String, Codable, CaseIterable, Identifiable {
    case both, codex, claude
    var id: String { rawValue }
    var label: String { self == .both ? "两者都有" : self == .codex ? "仅 Codex" : "仅 Claude Code" }
    func includes(_ provider: JournalProvider) -> Bool {
        self == .both || (self == .codex && provider == .codex) || (self == .claude && provider == .claude)
    }
}

struct JournalSettings: Codable, Equatable {
    var codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    var claudeHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
    var claudeDesktopSessionsHome: String?
    var desktopSessionsURL: URL? {
        if let path = claudeDesktopSessionsHome {
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        }
        // Custom transcript roots must not silently scan another account's desktop data.
        guard claudeHome == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Claude/claude-code-sessions")
    }
    var timeZoneID = TimeZone.current.identifier
    var summaryEngine: JournalProvider = .codex
    var model = ""
    var codexModelChoice: String?
    var claudeModelChoice: String?
    var excludedProjects = ""
    func includesProject(_ cwd: String) -> Bool {
        let exclusions = excludedProjects.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return !exclusions.contains { cwd.localizedCaseInsensitiveContains($0) }
    }
    var language = "简体中文"
    // Optional fields keep existing v1/v2 journals and chosen summary languages readable.
    var interfaceLanguageCode: String?
    var languageSetupComplete: Bool?
    var onboardingVersion: Int?
    var sourceSelectionCode: String?
    var sourceSelection: JournalSourceSelection {
        get { sourceSelectionCode.flatMap(JournalSourceSelection.init(rawValue:)) ?? .both }
        set { sourceSelectionCode = newValue.rawValue }
    }
    func includesProvider(_ provider: JournalProvider) -> Bool { sourceSelection.includes(provider) }
    var advisorEngine: JournalProvider?
    var advisorModel: String?
    var adviceSettings: JournalSettings {
        var copy = self
        copy.summaryEngine = advisorEngine ?? summaryEngine
        copy.model = advisorModel ?? model
        return copy
    }
    var uiLanguage: JournalInterfaceLanguage {
        get { interfaceLanguageCode.flatMap(JournalInterfaceLanguage.init(rawValue:)) ?? .systemDefault }
        set { interfaceLanguageCode = newValue.rawValue }
    }
    var summaryLanguage: JournalSummaryLanguage {
        get {
            if language == "English" || language == "en" { return .english }
            if language == "auto" { return .automatic }
            return .chinese
        }
        set { language = newValue == .chinese ? "简体中文" : newValue == .english ? "English" : "auto" }
    }

    mutating func selectEngine(_ engine: JournalProvider) {
        guard engine != summaryEngine else { return }
        rememberModel()
        summaryEngine = engine
        model = (engine == .codex ? codexModelChoice : claudeModelChoice) ?? ""
    }
    mutating func selectModel(_ value: String) {
        model = value.trimmingCharacters(in: .whitespacesAndNewlines)
        rememberModel()
    }
    mutating func rememberModel() {
        if summaryEngine == .codex { codexModelChoice = model }
        else { claudeModelChoice = model }
    }
}

enum JournalError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
