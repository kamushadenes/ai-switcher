import Foundation
import Testing
@testable import AISwitcher

struct RateLimitFetcherTests {
    @Test
    func claudeOAuthUsageRateLimitPreservesRetryAfterHeader() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RateLimitFetcherStubURLProtocol.self]
        RateLimitFetcherStubURLProtocol.response = (
            statusCode: 429,
            headers: ["Retry-After": "120"],
            body: Data()
        )
        defer { RateLimitFetcherStubURLProtocol.response = nil }

        let fetcher = RateLimitFetcher(session: URLSession(configuration: config))
        let result = await fetcher.fetchClaudeOAuthUsage(accessToken: "access-token")

        switch result {
        case .failure(let diagnostic):
            #expect(diagnostic.httpStatusCode == 429)
            #expect(diagnostic.retryAfter == 120)
        default:
            #expect(Bool(false))
        }
    }

    @Test
    func parsesClaudeOAuthUsageQuotaWindows() throws {
        let payload = Data("""
        {
          "five_hour": {
            "utilization": 45.2,
            "resets_at": "2026-05-19T21:00:00Z",
            "is_enabled": true
          },
          "seven_day": {
            "utilization": 12.8,
            "resets_at": "2026-05-24T18:30:00Z",
            "is_enabled": true
          },
          "seven_day_sonnet": {
            "utilization": 5.1,
            "resets_at": "2026-05-24T18:30:00Z",
            "is_enabled": true
          }
        }
        """.utf8)

        let info = try #require(RateLimitFetcher.parseClaudeOAuthUsage(payload))

        #expect(info.planType == "claude")
        #expect(info.weeklyUsedPercent == 13)
        #expect(info.weeklyRemainingPercent == 87)
        #expect(info.fiveHourRemainingPercent == 55)
        #expect(info.additionalQuotaWindows == [
            RateLimitQuotaWindow(
                key: "seven_day_sonnet",
                usedPercent: 5,
                resetAt: ISO8601DateFormatter().date(from: "2026-05-24T18:30:00Z")
            )
        ])
        #expect(info.weeklyResetAt == ISO8601DateFormatter().date(from: "2026-05-24T18:30:00Z"))
        #expect(info.fiveHourResetAt == ISO8601DateFormatter().date(from: "2026-05-19T21:00:00Z"))
    }

    @Test
    func claudeOAuthUsageExhaustsOnModelSpecificQuota() throws {
        let payload = Data("""
        {
          "five_hour": {
            "utilization": 10,
            "resets_at": "2026-05-19T21:00:00Z",
            "is_enabled": true
          },
          "seven_day": {
            "utilization": 50,
            "resets_at": "2026-05-24T18:30:00Z",
            "is_enabled": true
          },
          "seven_day_sonnet": {
            "utilization": 100,
            "resets_at": "2026-05-24T18:30:00Z",
            "is_enabled": true
          },
          "seven_day_opus": {
            "utilization": 30,
            "resets_at": "2026-05-24T18:30:00Z",
            "is_enabled": true
          },
          "monthly_limit": {
            "utilization": 30,
            "resets_at": "2026-06-01T00:00:00Z",
            "is_enabled": true
          }
        }
        """.utf8)

        let info = try #require(RateLimitFetcher.parseClaudeOAuthUsage(payload))

        #expect(info.weeklyRemainingPercent == 50)
        #expect(info.fiveHourRemainingPercent == 90)
        #expect(info.limitReached)
        #expect(!info.allowed)
        #expect(info.additionalQuotaWindows.map(\.key) == ["seven_day_sonnet", "seven_day_opus", "monthly_limit"])
        #expect(info.additionalQuotaWindows.first?.remainingPercent == 0)
    }

    @Test
    func claudeOAuthUsageExhaustsOnOpusQuota() throws {
        let payload = Data("""
        {
          "seven_day": {
            "utilization": 20,
            "resets_at": "2026-05-24T18:30:00Z",
            "is_enabled": true
          },
          "seven_day_opus": {
            "utilization": 100,
            "resets_at": "2026-05-24T18:30:00Z",
            "is_enabled": true
          }
        }
        """.utf8)

        let info = try #require(RateLimitFetcher.parseClaudeOAuthUsage(payload))

        #expect(info.weeklyRemainingPercent == 80)
        #expect(info.additionalQuotaWindows.map(\.key) == ["seven_day_opus"])
        #expect(info.additionalQuotaWindows.first?.remainingPercent == 0)
        #expect(info.limitReached)
        #expect(!info.allowed)
    }

    @Test
    func ignoresUnknownClaudeOAuthUsageWindows() throws {
        let payload = Data("""
        {
          "seven_day": {
            "utilization": 20,
            "resets_at": "2026-05-24T18:30:00Z",
            "is_enabled": true
          },
          "seven_day_experimental": {
            "utilization": 100,
            "resets_at": "2026-05-24T18:30:00Z",
            "is_enabled": true
          }
        }
        """.utf8)

        let info = try #require(RateLimitFetcher.parseClaudeOAuthUsage(payload))

        #expect(info.weeklyRemainingPercent == 80)
        #expect(info.additionalQuotaWindows.isEmpty)
        #expect(!info.limitReached)
        #expect(info.allowed)
    }

    @Test
    func ignoresDisabledClaudeOAuthUsageWindows() throws {
        let payload = Data("""
        {
          "five_hour": {
            "utilization": 80,
            "resets_at": "2026-05-19T21:00:00Z",
            "is_enabled": false
          },
          "seven_day": null
        }
        """.utf8)

        let info = try #require(RateLimitFetcher.parseClaudeOAuthUsage(payload))

        #expect(info.weeklyUsedPercent == nil)
        #expect(info.fiveHourRemainingPercent == nil)
        #expect(info.additionalQuotaWindows.isEmpty)
        #expect(info.limitReached == false)
    }

    @Test
    func parsesClaudeOAuthRefreshTokenResponse() throws {
        let payload = Data("""
        {
          "token_type": "Bearer",
          "access_token": "new-access-token",
          "refresh_token": "new-refresh-token",
          "expires_in": 3600,
          "scope": "user:inference"
        }
        """.utf8)

        let tokens = try #require(RateLimitFetcher.parseClaudeOAuthTokenResponse(payload))

        #expect(tokens.accessToken == "new-access-token")
        #expect(tokens.refreshToken == "new-refresh-token")
        #expect(tokens.expiresIn == 3600)
    }
}

private final class RateLimitFetcherStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (statusCode: Int, headers: [String: String], body: Data)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let response = Self.response,
              let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
