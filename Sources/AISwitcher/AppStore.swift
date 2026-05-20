import Foundation
import UserNotifications
import AppKit
import SwiftUI

enum AutomaticSwitchEvaluation {
    static func providerToSwitch(
        selectedProvider: AIProvider,
        activeProfileIdsByProvider: [AIProvider: UUID],
        rateLimits: [UUID: RateLimitInfo],
        exhaustedProviders: Set<AIProvider> = [],
        policy: SwitchDecisionPolicy
    ) -> (provider: AIProvider, rateLimit: RateLimitInfo)? {
        let providers = [selectedProvider] + AIProvider.allCases.filter { $0 != selectedProvider }
        for provider in providers {
            guard !exhaustedProviders.contains(provider) else { continue }
            guard let activeId = activeProfileIdsByProvider[provider],
                  let rateLimit = rateLimits[activeId],
                  policy.shouldLeaveCurrentProfile(rateLimit) else { continue }
            return (provider, rateLimit)
        }
        return nil
    }
}

enum AutomaticSwitchSessionGate {
    static func shouldDefer(
        provider: AIProvider,
        isCodexSessionActive: Bool,
        isClaudeProcessRunning: Bool
    ) -> Bool {
        switch provider {
        case .codex:
            return isCodexSessionActive
        case .claude:
            return isClaudeProcessRunning
        }
    }
}

enum AutomaticSwitchVerificationGate {
    static func shouldFailVerification(
        candidateProvider: AIProvider,
        attempt: SeamlessVerificationAttempt?
    ) -> Bool {
        attempt?.provider == candidateProvider
    }
}

enum ActivationInProgressGate {
    static func shouldRunOffMain(provider: AIProvider) -> Bool {
        provider == .claude
    }

    static func begin(profileId: UUID, active: inout Set<UUID>) -> Bool {
        active.insert(profileId).inserted
    }

    static func finish(profileId: UUID, active: inout Set<UUID>) {
        active.remove(profileId)
    }
}

enum ActivationFailureRetryPolicy {
    static func shouldRetrySynchronously(provider: AIProvider) -> Bool {
        provider == .codex
    }
}

@MainActor
final class AppStore: ObservableObject {

    static let shared = AppStore()

    @Published var profiles: [Profile] = []
    @Published var activeProfile: Profile?
    @Published var selectedProvider: AIProvider = .codex
    @Published var activeProfileIdsByProvider: [AIProvider: UUID] = [:]
    @Published var isAddingAccount: Bool = false
    @Published var addingStep: AddingStep = .idle
    @Published var addAccountErrorMessage: String?
    @Published var pendingProvider: AIProvider = .codex
    @Published var pendingProfileEmail: String = ""
    @Published var aliasText: String = ""
    @Published var allExhausted: Bool = false
    @Published var exhaustedProviders: Set<AIProvider> = []
    @Published var activeTurns: Int = 0
    @Published var rateLimits: [UUID: RateLimitInfo] = [:]
    @Published var isFetchingLimits: Bool = false
    @Published var switchHistory: [SwitchEvent] = []
    @Published var tokenUsage: [UUID: AccountTokenUsage] = [:]
    @Published var staleProfileIds: Set<UUID> = []
    @Published var rateLimitHealth: [UUID: RateLimitHealthStatus] = [:]
    @Published var costs: [UUID: Double] = [:]
    @Published var forecasts: [UUID: RateLimitForecast] = [:]
    @Published var lastKnownLimitState: [UUID: Bool] = [:]
    @Published var isSessionActive: Bool = false

    @Published var updateStatus: UpdateStatusSnapshot = .idle(currentVersion: UpdateChecker.currentVersion())
    @Published var analyticsTimeRange: AnalyticsTimeRange = .sevenDays
    @Published var analyticsSnapshot: AnalyticsSnapshot = .empty(for: .sevenDays)
    @Published var switchOrchestrationState: SwitchOrchestrationState = .idle
    @Published var pendingSwitchRequest: PendingSwitchRequest?
    @Published var lastSeamlessSwitchResult: SeamlessSwitchResult?
    @Published var switchReliability = SwitchReliabilitySnapshot()
    @Published var switchTimeline: [SwitchTimelineEvent] = []
    @Published var switchDecisionHistory: [SwitchDecisionRecord] = []
    @Published var automationConfidence: AutomationConfidenceSummary = .empty
    @Published var accountReliability: [AccountReliabilitySummary] = []

    // Stored properties — internal so extension files can access them
    var lastBudgetAlertDate: Date?
    var lastWeeklySummaryDate: Date?

