import Foundation
import Testing
@testable import AISwitcher

struct SessionTokenParserAttributionTests {
    @Test
    func calculateAttributesUsageToActiveProfileWhenSwitchHistoryIsEmpty() throws {
        let now = Date()
        let profile = Profile(alias: "Solo", email: "solo@example.com", accountId: "acct-solo", addedAt: now)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now.addingTimeInterval(-60))

        let fixture = try SessionFixture.make(lines: [
            """
            {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"output_tokens":30}}}}
            """
        ])
        defer { fixture.cleanup() }

        let parser = fixture.parser()

        let usage = parser.calculate(profiles: [profile], history: [], activeProfileId: profile.id)
        let daily = parser.calculateDaily(profiles: [profile], history: [], activeProfileId: profile.id, range: .sevenDays)
        let records = parser.calculateAnalyticsRecords(profiles: [profile], history: [], activeProfileId: profile.id)

        #expect(usage[profile.id]?.totalTokens == 150)
        #expect(daily[profile.id]?.contains(where: { $0.tokens == 150 }) == true)
        #expect(records.count == 1)
        #expect(records.first?.profileId == profile.id)
        #expect(records.first?.totalTokens == 150)
    }

    @Test
    func unchangedCodexSessionCachesAreNotRewritten() throws {
        let fixture = try SessionFixture.make(lines: [
            """
            {"timestamp":"2026-05-19T12:00:00.000Z","type":"session_meta","payload":{"id":"session-1","cwd":"/tmp/project"}}
            """,
            """
            {"timestamp":"2026-05-19T12:00:01.000Z","type":"event_msg","payload":{"type":"task_started"}}
            """,
            """
            {"timestamp":"2026-05-19T12:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"inspect this"}}
            """,
            """
            {"timestamp":"2026-05-19T12:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"output_tokens":30}}}}
            """
        ])
        defer { fixture.cleanup() }

        let parser = fixture.parser()
        #expect(parser.calculateSessionRecords(range: .allTime).count == 1)

        let cacheFile = fixture.cacheDir
            .appendingPathComponent("cache")
            .appendingPathComponent("session-meta-v3.json")
        let oldDate = ISO8601DateFormatter().date(from: "2026-05-19T10:00:00Z")!
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: cacheFile.path)

        #expect(parser.calculateSessionRecords(range: .allTime).count == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: cacheFile.path)
        #expect(attributes[.modificationDate] as? Date == oldDate)
    }

    @Test
    func emptyCodexSessionMetaCacheIsNotTreatedAsMissing() throws {
        let fixture = try SessionFixture.make(lines: [
            """
            {"timestamp":"2026-05-19T12:00:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"metadata-free prompt"}}
            """
        ])
        defer { fixture.cleanup() }

        let parser = fixture.parser()
        #expect(parser.calculateSessionRecords(range: .allTime).isEmpty)

        let cacheDir = fixture.cacheDir.appendingPathComponent("cache")
        let cacheFile = cacheDir.appendingPathComponent("session-meta-v3.json")
        let modFile = cacheDir.appendingPathComponent("session-meta-v3.mod")
        let oldDate = ISO8601DateFormatter().date(from: "2026-05-19T10:00:00Z")!
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: cacheFile.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: modFile.path)

        #expect(parser.calculateSessionRecords(range: .allTime).isEmpty)

        let cacheAttributes = try FileManager.default.attributesOfItem(atPath: cacheFile.path)
        let modAttributes = try FileManager.default.attributesOfItem(atPath: modFile.path)
        #expect(cacheAttributes[.modificationDate] as? Date == oldDate)
        #expect(modAttributes[.modificationDate] as? Date == oldDate)
    }
}
