import Foundation
import AppKit

private struct ClaudeUsageCredentials {
    let accessToken: String
    let refreshToken: String
    let credentialsData: Data
}

enum RateLimitRefreshGate {
    static func shouldContinueAfterCodexFailures(
        codexCredentialCount: Int,
        codexSuccessCount: Int,
        consecutiveFetchFailures: Int,
        attemptedProviders: Set<AIProvider>
    ) -> Bool {
        guard codexCredentialCount > 0,
              codexSuccessCount == 0,
              consecutiveFetchFailures >= 3 else { return true }
        return attemptedProviders.contains { $0 != .codex }
    }
}

enum ClaudeUsageRefreshPolicy {
    static func shouldRefreshAfterUsageResult(_ result: FetchResult) -> Bool {
        switch result {
        case .failure(let diagnostic):
            return diagnostic.httpStatusCode == 429 && diagnostic.retryAfter == nil
        case .stale(let diagnostic):
            return diagnostic.httpStatusCode == 401
        case .success:
            return false
        }
    }
}

enum ClaudeUsageBackoffPolicy {
    static func backoffDuration(after diagnostic: RateLimitFetchDiagnostic) -> TimeInterval? {
        if let retryAfter = diagnostic.retryAfter {
            return retryAfter
        }
        if diagnostic.httpStatusCode == 429 {
            return 30 * 60
        }
        return nil
    }
}

final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return snapshot
    }
}

enum ClaudeProcessProbe {
    static func isRunning(timeout: TimeInterval = 2) async -> Bool {
        await Task.detached(priority: .utility) {
            isRunningSynchronously(timeout: timeout)
        }.value
    }

    private static func isRunningSynchronously(timeout: TimeInterval) -> Bool {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,comm=,args="]
        task.standardOutput = pipe
        task.standardError = nil
        do {
            try task.run()
            let exited = DispatchSemaphore(value: 0)
            let output = LockedDataBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                output.append(chunk)
            }
            DispatchQueue.global(qos: .utility).async {
                task.waitUntilExit()
                exited.signal()
            }
            guard exited.wait(timeout: .now() + timeout) == .success else {
                pipe.fileHandleForReading.readabilityHandler = nil
                task.terminate()
                _ = exited.wait(timeout: .now() + 1)
                return false
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            guard task.terminationStatus == 0 else { return false }
            output.append(pipe.fileHandleForReading.readDataToEndOfFile())
            let data = output.snapshot()
            let processList = String(data: data, encoding: .utf8) ?? ""
            return ClaudeProcessDetector.containsRunningSession(in: processList)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return false
        }
    }
}

// MARK: - Rate Limit Polling & Fetch

extension AppStore {

