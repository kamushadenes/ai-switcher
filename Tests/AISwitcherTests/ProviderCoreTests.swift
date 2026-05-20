import Foundation
import Testing
@testable import AISwitcher

struct ProviderCoreTests {
    @Test
    func decodesKnownLegacyAndUnknownProviders() throws {
        let decoder = JSONDecoder()

        let codex = try decoder.decode(AIProvider.self, from: Data(#""codex""#.utf8))
        let claude = try decoder.decode(AIProvider.self, from: Data(#""claude""#.utf8))
        let legacyClaude = try decoder.decode(AIProvider.self, from: Data(#""claudeCode""#.utf8))
        let unknown = try decoder.decode(AIProvider.self, from: Data(#""futureProvider""#.utf8))

        #expect(codex == .codex)
        #expect(claude == .claude)
        #expect(legacyClaude == .claude)
        #expect(unknown == .codex)
    }

    @Test
    func profileInitializerPreservesProvider() {
        let profile = Profile(
            alias: "Claude",
            email: "dev@example.com",
            accountId: "org-123",
            addedAt: Date(timeIntervalSince1970: 1_760_000_000),
            aiProvider: .claude
        )

        #expect(profile.provider == .claude)
    }

    @Test
    func appConfigPersistsOneActiveProfilePerProvider() throws {
        let codex = Profile(
            alias: "Codex",
            email: "codex@example.com",
            accountId: "acct-codex",
            addedAt: Date(timeIntervalSince1970: 1_760_000_000),
            aiProvider: .codex
        )
        let claude = Profile(
            alias: "Claude",
            email: "claude@example.com",
            accountId: "org-claude",
            addedAt: Date(timeIntervalSince1970: 1_760_000_100),
            aiProvider: .claude
        )
        let config = AppConfig(
            profiles: [codex, claude],
            activeProfileId: nil,
            activeProfileIdsByProvider: [.codex: codex.id, .claude: claude.id],
            selectedProvider: .claude,
            roundRobinIndex: 0
        )

        #expect(config.activeProfileId == claude.id)

        let data = try JSONEncoder().encode(config)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains(#""codex""#))
        #expect(json.contains(#""claude""#))

        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.activeProfileIdsByProvider[.codex] == codex.id)
        #expect(decoded.activeProfileIdsByProvider[.claude] == claude.id)
        #expect(decoded.selectedProvider == .claude)
        #expect(decoded.activeProfileId == claude.id)
    }

    @Test
    func freshDefaultDataPathDoesNotUseLegacySwitcherDirectory() {
        #expect(ProfileManager.switcherDir.path.hasSuffix(".ai-switcher"))
        #expect(ProfileManager.configPath.path.hasSuffix(".ai-switcher/config.json"))
        #expect(!ProfileManager.switcherDir.path.contains(".codex-switcher"))
        #expect(!ProfileManager.configPath.path.contains(".codex-switcher"))
    }

    @Test
    func statisticsResetDeletesProviderSessionCaches() {
        #expect(StatisticsResetCacheFiles.names.contains("event-deltas-v2.json"))
        #expect(StatisticsResetCacheFiles.names.contains("session-meta-v3.json"))
        #expect(StatisticsResetCacheFiles.names.contains("session-meta-v3.mod"))
        #expect(StatisticsResetCacheFiles.names.contains("claude-session-meta-v2.json"))
        #expect(StatisticsResetCacheFiles.names.contains("claude-session-meta-v2.mod"))
    }

    @Test
    func claudeProcessDetectorIgnoresShellTextAndAuthCommands() {
        #expect(ClaudeProcessDetector.isSessionProcess(
            command: "/etc/profiles/per-user/example/bin/zsh",
            arguments: "zsh -c source ~/.claude/env && ps -axo pid=,comm=,args="
        ) == false)
        #expect(ClaudeProcessDetector.isSessionProcess(
            command: "/Users/example/.local/bin/claude",
            arguments: "/Users/example/.local/bin/claude auth login"
        ) == false)
        #expect(ClaudeProcessDetector.isSessionProcess(
            command: "/Users/example/.local/bin/claude",
            arguments: "/Users/example/.local/bin/claude"
        ))
        #expect(ClaudeProcessDetector.isSessionProcess(
            command: "/usr/local/bin/node",
            arguments: "node /opt/homebrew/bin/claude --model sonnet"
        ))
    }