    var availableUpdate: UpdateReleaseInfo? {
        updateStatus.state == .updateAvailable ? updateStatus.release : nil
    }

    var powerUserRecommendation: PowerUserRecommendation? {
        PowerUserRecommendationEngine.build(
            automation: automationConfidence,
            diagnostics: analyticsSnapshot.diagnosticsSummary,
            workflow: analyticsSnapshot.workflowSummary
        )
    }

    static let turnsLimit    = 50
    static let switchCooldown: TimeInterval = 60

    let profileManager    = ProfileManager()
    let usageMonitor      = UsageMonitor()
    let usageTracker      = SessionUsageTracker()
    let fetcher           = RateLimitFetcher()
    let historyStore      = SwitchHistoryStore()
    let switchTimelineStore = SwitchTimelineStore()
    let switchDecisionStore = SwitchDecisionStore()
    let codexStateStore = CodexStateStore()
    let tokenParser       = SessionTokenParser()
    let claudeTranscriptParser = ClaudeTranscriptParser()
    let analyticsEngine   = AnalyticsEngine()
    let switchDecisionPolicy = SwitchDecisionPolicy()

    var usageTimer: Timer?
    var rateLimitTimer: Timer?
    var automationHealthTimer: Timer?
    var authWatcher: DispatchSourceFileSystemObject?
    var authWatcherFd: Int32 = -1
    var loginTimeout: DispatchWorkItem?
    var loginProcess: Process?
    var loginOutputPipe: Pipe?
    var loginOutputBuffer = ""
    var didOpenLoginBrowser = false
    var suppressLoginFailureFeedback = false
    var lastAutoSwitchDateByProvider: [AIProvider: Date] = [:]
    var rateLimitCheckPending = false
    var lastAuthWriteDate: Date?
    var consecutiveFetchFailures: Int = 0
    var paceHistory: [SessionPacePoint] = []
    var tokenRefreshWork: DispatchWorkItem?
    var isTokenRefreshRunning = false
    var shouldRefreshTokenUsageAfterCurrentRun = false
    var warned80PercentIds: Set<UUID> = []
    var reloginTargetId: UUID?
    var pendingClaudeCredentialsData: Data?
    var pendingClaudeIdentity: ClaudeAccountIdentity?
    var pendingClaudeLoginDirectory: URL?
    var sessionActivitySequence = 0
    var switchOrchestrator = SwitchOrchestrator()
    var seamlessVerificationWork: DispatchWorkItem?
    var syncedTimelineEventCount = 0
    var lastAutomationAlertFingerprint: String?
    var analyticsWindow: NSWindow?
    var addAccountWindow: NSWindow?
    var activationInProgressProfileIds: Set<UUID> = []
    var rateLimitAuditSamples: [UUID: [RateLimitAuditSample]] = [:]
    var claudeUsageBackoffUntil: [UUID: Date] = [:]
    var notificationPermissionGate = NotificationPermissionGate()

    enum AddingStep { case idle, waitingLogin, confirmProfile, done }

    // MARK: - Init

    private init() {
        profileManager.bootstrap()
        let recoveryReport = profileManager.verifyAndRecoverActiveAuthReport(providers: [.codex])
        loadProfiles()
        markUnrecoveredProfilesStale(recoveryReport.unrecoverableProfileIds)
        recoverClaudeAuthInBackground()
        switchHistory = historyStore.load()
        switchTimeline = switchTimelineStore.load()
        switchDecisionHistory = switchDecisionStore.load()
        refreshReliabilityAnalytics()

        usageMonitor.onRateLimit = { [weak self] in
            Task { @MainActor in self?.handleRateLimitDetected() }
        }
        usageMonitor.onTokenUpdate = { [weak self] in
            self?.scheduleTokenRefresh()
        }
        usageMonitor.onSessionActivity = { [weak self] in
            Task { @MainActor in self?.recordSessionActivity() }
        }
        usageMonitor.start()
        startUsagePolling()
        startRateLimitPolling()
        startAutomationHealthPolling()
        refreshTokenUsage()
        syncSwitchOrchestrationState()
    }

    private func recoverClaudeAuthInBackground() {
        let profileManager = self.profileManager
        Task.detached(priority: .utility) {
            let report = profileManager.verifyAndRecoverActiveAuthReport(providers: [.claude])
            await MainActor.run {
                self.markUnrecoveredProfilesStale(report.unrecoverableProfileIds)
                if !report.unrecoverableProfileIds.isEmpty {
                    self.sendNotification(
                        title: L("Auth sorunu", "Auth issue"),
                        body: L("Claude hesabınızı yeniden giriş yapmanız gerekebilir.", "You may need to re-login to your Claude account.")
                    )
                }
            }
        }
    }

