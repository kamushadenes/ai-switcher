import Foundation

struct AuthCredentials: Sendable {
    let accessToken: String
    let accountId: String
}

struct RateLimitFetchDiagnostic: Sendable {
    let checkedAt: Date
    let httpStatusCode: Int?
    let staleReason: RateLimitStaleReason?
    let failureSummary: String?
    let retryAfter: TimeInterval?

    init(
        checkedAt: Date,
        httpStatusCode: Int?,
        staleReason: RateLimitStaleReason?,
        failureSummary: String?,
        retryAfter: TimeInterval? = nil
    ) {
        self.checkedAt = checkedAt
        self.httpStatusCode = httpStatusCode
        self.staleReason = staleReason
        self.failureSummary = failureSummary
        self.retryAfter = retryAfter
    }
}

struct RateLimitInfo: Sendable {
    var planType: String = "free"
    var allowed: Bool = true
    var limitReached: Bool = false

    // Haftalık kullanım (used %) — bar dolunca tükeniyor
    var weeklyUsedPercent: Int?
    var weeklyResetAt: Date?

    // 5 saatlik kalan (remaining %) — Codex IDE ile aynı format
    // 100 = tam dolu (iyi), 0 = tükenmiş
    var fiveHourRemainingPercent: Int?
    var fiveHourResetAt: Date?
    var additionalQuotaWindows: [RateLimitQuotaWindow] = []

    /// Gösterim için kalan haftalık % (Codex IDE formatı)
    var weeklyRemainingPercent: Int? {
        weeklyUsedPercent.map { max(0, 100 - $0) }
    }

    var isPlus: Bool {
        let freeNames = ["free", "guest", ""]
        return !freeNames.contains(planType.lowercased())
    }

    var weeklyResetLabel: String {
        guard let date = weeklyResetAt else { return "" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "tr_TR")
        fmt.dateFormat = "d MMM"
        return fmt.string(from: date)
    }

    var fiveHourResetLabel: String {
        guard let date = fiveHourResetAt else { return "" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "tr_TR")
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}

struct RateLimitQuotaWindow: Sendable, Equatable {
    let key: String
    let usedPercent: Int
    let resetAt: Date?

    var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }

    var resetLabel: String {
        guard let resetAt else { return "" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "tr_TR")
        fmt.dateFormat = "d MMM"
        return fmt.string(from: resetAt)
    }
}

enum FetchResult: Sendable {
    case success(RateLimitInfo, RateLimitFetchDiagnostic)
    case stale(RateLimitFetchDiagnostic)
    case failure(RateLimitFetchDiagnostic)
}

struct ClaudeOAuthTokens: Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

enum ClaudeOAuthRefreshResult: Sendable {
    case success(ClaudeOAuthTokens)
    case rateLimited(TimeInterval?)
    case invalidGrant(String?)
    case failure(Int?, String)
}

