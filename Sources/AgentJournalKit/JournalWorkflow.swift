import Foundation

enum JournalThreadStatus: String, Codable, CaseIterable {
    case active, waiting, paused, completed
    var label: String {
        switch self { case .active: return "进行中"; case .waiting: return "等待中"
        case .paused: return "暂时搁置"; case .completed: return "线程已完成" }
    }
}
struct JournalThreadState: Codable {
    var status: JournalThreadStatus
    var updatedAt: Date = Date()
}
enum JournalFeedbackStatus: String, Codable, CaseIterable {
    case pending, handled, waiting, dismissed
    var label: String {
        switch self { case .pending: return "尚未处理"; case .handled: return "已处理"
        case .waiting: return "等待中"; case .dismissed: return "不采纳" }
    }
}
struct JournalAdviceFeedback: Codable, Identifiable {
    var id = UUID()
    var resultID: UUID
    var threadKey: String
    var progressFingerprint: String
    var status: JournalFeedbackStatus
    var createdAt = Date()
}
enum JournalCallKind: String, Codable {
    case summary, automatic, advice, report, taskTree
    var label: String {
        switch self { case .summary: return "手动摘要"; case .automatic: return "自动草稿"
        case .advice: return "推进分析"; case .report: return "周报／月报"; case .taskTree: return "任务树草拟" }
    }
}
enum JournalCallOutcome: String, Codable {
    case started, succeeded, failed, cancelled
    var label: String {
        switch self { case .started: return "已开始"; case .succeeded: return "成功"
        case .failed: return "失败"; case .cancelled: return "已取消" }
    }
}
struct JournalCallRecord: Codable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var kind: JournalCallKind
    var engine: JournalProvider
    var model: String
    var itemCount: Int
    var outcome: JournalCallOutcome = .started
}
struct JournalWorkflowState: Codable {
    var version = 1
    var threads: [String: JournalThreadState] = [:]
    var feedback: [JournalAdviceFeedback] = []
    var dailyCallLimit = 20
    var automaticCallLimit = 5
    var automaticPaused = false
    var includeHistoricalAutomaticDrafts = false
    var calls: [JournalCallRecord] = []
    var reports: [JournalPeriodReport] = []
    // Restored metadata lets saved notes remain readable without original transcripts.
    // Never persist conversation excerpts in the portable backup/library.
    var library: [JournalActivity] = []

    func calls(on date: Date, clock: JournalClock) -> [JournalCallRecord] {
        guard let day = clock.calendar.dateInterval(of: .day, for: date) else { return [] }
        return calls.filter { $0.createdAt >= day.start && $0.createdAt < day.end }.sorted { $0.createdAt > $1.createdAt }
    }
    func feedback(resultID: UUID, threadKey: String) -> JournalAdviceFeedback? {
        feedback.last { $0.resultID == resultID && $0.threadKey == threadKey }
    }
}

/// All persistent writers share one advisory lock. The journal additionally uses
/// optimistic comparison; atomic replacement alone cannot prevent lost updates.
enum JournalFileAccess {
    static let maximumBytes = 64 * 1024 * 1024
    static func read(_ url: URL, maximum: Int = maximumBytes) throws -> Data? {
        let manager = FileManager.default
        guard (try? manager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw JournalError.message("存储文件不能使用符号链接，原文件已保留。")
        }
        guard manager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximum else {
            throw JournalError.message("存储文件过大或格式无效，原文件已保留。")
        }
        return try Data(contentsOf: url)
    }
    static func withLock<T>(directory: URL, allowRecovery: Bool = false, _ operation: () throws -> T) throws -> T {
        let manager = FileManager.default
        guard (try? manager.destinationOfSymbolicLink(atPath: directory.path)) == nil else {
            throw JournalError.message("存储目录不能使用符号链接。")
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: JournalPlatform.attributes(0o700))
        let lockURL = directory.appendingPathComponent(".agentjournal.lock")
        return try JournalPlatform.withLock(lockURL) {
            if !allowRecovery, try read(directory.appendingPathComponent(".restore-transaction.json"), maximum: 16384) != nil {
                throw JournalError.message("检测到未完成的恢复，请重新打开以恢复原文件；不会继续写入或调用模型。")
            }
            return try operation()
        }
    }
    static func write(_ data: Data, to url: URL) throws {
        guard data.count <= maximumBytes else { throw JournalError.message("存储文件过大，请先备份。") }
        _ = try read(url)
        try data.write(to: url, options: .atomic)
        try JournalPlatform.restrict(url)
    }
    static func saveJournal(_ data: Data, to url: URL, expected: Data?) throws {
        try withLock(directory: url.deletingLastPathComponent()) {
            guard try read(url) == expected else {
                throw JournalError.message("日志已由另一个实例修改，本次未覆盖；请导出备份后重新打开。")
            }
            try write(data, to: url)
        }
    }
}

