import Foundation

enum SwitchDecisionSource: String, Codable, Equatable {
    case automatic
    case manual
}

enum SwitchDecisionOutcome: String, Codable, Equatable {
    case queued
    case executed
    case blocked
    case halted
    case manualOverride
}

enum SwitchReadinessStatus: String, Codable, Equatable {
    case current
    case ready
    case warning
    case blocked
}

enum SwitchReadinessReason: String, Codable, Equatable {
    case activeProfile
    case staleAuth
    case missingRateLimit
    case limitReached
    case weeklyPressure
    case fiveHourPressure
}

struct SwitchCandidateReadiness: Codable, Equatable, Identifiable {
    var id: UUID { profileId }

    let profileId: UUID
    let provider: AIProvider?
    let profileName: String
    let status: SwitchReadinessStatus
    let score: Int
    let reasons: [SwitchReadinessReason]

    init(
        profileId: UUID,
        provider: AIProvider? = nil,
        profileName: String,
        status: SwitchReadinessStatus,
        score: Int,
        reasons: [SwitchReadinessReason]
    ) {
        self.profileId = profileId
        self.provider = provider
        self.profileName = profileName
        self.status = status
        self.score = score
        self.reasons = reasons
    }
}

struct SwitchReadinessEvaluation: Equatable {
    let candidates: [SwitchCandidateReadiness]
    let preferredCandidateId: UUID?
}

struct SwitchDecisionRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let provider: AIProvider?
    let source: SwitchDecisionSource
    let outcome: SwitchDecisionOutcome
    let requestedProfileId: UUID?
    let requestedProfileName: String?
    let chosenProfileId: UUID?
    let chosenProfileName: String?
    let reason: String
    let detail: String
    let overrideApplied: Bool
    let readiness: [SwitchCandidateReadiness]

    init(
        id: UUID,
        timestamp: Date,
        provider: AIProvider? = nil,
        source: SwitchDecisionSource,
        outcome: SwitchDecisionOutcome,
        requestedProfileId: UUID?,
        requestedProfileName: String?,
        chosenProfileId: UUID?,
        chosenProfileName: String?,
        reason: String,
        detail: String,
        overrideApplied: Bool,
        readiness: [SwitchCandidateReadiness]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.source = source
        self.outcome = outcome
        self.requestedProfileId = requestedProfileId
        self.requestedProfileName = requestedProfileName
        self.chosenProfileId = chosenProfileId
        self.chosenProfileName = chosenProfileName
        self.reason = reason
        self.detail = detail
        self.overrideApplied = overrideApplied
        self.readiness = readiness
    }
}
