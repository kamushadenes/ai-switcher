import Foundation

/// Profilleri ~/.ai-switcher/ altında saklar ve sağlayıcı auth geçişlerini yönetir.
final class ProfileManager: @unchecked Sendable {
    private let claudeManager: ClaudeCodeManager
    private let baseDir: URL
    private let profileStoreDir: URL
    private let claudeLoginStoreDir: URL
    private let configFile: URL
    private let codexAuthFile: URL
    private let authBackupFile: URL

    init(
        baseDirectory: URL? = nil,
        codexAuthPath: URL? = nil,
        claudeManager: ClaudeCodeManager = ClaudeCodeManager()
    ) {
        self.claudeManager = claudeManager
        baseDir = baseDirectory ?? Self.switcherDir
        profileStoreDir = baseDir.appendingPathComponent("profiles")
        claudeLoginStoreDir = baseDir.appendingPathComponent("claude-login-staging")
        configFile = baseDir.appendingPathComponent("config.json")
        self.codexAuthFile = codexAuthPath ?? Self.codexAuthPath
        authBackupFile = baseDir.appendingPathComponent("auth-backup.json")
    }

    // MARK: - Paths

    static let switcherDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".ai-switcher")
    }()

    static let profilesDir: URL = {
        switcherDir.appendingPathComponent("profiles")
    }()

    static let configPath: URL = {
        switcherDir.appendingPathComponent("config.json")
    }()

    static let codexAuthPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }()

    static let authBackupPath: URL = {
        switcherDir.appendingPathComponent("auth-backup.json")
    }()

    // MARK: - Bootstrap

    func bootstrap() {
        let fm = FileManager.default
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: profileStoreDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: claudeLoginStoreDir, withIntermediateDirectories: true)
    }

    // MARK: - Auth Recovery

    /// Verify auth.json on boot and recover if broken. Must run BEFORE loadProfiles().
    func verifyAndRecoverActiveAuthReport(providers: Set<AIProvider> = Set(AIProvider.allCases)) -> AuthRecoveryReport {
        if FileManager.default.fileExists(atPath: authBackupFile.path) {
            try? FileManager.default.removeItem(at: authBackupFile)
        }

        let config = loadConfig()
        var resultsByProfileId: [UUID: AuthVerificationResult] = [:]

        if providers.contains(.codex),
           let codexProfile = activeProfile(in: config, for: .codex) {
            resultsByProfileId[codexProfile.id] = verifyAndRecoverCodexAuth(for: codexProfile)
        }

        if providers.contains(.claude),
           let claudeProfile = activeProfile(in: config, for: .claude) {
            resultsByProfileId[claudeProfile.id] = verifyAndRecoverClaudeAuth(for: claudeProfile)
        }

        return AuthRecoveryReport(resultsByProfileId: resultsByProfileId)
    }

    /// Verify auth.json on boot and recover if broken. Must run BEFORE loadProfiles().
    func verifyAndRecoverActiveAuth() -> AuthVerificationResult {
        verifyAndRecoverActiveAuthReport().result
    }

    private func activeProfile(in config: AppConfig, for provider: AIProvider) -> Profile? {
        guard let activeId = config.activeProfileIdsByProvider[provider] else { return nil }
        return config.profiles.first { $0.id == activeId && $0.provider == provider }
    }

    private func verifyAndRecoverCodexAuth(for activeProfile: Profile) -> AuthVerificationResult {
        if isValidAuthFile(at: codexAuthFile, expectedAccountId: activeProfile.accountId) {
            return .valid
        }

        let profileAuthPath = authPath(for: activeProfile)
        if FileManager.default.fileExists(atPath: profileAuthPath.path),
           let data = try? Data(contentsOf: profileAuthPath),
           isValidAuthData(data, expectedAccountId: activeProfile.accountId) {
            do {
                try data.write(to: codexAuthFile, options: .atomic)
                return .recovered
            } catch {
                print("[AuthRecovery] recovery write failed: \(error)")
                return .unrecoverable
            }
        }

        return .unrecoverable
    }

    private func verifyAndRecoverClaudeAuth(for activeProfile: Profile) -> AuthVerificationResult {
        if verifyClaudeCodeProfile(activeProfile, allowUserPrompt: false) == .verified {
            return .valid
        }

        let profileAuthPath = claudeAuthPath(for: activeProfile)
        guard FileManager.default.fileExists(atPath: profileAuthPath.path),
              let data = try? Data(contentsOf: profileAuthPath) else {
            return .unrecoverable
        }

        if let localVerification = localClaudeCredentialVerification(data, match: activeProfile),
           localVerification != .verified {
            return .unrecoverable
        }

        return .unrecoverable
    }

    private func isValidAuthFile(at url: URL, expectedAccountId: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = dict["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else { return false }
        guard let actualId = extractAccountId(from: accessToken) else { return false }
        return actualId == expectedAccountId
    }

    private func isValidAuthData(_ data: Data, expectedAccountId: String) -> Bool {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = dict["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let actualId = extractAccountId(from: accessToken) else { return false }
        return actualId == expectedAccountId
    }

    // MARK: - Config I/O

    func loadConfig() -> AppConfig {
        guard let data = try? Data(contentsOf: configFile),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return .empty
        }
        return config
    }

    func saveConfig(_ config: AppConfig) {
        var normalized = config
        normalized.normalizeActiveProfiles()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(normalized) else { return }
        try? data.write(to: configFile, options: .atomic)
    }

    // MARK: - Profile Auth Paths

    func authPath(for profile: Profile) -> URL {
        profileStoreDir
            .appendingPathComponent(profile.id.uuidString)
            .appendingPathExtension("json")
    }

    func claudeAuthPath(for profile: Profile) -> URL {
        profileStoreDir
            .appendingPathComponent(profile.id.uuidString)
            .appendingPathExtension("claudeauth")
    }

    func makeClaudeLoginDirectory() -> URL? {
        let dir = claudeLoginStoreDir.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    func removeClaudeLoginDirectory(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Auth Read Helpers

    func readAuthDict(for profile: Profile) -> [String: Any]? {
        guard let data = try? Data(contentsOf: authPath(for: profile)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func readClaudeCredentialsData(for profile: Profile) -> Data? {
        guard profile.provider == .claude else { return nil }
        return try? Data(contentsOf: claudeAuthPath(for: profile))
    }

    func readClaudeUsageCredentialsData(for profile: Profile, isActive: Bool) -> Data? {
        guard profile.provider == .claude else { return nil }
        return readClaudeCredentialsData(for: profile)
    }

    @discardableResult
    func writeClaudeCredentialsData(_ data: Data, for profile: Profile) -> Bool {
        guard profile.provider == .claude else { return false }
        let dest = claudeAuthPath(for: profile)
        do {
            try data.write(to: dest, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            return true
        } catch {
            return false
        }
    }

    private func localClaudeCredentialVerification(_ data: Data, match profile: Profile) -> VerifyResult? {
        guard !data.isEmpty else { return .failed(.fileMissing) }
        if let accountId = claudeManager.parseAccountId(from: data), !accountId.isEmpty {
            return accountId == profile.accountId
                ? .verified
                : .failed(.mismatch(expected: profile.accountId, actual: accountId))
        }
        return nil
    }

    private func claudeAccountMetadataData(for profile: Profile) -> Data? {
        guard profile.provider == .claude else { return nil }
        return ClaudeAccountMetadataStore.accountMetadataData(
            email: profile.email,
            accountId: profile.accountId,
            alias: profile.alias,
            subscriptionType: profile.subscriptionType
        )
    }

    private func verifyClaudeAccountMetadata(for profile: Profile, required: Bool = false) -> VerifyResult {
        guard let data = claudeManager.readAccountMetadataData(),
              let metadata = ClaudeAccountMetadata(data: data) else {
            return required ? .failed(.claimNotFound) : .verified
        }
        guard metadata.matches(accountId: profile.accountId, email: profile.email) else {
            let actual = metadata.organizationId ?? metadata.accountId ?? metadata.email ?? "unknown"
            return .failed(.mismatch(expected: profile.accountId, actual: actual))
        }
        return .verified
    }

    func readLiveAuthDict() -> [String: Any]? {
        guard let data = try? Data(contentsOf: codexAuthFile) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Capture Current Auth

    func captureCurrentAuth(alias: String, provider: AIProvider = .codex) -> Profile? {
        switch provider {
        case .codex:
            return captureCodexAuth(alias: alias)
        case .claude:
            return captureClaudeCodeAuth(alias: alias)
        }
    }

    private func captureCodexAuth(alias: String) -> Profile? {
        guard let data = try? Data(contentsOf: codexAuthFile),
              let authDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = authDict["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let accountId = extractAccountId(from: accessToken) else { return nil }

        let email = extractEmail(from: accessToken) ?? "unknown@codex"
        let profile = Profile(id: UUID(), alias: alias, email: email,
                              accountId: accountId, addedAt: Date(), aiProvider: .codex)
        let dest = authPath(for: profile)
        try? data.write(to: dest, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        return profile
    }

    func captureClaudeCodeAuth(alias: String) -> Profile? {
        guard let data = claudeManager.readCredentialsData(),
              let identity = claudeManager.currentIdentity(credentialsData: data) else { return nil }

        return captureClaudeCodeAuth(alias: alias, credentialsData: data, identity: identity)
    }

    func captureClaudeCodeAuth(alias: String, credentialsData data: Data, identity: ClaudeAccountIdentity) -> Profile? {
        let profile = Profile(
            id: UUID(),
            alias: alias,
            email: identity.email,
            accountId: identity.accountId,
            addedAt: Date(),
            subscriptionType: identity.subscriptionType,
            aiProvider: .claude
        )
        return writeClaudeCredentialsData(data, for: profile) ? profile : nil
    }

    // MARK: - Activate

    @discardableResult
    func activate(profile: Profile) throws -> VerifyResult {
        switch profile.provider {
        case .codex:
            return try activateCodex(profile: profile)
        case .claude:
            return try activateClaudeCode(profile: profile)
        }
    }

    @discardableResult
    private func activateCodex(profile: Profile) throws -> VerifyResult {
        let src = authPath(for: profile)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw SwitcherError.missingAuthFile(profile.email)
        }
        let newData = try Data(contentsOf: src)

        if FileManager.default.fileExists(atPath: codexAuthFile.path) {
            do { try FileManager.default.copyItem(at: codexAuthFile, to: authBackupFile) }
            catch { print("[AuthBackup] backup failed: \(error)") }
        }

        try? FileManager.default.createDirectory(at: codexAuthFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = codexAuthFile.deletingLastPathComponent()
            .appendingPathComponent(".auth_tmp_\(UUID().uuidString).json")
        do {
            try newData.write(to: tmp, options: [])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            guard try FileManager.default.replaceItemAt(codexAuthFile, withItemAt: tmp) != nil else {
                try? FileManager.default.removeItem(at: tmp)
                throw SwitcherError.activationFailed(profile.email)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }

        let verifyResult = verifyActiveAccount(expectedAccountId: profile.accountId)
        if case .failed = verifyResult {
            if FileManager.default.fileExists(atPath: authBackupFile.path) {
                do { _ = try FileManager.default.replaceItemAt(codexAuthFile, withItemAt: authBackupFile) }
                catch { print("[AuthRollback] rollback failed: \(error)") }
            }
        } else {
            try? FileManager.default.removeItem(at: authBackupFile)
        }
        return verifyResult
    }

    private func activateClaudeCode(profile: Profile) throws -> VerifyResult {
        let path = claudeAuthPath(for: profile)
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path) else {
            throw SwitcherError.missingAuthFile(profile.email)
        }
        if let localVerification = localClaudeCredentialVerification(data, match: profile),
           localVerification != .verified {
            return localVerification
        }

        let previousData = claudeManager.readCredentialsData(allowUserPrompt: false)
        let previousMetadataData = claudeManager.readAccountMetadataData()
        guard claudeManager.writeCredentialsData(data, allowUserPrompt: false) else {
            throw SwitcherError.activationFailed(profile.email)
        }
        guard let metadataData = claudeAccountMetadataData(for: profile),
              claudeManager.writeAccountMetadataData(metadataData) else {
            restoreClaudeCredentials(previousData)
            throw SwitcherError.activationFailed(profile.email)
        }
        guard claudeManager.readCredentialsData(allowUserPrompt: false) == data else {
            restoreClaudeCredentials(previousData)
            restoreClaudeMetadata(previousMetadataData)
            return .failed(.claimNotFound)
        }
        let verifyResult = verifyClaudeCodeProfile(profile, allowUserPrompt: false, requireMetadata: true)
        if case .failed = verifyResult {
            restoreClaudeCredentials(previousData)
            restoreClaudeMetadata(previousMetadataData)
        }
        return verifyResult
    }

    private func verifyClaudeCodeProfile(
        _ profile: Profile,
        allowUserPrompt: Bool = false,
        requireMetadata: Bool = false
    ) -> VerifyResult {
        guard let liveData = claudeManager.readCredentialsData(allowUserPrompt: allowUserPrompt) else {
            return .failed(.fileMissing)
        }

        if let storedData = readClaudeCredentialsData(for: profile) {
            if liveData == storedData {
                return verifyClaudeAccountMetadata(for: profile, required: requireMetadata)
            }

            if let liveAccountId = claudeManager.parseAccountId(from: liveData), !liveAccountId.isEmpty {
                guard liveAccountId == profile.accountId else {
                    return .failed(.mismatch(expected: profile.accountId, actual: liveAccountId))
                }
                return verifyClaudeAccountMetadata(for: profile, required: requireMetadata)
            }

            return .failed(.claimNotFound)
        }

        if let actualId = claudeManager.parseAccountId(from: liveData), !actualId.isEmpty {
            guard actualId == profile.accountId else {
                return .failed(.mismatch(expected: profile.accountId, actual: actualId))
            }
            return verifyClaudeAccountMetadata(for: profile, required: requireMetadata)
        }

        return .failed(.claimNotFound)
    }

    private func restoreClaudeCredentials(_ previousData: Data?) {
        if let previousData {
            _ = claudeManager.writeCredentialsData(previousData, allowUserPrompt: false)
        } else {
            _ = claudeManager.deleteCredentialsData(allowUserPrompt: false)
        }
    }

    private func restoreClaudeMetadata(_ previousMetadataData: Data?) {
        guard let previousMetadataData else { return }
        _ = claudeManager.writeAccountMetadataData(previousMetadataData)
    }

    func verifyActiveAccount(expectedAccountId: String) -> VerifyResult {
        guard FileManager.default.fileExists(atPath: codexAuthFile.path) else {
            return .failed(.fileMissing)
        }
        guard let data = try? Data(contentsOf: codexAuthFile),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = dict["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else {
            return .failed(.invalidJSON)
        }
        guard let actualId = extractAccountId(from: accessToken) else {
            return .failed(.jwtParseFailed)
        }
        guard !actualId.isEmpty else { return .failed(.claimNotFound) }
        return actualId == expectedAccountId ? .verified
             : .failed(.mismatch(expected: expectedAccountId, actual: actualId))
    }

    func verifyActiveAccount(for profile: Profile, allowUserPrompt: Bool = false) -> VerifyResult {
        switch profile.provider {
        case .codex:
            return verifyActiveAccount(expectedAccountId: profile.accountId)
        case .claude:
            return verifyClaudeCodeProfile(profile, allowUserPrompt: allowUserPrompt)
        }
    }

    func deleteProfile(_ profile: Profile) {
        try? FileManager.default.removeItem(at: authPath(for: profile))
        try? FileManager.default.removeItem(at: claudeAuthPath(for: profile))
    }

    // MARK: - JWT Helpers

    func extractEmail(from jwt: String) -> String? {
        extractClaim(from: jwt, keyPath: ["https://api.openai.com/profile", "email"])
    }

    func extractAccountId(from jwt: String) -> String? {
        extractClaim(from: jwt, keyPath: ["https://api.openai.com/auth", "chatgpt_account_id"])
    }

    private func extractClaim(from jwt: String, keyPath: [String]) -> String? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }

        var b64 = parts[1]
        let remainder = b64.count % 4
        if remainder != 0 { b64 += String(repeating: "=", count: 4 - remainder) }

        guard let payloadData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        var current: Any = json as Any
        for (i, key) in keyPath.enumerated() {
            if i == keyPath.count - 1 {
                return (current as? [String: Any])?[key] as? String
            }
            guard let next = (current as? [String: Any])?[key] else { return nil }
            current = next
        }
        return nil
    }
}

enum SwitcherError: LocalizedError {
    case missingAuthFile(String)
    case noProfilesAvailable
    case allProfilesExhausted
    case activationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAuthFile(let email):
            return "Auth dosyası bulunamadı: \(email)"
        case .noProfilesAvailable:
            return "Henüz hesap eklenmedi."
        case .allProfilesExhausted:
            return "Tüm hesapların limiti doldu!"
        case .activationFailed(let email):
            return "Aktivasyon başarısız: \(email)"
        }
    }
}

enum AuthVerificationResult: Equatable {
    case valid
    case recovered
    case unrecoverable
}

struct AuthRecoveryReport: Equatable {
    let resultsByProfileId: [UUID: AuthVerificationResult]

    var result: AuthVerificationResult {
        let results = Array(resultsByProfileId.values)
        if results.contains(.unrecoverable) {
            return .unrecoverable
        }
        if results.contains(.recovered) {
            return .recovered
        }
        return .valid
    }

    var unrecoverableProfileIds: Set<UUID> {
        Set(resultsByProfileId.compactMap { profileId, result in
            result == .unrecoverable ? profileId : nil
        })
    }
}

enum VerifyResult: Equatable {
    case verified
    case failed(VerifyError)
}

enum VerifyError: Equatable {
    case fileMissing
    case invalidJSON
    case jwtParseFailed
    case claimNotFound
    case mismatch(expected: String, actual: String)
}