final class RateLimitFetcher: @unchecked Sendable {

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }

    private let session: URLSession

    init(session: URLSession = RateLimitFetcher.makeDefaultSession()) {
        self.session = session
    }

    func credentials(from authDict: [String: Any]) -> AuthCredentials? {
        guard let tokens = authDict["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else { return nil }
        return AuthCredentials(accessToken: access, accountId: tokens["account_id"] as? String ?? "")
    }

    func fetch(credentials: AuthCredentials) async -> FetchResult {
        let checkedAt = Date()
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(credentials.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            print("[RateLimit] fetch error for \(credentials.accountId): \(error)")
            return .failure(
                RateLimitFetchDiagnostic(
                    checkedAt: checkedAt,
                    httpStatusCode: nil,
                    staleReason: nil,
                    failureSummary: error.localizedDescription
                )
            )
        }

        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 0

        switch statusCode {
        case 200:
            guard let info = parse(data) else {
                return .failure(
                    RateLimitFetchDiagnostic(
                        checkedAt: checkedAt,
                        httpStatusCode: statusCode,
                        staleReason: nil,
                        failureSummary: "Invalid usage payload"
                    )
                )
            }
            return .success(
                info,
                RateLimitFetchDiagnostic(
                    checkedAt: checkedAt,
                    httpStatusCode: statusCode,
                    staleReason: nil,
                    failureSummary: nil
                )
            )
        case 401, 403:
            return .stale(
                RateLimitFetchDiagnostic(
                    checkedAt: checkedAt,
                    httpStatusCode: statusCode,
                    staleReason: statusCode == 401 ? .unauthorized : .forbidden,
                    failureSummary: nil
                )
            )
        case 429:
            return .failure(
                RateLimitFetchDiagnostic(
                    checkedAt: checkedAt,
                    httpStatusCode: statusCode,
                    staleReason: nil,
                    failureSummary: "HTTP \(statusCode)",
                    retryAfter: Self.retryAfter(from: http?.value(forHTTPHeaderField: "Retry-After"))
                )
            )
        default:
            return .failure(
                RateLimitFetchDiagnostic(
                    checkedAt: checkedAt,
                    httpStatusCode: statusCode,
                    staleReason: nil,
                    failureSummary: "HTTP \(statusCode)"
                )
            )
        }
    }

    func fetchClaudeOAuthUsage(accessToken: String) async -> FetchResult {
        let checkedAt = Date()
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1.143", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            print("[RateLimit] Claude usage fetch error: \(error)")
            return .failure(
                RateLimitFetchDiagnostic(
                    checkedAt: checkedAt,
                    httpStatusCode: nil,
                    staleReason: nil,
                    failureSummary: error.localizedDescription
                )
            )
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        switch statusCode {
        case 200:
            guard let info = Self.parseClaudeOAuthUsage(data) else {
                return .failure(
                    RateLimitFetchDiagnostic(
                        checkedAt: checkedAt,
                        httpStatusCode: statusCode,
                        staleReason: nil,
                        failureSummary: "Invalid Claude usage payload"
                    )
                )
            }
            return .success(
                info,
                RateLimitFetchDiagnostic(
                    checkedAt: checkedAt,
                    httpStatusCode: statusCode,
                    staleReason: nil,
                    failureSummary: nil
                )
            )
        case 401, 403:
            return .stale(
                RateLimitFetchDiagnostic(
                    checkedAt: checkedAt,
                    httpStatusCode: statusCode,
                    staleReason: statusCode == 401 ? .unauthorized : .forbidden,
                    failureSummary: nil
                )
            )
        case 429:
            return .failure(
                RateLimitFetchDiagnostic(
                    checkedAt: checkedAt,
                    httpStatusCode: statusCode,
                    staleReason: nil,
                    failureSummary: "HTTP 429",
                    retryAfter: Self.retryAfter(from: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"))
                )
            )
        default:
            return .failure(
                RateLimitFetchDiagnostic(
                    checkedAt: checkedAt,
                    httpStatusCode: statusCode,
                    staleReason: nil,
                    failureSummary: "HTTP \(statusCode)"
                )
            )
        }
    }

    func refreshClaudeOAuthToken(refreshToken: String) async -> ClaudeOAuthRefreshResult {
        var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-code/2.1.143", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(nil, "Invalid OAuth refresh request")
        }
        req.httpBody = bodyData

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            return .failure(nil, error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 0
        switch statusCode {
        case 200:
            guard let tokens = Self.parseClaudeOAuthTokenResponse(data) else {
                return .failure(statusCode, "Invalid OAuth refresh payload")
            }
            return .success(tokens)
        case 429:
            return .rateLimited(Self.retryAfter(from: http?.value(forHTTPHeaderField: "Retry-After")))
        default:
            if let error = Self.parseOAuthError(data), error.error == "invalid_grant" {
                return .invalidGrant(error.description)
            }
            return .failure(statusCode, "OAuth refresh HTTP \(statusCode)")
        }
    }

    static func parseClaudeOAuthTokenResponse(_ data: Data) -> ClaudeOAuthTokens? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              !accessToken.isEmpty,
              !refreshToken.isEmpty else { return nil }
        let expiresIn = (json["expires_in"] as? Int)
            ?? (json["expires_in"] as? Double).map { Int($0) }
            ?? 0
        return ClaudeOAuthTokens(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn)
    }

    static func parseClaudeOAuthUsage(_ data: Data) -> RateLimitInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var info = RateLimitInfo()
        info.planType = "claude"
        let quotas = activeClaudeQuotas(in: json)

        if let weekly = quotas["seven_day"] {
            info.weeklyUsedPercent = percentage(weekly["utilization"])
            info.weeklyResetAt = isoDate(weekly["resets_at"])
        }

        if let fiveHour = quotas["five_hour"],
           let used = percentage(fiveHour["utilization"]) {
            info.fiveHourRemainingPercent = max(0, 100 - used)
            info.fiveHourResetAt = isoDate(fiveHour["resets_at"])
        }

        info.additionalQuotaWindows = quotas
            .filter { key, _ in key != "seven_day" && key != "five_hour" }
            .compactMap { key, quota in
                guard let used = percentage(quota["utilization"]) else { return nil }
                return RateLimitQuotaWindow(
                    key: key,
                    usedPercent: used,
                    resetAt: isoDate(quota["resets_at"])
                )
            }
            .sorted { lhs, rhs in
                let priority = ["seven_day_sonnet": 0, "seven_day_opus": 1, "monthly_limit": 2, "extra_usage": 3]
                return (priority[lhs.key] ?? 100, lhs.key) < (priority[rhs.key] ?? 100, rhs.key)
            }

        info.limitReached = quotas.values.contains { quota in
            (percentage(quota["utilization"]) ?? 0) >= 100
        }
        info.allowed = !info.limitReached
        return info
    }

    private func parse(_ data: Data) -> RateLimitInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var info = RateLimitInfo()
        info.planType = json["plan_type"] as? String ?? "free"

        guard let rl = json["rate_limit"] as? [String: Any] else { return info }

        info.allowed      = rl["allowed"]       as? Bool ?? true
        info.limitReached = rl["limit_reached"] as? Bool ?? false

        let pw = rl["primary_window"]   as? [String: Any]
        let sw = rl["secondary_window"] as? [String: Any]

        // Pencereleri limit_window_seconds'a göre sınıflandır (CodexBar yaklaşımı)
        // 18000s = 5 saat (session penceresi), 604800s = 7 gün (haftalık pencere)
        // Bu sayede API primary/secondary sıralaması değişse bile doğru çalışır
        let fiveHourMaxSec = 21600  // 6 saat — 5h window için üst eşik

        let (fiveHourWindow, weeklyWindow) = classifyWindows(pw: pw, sw: sw, fiveHourMaxSec: fiveHourMaxSec)

        if let w = weeklyWindow {
            info.weeklyUsedPercent = intVal(w["used_percent"])
            info.weeklyResetAt     = dateVal(w["reset_at"])
        }

        if let h = fiveHourWindow, let used = intVal(h["used_percent"]) {
            info.fiveHourRemainingPercent = max(0, 100 - used)
            info.fiveHourResetAt          = dateVal(h["reset_at"])
        }

        return info
    }

    /// limit_window_seconds değerine bakarak hangi pencere 5h, hangisi haftalık olduğunu belirler.
    private func classifyWindows(
        pw: [String: Any]?,
        sw: [String: Any]?,
        fiveHourMaxSec: Int
    ) -> (fiveHour: [String: Any]?, weekly: [String: Any]?) {
        guard let pw = pw else {
            // Sadece secondary varsa
            guard let sw = sw else { return (nil, nil) }
            let sec = intVal(sw["limit_window_seconds"]) ?? 0
            return sec <= fiveHourMaxSec ? (sw, nil) : (nil, sw)
        }
        guard let sw = sw else {
            // Sadece primary varsa
            let sec = intVal(pw["limit_window_seconds"]) ?? 0
            return sec <= fiveHourMaxSec ? (pw, nil) : (nil, pw)
        }
        // Her ikisi de var — duration'a göre ayırt et
        let pwSec = intVal(pw["limit_window_seconds"]) ?? 0
        let swSec = intVal(sw["limit_window_seconds"]) ?? 0
        if pwSec <= fiveHourMaxSec && swSec > fiveHourMaxSec {
            return (pw, sw)
        } else if swSec <= fiveHourMaxSec && pwSec > fiveHourMaxSec {
            return (sw, pw)
        } else {
            // Duration'dan ayırt edilemiyorsa: position'a göre (varsayılan davranış)
            return (pw, sw)
        }
    }

    /// JSON sayısı Int veya Double olabilir.
    private func intVal(_ v: Any?) -> Int? {
        guard let v else { return nil }
        if let i = v as? Int    { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    /// Unix timestamp → Date (Int veya Double).
    private func dateVal(_ v: Any?) -> Date? {
        guard let v else { return nil }
        if let d = v as? Double { return Date(timeIntervalSince1970: d) }
        if let i = v as? Int    { return Date(timeIntervalSince1970: Double(i)) }
        return nil
    }

    private static func activeClaudeQuotas(in json: [String: Any]) -> [String: [String: Any]] {
        let knownQuotaKeys: Set<String> = [
            "five_hour",
            "seven_day",
            "seven_day_sonnet",
            "seven_day_opus",
            "monthly_limit",
            "extra_usage"
        ]
        var quotas: [String: [String: Any]] = [:]
        for (key, value) in json where knownQuotaKeys.contains(key) {
            guard let quota = value as? [String: Any] else { continue }
            if let isEnabled = quota["is_enabled"] as? Bool, !isEnabled { continue }
            guard quota["utilization"] != nil else { continue }
            quotas[key] = quota
        }
        return quotas
    }

    private static func percentage(_ value: Any?) -> Int? {
        let raw: Double?
        if let int = value as? Int {
            raw = Double(int)
        } else if let double = value as? Double {
            raw = double
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        return max(0, min(100, Int(raw.rounded())))
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }

        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: raw) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
    }

    private static func retryAfter(from value: String?) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private static func parseOAuthError(_ data: Data) -> (error: String, description: String?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? String else { return nil }
        return (error, json["error_description"] as? String)
    }
}