/// Append-only histories (advice, period reviews, request receipts) are moved here once
/// a live file passes `softLimit`, instead of growing toward the hard storage limit.
/// Archives are never deleted or rewritten; readers and backups include them.
enum JournalArchive {
    static let softLimit = 32 * 1024 * 1024
    struct Envelope: Codable {
        var format = "AgentJournal Archive"
        var version = 1
        var createdAt = Date()
        var advice: [JournalAgentResult] = []
        var reports: [JournalPeriodReport] = []
        var calls: [JournalCallRecord] = []
    }
    struct Summary: Equatable, Sendable {
        var files = 0, advice = 0, reports = 0, calls = 0
    }
    static func directory(beside url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("Archive")
    }
    static func validate(_ value: Envelope) throws {
        guard value.format == "AgentJournal Archive", value.version == 1,
              value.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw JournalError.message("归档格式无效，原文件已保留。")
        }
        try JournalAgentHistoryFile.validate(value.advice)
        try JournalWorkflowFile.validate(JournalWorkflowState(calls: value.calls, reports: value.reports))
    }
    static func load(in folder: URL) throws -> [Envelope] {
        let manager = FileManager.default
        guard (try? manager.destinationOfSymbolicLink(atPath: folder.path)) == nil else {
            throw JournalError.message("归档目录不能使用符号链接，原文件已保留。")
        }
        guard manager.fileExists(atPath: folder.path) else { return [] }
        let files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { file in
            guard let bytes = try JournalFileAccess.read(file) else { throw JournalError.message("归档读取失败，原文件已保留。") }
            let value = try JSONDecoder().decode(Envelope.self, from: bytes)
            try validate(value)
            return value
        }
    }
    static func advice(live: [JournalAgentResult], archives: [Envelope]) -> [JournalAgentResult] {
        var seen = Set<UUID>()
        return JournalAgentHistoryFile.sorted((live + archives.flatMap(\.advice)).filter { seen.insert($0.id).inserted })
    }
    static func reports(live: [JournalPeriodReport], archives: [Envelope]) -> [JournalPeriodReport] {
        var seen = Set<UUID>()
        return (live + archives.flatMap(\.reports)).filter { seen.insert($0.id).inserted }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
    }
    /// Number of newest items to keep so the live file returns to about half the limit.
    static func keepCount(_ count: Int, bytes: Int, limit: Int) -> Int {
        min(count, max(1, Int(Double(count) * Double(limit / 2) / Double(max(bytes, 1)))))
    }
    static func write(_ envelope: Envelope, beside url: URL) throws {
        try validate(envelope)
        let manager = FileManager.default
        let folder = directory(beside: url)
        guard (try? manager.destinationOfSymbolicLink(atPath: folder.path)) == nil else {
            throw JournalError.message("归档目录不能使用符号链接，原文件已保留。")
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: JournalPlatform.attributes(0o700))
        let stem = url.deletingPathExtension().lastPathComponent
        let stamp = JournalClock(timeZoneID: "UTC").label(envelope.createdAt, "yyyyMMdd-HHmmss")
        let file = folder.appendingPathComponent("\(stem)-archive-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= JournalFileAccess.maximumBytes else { throw JournalError.message("存储文件过大，请先备份。") }
        try data.write(to: file, options: .withoutOverwriting)
        try JournalPlatform.restrict(file)
    }
    /// Counts distinct archived items; an interrupted rotation may archive an item twice.
    static func summary(in folder: URL) -> Summary {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var summary = Summary()
        var advice = Set<UUID>(), reports = Set<UUID>(), calls = Set<UUID>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? JournalFileAccess.read(file),
                  let value = try? JSONDecoder().decode(Envelope.self, from: data),
                  value.format == "AgentJournal Archive", value.version == 1 else { continue }
            summary.files += 1
            advice.formUnion(value.advice.map(\.id)); reports.formUnion(value.reports.map(\.id)); calls.formUnion(value.calls.map(\.id))
        }
        summary.advice = advice.count; summary.reports = reports.count; summary.calls = calls.count
        return summary
    }
}

