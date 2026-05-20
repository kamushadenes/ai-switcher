import Foundation

// MARK: - AI Provider

enum AIProvider: String, Codable, CaseIterable {
    case codex = "codex"
    case claude = "claude"

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var shortBadge: String {
        switch self {
        case .codex: return "CX"
        case .claude: return "CL"
        }
    }

    var processName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "claude"
        }
    }

    var loginExecutableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        }
    }

    var loginShellCommand: String {
        switch self {
        case .codex: return "login"
        case .claude: return "auth login"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "claudeCode" {
            self = .claude
        } else {
            self = AIProvider(rawValue: raw) ?? .codex
        }
    }
}

// MARK: - Profile

struct Profile: Identifiable, Codable, Equatable {
    let id: UUID
    var alias: String
    var email: String
    var accountId: String
    var addedAt: Date
    var activatedAt: Date?
    var lastKnownTurns: Int?
    var subscriptionType: String?
    var aiProvider: AIProvider
    var provider: AIProvider {
        get { aiProvider }
        set { aiProvider = newValue }
    }

     init(id: UUID = UUID(), alias: String, email: String, accountId: String,
         addedAt: Date, activatedAt: Date? = nil, lastKnownTurns: Int? = nil,
         subscriptionType: String? = nil,
         aiProvider: AIProvider = .codex) {
        self.id = id; self.alias = alias; self.email = email
        self.accountId = accountId; self.addedAt = addedAt
        self.activatedAt = activatedAt; self.lastKnownTurns = lastKnownTurns
        self.subscriptionType = subscriptionType
        self.aiProvider = aiProvider
    }

    // Backward-compatible decoder: old profiles missing aiProvider default to .codex
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self,   forKey: .id)
        alias         = try c.decode(String.self, forKey: .alias)
        email         = try c.decode(String.self, forKey: .email)
        accountId     = try c.decode(String.self, forKey: .accountId)
        addedAt       = try c.decode(Date.self,   forKey: .addedAt)
        activatedAt   = try c.decodeIfPresent(Date.self,       forKey: .activatedAt)
        lastKnownTurns = try c.decodeIfPresent(Int.self,       forKey: .lastKnownTurns)
        subscriptionType = try c.decodeIfPresent(String.self,  forKey: .subscriptionType)
        aiProvider    = try c.decodeIfPresent(AIProvider.self, forKey: .aiProvider) ?? .codex
    }

    var displayName: String { alias.isEmpty ? email : alias }

    var shortEmail: String {
        let local = email.components(separatedBy: "@").first ?? email
        return local.count > 14 ? String(local.prefix(14)) + "…" : local
    }

    var initial: String { String(displayName.prefix(1).uppercased()) }
}

struct AppConfig: Codable {
    var profiles: [Profile]
    var activeProfileId: UUID?
    var activeProfileIdsByProvider: [AIProvider: UUID]
    var selectedProvider: AIProvider
    var roundRobinIndex: Int

    enum CodingKeys: String, CodingKey {
        case profiles
        case activeProfileId
        case activeProfileIdsByProvider
        case selectedProvider
        case roundRobinIndex
    }