    // MARK: - Update Checker

    func checkForUpdates() {
        Task {
            let prior = updateStatus
            await MainActor.run {
                self.updateStatus = .checking(
                    currentVersion: prior.currentVersion,
                    latestVersion: prior.latestVersion,
                    release: prior.release,
                    lastCheckedAt: prior.lastCheckedAt
                )
            }
            let snapshot = await UpdateChecker.check()
            await MainActor.run { self.updateStatus = snapshot }
            if let release = snapshot.release, snapshot.state == .updateAvailable {
                sendNotification(
                    title: L("Güncelleme mevcut", "Update available"),
                    body: "AI Switcher \(release.version)"
                )
            }
        }
    }

    func checkForUpdatesManually() {
        Task {
            let prior = updateStatus
            await MainActor.run {
                self.updateStatus = .checking(
                    currentVersion: prior.currentVersion,
                    latestVersion: prior.latestVersion,
                    release: prior.release,
                    lastCheckedAt: prior.lastCheckedAt
                )
            }
            let snapshot = await UpdateChecker.check()
            await MainActor.run {
                self.updateStatus = snapshot
                self.openReleasePage()
            }
        }
    }

    func openReleasePage() {
        if let url = updateStatus.release?.releaseURL {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/kamushadenes/ai-switcher/releases")!)
        }
    }

    // MARK: - Usage Polling