    @Test
    func claudeProcessDetectorParsesProcessList() {
        let processList = """
        18011 /etc/profiles/pe /etc/profiles/per-user/example/bin/zsh -c rg claude
        18029 rg               rg claude
        63019 /Users/example/. /Users/example/.local/bin/claude auth login
        73000 /Users/example/. /Users/example/.local/bin/claude --model sonnet
        """

        #expect(ClaudeProcessDetector.containsRunningSession(in: processList))
    }

    @Test
    func activationInProgressGateRunsClaudeOffMainAndBlocksDuplicates() {
        let profileId = UUID()
        var active: Set<UUID> = []

        #expect(ActivationInProgressGate.shouldRunOffMain(provider: .claude))
        #expect(!ActivationInProgressGate.shouldRunOffMain(provider: .codex))
        #expect(ActivationInProgressGate.begin(profileId: profileId, active: &active))
        #expect(!ActivationInProgressGate.begin(profileId: profileId, active: &active))

        ActivationInProgressGate.finish(profileId: profileId, active: &active)

        #expect(ActivationInProgressGate.begin(profileId: profileId, active: &active))
    }

    @Test
    func activationFailureRetryPolicyDoesNotRetryClaudeOnMain() {
        #expect(ActivationFailureRetryPolicy.shouldRetrySynchronously(provider: .codex))
        #expect(!ActivationFailureRetryPolicy.shouldRetrySynchronously(provider: .claude))
    }

    @Test
    func providerReorderMovesDownOneSlotWithoutOvershooting() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let a = Profile(alias: "A", email: "a@example.com", accountId: "a", addedAt: now)
        let b = Profile(alias: "B", email: "b@example.com", accountId: "b", addedAt: now)
        let c = Profile(alias: "C", email: "c@example.com", accountId: "c", addedAt: now)

        let reordered = ProfileOrdering.reordered(
            [a, b, c],
            moving: a.id,
            toProviderDestinationIndex: 2
        )

