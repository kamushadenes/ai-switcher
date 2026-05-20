import Foundation

final class ClaudeTranscriptParser: @unchecked Sendable {
    private static let metadataScanLimit = 16 * 1024

    private let projectsDir: URL
    private let sessionCacheURL: URL
    private let modTimeCacheURL: URL
    private let iso8601WithFractions: ISO8601DateFormatter
    private let iso8601: ISO8601DateFormatter

    private struct CachedSession: Codable {
        let sessionId: String
        let projectPath: String
        let projectName: String
        let firstPrompt: String
        let parentId: String?
        let turns: [CachedTurn]

        var lastActivity: Date {
            Date(timeIntervalSince1970: turns.map(\.timestamp).max() ?? 0)
        }
    }

    private struct CachedTurn: Codable {
        let promptPreview: String
        let timestamp: Double
        let model: String
    }

    private struct FileFingerprint: Codable {
        let modifiedAt: Double
        let size: Int

        func matches(modDate: Date, size: Int) -> Bool {
            self.size == size && abs(modifiedAt - modDate.timeIntervalSince1970) < 1
        }
    }

    init(projectsDir: URL? = nil, cacheBaseDir: URL? = nil) {
        self.projectsDir = projectsDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let base = cacheBaseDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ai-switcher")
        let cacheDir = base.appendingPathComponent("cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        sessionCacheURL = cacheDir.appendingPathComponent("claude-session-meta-v2.json")
        modTimeCacheURL = cacheDir.appendingPathComponent("claude-session-meta-v2.mod")
        iso8601WithFractions = ISO8601DateFormatter()
        iso8601WithFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime]
    }

    func calculateSessionRecords(range: AnalyticsTimeRange = .allTime, now: Date = Date()) -> [AnalyticsSessionRecord] {
        let cache = refreshSessionCache()
        let cutoff = range.cutoffDate(from: now)
        return cache.values.compactMap { session in
            let filteredTurns = session.turns.filter { turn in
                guard let cutoff else { return true }
                return Date(timeIntervalSince1970: turn.timestamp) > cutoff
            }
            guard !filteredTurns.isEmpty else { return nil }

            return AnalyticsSessionRecord(
                sessionId: session.sessionId,
                projectPath: session.projectPath,
                projectName: session.projectName,
                firstPrompt: session.firstPrompt,
                depth: 0,
                agentRole: "Claude",
                parentId: session.parentId,
                turns: filteredTurns.map { turn in
                    AnalyticsSessionTurnRecord(
                        promptPreview: turn.promptPreview,
                        inputTokens: 0,
                        cachedInputTokens: 0,
                        outputTokens: 0,
                        timestamp: Date(timeIntervalSince1970: turn.timestamp),
                        model: turn.model
                    )
                },
                provider: .claude
            )
        }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    private func refreshSessionCache() -> [String: CachedSession] {
        let cacheLoad = loadSessionCache()
        var cache = cacheLoad.cache
        let previousFingerprints = loadFingerprints()
        var currentFingerprints: [String: FileFingerprint] = [:]
        var cacheChanged = false
        let shouldRebuildKnownFiles = !cacheLoad.loaded && !previousFingerprints.isEmpty

        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return cache }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modDate = values?.contentModificationDate ?? .distantPast
            let fileSize = values?.fileSize ?? 0
            currentFingerprints[url.path] = FileFingerprint(
                modifiedAt: modDate.timeIntervalSince1970,
                size: fileSize
            )

            let fingerprintMatches = previousFingerprints[url.path]?.matches(modDate: modDate, size: fileSize) == true
            if shouldRebuildKnownFiles || !fingerprintMatches {
                cacheChanged = true
                if let parsed = parseTranscript(at: url) {
                    cache[url.path] = parsed
                } else {
                    cache.removeValue(forKey: url.path)
                }
            }
        }

        for path in previousFingerprints.keys where currentFingerprints[path] == nil {
            cacheChanged = true
            cache.removeValue(forKey: path)
        }