    init(
        profiles: [Profile],
        activeProfileId: UUID?,
        activeProfileIdsByProvider: [AIProvider: UUID] = [:],
        selectedProvider: AIProvider = .codex,
        roundRobinIndex: Int
    ) {
        self.profiles = profiles
        self.activeProfileId = activeProfileId
        self.activeProfileIdsByProvider = activeProfileIdsByProvider
        self.selectedProvider = selectedProvider
        self.roundRobinIndex = roundRobinIndex
        normalizeActiveProfiles()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        activeProfileId = try c.decodeIfPresent(UUID.self, forKey: .activeProfileId)
        if let rawMap = try c.decodeIfPresent([String: UUID].self, forKey: .activeProfileIdsByProvider) {
            activeProfileIdsByProvider = Dictionary(uniqueKeysWithValues: rawMap.compactMap { key, value in
                let provider = key == "claudeCode" ? AIProvider.claude : AIProvider(rawValue: key)
                return provider.map { ($0, value) }
            })
        } else {
            activeProfileIdsByProvider = [:]
        }
        selectedProvider = try c.decodeIfPresent(AIProvider.self, forKey: .selectedProvider) ?? .codex
        roundRobinIndex = try c.decodeIfPresent(Int.self, forKey: .roundRobinIndex) ?? 0
        normalizeActiveProfiles()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profiles, forKey: .profiles)
        try c.encodeIfPresent(activeProfileId, forKey: .activeProfileId)
        let providerMap = Dictionary(uniqueKeysWithValues: activeProfileIdsByProvider.map { ($0.key.rawValue, $0.value) })
        try c.encode(providerMap, forKey: .activeProfileIdsByProvider)
        try c.encode(selectedProvider, forKey: .selectedProvider)
        try c.encode(roundRobinIndex, forKey: .roundRobinIndex)
    }

    mutating func normalizeActiveProfiles() {
        if let activeProfileId,
           let profile = profiles.first(where: { $0.id == activeProfileId }) {
            activeProfileIdsByProvider[profile.provider] = activeProfileId
        }

        for provider in AIProvider.allCases {
            if let activeId = activeProfileIdsByProvider[provider],
               profiles.contains(where: { $0.id == activeId && $0.provider == provider }) {
                continue
            }
            activeProfileIdsByProvider[provider] = profiles.first(where: { $0.provider == provider })?.id
        }

        activeProfileId = activeProfileIdsByProvider[selectedProvider]
            ?? activeProfileIdsByProvider[.codex]
            ?? profiles.first?.id
    }

    mutating func setActiveProfile(_ profile: Profile) {
        activeProfileIdsByProvider[profile.provider] = profile.id
        selectedProvider = profile.provider
        activeProfileId = profile.id
    }

    static let empty = AppConfig(profiles: [], activeProfileId: nil, roundRobinIndex: 0)
}

enum SwitchOrchestrationState: String, Codable {
    case idle
    case pendingSwitch
    case readyToSwitch
    case verifying
}

struct PendingSwitchRequest: Equatable {
    let targetProfileId: UUID
    let targetProfileName: String
    var provider: AIProvider = .codex
    let reason: String
    let queuedAt: Date
}

struct SeamlessSwitchResult: Equatable {
    enum Outcome: String, Codable {
        case deferred
        case seamlessSuccess
        case fallbackRestart
        case inconclusive
    }

    let outcome: Outcome
    let recordedAt: Date
    let detail: String
}

struct SeamlessVerificationAttempt: Equatable {
    let targetProfileId: UUID
    let targetProfileName: String
    var provider: AIProvider = .codex
    let startedAt: Date
}

struct SwitchReliabilitySnapshot: Equatable {
    var pendingSwitchCount: Int = 0
    var completedDeferredSwitchCount: Int = 0
    var seamlessSuccessCount: Int = 0
    var inconclusiveCount: Int = 0
    var fallbackRestartCount: Int = 0
    var blockedDecisionCount: Int = 0
    var haltedDecisionCount: Int = 0
}

struct SwitchTimelineEvent: Codable, Identifiable, Equatable {
    enum Stage: String, Codable {
        case queued
        case ready
        case verifying
        case seamlessSuccess
        case fallbackRestart
        case inconclusive
        case blocked
        case halted
    }

    let id: UUID
    let timestamp: Date
    let provider: AIProvider?
    let stage: Stage
    let targetProfileName: String
    let reason: String?
    let detail: String
    let waitDurationSeconds: Int?
    let verificationDurationSeconds: Int?

    init(
        id: UUID,
        timestamp: Date,
        provider: AIProvider? = nil,
        stage: Stage,
        targetProfileName: String,
        reason: String?,
        detail: String,
        waitDurationSeconds: Int?,
        verificationDurationSeconds: Int?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.stage = stage
        self.targetProfileName = targetProfileName
        self.reason = reason
        self.detail = detail
        self.waitDurationSeconds = waitDurationSeconds
        self.verificationDurationSeconds = verificationDurationSeconds
    }
}

enum AutomationConfidenceStatus: String, Codable {
    case healthy
    case warning
    case critical
}

struct AutomationConfidenceSummary: Equatable {
    let status: AutomationConfidenceStatus
    let highlight: String
    let staleProfileCount: Int
    let fallbackRestartCount: Int
    let seamlessSuccessCount: Int
    let blockedDecisionCount: Int
    let haltedDecisionCount: Int
    let stuckPendingSwitch: Bool
    let lastVerifiedSwitchAt: Date?