        #expect(reordered.map(\.id) == [b.id, a.id, c.id])
    }

    @Test
    func providerReorderKeepsOtherProvidersInPlace() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let claude = Profile(alias: "Claude", email: "claude@example.com", accountId: "claude", addedAt: now, aiProvider: .claude)
        let a = Profile(alias: "A", email: "a@example.com", accountId: "a", addedAt: now)
        let b = Profile(alias: "B", email: "b@example.com", accountId: "b", addedAt: now)
        let c = Profile(alias: "C", email: "c@example.com", accountId: "c", addedAt: now)

        let reordered = ProfileOrdering.reordered(
            [claude, a, b, c],
            moving: a.id,
            toProviderDestinationIndex: 2
        )

        #expect(reordered.map(\.id) == [claude.id, b.id, a.id, c.id])
    }

    @Test
    func deletingLastSelectedCodexAccountSelectsRemainingClaudeProvider() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let codex = Profile(alias: "Codex", email: "codex@example.com", accountId: "codex", addedAt: now)
        let claude = Profile(alias: "Claude", email: "claude@example.com", accountId: "claude", addedAt: now, aiProvider: .claude)
        let config = AppConfig(
            profiles: [codex, claude],
            activeProfileId: codex.id,
            activeProfileIdsByProvider: [.codex: codex.id, .claude: claude.id],
            selectedProvider: .codex,
            roundRobinIndex: 0
        )

        let plan = ProfileDeletion.planDeleting(codex, from: config)

        #expect(plan.config.selectedProvider == .claude)
        #expect(plan.config.activeProfileId == claude.id)
        #expect(plan.config.activeProfileIdsByProvider[.codex] == nil)
        #expect(plan.config.activeProfileIdsByProvider[.claude] == claude.id)
    }

    @Test
    func deletingActiveProviderAccountKeepsSelectedProviderWhenReplacementExists() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let active = Profile(alias: "A", email: "a@example.com", accountId: "a", addedAt: now)
        let replacement = Profile(alias: "B", email: "b@example.com", accountId: "b", addedAt: now)
        let config = AppConfig(
            profiles: [active, replacement],
            activeProfileId: active.id,
            activeProfileIdsByProvider: [.codex: active.id],
            selectedProvider: .codex,
            roundRobinIndex: 0
        )

        let plan = ProfileDeletion.planDeleting(active, from: config)

        #expect(plan.config.selectedProvider == .codex)
        #expect(plan.config.activeProfileId == replacement.id)
        #expect(plan.replacementActiveProfile?.id == replacement.id)
    }

    @Test
    func codexStaleRefreshPreservesClaudeStaleProfiles() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let staleCodex = Profile(alias: "Codex stale", email: "stale@example.com", accountId: "stale", addedAt: now)
        let freshCodex = Profile(alias: "Codex fresh", email: "fresh@example.com", accountId: "fresh", addedAt: now)
        let staleClaude = Profile(alias: "Claude stale", email: "claude@example.com", accountId: "claude", addedAt: now, aiProvider: .claude)

        let refreshed = ProviderStaleProfiles.replacingProviderStale(
            existing: [staleCodex.id, staleClaude.id],
            profiles: [staleCodex, freshCodex, staleClaude],
            provider: .codex,
            with: [freshCodex.id]
        )

        #expect(refreshed == [freshCodex.id, staleClaude.id])
    }

    @Test
    func cancellingClaudeAddRestoresClaudeActiveProfileWhenCodexIsSelected() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let codex = Profile(alias: "Codex", email: "codex@example.com", accountId: "codex", addedAt: now)
        let claude = Profile(alias: "Claude", email: "claude@example.com", accountId: "claude", addedAt: now, aiProvider: .claude)

        let restore = ProfileCancellationRestore.profileToRestore(
            pendingProvider: .claude,
            selectedActiveProfile: codex,
            profiles: [codex, claude],
            activeProfileIdsByProvider: [.codex: codex.id, .claude: claude.id]
        )

        #expect(restore?.id == claude.id)
    }

    @Test
    func inactiveClaudeReloginRestoresCurrentActiveClaudeProfile() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let active = Profile(alias: "Active", email: "active@example.com", accountId: "active", addedAt: now, aiProvider: .claude)
        let reloginTarget = Profile(alias: "Target", email: "target@example.com", accountId: "target", addedAt: now, aiProvider: .claude)

        let restore = ClaudeReloginRestore.profileToRestoreAfterRelogin(
            targetId: reloginTarget.id,
            matchedTarget: true,
            profiles: [active, reloginTarget],
            activeProfileIdsByProvider: [.claude: active.id]
        )

        #expect(restore?.id == active.id)
    }

    @Test
    func activeClaudeReloginDoesNotRestoreWhenTargetMatches() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let active = Profile(alias: "Active", email: "active@example.com", accountId: "active", addedAt: now, aiProvider: .claude)

        let restore = ClaudeReloginRestore.profileToRestoreAfterRelogin(
            targetId: active.id,
            matchedTarget: true,
            profiles: [active],
            activeProfileIdsByProvider: [.claude: active.id]
        )

        #expect(restore == nil)
    }

    @Test
    func automaticSwitchEvaluationChoosesClaudeWhenActiveClaudeIsExhausted() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let codex = Profile(alias: "Codex", email: "codex@example.com", accountId: "codex", addedAt: now)
        let claude = Profile(alias: "Claude", email: "claude@example.com", accountId: "claude", addedAt: now, aiProvider: .claude)
        let rateLimit = RateLimitInfo(
            planType: "claude",
            allowed: false,
            limitReached: true,
            weeklyUsedPercent: 100,
            weeklyResetAt: nil,
            fiveHourRemainingPercent: 0,
            fiveHourResetAt: nil
        )

        let candidate = AutomaticSwitchEvaluation.providerToSwitch(
            selectedProvider: .claude,
            activeProfileIdsByProvider: [.codex: codex.id, .claude: claude.id],
            rateLimits: [claude.id: rateLimit],
            policy: SwitchDecisionPolicy()
        )

        #expect(candidate?.provider == .claude)
    }

    @Test
    func automaticSwitchEvaluationSkipsOnlyExhaustedProvider() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let codex = Profile(alias: "Codex", email: "codex@example.com", accountId: "codex", addedAt: now)
        let claude = Profile(alias: "Claude", email: "claude@example.com", accountId: "claude", addedAt: now, aiProvider: .claude)
        let exhaustedRateLimit = RateLimitInfo(
            planType: "plus",
            allowed: false,
            limitReached: true,
            weeklyUsedPercent: 100,
            weeklyResetAt: nil,
            fiveHourRemainingPercent: 0,
            fiveHourResetAt: nil
        )

        let candidate = AutomaticSwitchEvaluation.providerToSwitch(
            selectedProvider: .claude,
            activeProfileIdsByProvider: [.codex: codex.id, .claude: claude.id],
            rateLimits: [codex.id: exhaustedRateLimit, claude.id: exhaustedRateLimit],
            exhaustedProviders: [.claude],
            policy: SwitchDecisionPolicy()
        )

        #expect(candidate?.provider == .codex)
    }

    @Test
    func automaticSwitchSessionGateDefersClaudeWhileClaudeProcessRuns() {
        #expect(AutomaticSwitchSessionGate.shouldDefer(
            provider: .claude,
            isCodexSessionActive: false,
            isClaudeProcessRunning: true
        ))
        #expect(!AutomaticSwitchSessionGate.shouldDefer(
            provider: .claude,
            isCodexSessionActive: true,
            isClaudeProcessRunning: false
        ))
    }

    @Test
    func automaticSwitchVerificationFailureRequiresMatchingProvider() {
        let attempt = SeamlessVerificationAttempt(
            targetProfileId: UUID(),
            targetProfileName: "Codex 2",
            provider: .codex,
            startedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )

        #expect(AutomaticSwitchVerificationGate.shouldFailVerification(candidateProvider: .codex, attempt: attempt))
        #expect(!AutomaticSwitchVerificationGate.shouldFailVerification(candidateProvider: .claude, attempt: attempt))
        #expect(!AutomaticSwitchVerificationGate.shouldFailVerification(candidateProvider: .codex, attempt: nil))
    }

    @Test
    func automaticSwitchCooldownCanBeScopedPerProvider() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let lastSwitchByProvider: [AIProvider: Date] = [.codex: now]
        let cooldown: TimeInterval = 60

        #expect(now.timeIntervalSince(lastSwitchByProvider[.codex] ?? .distantPast) < cooldown)
        #expect(now.timeIntervalSince(lastSwitchByProvider[.claude] ?? .distantPast) >= cooldown)
    }

    @Test
    func claudeHealthStateShowsExhaustedWhenClaudeLimitIsReached() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let claude = Profile(alias: "Claude", email: "claude@example.com", accountId: "claude", addedAt: now, aiProvider: .claude)
        let rateLimit = RateLimitInfo(
            planType: "claude",
            allowed: false,
            limitReached: true,
            weeklyUsedPercent: 100,
            weeklyResetAt: nil,
            fiveHourRemainingPercent: 0,
            fiveHourResetAt: nil
        )

        let state = ProfileHealthState.state(
            for: claude,
            staleProfileIds: [],
            rateLimits: [claude.id: rateLimit]
        )

        #expect(state == .exhausted)
    }

    @Test
    func codexFailureGateStillContinuesWhenClaudeHadARefreshResult() {
        let shouldContinue = RateLimitRefreshGate.shouldContinueAfterCodexFailures(
            codexCredentialCount: 1,
            codexSuccessCount: 0,
            consecutiveFetchFailures: 3,
            attemptedProviders: [.codex, .claude]
        )

        #expect(shouldContinue)
    }

    @Test
    func codexFailureGateStopsCodexOnlyRepeatedFailures() {
        let shouldContinue = RateLimitRefreshGate.shouldContinueAfterCodexFailures(
            codexCredentialCount: 1,
            codexSuccessCount: 0,
            consecutiveFetchFailures: 3,
            attemptedProviders: [.codex]
        )

        #expect(!shouldContinue)
    }

    @Test
    func claudeUsageRefreshPolicyRefreshesUnauthorizedUsageResult() {
        let shouldRefresh = ClaudeUsageRefreshPolicy.shouldRefreshAfterUsageResult(.stale(
            RateLimitFetchDiagnostic(
                checkedAt: Date(timeIntervalSince1970: 1_760_000_000),
                httpStatusCode: 401,
                staleReason: .unauthorized,
                failureSummary: nil
            )
        ))

        #expect(shouldRefresh)
    }

    @Test
    func claudeUsageRefreshPolicyRefreshesRateLimitedUsageResult() {
        let shouldRefresh = ClaudeUsageRefreshPolicy.shouldRefreshAfterUsageResult(.failure(
            RateLimitFetchDiagnostic(
                checkedAt: Date(timeIntervalSince1970: 1_760_000_000),
                httpStatusCode: 429,
                staleReason: nil,
                failureSummary: "HTTP 429"
            )
        ))

        #expect(shouldRefresh)
    }

    @Test
    func claudeUsageRefreshPolicyDoesNotRefreshRateLimitedUsageResultWithRetryAfter() {
        let shouldRefresh = ClaudeUsageRefreshPolicy.shouldRefreshAfterUsageResult(.failure(
            RateLimitFetchDiagnostic(
                checkedAt: Date(timeIntervalSince1970: 1_760_000_000),
                httpStatusCode: 429,
                staleReason: nil,
                failureSummary: "HTTP 429",
                retryAfter: 120
            )
        ))

        #expect(!shouldRefresh)
    }

    @Test
    func claudeUsageBackoffPolicyHonorsRetryAfter() {
        let diagnostic = RateLimitFetchDiagnostic(
            checkedAt: Date(timeIntervalSince1970: 1_760_000_000),
            httpStatusCode: 429,
            staleReason: nil,
            failureSummary: "HTTP 429",
            retryAfter: 120
        )

        #expect(ClaudeUsageBackoffPolicy.backoffDuration(after: diagnostic) == 120)
    }

    @Test
    func claudeUsageBackoffPolicyAvoidsDefaultBackoffWhenRefreshOnlySkipped() {
        let diagnostic = RateLimitFetchDiagnostic(
            checkedAt: Date(timeIntervalSince1970: 1_760_000_000),
            httpStatusCode: nil,
            staleReason: nil,
            failureSummary: "Skipped OAuth refresh while Claude is running"
        )

        #expect(ClaudeUsageBackoffPolicy.backoffDuration(after: diagnostic) == nil)
    }

    @Test
    func seamlessFallbackRestartTargetsVerificationProviderWhenAnotherProviderIsSelected() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let codex = Profile(alias: "Codex", email: "codex@example.com", accountId: "codex", addedAt: now)
        let claude = Profile(alias: "Claude", email: "claude@example.com", accountId: "claude", addedAt: now, aiProvider: .claude)
        let attempt = SeamlessVerificationAttempt(
            targetProfileId: codex.id,
            targetProfileName: codex.displayName,
            provider: .codex,
            startedAt: now
        )

        let target = SeamlessFallbackRestartTarget.select(
            verificationAttempt: attempt,
            profiles: [codex, claude],
            activeProfileIdsByProvider: [.codex: codex.id, .claude: claude.id],
            selectedActiveProfile: claude
        )

        #expect(target?.id == codex.id)
    }
}