    func startRateLimitPolling() {
        Task { await fetchAllRateLimits(showSpinner: false) }
        rateLimitTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.fetchAllRateLimits(showSpinner: false) }
        }
    }

    func fetchAllRateLimits(showSpinner: Bool = true) async {
        if showSpinner { isFetchingLimits = true }
        defer { if showSpinner { isFetchingLimits = false } }

        let fetcher = self.fetcher
        let activeProfileId = activeProfile(for: .codex)?.id
        let providerById = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.provider) })
        let codexCredPairs: [(UUID, AuthCredentials)] = profiles.compactMap { profile in
            guard profile.provider == .codex else { return nil }
            let dict: [String: Any]?
            if profile.id == activeProfileId,
               let liveDict = profileManager.readLiveAuthDict() {
                dict = liveDict
            } else {
                dict = profileManager.readAuthDict(for: profile)
            }
            guard let dict,
                  let creds = fetcher.credentials(from: dict) else { return nil }
            return (profile.id, creds)
        }
        let now = Date()
        var claudeCredentialsById: [UUID: ClaudeUsageCredentials] = [:]
        let claudeCredPairs: [(UUID, String)] = profiles.compactMap { profile in
            guard profile.provider == .claude else { return nil }
            if let backoffUntil = claudeUsageBackoffUntil[profile.id], backoffUntil > now {
                return nil
            }
            let isActiveClaudeProfile = profile.id == activeProfile(for: .claude)?.id
            guard let data = profileManager.readClaudeUsageCredentialsData(for: profile, isActive: isActiveClaudeProfile),
                  let accessToken = ClaudeCodeManager.oauthAccessToken(from: data),
                  !accessToken.isEmpty else { return nil }
            let refreshToken = ClaudeCodeManager.oauthRefreshToken(from: data) ?? ""
            claudeCredentialsById[profile.id] = ClaudeUsageCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                credentialsData: data
            )
            return (profile.id, accessToken)
        }

        var results: [(UUID, FetchResult)] = []
        await withTaskGroup(of: (UUID, FetchResult).self) { group in
            for (id, creds) in codexCredPairs {
                group.addTask {
                    let result = await fetcher.fetch(credentials: creds)
                    return (id, result)
                }
            }
            for (id, accessToken) in claudeCredPairs {
                group.addTask {
                    let result = await fetcher.fetchClaudeOAuthUsage(accessToken: accessToken)
                    return (id, result)
                }
            }
            for await pair in group { results.append(pair) }
        }

        let attemptedProviders = Set(results.compactMap { providerById[$0.0] })
        var newStaleByProvider: [AIProvider: Set<UUID>] = [:]
        var codexSuccessCount = 0
        for (id, result) in results {
            let provider = providerById[id] ?? .codex
            let effectiveResult: FetchResult
            if provider == .claude,
               ClaudeUsageRefreshPolicy.shouldRefreshAfterUsageResult(result),
               let diagnostic = claudeRefreshableDiagnostic(from: result),
               let credentials = claudeCredentialsById[id] {
                effectiveResult = await refreshAndRetryClaudeUsage(
                    profileId: id,
                    credentials: credentials,
                    originalDiagnostic: diagnostic
                )
            } else {
                effectiveResult = result
            }

            switch effectiveResult {
            case .success(let info, let diagnostic):
                rateLimits[id] = info
                appendRateLimitAuditSample(for: id, info: info, checkedAt: diagnostic.checkedAt)
                if provider == .codex { codexSuccessCount += 1 }
                if provider == .claude { claudeUsageBackoffUntil[id] = nil }
                let previous = rateLimitHealth[id] ?? RateLimitHealthStatus()
                rateLimitHealth[id] = RateLimitHealthStatus(
                    lastCheckedAt: diagnostic.checkedAt,
                    lastSuccessfulFetchAt: diagnostic.checkedAt,
                    lastFailedFetchAt: previous.lastFailedFetchAt,
                    lastHTTPStatusCode: diagnostic.httpStatusCode,
                    staleReason: nil,
                    failureSummary: nil
                )
                let profileName = profiles.first(where: { $0.id == id })?.displayName ?? L("Hesap", "Account")
                if lastKnownLimitState[id] == true, info.limitReached == false {
                    sendNotification(
                        title: L("Limit sıfırlandı", "Limit reset"),
                        body: L("\(profileName) kullanıma hazır", "\(profileName) is ready to use again")
                    )
                    warned80PercentIds.remove(id)
                }
                lastKnownLimitState[id] = info.limitReached
                if provider == .codex,
                   let used = info.weeklyUsedPercent,
                   used >= 80, !info.limitReached,
                   !warned80PercentIds.contains(id) {
                    warned80PercentIds.insert(id)
                    sendNotification(
                        title: L("Limit uyarısı", "Limit warning"),
                        body: L("\(profileName) haftalık limitinin %\(100 - used)'i kaldı", "\(profileName) has \(100 - used)% weekly limit remaining")
                    )
                }
            case .stale(let diagnostic):
                newStaleByProvider[provider, default: []].insert(id)
                let previous = rateLimitHealth[id] ?? RateLimitHealthStatus()
                rateLimitHealth[id] = RateLimitHealthStatus(
                    lastCheckedAt: diagnostic.checkedAt,
                    lastSuccessfulFetchAt: previous.lastSuccessfulFetchAt,
                    lastFailedFetchAt: diagnostic.checkedAt,
                    lastHTTPStatusCode: diagnostic.httpStatusCode,
                    staleReason: diagnostic.staleReason,
                    failureSummary: diagnostic.failureSummary
                )
            case .failure(let diagnostic):
                if provider == .claude,
                   let backoffDuration = ClaudeUsageBackoffPolicy.backoffDuration(after: diagnostic) {
                    let existingBackoff = claudeUsageBackoffUntil[id]
                    if existingBackoff == nil || existingBackoff ?? .distantPast <= diagnostic.checkedAt {
                        claudeUsageBackoffUntil[id] = diagnostic.checkedAt.addingTimeInterval(backoffDuration)
                    }
                }
                let previous = rateLimitHealth[id] ?? RateLimitHealthStatus()
                rateLimitHealth[id] = RateLimitHealthStatus(
                    lastCheckedAt: diagnostic.checkedAt,
                    lastSuccessfulFetchAt: previous.lastSuccessfulFetchAt,
                    lastFailedFetchAt: diagnostic.checkedAt,
                    lastHTTPStatusCode: diagnostic.httpStatusCode,
                    staleReason: nil,
                    failureSummary: diagnostic.failureSummary
                )
            }
        }

        if codexSuccessCount == 0, !codexCredPairs.isEmpty {
            consecutiveFetchFailures += 1
            if !RateLimitRefreshGate.shouldContinueAfterCodexFailures(
                codexCredentialCount: codexCredPairs.count,
                codexSuccessCount: codexSuccessCount,
                consecutiveFetchFailures: consecutiveFetchFailures,
                attemptedProviders: attemptedProviders
            ) {
                return
            }
        } else {
            consecutiveFetchFailures = 0
        }

        var updatedStale = staleProfileIds
        for provider in attemptedProviders {
            updatedStale = ProviderStaleProfiles.replacingProviderStale(
                existing: updatedStale,
                profiles: profiles,
                provider: provider,
                with: newStaleByProvider[provider] ?? []
            )
        }
        staleProfileIds = updatedStale
        for provider in attemptedProviders where isAllExhausted(provider: provider) {
            let evaluation = makeSwitchReadinessEvaluation(provider: provider)
            if evaluation.candidates.contains(where: { $0.status == .ready }) {
                clearAllExhausted(provider: provider)
            }
        }
        refreshReliabilityAnalytics()
        NotificationCenter.default.post(name: .rateLimitsUpdated, object: nil)
        await evaluateAutomaticSwitchAfterRateLimitRefresh()
        refreshTokenUsage()
    }

    func appendRateLimitAuditSample(for profileId: UUID, info: RateLimitInfo, checkedAt: Date) {
        let sample = RateLimitAuditSample(
            timestamp: checkedAt,
            weeklyRemainingPercent: info.weeklyRemainingPercent,
            fiveHourRemainingPercent: info.fiveHourRemainingPercent,
            limitReached: info.limitReached
        )
        var samples = rateLimitAuditSamples[profileId] ?? []
        if let last = samples.last,
           last.weeklyRemainingPercent == sample.weeklyRemainingPercent,
           last.fiveHourRemainingPercent == sample.fiveHourRemainingPercent,
           last.limitReached == sample.limitReached,
           checkedAt.timeIntervalSince(last.timestamp) < 60 {
            return
        }
        samples.append(sample)
        if samples.count > 240 { samples.removeFirst(samples.count - 240) }
        rateLimitAuditSamples[profileId] = samples
    }

    private func claudeRefreshableDiagnostic(from result: FetchResult) -> RateLimitFetchDiagnostic? {
        switch result {
        case .failure(let diagnostic) where diagnostic.httpStatusCode == 429:
            return diagnostic
        case .stale(let diagnostic) where diagnostic.httpStatusCode == 401:
            return diagnostic
        default:
            return nil
        }
    }

    private func refreshAndRetryClaudeUsage(
        profileId: UUID,
        credentials: ClaudeUsageCredentials,
        originalDiagnostic: RateLimitFetchDiagnostic
    ) async -> FetchResult {
        guard !credentials.refreshToken.isEmpty else {
            return .failure(originalDiagnostic)
        }

        if activeProfile(for: .claude)?.id == profileId, await isClaudeCodeProcessRunning() {
            return .failure(
                RateLimitFetchDiagnostic(
                    checkedAt: originalDiagnostic.checkedAt,
                    httpStatusCode: nil,
                    staleReason: nil,
                    failureSummary: L(
                        "Claude çalışırken OAuth yenileme atlandı",
                        "Skipped OAuth refresh while Claude is running"
                    ),
                    retryAfter: originalDiagnostic.retryAfter
                )
            )
        }

        switch await fetcher.refreshClaudeOAuthToken(refreshToken: credentials.refreshToken) {
        case .success(let tokens):
            guard let updatedData = ClaudeCodeManager.updatingOAuthTokens(
                in: credentials.credentialsData,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                expiresIn: tokens.expiresIn
            ),
            let profile = profiles.first(where: { $0.id == profileId }) else {
                return .failure(
                    RateLimitFetchDiagnostic(
                        checkedAt: Date(),
                        httpStatusCode: nil,
                        staleReason: nil,
                        failureSummary: "OAuth credentials could not be updated"
                    )
                )
            }

            if !profileManager.writeClaudeCredentialsData(updatedData, for: profile) {
                return .failure(
                    RateLimitFetchDiagnostic(
                        checkedAt: Date(),
                        httpStatusCode: nil,
                        staleReason: nil,
                        failureSummary: "OAuth refreshed but profile credential update failed"
                    )
                )
            }

            return await fetcher.fetchClaudeOAuthUsage(accessToken: tokens.accessToken)
        case .rateLimited(let retryAfter):
            let checkedAt = Date()
            claudeUsageBackoffUntil[profileId] = checkedAt.addingTimeInterval(retryAfter ?? 30 * 60)
            return .failure(
                RateLimitFetchDiagnostic(
                    checkedAt: checkedAt,
                    httpStatusCode: 429,
                    staleReason: nil,
                    failureSummary: "OAuth refresh HTTP 429",
                    retryAfter: retryAfter
                )
            )
        case .invalidGrant(let description):
            return .stale(
                RateLimitFetchDiagnostic(
                    checkedAt: Date(),
                    httpStatusCode: nil,
                    staleReason: .invalidAuth,
                    failureSummary: description ?? "OAuth refresh token invalid"
                )
            )
        case .failure(let statusCode, let summary):
            return .failure(
                RateLimitFetchDiagnostic(
                    checkedAt: Date(),
                    httpStatusCode: statusCode,
                    staleReason: nil,
                    failureSummary: summary
                )
            )
        }
    }

    func isClaudeCodeProcessRunning() async -> Bool {
        await ClaudeProcessProbe.isRunning()
    }
}