    static let empty = AutomationConfidenceSummary(
        status: .healthy,
        highlight: "Automation looks healthy.",
        staleProfileCount: 0,
        fallbackRestartCount: 0,
        seamlessSuccessCount: 0,
        blockedDecisionCount: 0,
        haltedDecisionCount: 0,
        stuckPendingSwitch: false,
        lastVerifiedSwitchAt: nil
    )
}

enum AccountReliabilityStatus: String, Codable {
    case healthy
    case warning
    case critical
}

struct AccountReliabilitySummary: Identifiable, Equatable {
    var id: UUID { profileId }

    let profileId: UUID
    let provider: AIProvider
    let profileName: String
    let status: AccountReliabilityStatus
    let detail: String
    let lastCheckedAt: Date?
    let cost: Double?
    let riskLabel: String?

    init(
        profileId: UUID,
        provider: AIProvider = .codex,
        profileName: String,
        status: AccountReliabilityStatus,
        detail: String,
        lastCheckedAt: Date?,
        cost: Double?,
        riskLabel: String?
    ) {
        self.profileId = profileId
        self.provider = provider
        self.profileName = profileName
        self.status = status
        self.detail = detail
        self.lastCheckedAt = lastCheckedAt
        self.cost = cost
        self.riskLabel = riskLabel
    }
}

enum AutomationAlertSeverity: String, Codable {
    case warning
    case critical
}

struct AutomationAlert: Equatable {
    let fingerprint: String
    let severity: AutomationAlertSeverity
    let title: String
    let body: String
}

// MARK: - Switch History

struct SwitchEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    var provider: AIProvider? = nil
    let fromAccountName: String?
    let fromAccountId: UUID?
    let toAccountName: String
    let toAccountId: UUID
    let reason: String
}

// MARK: - Token Usage

struct AccountTokenUsage: Codable {
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var sessionCount: Int = 0
    var modelUsage: [String: ModelTokenUsage] = [:]  // model name -> usage

    var totalTokens: Int { inputTokens + outputTokens }
    var effectiveInputTokens: Int { max(0, inputTokens - cachedInputTokens) }

    static func + (lhs: AccountTokenUsage, rhs: AccountTokenUsage) -> AccountTokenUsage {
        var mergedModels = lhs.modelUsage
        for (model, usage) in rhs.modelUsage {
            mergedModels[model, default: ModelTokenUsage()] = mergedModels[model, default: ModelTokenUsage()] + usage
        }
        return AccountTokenUsage(
            inputTokens:       lhs.inputTokens       + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens:      lhs.outputTokens      + rhs.outputTokens,
            reasoningTokens:   lhs.reasoningTokens   + rhs.reasoningTokens,
            sessionCount:      lhs.sessionCount      + rhs.sessionCount,
            modelUsage:        mergedModels
        )
    }
}

/// Per-model token usage tracking
struct ModelTokenUsage: Codable, Equatable {
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var sessionCount: Int = 0

    var totalTokens: Int { inputTokens + outputTokens }

    static func + (lhs: ModelTokenUsage, rhs: ModelTokenUsage) -> ModelTokenUsage {
        ModelTokenUsage(
            inputTokens:       lhs.inputTokens       + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens:      lhs.outputTokens      + rhs.outputTokens,
            sessionCount:      lhs.sessionCount      + rhs.sessionCount
        )
    }
    
    static func += (lhs: inout ModelTokenUsage, rhs: ModelTokenUsage) {
        lhs.inputTokens += rhs.inputTokens
        lhs.cachedInputTokens += rhs.cachedInputTokens
        lhs.outputTokens += rhs.outputTokens
        lhs.sessionCount += rhs.sessionCount
    }
}

// MARK: - Daily Usage (for 7-day chart)

struct DailyUsage: Identifiable, Equatable, Sendable {
    let dayStart: Date   // start of calendar day (local timezone)
    let tokens: Int      // total input + output tokens for this day
    var id: TimeInterval { dayStart.timeIntervalSince1970 }
}

enum AnalyticsTimeRange: String, Codable, CaseIterable {
    case twentyFourHours
    case sevenDays
    case thirtyDays
    case allTime

    var title: String {
        switch self {
        case .twentyFourHours: return "24h"
        case .sevenDays: return "7d"
        case .thirtyDays: return "30d"
        case .allTime: return "All"
        }
    }

    var dayWindow: Int? {
        switch self {
        case .twentyFourHours: return 1
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .allTime: return nil
        }
    }

