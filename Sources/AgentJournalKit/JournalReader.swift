import Foundation

actor JournalReader {
    private struct FileState: Codable {
        var offset: UInt64 = 0
        var modifiedAt: Date = .distantPast
        var threadID = ""
        var cwd = ""
        var title = ""
        var excluded = false
        var days: [String: JournalActivity] = [:]
        var skippingLargeLine: Bool? = nil
        var currentModel: String? = nil
        // Carried across an index rebuild after the source transcript was cleaned up.
        var retainedOnly: Bool? = nil
    }
    private struct Index: Codable {
        var version = 2
        var signature: String?
        var sourceSignature: String?
        var files: [String: FileState] = [:]
    }
    // A transcript may disappear immediately after a scan: changed entries are
    // retained history, not merely a replayable cache. Persist before returning.
    private let settings: JournalSettings
    private let clock: JournalClock
    private let indexURL: URL
    private let exclusions: [String]
    private var index = Index()
    private var indexLoaded = false
    private var indexDirty = false
    private let previousSettings: JournalSettings?
    private var migrationWarning: String?
    private var retained: [String: FileState] = [:]
    private let fractional = ISO8601DateFormatter()
    private let ordinary = ISO8601DateFormatter()
    private let dayFormatter = DateFormatter()
    private let codexMarkers = ["session_meta", "turn_context", "message"].flatMap { type in
        [Data("\"type\":\"\(type)\"".utf8), Data("\"type\": \"\(type)\"".utf8)]
    }

    init(settings: JournalSettings, indexURL: URL, previousSettings: JournalSettings? = nil) {
        self.settings = settings
        self.previousSettings = previousSettings
        clock = JournalClock(timeZoneID: settings.timeZoneID)
        self.indexURL = indexURL
        exclusions = settings.excludedProjects.split(separator: "\n").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        dayFormatter.calendar = clock.calendar
        dayFormatter.locale = clock.calendar.locale
        dayFormatter.timeZone = clock.calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    // Loaded on the actor at the first scan, never on the caller's (main) thread.
    private func loadIndex() throws {
        guard !indexLoaded else { return }
        indexLoaded = true
        let sourceSuffix = settings.sourceSelection == .both ? "" : "|sources=\(settings.sourceSelection.rawValue)"
        let signature = JournalClock.hash("\(settings.codexHome)|\(settings.claudeHome)|\(settings.timeZoneID)|\(settings.excludedProjects)\(sourceSuffix)")
        let sourceSignature = JournalClock.hash("\(settings.codexHome)|\(settings.claudeHome)")
        let bytes = try JournalFileAccess.read(indexURL)
        let cached = bytes.flatMap { try? JSONDecoder().decode(Index.self, from: $0) }
        if var cached, cached.version == 2 && cached.signature == signature {
            indexDirty = cached.sourceSignature != sourceSignature
            cached.sourceSignature = sourceSignature
            index = cached
            return
        }
        indexDirty = true
        if var legacy = cached, legacy.version == 1 && settings.timeZoneID == "Asia/Shanghai" {
            // Keep retained excerpts even if Codex later removes an original file.
            legacy.files = Dictionary(uniqueKeysWithValues: legacy.files.map { ("codex|\($0.key)", $0.value) })
            legacy.version = 2
            index = legacy
        } else if let cached, cached.version == 2,
                  cached.sourceSignature == sourceSignature || (cached.sourceSignature == nil && legacySourceMatches(cached.signature)) {
            // Same transcript folders, new timezone or exclusions: rebuild, but keep the
            // history of transcripts that were cleaned up since they were scanned.
            retained = cached.files
        } else if let cached, cached.version == 2, cached.sourceSignature == nil, let bytes {
            // Old signatures do not encode independently verifiable roots. If we
            // cannot establish provenance, preserve the exact cache, never mix it
            // into a different source folder or silently replace its only copy.
            let preserved = indexURL.deletingLastPathComponent().appendingPathComponent(
                "\(indexURL.deletingPathExtension().lastPathComponent)-preserved-v2-\(JournalClock.hash(String(decoding: bytes, as: UTF8.self))).json")
            if try JournalFileAccess.read(preserved) == nil { try JournalFileAccess.write(bytes, to: preserved) }
            migrationWarning = "旧索引来源无法确认，已保留原索引副本；当前目录将重新扫描。"
        }
        index.signature = signature
        index.sourceSignature = sourceSignature
    }

    private func legacySourceMatches(_ signature: String?) -> Bool {
        guard let signature else { return false }
        var exclusions = Set([settings.excludedProjects, ""])
        if let previousSettings, previousSettings.codexHome == settings.codexHome,
           previousSettings.claudeHome == settings.claudeHome { exclusions.insert(previousSettings.excludedProjects) }
        var zones = Set(TimeZone.knownTimeZoneIdentifiers + ["UTC", settings.timeZoneID])
        if let previousSettings { zones.insert(previousSettings.timeZoneID) }
        return exclusions.contains { excluded in zones.contains { zone in
            JournalClock.hash("\(settings.codexHome)|\(settings.claudeHome)|\(zone)|\(excluded)") == signature
        } }
    }

    func scan() throws -> JournalSnapshot {
        do { try loadIndex() }
        catch { indexLoaded = false; throw error }
        let manager = FileManager.default
        let l = JournalText(settings.uiLanguage)
        var warnings: [String] = []
        if let migrationWarning { warnings.append(migrationWarning) }
        var seen = Set<String>()
        let codexHome = URL(fileURLWithPath: settings.codexHome)
        let claudeHome = URL(fileURLWithPath: settings.claudeHome)
        let roots: [(JournalProvider, URL)] = [
            (.codex, codexHome.appendingPathComponent("sessions")),
            (.codex, codexHome.appendingPathComponent("archived_sessions")),
            (.claude, claudeHome.appendingPathComponent("projects"))
        ]
        for (provider, root) in roots {
            guard settings.includesProvider(provider) else { continue }
            guard manager.fileExists(atPath: root.path) else { continue }
            guard let enumerator = manager.enumerator(at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else {
                warnings.append(l("%@ 目录无法读取，请检查权限。", provider.label))
                continue
            }
            for case let file as URL in enumerator {
                if file.lastPathComponent == "subagents" { enumerator.skipDescendants(); continue }
                guard file.pathExtension == "jsonl" else { continue }
                if provider == .codex && !file.lastPathComponent.hasPrefix("rollout-") { continue }
                if provider == .claude && file.lastPathComponent.hasPrefix("agent-") { continue }
                do {
                    let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true else { continue }
                    let modified = values.contentModificationDate ?? .distantPast
                    let size = UInt64(values.fileSize ?? 0)
                    let key = provider == .codex ? "codex|\(file.lastPathComponent)" : "claude|\(file.path)"
                    seen.insert(key)
                    var state = index.files[key] ?? FileState()
                    if size < state.offset || (size == state.offset && modified != state.modifiedAt)
                        || state.retainedOnly == true {
                        state = FileState()
                    }
                    if size > state.offset || modified != state.modifiedAt {
                        try read(file, provider: provider, into: &state, size: size)
                        state.modifiedAt = modified
                        index.files[key] = state
                        indexDirty = true
                    }
                } catch { warnings.append(l("一个 %@ 日志暂时无法读取，刷新时会重试。", provider.label)) }
            }
        }
        carryRetainedHistory(seen: seen)
        let names = settings.includesProvider(.codex) ? readCodexNames(codexHome) : [:]
        let desktop = JournalDesktopSessions.load(settings.includesProvider(.claude) ? settings.desktopSessionsURL : nil)
        if desktop.incomplete { warnings.append(l("部分 Claude 桌面会话元数据无法读取；日志仍可查看，原线程定位可能不可用。")) }
        var combined: [String: JournalActivity] = [:]
        for state in index.files.values where !state.excluded {
            for var activity in state.days.values {
                guard settings.includesProvider(activity.source) else { continue }
                guard !isExcluded(activity.cwd) else { continue }
                activity.title = (activity.source == .codex ? names[activity.threadID] : nil) ?? state.title
                if activity.source == .claude {
                    // Enrich every refresh, including unchanged/cached JSONL files. Never duplicate a CLI thread.
                    let session = desktop.sessions[activity.threadID.lowercased()]
                    activity.desktopSessionID = session?.sessionId
                    activity.desktopSessionArchived = session?.isArchived
                    if let title = session?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                        activity.title = String(title.prefix(300))
                    }
                }
                if activity.title.isEmpty { activity.title = l("未命名线程") }
                if var existing = combined[activity.id] {
                    existing.merge(activity)
                    combined[activity.id] = existing
                } else { combined[activity.id] = activity }
            }
        }
        if settings.includesProvider(.codex), !manager.fileExists(atPath: codexHome.appendingPathComponent("sessions").path)
            && !manager.fileExists(atPath: codexHome.appendingPathComponent("archived_sessions").path) {
            warnings.append("未发现 Codex 本地记录；可在设置中指定目录。")
        }
        if settings.includesProvider(.claude), !manager.fileExists(atPath: claudeHome.appendingPathComponent("projects").path) {
            warnings.append("未发现 Claude Code 本地记录；可在设置中指定目录。")
        }
        if indexDirty {
            do {
                try manager.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: JournalPlatform.attributes(0o700))
                try JournalFileAccess.withLock(directory: indexURL.deletingLastPathComponent()) {
                    try JournalFileAccess.write(JSONEncoder().encode(index), to: indexURL)
                }
                indexDirty = false
            } catch { warnings.append("索引未能缓存，当前记录仍可查看。") }
        }
        return JournalSnapshot(activities: Array(combined.values), warnings: Array(Set(warnings)).sorted())
    }

    /// After a rebuild, keep entries whose transcript no longer exists. Their days keep
    /// the original timezone; newly excluded projects are dropped rather than retained.
    private func carryRetainedHistory(seen: Set<String>) {
        guard !retained.isEmpty else { return }
        defer { retained = [:] }
        for (key, var state) in retained where index.files[key] == nil && !seen.contains(key) && !state.excluded {
            if key.hasPrefix("claude|"), FileManager.default.fileExists(atPath: String(key.dropFirst(7))) { continue }
            guard !isExcluded(state.cwd) else { continue }
            state.days = state.days.filter { !isExcluded($0.value.cwd) }
            guard !state.days.isEmpty else { continue }
            state.retainedOnly = true
            index.files[key] = state
        }
    }
    private func isExcluded(_ cwd: String) -> Bool {
        exclusions.contains { cwd.localizedCaseInsensitiveContains($0) }
    }

    private func readCodexNames(_ home: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("session_index.jsonl")) else { return [:] }
        var names: [String: String] = [:]
        for line in data.split(separator: 10) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = row["id"] as? String, let title = row["thread_name"] as? String else { continue }
            names[id] = title
        }
        return names
    }

    private func read(_ file: URL, provider: JournalProvider, into state: inout FileState, size: UInt64) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: state.offset)
        var pending = Data()
        while true {
            // Foundation's file/JSON bridges can leave autoreleased objects alive
            // for the whole actor call. Drain per chunk, not after a multi-GB scan.
            let more = try JournalPlatform.drainPool { () throws -> Bool in
                guard let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { return false }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending.subdata(in: 0..<newline)
                    let consumed = newline + 1
                    pending.removeSubrange(0..<consumed)
                    state.offset += UInt64(consumed)
                    if state.skippingLargeLine == true { state.skippingLargeLine = false; continue }
                    if line.count <= 8 * 1024 * 1024 {
                        if provider == .codex {
                            // Most rollout bytes are tool results/events, not journal material.
                            // Unusual whitespace falls back to parsing; this is only an optimization.
                            let unusualWhitespace = line.contains(9) || line.contains(13)
                                || line.range(of: Data("\"type\" ".utf8)) != nil
                                || line.range(of: Data("\"type\":  ".utf8)) != nil
                            if unusualWhitespace || codexMarkers.contains(where: { line.range(of: $0) != nil }) {
                                parseCodex(line, into: &state)
                            }
                        } else {
                            parseClaude(line, fallbackID: file.deletingPathExtension().lastPathComponent, into: &state)
                        }
                    }
                    if state.excluded { state.offset = size; return false }
                }
                if pending.count > 8 * 1024 * 1024 {
                    state.offset += UInt64(pending.count)
                    pending.removeAll(keepingCapacity: false)
                    state.skippingLargeLine = true
                }
                return true
            }
            if !more { break }
        }
        // Never commit a partially-written final line. Replay it on the next refresh.
    }

    private func parseCodex(_ line: Data, into state: inout FileState) {
        guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = row["type"] as? String, let payload = row["payload"] as? [String: Any] else { return }
        if type == "session_meta" {
            state.threadID = payload["id"] as? String ?? ""
            state.cwd = payload["cwd"] as? String ?? ""
            let source = payload["source"] as? String ?? ""
            state.excluded = payload["source"] is [String: Any] || source == "exec"
            return
        }
        if type == "turn_context" {
            state.currentModel = payload["model"] as? String
            return
        }
        guard !state.excluded, !state.threadID.isEmpty, type == "response_item",
              payload["type"] as? String == "message",
              let role = payload["role"] as? String, role == "user" || role == "assistant",
              let timestamp = timestamp(row["timestamp"]) else { return }
        if role == "assistant", payload["phase"] as? String == "commentary"
            || payload["channel"] as? String == "analysis" { return }
        let text = textContent(payload["content"])
        append(text, role: role, timestamp: timestamp, provider: .codex, model: state.currentModel, state: &state)
    }

    private func parseClaude(_ line: Data, fallbackID: String, into state: inout FileState) {
        guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              row["isSidechain"] as? Bool != true,
              let type = row["type"] as? String else { return }
        if let id = row["sessionId"] as? String { state.threadID = id }
        if state.threadID.isEmpty { state.threadID = fallbackID }
        if let cwd = row["cwd"] as? String { state.cwd = cwd }
        if type == "custom-title", let title = row["customTitle"] as? String, !title.isEmpty {
            state.title = title; return
        }
        guard type == "user" || type == "assistant", row["isMeta"] as? Bool != true,
              row["isCompactSummary"] as? Bool != true,
              let message = row["message"] as? [String: Any],
              let timestamp = timestamp(row["timestamp"]) else { return }
        // Only human-readable text: no thinking, tool_result, tool_use, images or attachments.
        let text = textContent(message["content"])
        let model = type == "assistant" ? message["model"] as? String : nil
        append(text, role: type, timestamp: timestamp, provider: .claude, model: model,
               messageID: row["uuid"] as? String, state: &state)
    }

    private func textContent(_ value: Any?) -> String {
        if let text = value as? String { return text }
        return (value as? [[String: Any]] ?? []).compactMap { part in
            let kind = part["type"] as? String ?? ""
            return ["text", "input_text", "output_text"].contains(kind) ? part["text"] as? String : nil
        }.joined(separator: "\n")
    }
    private func timestamp(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractional.date(from: text) ?? ordinary.date(from: text)
    }
    private func append(_ raw: String, role: String, timestamp: Date, provider: JournalProvider,
                        model: String? = nil, messageID: String? = nil, state: inout FileState) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isExcluded(state.cwd) else { return }
        let ignored = ["<environment_context>", "<external_codex_apps_open_page>", "# AGENTS.md instructions",
                       "<permissions instructions>", "<local-command-stdout>", "<local-command-caveat>",
                       "<command-name>", "<system-reminder>"]
        if role == "user" && ignored.contains(where: { text.hasPrefix($0) }) { return }
        if state.title.isEmpty && role == "user" { state.title = String(text.prefix(100)) }
        let day = dayFormatter.string(from: timestamp)
        var activity = state.days[day] ?? JournalActivity(provider: provider, threadID: state.threadID,
            day: day, title: state.title, cwd: state.cwd, firstActivity: timestamp, lastActivity: timestamp)
        if let model { activity.sourceModel = model }
        activity.append(JournalExcerpt(timestamp: timestamp, role: role, text: String(text.prefix(1600))), messageID: messageID)
        state.days[day] = activity
    }
}
