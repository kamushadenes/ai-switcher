import Foundation

struct SwitchOrchestrator {
    private(set) var state: SwitchOrchestrationState = .idle
    private(set) var pendingRequestsByProvider: [AIProvider: PendingSwitchRequest] = [:]
    private(set) var verificationAttempt: SeamlessVerificationAttempt?
    private(set) var lastResult: SeamlessSwitchResult?
    private(set) var reliability = SwitchReliabilitySnapshot()
    private(set) var timelineEvents: [SwitchTimelineEvent] = []

    var pendingRequests: [PendingSwitchRequest] {
        pendingRequestsByProvider.values.sorted { $0.queuedAt < $1.queuedAt }
    }

    var pendingRequest: PendingSwitchRequest? {
        pendingRequests.first
    }

    func pendingRequest(for provider: AIProvider) -> PendingSwitchRequest? {
        pendingRequestsByProvider[provider]
    }

    mutating func queue(request: PendingSwitchRequest, detail: String, now: Date = Date()) -> Bool {
        guard pendingRequestsByProvider[request.provider] == nil else { return false }

        pendingRequestsByProvider[request.provider] = request
        state = .pendingSwitch
        reliability.pendingSwitchCount += 1
        lastResult = SeamlessSwitchResult(
            outcome: .deferred,
            recordedAt: now,
            detail: detail
        )
        appendTimelineEvent(
            stage: .queued,
            timestamp: now,
            provider: request.provider,
            targetProfileName: request.targetProfileName,
            reason: request.reason,
            detail: detail
        )
        return true
    }

    mutating func readySwitchIfPossible(
        provider: AIProvider? = nil,
        isSessionActive: Bool,
        now: Date = Date()
    ) -> PendingSwitchRequest? {
        let request = provider.flatMap { pendingRequestsByProvider[$0] } ?? pendingRequest
        guard let request, !isSessionActive else { return nil }

        pendingRequestsByProvider[request.provider] = nil
        state = pendingRequestsByProvider.isEmpty ? .readyToSwitch : .pendingSwitch
        reliability.completedDeferredSwitchCount += 1
        appendTimelineEvent(
            stage: .ready,
            timestamp: now,
            provider: request.provider,
            targetProfileName: request.targetProfileName,
            reason: request.reason,
            detail: "Pending switch is ready to execute.",
            waitDurationSeconds: max(0, Int(now.timeIntervalSince(request.queuedAt).rounded()))
        )
        return request
    }

    mutating func startVerifying(
        targetProfileId: UUID,
        targetProfileName: String,
        provider: AIProvider = .codex,
        now: Date = Date()
    ) {
        verificationAttempt = SeamlessVerificationAttempt(
            targetProfileId: targetProfileId,
            targetProfileName: targetProfileName,
            provider: provider,
            startedAt: now
        )
        state = .verifying
        appendTimelineEvent(
            stage: .verifying,
            timestamp: now,
            provider: provider,
            targetProfileName: targetProfileName,
            detail: "Seamless switch verification started."
        )
    }

    mutating func completeSeamlessSuccess(detail: String, now: Date = Date()) {
        let verificationDurationSeconds = verificationAttempt.map {
            max(0, Int(now.timeIntervalSince($0.startedAt).rounded()))
        }
        let targetProfileName = verificationAttempt?.targetProfileName ?? "Unknown"
        let provider = verificationAttempt?.provider
        verificationAttempt = nil
        state = pendingRequestsByProvider.isEmpty ? .idle : .pendingSwitch
        reliability.seamlessSuccessCount += 1
        lastResult = SeamlessSwitchResult(
            outcome: .seamlessSuccess,
            recordedAt: now,
            detail: detail
        )
        appendTimelineEvent(
            stage: .seamlessSuccess,
            timestamp: now,
            provider: provider,
            targetProfileName: targetProfileName,
            detail: detail,
            verificationDurationSeconds: verificationDurationSeconds
        )
    }