enum JournalWorkflowFile {
    static func load(_ url: URL) throws -> JournalWorkflowState {
        guard let data = try JournalFileAccess.read(url) else { return JournalWorkflowState() }
        return try decode(data)
    }
    static func decode(_ data: Data) throws -> JournalWorkflowState {
        let value = try JSONDecoder().decode(JournalWorkflowState.self, from: data)
        try validate(value)
        return value
    }
    @discardableResult
    static func update(_ url: URL, now: Date = Date(), archiveLimit: Int = JournalArchive.softLimit,
                       _ change: (inout JournalWorkflowState) throws -> Void) throws -> JournalWorkflowState {
        try JournalFileAccess.withLock(directory: url.deletingLastPathComponent()) {
            var value = try load(url)
            try change(&value)
            try validate(value)
            var bytes = try JSONEncoder().encode(value)
            if bytes.count > archiveLimit,
               let rotated = try archiveOldest(value, bytes: bytes.count, limit: archiveLimit, beside: url, now: now) {
                value = rotated
                bytes = try JSONEncoder().encode(value)
            }
            try JournalFileAccess.write(bytes, to: url)
            return value
        }
    }
    /// Moves the oldest period reviews and request receipts older than 30 days to an
    /// archive file, so retained history can never block daily summaries or limits.
    private static func archiveOldest(_ value: JournalWorkflowState, bytes: Int, limit: Int, beside url: URL,
                                      now: Date) throws -> JournalWorkflowState? {
        var kept = value
        var archived = JournalArchive.Envelope()
        let reports = value.reports.sorted { $0.createdAt > $1.createdAt }
        let reportBytes = try JSONEncoder().encode(value.reports).count
        let budget = max(0, limit / 2 - (bytes - reportBytes))
        let keep = reportBytes == 0 ? reports.count : min(reports.count, reports.count * budget / reportBytes)
        let keptReports = Set(reports.prefix(keep).map(\.id))
        archived.reports = Array(reports.dropFirst(keep).reversed())
        kept.reports = value.reports.filter { keptReports.contains($0.id) }
        let cutoff = now.addingTimeInterval(-30 * 86400)
        archived.calls = value.calls.filter { $0.createdAt < cutoff }
        kept.calls = value.calls.filter { $0.createdAt >= cutoff }
        guard !archived.reports.isEmpty || !archived.calls.isEmpty else { return nil }
        try JournalArchive.write(archived, beside: url)
        return kept
    }
    static func reserve(_ url: URL, kind: JournalCallKind, settings: JournalSettings, itemCount: Int,
                        now: Date = Date()) throws -> (JournalWorkflowState, JournalCallRecord) {
        let call = JournalCallRecord(createdAt: now, kind: kind, engine: settings.summaryEngine,
                                     model: String(settings.model.prefix(300)), itemCount: itemCount)
        let state = try update(url) { value in
            let archived = try JournalArchive.load(in: JournalArchive.directory(beside: url)).flatMap(\.calls)
            var seen = Set<UUID>()
            let all = (value.calls + archived).filter { seen.insert($0.id).inserted }
            let today = JournalWorkflowState(calls: all).calls(on: now, clock: JournalClock(timeZoneID: settings.timeZoneID))
            guard today.count < value.dailyCallLimit else { throw JournalError.message("已达到今日模型调用上限；可在调用控制中调整。") }
            if kind == .automatic {
                guard !value.automaticPaused else { throw JournalError.message("自动草稿已暂停。") }
                guard today.filter({ $0.kind == .automatic }).count < value.automaticCallLimit else {
                    throw JournalError.message("已达到今日自动草稿上限，剩余内容不会继续调用模型。")
                }
            }
            value.calls.append(call)
        }
        return (state, call)
    }
    static func validate(_ value: JournalWorkflowState) throws {
        guard value.version == 1, (0...1000).contains(value.dailyCallLimit),
              (0...1000).contains(value.automaticCallLimit),
              Set(value.feedback.map(\.id)).count == value.feedback.count,
              Set(value.calls.map(\.id)).count == value.calls.count,
              Set(value.reports.map(\.id)).count == value.reports.count,
              value.threads.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 512 && $0.value.updatedAt.timeIntervalSinceReferenceDate.isFinite }),
              value.feedback.allSatisfy({ !$0.threadKey.isEmpty && $0.threadKey.count <= 512 && $0.progressFingerprint.count == 64 && $0.createdAt.timeIntervalSinceReferenceDate.isFinite }),
              value.calls.allSatisfy({ $0.createdAt.timeIntervalSinceReferenceDate.isFinite && $0.model.count <= 300 && (0...100000).contains($0.itemCount) }),
              Set(value.library.map(\.id)).count == value.library.count,
              value.library.allSatisfy({ $0.excerpts.isEmpty && !$0.threadID.isEmpty && $0.threadKey.count <= 512 && JournalClock.isDayKey($0.day) && $0.firstActivity.timeIntervalSinceReferenceDate.isFinite && $0.lastActivity.timeIntervalSinceReferenceDate.isFinite }) else {
            throw JournalError.message("状态或调用记录格式无效，原文件已保留。")
        }
        for report in value.reports { try JournalPeriodReporter.validate(report) }
    }
}