        if cacheChanged {
            saveSessionCache(cache)
            saveFingerprints(currentFingerprints)
        }
        return cache
    }

    private func parseTranscript(at url: URL) -> CachedSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let sessionId = url.deletingPathExtension().lastPathComponent
        var projectPath = ""
        var parentId: String?
        var model = "claude"
        var turns: [CachedTurn] = []

        let parsedAllLines = readJSONLines(from: handle) { data in
            autoreleasepool {
                if projectPath.isEmpty, let cwd = stringValue(for: "cwd", in: data, limit: Self.metadataScanLimit), !cwd.isEmpty {
                    projectPath = cwd
                }
                if parentId == nil {
                    parentId = stringValue(for: "parentUuid", in: data, limit: Self.metadataScanLimit)
                }
                if let parsedModel = stringValue(for: "model", in: data, limit: Self.metadataScanLimit), !parsedModel.isEmpty {
                    model = parsedModel
                }

                guard isHumanUserLine(data) else { return }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

                if let parsedModel = extractModel(from: json) {
                    model = parsedModel
                }

                guard let prompt = extractPrompt(from: json),
                      let timestamp = parseTimestamp(json["timestamp"]) else { return }

                turns.append(
                    CachedTurn(
                        promptPreview: prompt,
                        timestamp: timestamp.timeIntervalSince1970,
                        model: model
                    )
                )
            }
        }
        guard parsedAllLines else { return nil }

        guard !turns.isEmpty else { return nil }
        let resolvedProjectPath = projectPath.isEmpty ? url.deletingLastPathComponent().lastPathComponent : projectPath
        let projectName = resolvedProjectPath.isEmpty
            ? L("Claude", "Claude")
            : URL(fileURLWithPath: resolvedProjectPath).lastPathComponent

        return CachedSession(
            sessionId: sessionId.isEmpty ? UUID().uuidString : sessionId,
            projectPath: resolvedProjectPath,
            projectName: projectName.isEmpty ? L("Claude", "Claude") : projectName,
            firstPrompt: turns.first?.promptPreview ?? L("Claude oturumu", "Claude session"),
            parentId: parentId,
            turns: turns
        )
    }

    private func readJSONLines(from handle: FileHandle, _ consume: (Data) -> Void) -> Bool {
        let newline = Data([0x0A])
        var pending = Data()
        var discardingCurrentLine = false

        while true {
            let maybeChunk: Data?
            do {
                maybeChunk = try handle.read(upToCount: 1024 * 1024)
            } catch {
                return false
            }

            guard let chunk = maybeChunk, !chunk.isEmpty else { break }

            var start = chunk.startIndex
            while let range = chunk[start...].firstRange(of: newline) {
                if discardingCurrentLine {
                    discardingCurrentLine = false
                } else {
                    pending.append(chunk[start..<range.lowerBound])
                    if !pending.isEmpty, !isToolResultLinePrefix(pending) {
                        consume(pending)
                    }
                    pending.removeAll(keepingCapacity: true)
                }
                start = range.upperBound
            }

            guard start < chunk.endIndex else { continue }

            if !discardingCurrentLine {
                pending.append(chunk[start..<chunk.endIndex])
                if isToolResultLinePrefix(pending) {
                    pending.removeAll(keepingCapacity: true)
                    discardingCurrentLine = true
                }
            }
        }

        if !discardingCurrentLine, !pending.isEmpty, !isToolResultLinePrefix(pending) {
            consume(pending)
        }
        return true
    }

    private func isToolResultLinePrefix(_ data: Data) -> Bool {
        containsStringValue("tool_result", for: "type", in: data, limit: Self.metadataScanLimit)
    }

    private func isHumanUserLine(_ data: Data) -> Bool {
        containsStringValue("user", for: "type", in: data, limit: Self.metadataScanLimit)
    }

    private func stringValue(for key: String, in data: Data, limit: Int? = nil) -> String? {
        stringValue(for: key, in: data, from: data.startIndex, limit: limit)?.value
    }

    private func containsStringValue(_ expected: String, for key: String, in data: Data, limit: Int? = nil) -> Bool {
        var searchStart = data.startIndex
        while let result = stringValue(for: key, in: data, from: searchStart, limit: limit) {
            if result.value == expected { return true }
            searchStart = result.nextIndex
        }
        return false
    }

    private func stringValue(
        for key: String,
        in data: Data,
        from startIndex: Data.Index,
        limit: Int? = nil
    ) -> (value: String, nextIndex: Data.Index)? {
        let keyBytes = Array("\"\(key)\"".utf8)
        guard !keyBytes.isEmpty else { return nil }

        return data.withUnsafeBytes { rawBuffer -> (value: String, nextIndex: Data.Index)? in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard !bytes.isEmpty else { return nil }

            let upperBound = min(bytes.count, limit ?? bytes.count)
            guard startIndex < upperBound, keyBytes.count <= upperBound else { return nil }

            var index = max(0, startIndex)
            while index <= upperBound - keyBytes.count {
                if bytes[index] == keyBytes[0],
                   (index == 0 || bytes[index - 1] != UInt8(ascii: "\\")),
                   matches(keyBytes, in: bytes, at: index) {
                    var cursor = index + keyBytes.count
                    skipWhitespace(in: bytes, cursor: &cursor, upperBound: upperBound)
                    guard cursor < upperBound, bytes[cursor] == UInt8(ascii: ":") else {
                        index += 1
                        continue
                    }
                    cursor += 1
                    skipWhitespace(in: bytes, cursor: &cursor, upperBound: upperBound)
                    guard cursor < upperBound, bytes[cursor] == UInt8(ascii: "\"") else { return nil }
                    cursor += 1

                    let valueStart = cursor
                    var escapedValue: [UInt8]?
                    var escaping = false
                    while cursor < upperBound {
                        let byte = bytes[cursor]
                        if escaping {
                            escapedValue?.append(byte)
                            escaping = false
                            cursor += 1
                            continue
                        }
                        if byte == UInt8(ascii: "\\") {
                            if escapedValue == nil {
                                escapedValue = Array(bytes[valueStart..<cursor])
                            }
                            escaping = true
                            cursor += 1
                            continue
                        }
                        if byte == UInt8(ascii: "\"") {
                            let value: String
                            if let escapedValue {
                                value = String(decoding: escapedValue, as: UTF8.self)
                            } else {
                                value = String(
                                    decoding: UnsafeBufferPointer(rebasing: bytes[valueStart..<cursor]),
                                    as: UTF8.self
                                )
                            }
                            return (value, cursor + 1)
                        }
                        escapedValue?.append(byte)
                        cursor += 1
                    }
                    return nil
                }
                index += 1
            }
            return nil
        }
    }

    private func matches(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        guard index + needle.count <= bytes.count else { return false }
        for offset in 0..<needle.count where bytes[index + offset] != needle[offset] {
            return false
        }
        return true
    }

    private func skipWhitespace(in bytes: UnsafeBufferPointer<UInt8>, cursor: inout Int, upperBound: Int) {
        while cursor < upperBound {
            switch bytes[cursor] {
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
                cursor += 1
            default:
                return
            }
        }
    }

    private func loadSessionCache() -> (cache: [String: CachedSession], loaded: Bool) {
        guard let data = try? Data(contentsOf: sessionCacheURL),
              let cache = try? JSONDecoder().decode([String: CachedSession].self, from: data)
        else { return ([:], false) }
        return (cache, true)
    }

    private func saveSessionCache(_ cache: [String: CachedSession]) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: sessionCacheURL, options: .atomic)
    }

    private func loadFingerprints() -> [String: FileFingerprint] {
        guard let data = try? Data(contentsOf: modTimeCacheURL),
              let dict = try? JSONDecoder().decode([String: FileFingerprint].self, from: data)
        else {
            return [:]
        }
        return dict
    }

    private func saveFingerprints(_ fingerprints: [String: FileFingerprint]) {
        guard let data = try? JSONEncoder().encode(fingerprints) else { return }
        try? data.write(to: modTimeCacheURL, options: .atomic)
    }

    private func parseTimestamp(_ raw: Any?) -> Date? {
        if let seconds = raw as? TimeInterval {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = raw as? String else { return nil }
        return iso8601WithFractions.date(from: string) ?? iso8601.date(from: string)
    }

    private func extractModel(from json: [String: Any]) -> String? {
        if let model = json["model"] as? String, !model.isEmpty {
            return model
        }
        if let message = json["message"] as? [String: Any],
           let model = message["model"] as? String,
           !model.isEmpty {
            return model
        }
        return nil
    }

    private func extractPrompt(from json: [String: Any]) -> String? {
        if let text = json["content"] as? String {
            return preview(text)
        }
        guard let message = json["message"] else { return nil }

        if let text = message as? String {
            return preview(text)
        }
        guard let dict = message as? [String: Any] else { return nil }
        if let text = dict["content"] as? String {
            return preview(text)
        }
        if let parts = dict["content"] as? [[String: Any]] {
            let text = parts.compactMap { part -> String? in
                if part["type"] as? String == "tool_result" { return nil }
                if let text = part["text"] as? String { return text }
                return part["content"] as? String
            }
            .joined(separator: " ")
            return text.isEmpty ? nil : preview(text)
        }
        return nil
    }

    private func preview(_ text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > 160 else { return compact }
        return String(compact.prefix(160)) + "..."
    }
}