enum ClaudeProcessDetector {
    static func containsRunningSession(in processList: String) -> Bool {
        processList
            .split(separator: "\n", omittingEmptySubsequences: true)
            .contains { line in
                guard let process = parseProcessLine(String(line)) else { return false }
                return isSessionProcess(command: process.command, arguments: process.arguments)
            }
    }

    static func isSessionProcess(command: String, arguments: String) -> Bool {
        let tokens = arguments
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard let firstExecutable = tokens.first else { return false }

        let commandName = basename(command)
        let firstExecutableName = basename(firstExecutable)
        let secondExecutableName = tokens.dropFirst().first.map(basename)

        let launchedClaudeDirectly = commandName == "claude" || firstExecutableName == "claude"
        let launchedClaudeThroughRuntime = ["node", "bun"].contains(firstExecutableName)
            && secondExecutableName == "claude"
        guard launchedClaudeDirectly || launchedClaudeThroughRuntime else { return false }

        let claudeArguments = launchedClaudeThroughRuntime ? tokens.dropFirst(2) : tokens.dropFirst()
        return claudeArguments.first != "auth"
    }

    private static func parseProcessLine(_ line: String) -> (command: String, arguments: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pidEnd = trimmed.firstIndex(where: \.isWhitespace) else { return nil }
        let withoutPID = trimmed[pidEnd...].trimmingCharacters(in: .whitespaces)
        guard let commandEnd = withoutPID.firstIndex(where: \.isWhitespace) else { return nil }
        let command = String(withoutPID[..<commandEnd])
        let arguments = withoutPID[commandEnd...].trimmingCharacters(in: .whitespaces)
        return (command, arguments)
    }

    private static func basename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

enum ProviderStaleProfiles {
    static func replacingProviderStale(
        existing: Set<UUID>,
        profiles: [Profile],
        provider: AIProvider,
        with providerStale: Set<UUID>
    ) -> Set<UUID> {
        let providerProfileIds = Set(profiles.filter { $0.provider == provider }.map(\.id))
        return existing.subtracting(providerProfileIds).union(providerStale)
    }
}
