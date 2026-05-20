import Foundation
import Testing
@testable import AISwitcher

struct ClaudeTranscriptParserTests {
    @Test
    func parsesLocalClaudeActivityWithoutInferringUsage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserTests-\(UUID().uuidString)")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserCacheTests-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-Users-dev-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let transcript = project.appendingPathComponent("session-1.jsonl")
        let lines = [
            try jsonLine([
                "type": "user",
                "timestamp": "2026-05-19T12:00:00.000Z",
                "uuid": "turn-1",
                "cwd": "/Users/dev/project",
                "message": [
                    "content": [
                        ["type": "text", "text": "Please inspect the failing test."]
                    ]
                ]
            ]),
            try jsonLine([
                "type": "assistant",
                "timestamp": "2026-05-19T12:00:03.000Z",
                "cwd": "/Users/dev/project",
                "message": [
                    "model": "claude-sonnet-4-5",
                    "content": [
                        ["type": "text", "text": "I will inspect it."]
                    ]
                ]
            ])
        ]
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let parser = ClaudeTranscriptParser(projectsDir: root, cacheBaseDir: cacheRoot)
        let records = parser.calculateSessionRecords(range: .allTime)

        #expect(records.count == 1)
        #expect(records[0].provider == .claude)
        #expect(records[0].projectPath == "/Users/dev/project")
        #expect(records[0].projectName == "project")
        #expect(records[0].firstPrompt == "Please inspect the failing test.")
        #expect(records[0].turns.count == 1)
        #expect(records[0].turns[0].inputTokens == 0)
        #expect(records[0].turns[0].outputTokens == 0)
        #expect(records[0].totalTokens == 0)
    }

    @Test
    func filtersClaudeActivityByAnalyticsRange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserTests-\(UUID().uuidString)")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserCacheTests-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let transcript = project.appendingPathComponent("session-2.jsonl")
        let lines = [
            try jsonLine([
                "type": "user",
                "timestamp": "2026-05-10T12:00:00.000Z",
                "cwd": "/tmp/project",
                "message": ["content": "old prompt"]
            ]),
            try jsonLine([
                "type": "user",
                "timestamp": "2026-05-19T12:00:00.000Z",
                "cwd": "/tmp/project",
                "message": ["content": "fresh prompt"]
            ])
        ]
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let parser = ClaudeTranscriptParser(projectsDir: root, cacheBaseDir: cacheRoot)
        let records = parser.calculateSessionRecords(
            range: .sevenDays,
            now: ISO8601DateFormatter().date(from: "2026-05-19T13:00:00Z")!
        )

        #expect(records.count == 1)
        #expect(records[0].turns.map(\.promptPreview) == ["fresh prompt"])
    }

    @Test
    func preservesMetadataFromNonUserTranscriptLines() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserTests-\(UUID().uuidString)")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserCacheTests-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let transcript = project.appendingPathComponent("session-3.jsonl")
        let lines = [
            try jsonLine([
                "type": "assistant",
                "cwd": "/tmp/metadata-project",
                "parentUuid": "parent-session",
                "message": [
                    "model": "claude-sonnet-4-5",
                    "content": [["type": "text", "text": "metadata line"]]
                ]
            ]),
            try jsonLine([
                "type": "user",
                "timestamp": "2026-05-19T12:00:01.000Z",
                "message": ["content": "prompt after metadata"]
            ])
        ]
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let parser = ClaudeTranscriptParser(projectsDir: root, cacheBaseDir: cacheRoot)
        let records = parser.calculateSessionRecords(range: .allTime)

        #expect(records.count == 1)
        #expect(records[0].projectPath == "/tmp/metadata-project")
        #expect(records[0].parentId == "parent-session")
        #expect(records[0].turns.first?.model == "claude-sonnet-4-5")
    }

    @Test
    func skipsClaudeToolResultUserLines() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserTests-\(UUID().uuidString)")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserCacheTests-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let transcript = project.appendingPathComponent("session-tool-result.jsonl")
        let lines = [
            #"{"type":"assistant","message":{"model":"claude-sonnet-4-5"}}"#,
            #"{"type":"user","timestamp":"2026-05-19T12:00:00.000Z","cwd":"/tmp/project","message":{"content":"real user prompt"}}"#,
            #"{"type":"user","timestamp":"2026-05-19T12:00:05.000Z","cwd":"/tmp/project","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"command output"}]}}"#
        ]
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let parser = ClaudeTranscriptParser(projectsDir: root, cacheBaseDir: cacheRoot)
        let records = parser.calculateSessionRecords(range: .allTime)

        #expect(records.count == 1)
        #expect(records[0].turns.map(\.promptPreview) == ["real user prompt"])
        #expect(records[0].turns.first?.model == "claude-sonnet-4-5")
    }

    @Test
    func skipsLargeClaudeToolResultLines() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserTests-\(UUID().uuidString)")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserCacheTests-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let transcript = project.appendingPathComponent("session-large-tool-result.jsonl")
        let largeOutput = String(repeating: "x", count: 2 * 1024 * 1024)
        let lines = [
            #"{"type":"user","timestamp":"2026-05-19T12:00:00.000Z","cwd":"/tmp/project","message":{"content":"real user prompt"}}"#,
            #"{"type":"user","timestamp":"2026-05-19T12:00:05.000Z","cwd":"/tmp/project","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":""# + largeOutput + #""}]}}"#
        ]
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let parser = ClaudeTranscriptParser(projectsDir: root, cacheBaseDir: cacheRoot)
        let records = parser.calculateSessionRecords(range: .allTime)

        #expect(records.count == 1)
        #expect(records[0].turns.map(\.promptPreview) == ["real user prompt"])
    }

    @Test
    func keepsHumanPromptsThatMentionToolResult() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserTests-\(UUID().uuidString)")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserCacheTests-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let transcript = project.appendingPathComponent("session-human-tool-result-text.jsonl")
        let lines = [
            #"{"type":"user","timestamp":"2026-05-19T12:00:00.000Z","cwd":"/tmp/project","message":{"content":"explain tool_result entries in Claude logs"}}"#,
            #"{"type":"user","timestamp":"2026-05-19T12:00:05.000Z","cwd":"/tmp/project","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"command output"}]}}"#
        ]
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let parser = ClaudeTranscriptParser(projectsDir: root, cacheBaseDir: cacheRoot)
        let records = parser.calculateSessionRecords(range: .allTime)

        #expect(records.count == 1)
        #expect(records[0].turns.map(\.promptPreview) == ["explain tool_result entries in Claude logs"])
    }

    @Test
    func doesNotRewriteClaudeSessionCacheWhenInputsAreUnchanged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserTests-\(UUID().uuidString)")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserCacheTests-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let transcript = project.appendingPathComponent("session-cache.jsonl")
        try jsonLine([
            "type": "user",
            "timestamp": "2026-05-19T12:00:00.000Z",
            "cwd": "/tmp/project",
            "message": ["content": "cached prompt"]
        ]).write(to: transcript, atomically: true, encoding: .utf8)

        let parser = ClaudeTranscriptParser(projectsDir: root, cacheBaseDir: cacheRoot)
        _ = parser.calculateSessionRecords(range: .allTime)

        let cacheFile = cacheRoot
            .appendingPathComponent("cache")
            .appendingPathComponent("claude-session-meta-v2.json")
        let oldDate = ISO8601DateFormatter().date(from: "2026-05-19T10:00:00Z")!
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: cacheFile.path)

        _ = parser.calculateSessionRecords(range: .allTime)

        let attributes = try FileManager.default.attributesOfItem(atPath: cacheFile.path)
        #expect(attributes[.modificationDate] as? Date == oldDate)
    }

    @Test
    func emptyClaudeSessionCacheIsNotTreatedAsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserTests-\(UUID().uuidString)")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserCacheTests-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let transcript = project.appendingPathComponent("assistant-only.jsonl")
        try jsonLine([
            "type": "assistant",
            "timestamp": "2026-05-19T12:00:00.000Z",
            "message": [
                "model": "claude-sonnet-4-5",
                "content": [["type": "text", "text": "metadata only"]]
            ]
        ]).write(to: transcript, atomically: true, encoding: .utf8)

        let parser = ClaudeTranscriptParser(projectsDir: root, cacheBaseDir: cacheRoot)
        #expect(parser.calculateSessionRecords(range: .allTime).isEmpty)

        let cacheDir = cacheRoot.appendingPathComponent("cache")
        let cacheFile = cacheDir.appendingPathComponent("claude-session-meta-v2.json")
        let modFile = cacheDir.appendingPathComponent("claude-session-meta-v2.mod")
        let oldDate = ISO8601DateFormatter().date(from: "2026-05-19T10:00:00Z")!
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: cacheFile.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: modFile.path)

        #expect(parser.calculateSessionRecords(range: .allTime).isEmpty)

        let cacheAttributes = try FileManager.default.attributesOfItem(atPath: cacheFile.path)
        let modAttributes = try FileManager.default.attributesOfItem(atPath: modFile.path)
        #expect(cacheAttributes[.modificationDate] as? Date == oldDate)
        #expect(modAttributes[.modificationDate] as? Date == oldDate)
    }

    @Test
    func includesRecentActivityEvenWhenTranscriptFileIsOlderThanSelectedRange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserTests-\(UUID().uuidString)")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptParserCacheTests-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let oldTranscript = project.appendingPathComponent("old.jsonl")
        try jsonLine([
            "type": "user",
            "timestamp": "2026-05-19T12:00:00.000Z",
            "cwd": "/tmp/project",
            "message": ["content": "old file prompt"]
        ]).write(to: oldTranscript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-05-01T12:00:00Z")!],
            ofItemAtPath: oldTranscript.path
        )

        let parser = ClaudeTranscriptParser(projectsDir: root, cacheBaseDir: cacheRoot)
        let records = parser.calculateSessionRecords(
            range: .sevenDays,
            now: ISO8601DateFormatter().date(from: "2026-05-19T13:00:00Z")!
        )

        #expect(records.count == 1)
        #expect(records[0].turns.map(\.promptPreview) == ["old file prompt"])
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }
}