    private func startUsagePolling() {
        refreshActiveTurns()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshActiveTurns() }
        }
    }

    func refreshActiveTurns() {
        guard let profile = activeProfile, let activatedAt = profile.activatedAt else {
            activeTurns = usageTracker.turnsInLast(hours: 5)
            return
        }
        activeTurns = usageTracker.turnsSince(activatedAt)
    }

    private func captureUsageForActive(provider: AIProvider? = nil) {
        let active = provider.flatMap { activeProfile(for: $0) } ?? activeProfile
        guard let active else { return }
        var config = profileManager.loadConfig()
        guard let idx = config.profiles.firstIndex(where: { $0.id == active.id }) else { return }
        config.profiles[idx].lastKnownTurns = activeTurns
        profileManager.saveConfig(config)
        profiles = config.profiles
    }

    // MARK: - Profile Loading

    func loadProfiles() {
        var config = profileManager.loadConfig()
        config.normalizeActiveProfiles()
        profiles = config.profiles
        selectedProvider = config.selectedProvider
        activeProfileIdsByProvider = config.activeProfileIdsByProvider
        activeProfile = profile(for: activeProfileIdsByProvider[selectedProvider])
        refreshSelectedExhaustionFlag()
        if activeProfile == nil, let first = profiles.first(where: { $0.provider == selectedProvider }) ?? profiles.first {
            config.setActiveProfile(first)
            selectedProvider = config.selectedProvider
            activeProfileIdsByProvider = config.activeProfileIdsByProvider
            activeProfile = first
            profileManager.saveConfig(config)
            refreshSelectedExhaustionFlag()
        }
    }

    var visibleProfiles: [Profile] {
        profiles.filter { $0.provider == selectedProvider }
    }

    func profile(for id: UUID?) -> Profile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    func activeProfile(for provider: AIProvider) -> Profile? {
        profile(for: activeProfileIdsByProvider[provider])
    }

    func isAllExhausted(provider: AIProvider) -> Bool {
        exhaustedProviders.contains(provider)
    }

    func markAllExhausted(provider: AIProvider) {
        exhaustedProviders.insert(provider)
        refreshSelectedExhaustionFlag()
    }

    func clearAllExhausted(provider: AIProvider) {
        exhaustedProviders.remove(provider)
        refreshSelectedExhaustionFlag()
    }

    func refreshSelectedExhaustionFlag() {
        allExhausted = exhaustedProviders.contains(selectedProvider)
    }

    func selectProvider(_ provider: AIProvider) {
        guard selectedProvider != provider else { return }
        selectedProvider = provider
        var config = profileManager.loadConfig()
        config.selectedProvider = provider
        config.normalizeActiveProfiles()
        profileManager.saveConfig(config)
        activeProfileIdsByProvider = config.activeProfileIdsByProvider
        activeProfile = profile(for: activeProfileIdsByProvider[provider])
        refreshSelectedExhaustionFlag()
        notifyProfileChanged()
    }

    private func markUnrecoveredProfilesStale(_ profileIds: Set<UUID>) {
        staleProfileIds.formUnion(profileIds)
    }

    func setAnalyticsTimeRange(_ range: AnalyticsTimeRange) {
        guard analyticsTimeRange != range else { return }
        analyticsTimeRange = range
        analyticsSnapshot = .empty(for: range)
        refreshTokenUsage()
    }

    func openAnalyticsWindow() {
        if let window = analyticsWindow, window.isVisible {
            window.makeKeyAndOrderFront(NSApp)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: AnalyticsWindowView().environmentObject(self))
        hosting.frame = NSRect(x: 0, y: 0, width: 1040, height: 780)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L("Analitik", "Analytics")
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 920, height: 680)
        let isDark = UserDefaults.standard.object(forKey: "isDarkMode") as? Bool ?? true
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.backgroundColor = isDark
            ? NSColor.black.withAlphaComponent(0.82)
            : NSColor.white.withAlphaComponent(0.88)
        window.center()
        window.makeKeyAndOrderFront(NSApp)
        NSApp.activate(ignoringOtherApps: true)
        analyticsWindow = window
    }

    // MARK: - Token / Rate Limit Accessors

    func getTokenUsage(for profile: Profile) -> AccountTokenUsage? { tokenUsage[profile.id] }
    func rateLimit(for profile: Profile) -> RateLimitInfo? { rateLimits[profile.id] }

    var nextResetInfo: (profileName: String, resetTime: String)? {
        let exhaustedProfiles = visibleProfiles.filter { rateLimits[$0.id]?.limitReached == true }
        let resetTimes = exhaustedProfiles.compactMap { profile -> (String, Date)? in
            let rl = rateLimits[profile.id]
            let candidates = ([rl?.weeklyResetAt, rl?.fiveHourResetAt] + (rl?.additionalQuotaWindows.map(\.resetAt) ?? []))
                .compactMap { $0 }
            guard let earliest = candidates.min() else { return nil }
            return (profile.displayName, earliest)
        }
        guard let (name, date) = resetTimes.min(by: { $0.1 < $1.1 }) else { return nil }
        let fmt = DateFormatter()
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(date)
        fmt.dateFormat = isToday ? "HH:mm" : "d MMM HH:mm"
        return (name, fmt.string(from: date))
    }

    // MARK: - Smart Switch

    func smartNextProfile(auto: Bool, provider: AIProvider? = nil) -> Profile? {
        let provider = provider ?? activeProfile?.provider ?? selectedProvider
        let evaluation = makeSwitchReadinessEvaluation(provider: provider)
        let preferredId: UUID?
        if auto {
            preferredId = evaluation.candidates.first(where: { $0.status == .ready })?.profileId
                ?? evaluation.preferredCandidateId
        } else {
            preferredId = evaluation.preferredCandidateId
        }
        guard let preferredId else { return nil }
        return profiles.first { $0.id == preferredId && $0.provider == provider }
    }

    // MARK: - Switching

    func switchToNext(reason: String = L("Manuel geçiş", "Manual switch")) {
        switchToNext(provider: selectedProvider, reason: reason)
    }

    func switchToNext(provider: AIProvider, reason: String = L("Manuel geçiş", "Manual switch")) {
        captureUsageForActive(provider: provider)
        let isAuto = reason.contains(L("Limit", "Limit"))
        guard let candidate = smartNextProfile(auto: isAuto, provider: provider) else {
            if isAuto {
                recordSwitchDecision(
                    requestedProfile: nil,
                    chosenProfile: nil,
                    provider: provider,
                    source: .automatic,
                    outcome: .halted,
                    reason: reason,
                    detail: L("Güvenli hedef bulunamadı.", "No safe target was available."),
                    overrideApplied: false
                )
                switchOrchestrator.recordHaltedDecision(
                    reason: reason,
                    detail: L("Hiçbir hesap güvenli hedef olarak seçilemedi.", "No account qualified as a safe switch target.")
                )
                syncSwitchOrchestrationState()
            }
            markAllExhausted(provider: provider)
            sendNotification(title: Str.allExhausted, body: L("Limitler sıfırlanınca devam eder.", "Will resume when limits reset."))
            return
        }
        activateCandidate(candidate, reason: reason, source: isAuto ? .automatic : .manual, overrideApplied: false)
    }

    func switchTo(profile: Profile) {
        if selectedProvider != profile.provider {
            selectProvider(profile.provider)
        }
        captureUsageForActive(provider: profile.provider)
        let evaluation = makeSwitchReadinessEvaluation(provider: profile.provider)
        let readiness = evaluation.candidates.first(where: { $0.profileId == profile.id })
        let isSafe = readiness?.status == .ready || readiness?.status == .warning
        guard isSafe else {
            recordSwitchDecision(
                requestedProfile: profile,
                chosenProfile: profile,
                source: .manual,
                outcome: .manualOverride,
                reason: L("Manuel seçim", "Manual selection"),
                detail: manualSwitchBlockedMessage(for: profile, rateLimit: rateLimits[profile.id]),
                overrideApplied: true,
                evaluation: evaluation
            )
            switchOrchestrator.recordBlockedDecision(
                targetProfileName: profile.displayName,
                reason: L("Manuel override", "Manual override"),
                detail: L(
                    "Güvensiz hedef uyarı ile seçildi; manuel override uygulandı.",
                    "Unsafe target was selected with a warning; manual override was applied."
                )
            )
            syncSwitchOrchestrationState()
            sendNotification(
                title: L("Dikkatli geçiş", "Proceeding with caution"),
                body: manualSwitchBlockedMessage(for: profile, rateLimit: rateLimits[profile.id])
            )
            switchTo(profile: profile, reason: L("Manuel override", "Manual override"), source: .manual, overrideApplied: true)
            return
        }
        switchTo(profile: profile, reason: L("Manuel seçim", "Manual selection"), source: .manual, overrideApplied: false)
    }

    func switchTo(profile: Profile, reason: String) {
        switchTo(profile: profile, reason: reason, source: .manual, overrideApplied: false)
    }

    func switchTo(
        profile: Profile,
        reason: String,
        source: SwitchDecisionSource,
        overrideApplied: Bool
    ) {
        activateCandidate(profile, reason: reason, source: source, overrideApplied: overrideApplied)
    }

    func activateCandidate(
        _ candidate: Profile,
        reason: String,
        source: SwitchDecisionSource,
        overrideApplied: Bool
    ) {
        guard ActivationInProgressGate.begin(profileId: candidate.id, active: &activationInProgressProfileIds) else {
            return
        }
        // NOTE: history is written in finalizeActivation, NOT here.
        // Writing before we know activation succeeded would permanently corrupt analytics
        // attribution (the parser treats history as authoritative for token ownership).
        let evaluation = makeSwitchReadinessEvaluation(provider: candidate.provider)
        lastAuthWriteDate = Date()

        if ActivationInProgressGate.shouldRunOffMain(provider: candidate.provider) {
            let profileManager = self.profileManager
            Task.detached(priority: .userInitiated) {
                let result: Result<VerifyResult, Error>
                do {
                    result = .success(try profileManager.activate(profile: candidate))
                } catch {
                    result = .failure(error)
                }
                await MainActor.run {
                    self.completeActivationAttempt(
                        candidate,
                        result: result,
                        reason: reason,
                        source: source,
                        overrideApplied: overrideApplied,
                        evaluation: evaluation
                    )
                }
            }
            return
        }

        do {
            let verifyResult = try profileManager.activate(profile: candidate)
            completeActivationAttempt(
                candidate,
                result: .success(verifyResult),
                reason: reason,
                source: source,
                overrideApplied: overrideApplied,
                evaluation: evaluation
            )
        } catch {
            completeActivationAttempt(
                candidate,
                result: .failure(error),
                reason: reason,
                source: source,
                overrideApplied: overrideApplied,
                evaluation: evaluation
            )
        }
    }

    private func completeActivationAttempt(
        _ candidate: Profile,
        result: Result<VerifyResult, Error>,
        reason: String,
        source: SwitchDecisionSource,
        overrideApplied: Bool,
        evaluation: SwitchReadinessEvaluation
    ) {
        defer {
            ActivationInProgressGate.finish(profileId: candidate.id, active: &activationInProgressProfileIds)
        }

        switch result {
        case .success(let verifyResult):

            switch verifyResult {
            case .verified:
                finalizeActivation(
                    candidate,
                    reason: reason,
                    source: source,
                    overrideApplied: overrideApplied,
                    evaluation: evaluation
                )
            case .failed:
                let retryResult = ActivationFailureRetryPolicy.shouldRetrySynchronously(provider: candidate.provider)
                    ? profileManager.verifyActiveAccount(for: candidate)
                    : verifyResult
                switch retryResult {
                case .verified:
                    finalizeActivation(
                        candidate,
                        reason: reason,
                        source: source,
                        overrideApplied: overrideApplied,
                        evaluation: evaluation
                    )
                case .failed:
                    recordSwitchDecision(
                        requestedProfile: candidate,
                        chosenProfile: candidate,
                        source: source,
                        outcome: .blocked,
                        reason: reason,
                        detail: L("Hesap doğrulanamadı.", "Account verification failed."),
                        overrideApplied: overrideApplied,
                        evaluation: evaluation
                    )
                    switchOrchestrator.recordBlockedDecision(
                        targetProfileName: candidate.displayName,
                        reason: reason,
                        detail: L("Hedef hesap doğrulanamadı.", "Target account could not be verified.")
                    )
                    syncSwitchOrchestrationState()
                    sendNotification(
                        title: L("Geçiş başarısız", "Switch failed"),
                        body: L("Hesap doğrulanamadı. Lütfen tekrar deneyin.", "Account verification failed. Please try again.")
                    )
                }
            }
        case .failure(let error):
            recordSwitchDecision(
                requestedProfile: candidate,
                chosenProfile: candidate,
                source: source,
                outcome: .blocked,
                reason: reason,
                detail: error.localizedDescription,
                overrideApplied: overrideApplied,
                evaluation: evaluation
            )
            switchOrchestrator.recordBlockedDecision(
                targetProfileName: candidate.displayName,
                reason: reason,
                detail: error.localizedDescription
            )
            syncSwitchOrchestrationState()
            sendNotification(title: L("Geçiş başarısız", "Switch failed"), body: error.localizedDescription)
        }
    }

    private func manualSwitchBlockedMessage(for profile: Profile, rateLimit: RateLimitInfo?) -> String {
        guard let rateLimit else {
            return L(
                "\(profile.displayName) için güncel limit verisi yok.",
                "No current limit data is available for \(profile.displayName)."
            )
        }
        let weeklyRemaining  = max(0, 100 - (rateLimit.weeklyUsedPercent ?? 100))
        let fiveHourRemaining = rateLimit.fiveHourRemainingPercent ?? 0
        return L(
            "\(profile.displayName) güvenli değil. Haftalık kalan %\(weeklyRemaining), 5 saatlik kalan %\(fiveHourRemaining).",
            "\(profile.displayName) is not safe to switch into. Weekly remaining \(weeklyRemaining)%, 5-hour remaining \(fiveHourRemaining)%."
        )
    }

    private func finalizeActivation(
        _ candidate: Profile,
        reason: String,
        source: SwitchDecisionSource,
        overrideApplied: Bool,
        evaluation: SwitchReadinessEvaluation
    ) {
        let previousSelectedProvider = selectedProvider
        let previousProviderActiveProfile = activeProfile(for: candidate.provider)

        // Write history ONLY after verified activation to keep analytics attribution clean.
        let event = SwitchEvent(
            id: UUID(),
            timestamp: Date(),
            provider: candidate.provider,
            fromAccountName: previousProviderActiveProfile?.displayName,
            fromAccountId: previousProviderActiveProfile?.id,
            toAccountName: candidate.displayName,
            toAccountId: candidate.id,
            reason: reason
        )
        historyStore.append(event)
        switchHistory = historyStore.load()
        recordSwitchDecision(
            requestedProfile: candidate,
            chosenProfile: candidate,
            source: source,
            outcome: overrideApplied ? .manualOverride : .executed,
            reason: reason,
            detail: L("Hedef hesap doğrulandı ve aktif edildi.", "Target account was verified and activated."),
            overrideApplied: overrideApplied,
            evaluation: evaluation
        )

        var config = profileManager.loadConfig()
        if let i = config.profiles.firstIndex(where: { $0.id == candidate.id }) {
            config.profiles[i].activatedAt = Date()
        }
        config.activeProfileIdsByProvider[candidate.provider] = candidate.id
        config.selectedProvider = previousSelectedProvider
        if previousSelectedProvider == candidate.provider {
            config.setActiveProfile(config.profiles.first(where: { $0.id == candidate.id }) ?? candidate)
        } else {
            config.normalizeActiveProfiles()
        }
        profileManager.saveConfig(config)

        let newActiveProfile = config.profiles.first { $0.id == candidate.id }
        profiles = config.profiles
        selectedProvider = config.selectedProvider
        activeProfileIdsByProvider = config.activeProfileIdsByProvider
        activeProfile = profile(for: activeProfileIdsByProvider[selectedProvider]) ?? newActiveProfile
        clearAllExhausted(provider: candidate.provider)
        activeTurns = 0

        refreshTokenUsage()
        notifyProfileChanged()
        sendNotification(title: L("Hesap değiştirildi", "Account switched"), body: "\(candidate.displayName) — \(reason)")
        Task { await fetchAllRateLimits() }
        if candidate.provider == .codex {
            if isCodexRunning() {
                switchOrchestrator.recordImmediateRestart(
                    targetProfileName: candidate.displayName,
                    provider: candidate.provider,
                    detail: L(
                        "Desktop Codex arka planda yeni hesabı yüklemesi için yenileniyor.",
                        "Desktop Codex is refreshing in the background so the new account can be loaded."
                    )
                )
                syncSwitchOrchestrationState()
                restartAIIfRunning(for: candidate)
            } else {
                attemptSeamlessSwitch(for: candidate)
            }
        } else {
            restartAIIfRunning(for: candidate)
        }
    }

    func makeSwitchReadinessEvaluation(provider: AIProvider? = nil) -> SwitchReadinessEvaluation {
        let provider = provider ?? selectedProvider
        let providerProfiles = profiles.filter { $0.provider == provider }
        let activeId = activeProfileIdsByProvider[provider]
        return SwitchReadinessEvaluator(policy: switchDecisionPolicy).evaluate(
            profiles: providerProfiles,
            activeProfileId: activeId,
            rateLimits: rateLimits,
            staleProfileIds: staleProfileIds
        )
    }

    func recordSwitchDecision(
        requestedProfile: Profile?,
        chosenProfile: Profile?,
        provider: AIProvider? = nil,
        source: SwitchDecisionSource,
        outcome: SwitchDecisionOutcome,
        reason: String,
        detail: String,
        overrideApplied: Bool,
        evaluation: SwitchReadinessEvaluation? = nil
    ) {
        let decisionProvider = provider ?? chosenProfile?.provider ?? requestedProfile?.provider ?? selectedProvider
        let record = SwitchDecisionRecord(
            id: UUID(),
            timestamp: Date(),
            provider: decisionProvider,
            source: source,
            outcome: outcome,
            requestedProfileId: requestedProfile?.id,
            requestedProfileName: requestedProfile?.displayName,
            chosenProfileId: chosenProfile?.id,
            chosenProfileName: chosenProfile?.displayName,
            reason: reason,
            detail: detail,
            overrideApplied: overrideApplied,
            readiness: (evaluation ?? makeSwitchReadinessEvaluation(provider: decisionProvider)).candidates
        )
        switchDecisionStore.append(record)
        switchDecisionHistory = switchDecisionStore.load()
    }

    // MARK: - AI Restart

    func restartAIIfRunning(for profile: Profile) {
        switch profile.provider {
        case .codex:
            restartCodexIfRunning()
        case .claude:
            notifyClaudeSessionsNeedRestart(profile: profile)
        }
    }

    private func notifyClaudeSessionsNeedRestart(profile: Profile) {
        sendNotification(
            title: L("Claude kimliği değişti", "Claude credentials switched"),
            body: L(
                "\(profile.displayName) sonraki Claude oturumlarında kullanılacak. Açık `claude` oturumlarını yeniden başlatın.",
                "\(profile.displayName) will be used by new Claude sessions. Restart any open `claude` sessions."
            )
        )
    }

    private func restartCodexIfRunning() {
        guard let codexApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == "Codex" && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }) else { return }

        let bundleURL = codexApp.bundleURL
        terminateBundledCodexAppServerProcesses(bundleURL: bundleURL)

        sendNotification(
            title: L("Hesap değiştirildi", "Account Switched"),
            body: L(
                "Codex arka planda yeni hesabı yüklüyor. Pencere açık kalacak.",
                "Codex is reloading the new account in the background. The window will stay open."
            )
        )

        scheduleCodexWindowRecovery()

        guard let bundleURL else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard !self.isBundledCodexAppServerRunning(bundleURL: bundleURL) else { return }
            self.sendNotification(
                title: L("Codex yenilemesi tamamlanmadı", "Codex refresh did not complete"),
                body: L(
                    "Arka plan oturumu otomatik bağlanmadı. Gerekirse Codex'i elle yeniden aç.",
                    "The background session did not reconnect automatically. Reopen Codex manually if needed."
                )
            )
        }
    }

    private func terminateBundledCodexAppServerProcesses(bundleURL: URL?) {
        guard let bundleURL else { return }
        let executablePath = bundleURL
            .appendingPathComponent("Contents/Resources/codex")
            .path

        runDetachedTool(
            executableURL: URL(fileURLWithPath: "/usr/bin/pkill"),
            arguments: ["-f", "\(executablePath) app-server"]
        )
    }

    private func scheduleCodexWindowRecovery() {
        let delays: [TimeInterval] = [0.8, 1.6, 2.8]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                _ = self.tryClickCodexReloadButton()
            }
        }
    }

    private func tryClickCodexReloadButton() -> Bool {
        let script = """
        tell application "System Events"
            if not (exists process "Codex") then
                return "missing"
            end if
            tell process "Codex"
                repeat with buttonName in {"Reload", "Yeniden Yükle"}
                    try
                        if exists (button (buttonName as text) of window 1) then
                            click button (buttonName as text) of window 1
                            return "clicked"
                        end if
                    end try
                end repeat
            end tell
        end tell
        return "missing"
        """

        return runAppleScript(source: script) == "clicked"
    }

    private func runAppleScript(source: String) -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private func isBundledCodexAppServerRunning(bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let executablePath = bundleURL
            .appendingPathComponent("Contents/Resources/codex")
            .path

        return runDetachedTool(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-f", "\(executablePath) app-server"]
        ) == 0
    }

    @discardableResult
    private func runDetachedTool(executableURL: URL, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    // MARK: - Rate Limit Detection

    func handleRateLimitDetected() {
        guard !isAllExhausted(provider: .codex), !rateLimitCheckPending else { return }
        if let last = lastAutoSwitchDateByProvider[.codex],
           Date().timeIntervalSince(last) < Self.switchCooldown { return }

        rateLimitCheckPending = true
        Task {
            await fetchAllRateLimits(showSpinner: false)
            rateLimitCheckPending = false

            guard let active = activeProfile(for: .codex) else { return }
            let activeId = active.id

            if let rl = rateLimits[activeId] {
                guard self.switchDecisionPolicy.shouldLeaveCurrentProfile(rl) else { return }
            }

            if self.switchOrchestrationState == .verifying {
                self.handleSeamlessVerificationFailure()
                return
            }

            lastAutoSwitchDateByProvider[.codex] = Date()
            let reason = self.automaticSwitchReason(for: self.rateLimits[activeId])
            if self.isSessionActive {
                self.queuePendingSwitch(reason: reason)
                return
            }
            self.switchToNext(provider: .codex, reason: reason)
        }
    }

    func evaluateAutomaticSwitchAfterRateLimitRefresh() async {
        await processPendingSwitchIfNeeded(trigger: L("yeniden kontrol", "recheck"))
        guard let candidate = AutomaticSwitchEvaluation.providerToSwitch(
            selectedProvider: selectedProvider,
            activeProfileIdsByProvider: activeProfileIdsByProvider,
            rateLimits: rateLimits,
            exhaustedProviders: exhaustedProviders,
            policy: switchDecisionPolicy
        ) else { return }
        guard switchOrchestrator.pendingRequest(for: candidate.provider) == nil else { return }
        if let last = lastAutoSwitchDateByProvider[candidate.provider],
           Date().timeIntervalSince(last) < Self.switchCooldown { return }
        if switchOrchestrationState == .verifying,
           AutomaticSwitchVerificationGate.shouldFailVerification(
            candidateProvider: candidate.provider,
            attempt: switchOrchestrator.verificationAttempt
           ) {
            handleSeamlessVerificationFailure()
            return
        }

        let reason = automaticSwitchReason(for: candidate.rateLimit)
        lastAutoSwitchDateByProvider[candidate.provider] = Date()
        let claudeProcessRunning = candidate.provider == .claude
            ? await isClaudeCodeProcessRunning()
            : false
        if AutomaticSwitchSessionGate.shouldDefer(
            provider: candidate.provider,
            isCodexSessionActive: isSessionActive,
            isClaudeProcessRunning: claudeProcessRunning
        ) {
            queuePendingSwitch(reason: reason, provider: candidate.provider)
            return
        }
        switchToNext(provider: candidate.provider, reason: reason)
    }

    // MARK: - Helpers

    func notifyProfileChanged() {
        NotificationCenter.default.post(name: .profileChanged, object: nil)
    }

    private func automaticSwitchReason(for rateLimit: RateLimitInfo?) -> String {
        switch switchDecisionPolicy.automaticReasonKind(for: rateLimit) {
        case .limitReached:   return L("Limit doldu", "Limit reached")
        case .fiveHourPressure: return L("5 saatlik limit kritik seviyede", "5-hour limit is critically low")
        case .weeklyPressure:  return L("Haftalık limit kritik seviyede", "Weekly limit is critically low")
        case nil:             return L("Limit kritik seviyede", "Limit is critically low")
        }
    }

    func requestNotificationPermissionIfNeeded() {
        notificationPermissionGate.runIfNeeded {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func sendNotification(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        )
    }
}