    mutating func markInconclusive(
        provider fallbackProvider: AIProvider? = nil,
        targetProfileName fallbackTargetProfileName: String? = nil,
        detail: String,
        now: Date = Date()
    ) {
        let verificationDurationSeconds = verificationAttempt.map {
            max(0, Int(now.timeIntervalSince($0.startedAt).rounded()))
        }
        let targetProfileName = verificationAttempt?.targetProfileName ?? fallbackTargetProfileName ?? "Unknown"
        let provider = verificationAttempt?.provider ?? fallbackProvider
        verificationAttempt = nil
        state = pendingRequestsByProvider.isEmpty ? .idle : .pendingSwitch
        reliability.inconclusiveCount += 1
        lastResult = SeamlessSwitchResult(
            outcome: .inconclusive,
            recordedAt: now,
            detail: detail
        )
        appendTimelineEvent(
            stage: .inconclusive,
            timestamp: now,
            provider: provider,
            targetProfileName: targetProfileName,
            detail: detail,
            verificationDurationSeconds: verificationDurationSeconds
        )
    }

    mutating func finishSwitchCycle() {
        state = pendingRequestsByProvider.isEmpty ? .idle : .pendingSwitch
    }

    mutating func clearPending(provider: AIProvider? = nil) {
        if let provider {
            pendingRequestsByProvider[provider] = nil
        } else {
            pendingRequestsByProvider.removeAll()
        }
        verificationAttempt = nil
        state = pendingRequestsByProvider.isEmpty ? .idle : .pendingSwitch
    }

    mutating func recordFallbackRestart(detail: String, now: Date = Date()) {
        let verificationDurationSeconds = verificationAttempt.map {
            max(0, Int(now.timeIntervalSince($0.startedAt).rounded()))
        }
        let targetProfileName = verificationAttempt?.targetProfileName ?? pendingRequest?.targetProfileName ?? "Unknown"
        let provider = verificationAttempt?.provider ?? pendingRequest?.provider
        finalizeFallbackRestart(
            provider: provider,
            targetProfileName: targetProfileName,
            detail: detail,
            verificationDurationSeconds: verificationDurationSeconds,
            now: now
        )
    }

    mutating func recordImmediateRestart(
        targetProfileName: String,
        provider: AIProvider = .codex,
        detail: String,
        now: Date = Date()
    ) {
        finalizeFallbackRestart(
            provider: provider,
            targetProfileName: targetProfileName,
            detail: detail,
            verificationDurationSeconds: nil,
            now: now
        )
    }

    mutating func recordBlockedDecision(
        targetProfileName: String,
        reason: String,
        detail: String,
        now: Date = Date()
    ) {
        state = pendingRequestsByProvider.isEmpty ? .idle : .pendingSwitch
        reliability.blockedDecisionCount += 1
        appendTimelineEvent(
            stage: .blocked,
            timestamp: now,
            targetProfileName: targetProfileName,
            reason: reason,
            detail: detail
        )
    }

    mutating func recordHaltedDecision(reason: String, detail: String, now: Date = Date()) {
        state = pendingRequestsByProvider.isEmpty ? .idle : .pendingSwitch
        reliability.haltedDecisionCount += 1
        appendTimelineEvent(
            stage: .halted,
            timestamp: now,
            targetProfileName: "Automation",
            reason: reason,
            detail: detail
        )
    }

    private mutating func finalizeFallbackRestart(
        provider: AIProvider?,
        targetProfileName: String,
        detail: String,
        verificationDurationSeconds: Int?,
        now: Date
    ) {
        verificationAttempt = nil
        if let provider {
            pendingRequestsByProvider[provider] = nil
        } else {
            pendingRequestsByProvider.removeAll()
        }
        state = pendingRequestsByProvider.isEmpty ? .idle : .pendingSwitch
        reliability.fallbackRestartCount += 1
        lastResult = SeamlessSwitchResult(
            outcome: .fallbackRestart,
            recordedAt: now,
            detail: detail
        )
        appendTimelineEvent(
            stage: .fallbackRestart,
            timestamp: now,
            provider: provider,
            targetProfileName: targetProfileName,
            detail: detail,
            verificationDurationSeconds: verificationDurationSeconds
        )
    }

    private mutating func appendTimelineEvent(
        stage: SwitchTimelineEvent.Stage,
        timestamp: Date,
        provider: AIProvider? = nil,
        targetProfileName: String,
        reason: String? = nil,
        detail: String,
        waitDurationSeconds: Int? = nil,
        verificationDurationSeconds: Int? = nil
    ) {
        timelineEvents.append(
            SwitchTimelineEvent(
                id: UUID(),
                timestamp: timestamp,
                provider: provider,
                stage: stage,
                targetProfileName: targetProfileName,
                reason: reason,
                detail: detail,
                waitDurationSeconds: waitDurationSeconds,
                verificationDurationSeconds: verificationDurationSeconds
            )
        )
    }
}