struct JournalBackupEnvelope: Codable {
    var format = "AgentJournal Backup"
    var version = 2
    var createdAt = Date()
    var journal: Data
    var advice: [JournalAgentResult]
    var workflow: JournalWorkflowState
    // Optional for v1 compatibility. Keep each archive bounded instead of
    // re-expanding live files past their 64 MiB safety limit on import.
    var archives: [JournalArchive.Envelope]? = nil
    // Version 3 prevents older apps from silently dropping task trees on restore.
    var progress: JournalProgressState? = nil
}

@MainActor
enum JournalBackupFile {
    struct RestoreManifest: Codable {
        var version = 1
        var backupID: UUID
        var files: [String]
        var missing: [String]
        var newArchives: [String]? = nil
    }
    private static func importedArchiveURLs(_ manifest: RestoreManifest, directory: URL) throws -> [URL] {
        let names = manifest.newArchives ?? []
        let prefix = "restore-\(manifest.backupID.uuidString)-"
        guard Set(names).count == names.count, names.enumerated().allSatisfy({
            $0.element == "\(prefix)\($0.offset).json"
        }) else { throw JournalError.message("恢复事务格式无效，所有文件已保留。") }
        let folder = directory.appendingPathComponent("Archive")
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) == nil else {
            throw JournalError.message("归档目录不能使用符号链接，原文件已保留。")
        }
        return names.map { folder.appendingPathComponent($0) }
    }
    static func recover(in directory: URL, expectedFiles: [URL]) throws {
        let transaction = directory.appendingPathComponent(".restore-transaction.json")
        guard try JournalFileAccess.read(transaction, maximum: 16384) != nil else { return }
        try JournalFileAccess.withLock(directory: directory, allowRecovery: true) {
            guard let bytes = try JournalFileAccess.read(transaction, maximum: 16384) else { return }
            let manifest = try JSONDecoder().decode(RestoreManifest.self, from: bytes)
            let expectedNames = Set(expectedFiles.map(\.lastPathComponent))
            let legacyNames = Set(expectedNames.filter { !$0.hasSuffix("progress.json") })
            let actualNames = Set(manifest.files)
            guard [1, 2].contains(manifest.version), actualNames == expectedNames || actualNames == legacyNames,
                  actualNames.count == manifest.files.count, Set(manifest.missing).isSubset(of: actualNames) else {
                throw JournalError.message("恢复事务格式无效，所有文件已保留。")
            }
            let imported = try importedArchiveURLs(manifest, directory: directory)
            let parent = directory.appendingPathComponent("Restore Backups")
            let safety = parent.appendingPathComponent(manifest.backupID.uuidString)
            for folder in [parent, safety] {
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) == nil else {
                    throw JournalError.message("恢复备份目录不能使用符号链接。")
                }
            }
            // Read and validate every original before rolling anything back.
            var originals: [(URL, Data?)] = []
            for url in expectedFiles where actualNames.contains(url.lastPathComponent) {
                if manifest.missing.contains(url.lastPathComponent) { originals.append((url, nil)) }
                else {
                    guard let data = try JournalFileAccess.read(safety.appendingPathComponent(url.lastPathComponent)) else {
                        throw JournalError.message("恢复前原文件不完整，请保留 Restore Backups 并手动修复。")
                    }
                    originals.append((url, data))
                }
            }
            for (url, original) in originals {
                if let original { try JournalFileAccess.write(original, to: url) }
                else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            for url in imported {
                _ = try JournalFileAccess.read(url)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            try FileManager.default.removeItem(at: transaction)
        }
    }
    static func decode(_ data: Data) throws -> JournalBackupEnvelope {
        guard data.count <= 128 * 1024 * 1024 else { throw JournalError.message("备份文件过大。") }
        let value = try JSONDecoder().decode(JournalBackupEnvelope.self, from: data)
        guard value.format == "AgentJournal Backup", [1, 2, 3].contains(value.version),
              value.createdAt.timeIntervalSinceReferenceDate.isFinite,
              (value.version == 3) == (value.progress != nil),
              value.journal.count <= JournalFileAccess.maximumBytes else { throw JournalError.message("备份格式或版本不兼容。") }
        let journal = try JSONDecoder().decode(JournalSaved.self, from: value.journal)
        guard [1, 2].contains(journal.version) else { throw JournalError.message("备份日志版本不兼容。") }
        try JournalAgentHistoryFile.validate(value.advice)
        try JournalWorkflowFile.validate(value.workflow)
        if let progress = value.progress {
            guard value.version == 3, try JSONEncoder().encode(progress).count <= JournalFileAccess.maximumBytes else {
                throw JournalError.message("备份格式或版本不兼容。")
            }
            try JournalProgressFile.validate(progress)
        }
        if value.version == 1, !(value.archives ?? []).isEmpty { throw JournalError.message("备份格式或版本不兼容。") }
        for archive in value.archives ?? [] {
            try JournalArchive.validate(archive)
            guard try JSONEncoder().encode(archive).count <= JournalFileAccess.maximumBytes else {
                throw JournalError.message("备份文件过大。")
            }
        }
        guard try JSONEncoder().encode(value.workflow).count <= JournalFileAccess.maximumBytes,
              try JournalAgentHistoryFile.encoded(value.advice).count <= JournalFileAccess.maximumBytes else {
            throw JournalError.message("备份文件过大。")
        }
        return value
    }
    /// Validate before any replacement. Keep exact originals (including damaged
    /// files) in a private safety directory, and roll back on partial IO failure.
    static func replace(_ files: [(URL, Data)], directory: URL, library: [JournalActivity] = [],
                        archives: [JournalArchive.Envelope] = []) throws -> URL {
        try JournalFileAccess.withLock(directory: directory) {
            let manager = FileManager.default
            let backupID = UUID()
            let archiveNames = archives.indices.map { "restore-\(backupID.uuidString)-\($0).json" }
            let archiveBytes = try archives.map { value -> Data in
                try JournalArchive.validate(value)
                let bytes = try JSONEncoder().encode(value)
                guard bytes.count <= JournalFileAccess.maximumBytes else { throw JournalError.message("备份文件过大。") }
                return bytes
            }
            let archiveFolder = directory.appendingPathComponent("Archive")
            let archiveManifest = RestoreManifest(version: 2, backupID: backupID, files: [], missing: [], newArchives: archiveNames)
            let imported = try importedArchiveURLs(archiveManifest, directory: directory)
            if !imported.isEmpty {
                try manager.createDirectory(at: archiveFolder, withIntermediateDirectories: true, attributes: JournalPlatform.attributes(0o700))
                for url in imported {
                    guard try JournalFileAccess.read(url) == nil else { throw JournalError.message("恢复目标已存在，原文件已保留。") }
                }
            }
            let parent = directory.appendingPathComponent("Restore Backups")
            guard (try? manager.destinationOfSymbolicLink(atPath: parent.path)) == nil else { throw JournalError.message("恢复备份目录不能使用符号链接。") }
            let safety = parent.appendingPathComponent(backupID.uuidString)
            try manager.createDirectory(at: safety, withIntermediateDirectories: true, attributes: JournalPlatform.attributes(0o700))
            var originals: [(URL, Data?)] = []
            var prepared = files
            for (index, pair) in files.enumerated() {
                let (url, bytes) = pair
                guard url.deletingLastPathComponent() == directory, bytes.count <= JournalFileAccess.maximumBytes else {
                    throw JournalError.message("恢复目标或文件大小无效。")
                }
                let original = try JournalFileAccess.read(url)
                originals.append((url, original))
                if let original { try JournalFileAccess.write(original, to: safety.appendingPathComponent(url.lastPathComponent)) }
                if url.lastPathComponent.hasSuffix("workflow.json"), let original,
                   let latest = try? JournalWorkflowFile.decode(original) {
                    var restored = try JournalWorkflowFile.decode(bytes)
                    var calls = Dictionary(uniqueKeysWithValues: restored.calls.map { ($0.id, $0) })
                    for call in latest.calls { calls[call.id] = call }
                    restored.calls = calls.values.sorted { $0.createdAt < $1.createdAt }
                    prepared[index].1 = try JSONEncoder().encode(restored)
                }
            }
            // When originals are readable, also leave a directly importable
            // pre-restore backup. Corrupt originals are still preserved exactly.
            do {
                let journal = try originals.first { $0.0.lastPathComponent == "journal.json" || $0.0.lastPathComponent == "codex-journal.json" }?.1
                    ?? JSONEncoder().encode(JournalSaved(drafts: [:], autoSummarize: false, settings: nil))
                let adviceBytes = originals.first { $0.0.lastPathComponent.hasSuffix("advice.json") }?.1
                let advice = try adviceBytes.map(JournalAgentHistoryFile.decode) ?? []
                let workflowBytes = originals.first { $0.0.lastPathComponent.hasSuffix("workflow.json") }?.1
                var state = try workflowBytes.map(JournalWorkflowFile.decode) ?? JournalWorkflowState()
                var metadata = Dictionary(uniqueKeysWithValues: state.library.map { ($0.id, $0) })
                for var activity in library { activity.excerpts = []; metadata[activity.id] = activity }
                state.library = metadata.values.sorted { $0.id < $1.id }
                let progressBytes = originals.first { $0.0.lastPathComponent.hasSuffix("progress.json") }?.1
                let progress = try progressBytes.map(JournalProgressFile.decode)
                let envelope = JournalBackupEnvelope(version: progress == nil ? 2 : 3, journal: journal, advice: advice, workflow: state,
                    archives: try JournalArchive.load(in: archiveFolder), progress: progress)
                let data = try JSONEncoder().encode(envelope)
                _ = try decode(data)
                try JournalFileAccess.write(data, to: safety.appendingPathComponent("AgentJournal-PreRestore.json"))
            } catch {
                // This optional convenience must never discard exact originals
                // or stop recovery of a damaged state file from a valid backup.
            }
            let transaction = directory.appendingPathComponent(".restore-transaction.json")
            let manifest = RestoreManifest(version: 2, backupID: backupID, files: files.map { $0.0.lastPathComponent },
                missing: originals.filter { $0.1 == nil }.map { $0.0.lastPathComponent }, newArchives: archiveNames)
            try JournalFileAccess.write(JSONEncoder().encode(manifest), to: transaction)
            do {
                for (url, bytes) in prepared { try JournalFileAccess.write(bytes, to: url) }
                for (url, bytes) in zip(imported, archiveBytes) { try JournalFileAccess.write(bytes, to: url) }
                try manager.removeItem(at: transaction)
            }
            catch {
                var rollbackFailed = false
                for (url, original) in originals {
                    do {
                        if let original { try JournalFileAccess.write(original, to: url) }
                        else if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
                    } catch { rollbackFailed = true }
                }
                for url in imported {
                    do {
                        _ = try JournalFileAccess.read(url)
                        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
                    } catch { rollbackFailed = true }
                }
                if rollbackFailed { throw JournalError.message("恢复未完成，回滚失败；原文件已保存在 Restore Backups，请勿继续编辑。") }
                try manager.removeItem(at: transaction)
                throw error
            }
            return safety
        }
    }
}