    func cutoffDate(from now: Date) -> Date? {
        switch self {
        case .twentyFourHours:
            return now.addingTimeInterval(-24 * 3600)
        case .sevenDays:
            return now.addingTimeInterval(-7 * 24 * 3600)
        case .thirtyDays:
            return now.addingTimeInterval(-30 * 24 * 3600)
        case .allTime:
            return nil
        }
    }
}

enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case failed
}

struct UpdateReleaseInfo: Equatable, Sendable {
    let version: String
    let releaseURL: URL
    let tagName: String
}

struct UpdateStatusSnapshot: Equatable, Sendable {
    let currentVersion: String
    let latestVersion: String?
    let release: UpdateReleaseInfo?
    let lastCheckedAt: Date?
    let state: UpdateCheckState
    let errorSummary: String?

    static func idle(currentVersion: String) -> UpdateStatusSnapshot {
        UpdateStatusSnapshot(
            currentVersion: currentVersion,
            latestVersion: nil,
            release: nil,
            lastCheckedAt: nil,
            state: .idle,
            errorSummary: nil
        )
    }

    static func checking(currentVersion: String, latestVersion: String?, release: UpdateReleaseInfo?, lastCheckedAt: Date?) -> UpdateStatusSnapshot {
        UpdateStatusSnapshot(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            release: release,
            lastCheckedAt: lastCheckedAt,
            state: .checking,
            errorSummary: nil
        )
    }
}

enum RateLimitStaleReason: String, Codable, Sendable {
    case unauthorized
    case forbidden
    case invalidAuth
    case unknown

    var summary: String {
        switch self {
        case .unauthorized: return "401 unauthorized"
        case .forbidden: return "403 forbidden"
        case .invalidAuth: return "invalid auth"
        case .unknown: return "stale auth"
        }
    }
}

struct RateLimitHealthStatus: Sendable {
    var lastCheckedAt: Date?
    var lastSuccessfulFetchAt: Date?
    var lastFailedFetchAt: Date?
    var lastHTTPStatusCode: Int?
    var staleReason: RateLimitStaleReason?
    var failureSummary: String?
}

// MARK: - Codex Insights

struct ProjectUsage: Identifiable, Equatable, Sendable {
    let id: String          // cwd path as stable key
    let name: String        // last path component
    let path: String
    let tokens: Int
    let cost: Double
    let sessionCount: Int
    let lastUsed: Date
}

struct SessionSummary: Identifiable, Equatable, Sendable {
    let id: String          // session UUID
    let provider: AIProvider
    let projectName: String
    let projectPath: String
    let firstPrompt: String
    let tokens: Int
    let timestamp: Date
    let depth: Int
    let agentRole: String
    let parentId: String?   // nil = root session

    init(
        id: String,
        provider: AIProvider = .codex,
        projectName: String,
        projectPath: String,
        firstPrompt: String,
        tokens: Int,
        timestamp: Date,
        depth: Int,
        agentRole: String,
        parentId: String?
    ) {
        self.id = id
        self.provider = provider
        self.projectName = projectName
        self.projectPath = projectPath
        self.firstPrompt = firstPrompt
        self.tokens = tokens
        self.timestamp = timestamp
        self.depth = depth
        self.agentRole = agentRole
        self.parentId = parentId
    }
}

struct HourlyActivity: Identifiable, Equatable, Sendable {
    let hour: Int           // 0–23
    let dayOfWeek: Int      // 0=Mon … 6=Sun
    let tokens: Int
    var id: String { "\(dayOfWeek)-\(hour)" }
}

struct ExpensiveTurn: Identifiable, Equatable, Sendable {
    let id: String
    let projectName: String
    let promptPreview: String
    let inputTokens: Int
    let outputTokens: Int
    let cost: Double
    let timestamp: Date
    let model: String

    var tokens: Int { inputTokens + outputTokens }
}

// MARK: - Session Event

struct SessionEvent: Codable {
    let timestamp: String
    let type: String
    let payload: PayloadData

    struct PayloadData: Codable {
        let type: String?
        let error: ErrorData?
        let statusCode: Int?

        enum CodingKeys: String, CodingKey {
            case type
            case error
            case statusCode = "status_code"
        }
    }

    struct ErrorData: Codable {
        let code: String?
        let type: String?
        let message: String?
    }
}
