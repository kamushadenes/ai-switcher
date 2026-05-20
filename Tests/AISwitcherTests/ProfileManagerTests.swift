import Foundation
import Testing
@testable import AISwitcher

struct ProfileManagerTests {

    // MARK: - Helpers

    /// Creates a signed-less JWT (header.payload.fake) with the given payload.
    private func makeJWT(payload: [String: Any]) -> String {
        let header = Data("{\"alg\":\"none\"}".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)
        let payloadB64 = payloadData
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(payloadB64).fake"
    }

    private func makeCodexAuthData(accountId: String, email: String = "dev@example.com") throws -> Data {
        let token = makeJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": accountId],
            "https://api.openai.com/profile": ["email": email]
        ])
        return try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "access_token": token
            ]
        ])
    }

    // MARK: - extractAccountId

    @Test("extractAccountId returns chatgpt_account_id from well-formed JWT")
    func extractAccountIdFromValidJWT() {
        let pm = ProfileManager()
        let jwt = makeJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "user-abc123"]
        ])
        #expect(pm.extractAccountId(from: jwt) == "user-abc123")
    }

    @Test("extractAccountId returns nil when top-level auth key is absent")
    func extractAccountIdMissingTopLevelKey() {
        let pm = ProfileManager()
        let jwt = makeJWT(payload: ["sub": "irrelevant"])
        #expect(pm.extractAccountId(from: jwt) == nil)
    }

    @Test("extractAccountId returns nil when nested chatgpt_account_id key is absent")
    func extractAccountIdMissingNestedKey() {
        let pm = ProfileManager()
        let jwt = makeJWT(payload: [
            "https://api.openai.com/auth": ["other_field": "value"]
        ])
        #expect(pm.extractAccountId(from: jwt) == nil)
    }

    @Test("extractAccountId returns nil for a non-JWT string")
    func extractAccountIdForNonJWT() {
        let pm = ProfileManager()
        #expect(pm.extractAccountId(from: "not-a-jwt") == nil)
        #expect(pm.extractAccountId(from: "") == nil)
    }

    @Test("extractAccountId returns nil when payload segment is not valid base64-JSON")
    func extractAccountIdInvalidPayloadSegment() {
        let pm = ProfileManager()
        #expect(pm.extractAccountId(from: "header.!!!invalid!!!.sig") == nil)
    }

    @Test("extractAccountId handles base64 segments that need padding")
    func extractAccountIdPaddingRestored() {
        // makeJWT strips '=' padding; the parser must restore it before decoding.
        let pm = ProfileManager()
        let jwt = makeJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-xyz789"]
        ])
        // Verify the payload segment has no '=' before parsing — confirms the test
        // actually exercises the padding-restoration path in extractClaim.
        let segment = jwt.components(separatedBy: ".")[1]
        #expect(!segment.contains("="))
        #expect(pm.extractAccountId(from: jwt) == "acct-xyz789")
    }

    // MARK: - extractEmail

    @Test("extractEmail returns email from well-formed JWT")
    func extractEmailFromValidJWT() {
        let pm = ProfileManager()
        let jwt = makeJWT(payload: [
            "https://api.openai.com/profile": ["email": "dev@example.com"]
        ])
        #expect(pm.extractEmail(from: jwt) == "dev@example.com")
    }

    @Test("extractEmail returns nil when profile key is absent")
    func extractEmailMissingProfileKey() {
        let pm = ProfileManager()
        let jwt = makeJWT(payload: ["sub": "user-999"])
        #expect(pm.extractEmail(from: jwt) == nil)
    }

    @Test("extractEmail returns nil when email field is absent inside profile")
    func extractEmailMissingEmailField() {
        let pm = ProfileManager()
        let jwt = makeJWT(payload: [
            "https://api.openai.com/profile": ["name": "Alice"]
        ])
        #expect(pm.extractEmail(from: jwt) == nil)
    }

    // MARK: - Both claims in one JWT

    @Test("extractAccountId and extractEmail both resolve from a single JWT")
    func bothClaimsFromOneJWT() {
        let pm = ProfileManager()
        let jwt = makeJWT(payload: [
            "https://api.openai.com/auth":    ["chatgpt_account_id": "acct-multi"],
            "https://api.openai.com/profile": ["email": "multi@example.com"]
        ])
        #expect(pm.extractAccountId(from: jwt) == "acct-multi")
        #expect(pm.extractEmail(from: jwt) == "multi@example.com")
    }

    // MARK: - Startup recovery

    @Test
    func recoveryRepairsCodexAuthWhenClaudeIsSelected() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let codexAuthPath = tempDir
            .appendingPathComponent("codex")
            .appendingPathComponent("auth.json")
        let claudeData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-claude",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "claude@example.com", "sub": "user-claude"])
            ]
        ])
        let manager = ProfileManager(
            baseDirectory: tempDir.appendingPathComponent("switcher"),
            codexAuthPath: codexAuthPath,
            claudeManager: ClaudeCodeManager(
                store: FakeClaudeCredentialsStore(data: claudeData),
                metadataStore: ClaudeAccountMetadataStore(configDirectory: tempDir.appendingPathComponent(".claude")),
                authStatusLoader: { nil }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let codex = Profile(alias: "Codex", email: "codex@example.com", accountId: "acct-codex", addedAt: Date())
        let claude = Profile(alias: "Claude", email: "claude@example.com", accountId: "org-claude", addedAt: Date(), aiProvider: .claude)
        manager.saveConfig(AppConfig(
            profiles: [codex, claude],
            activeProfileId: claude.id,
            activeProfileIdsByProvider: [.codex: codex.id, .claude: claude.id],
            selectedProvider: .claude,
            roundRobinIndex: 0
        ))

        try FileManager.default.createDirectory(at: codexAuthPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"bad.jwt.value"}}"#.utf8).write(to: codexAuthPath)
        try makeCodexAuthData(accountId: codex.accountId, email: codex.email).write(to: manager.authPath(for: codex))
        try claudeData.write(to: manager.claudeAuthPath(for: claude))

        #expect(manager.verifyAndRecoverActiveAuth() == .recovered)
        #expect(manager.verifyActiveAccount(for: codex) == .verified)
    }

    @Test
    func scopedCodexRecoveryDoesNotTouchClaudeAuthStatus() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let codexAuthPath = tempDir
            .appendingPathComponent("codex")
            .appendingPathComponent("auth.json")
        let counter = AuthStatusCounter()
        let manager = ProfileManager(
            baseDirectory: tempDir.appendingPathComponent("switcher"),
            codexAuthPath: codexAuthPath,
            claudeManager: ClaudeCodeManager(
                store: FakeClaudeCredentialsStore(),
                authStatusLoader: {
                    counter.count += 1
                    return nil
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let codex = Profile(alias: "Codex", email: "codex@example.com", accountId: "acct-codex", addedAt: Date())
        let claude = Profile(alias: "Claude", email: "claude@example.com", accountId: "org-claude", addedAt: Date(), aiProvider: .claude)
        manager.saveConfig(AppConfig(
            profiles: [codex, claude],
            activeProfileId: claude.id,
            activeProfileIdsByProvider: [.codex: codex.id, .claude: claude.id],
            selectedProvider: .claude,
            roundRobinIndex: 0
        ))

        try FileManager.default.createDirectory(at: codexAuthPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"bad.jwt.value"}}"#.utf8).write(to: codexAuthPath)
        try makeCodexAuthData(accountId: codex.accountId, email: codex.email).write(to: manager.authPath(for: codex))

        let report = manager.verifyAndRecoverActiveAuthReport(providers: [.codex])

        #expect(report.result == .recovered)
        #expect(report.resultsByProfileId[claude.id] == nil)
        #expect(counter.count == 0)
    }

    @Test
    func recoveryDoesNotRestoreClaudeCredentialsWithoutSwitch() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let liveData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-live",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "live@example.com", "sub": "user-live"])
            ]
        ])
        let storedData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-active",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "active@example.com", "sub": "user-active"])
            ]
        ])
        let store = FakeClaudeCredentialsStore(data: liveData)
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(store: store, authStatusLoader: { nil })
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        manager.saveConfig(AppConfig(
            profiles: [claude],
            activeProfileId: claude.id,
            activeProfileIdsByProvider: [.claude: claude.id],
            selectedProvider: .claude,
            roundRobinIndex: 0
        ))
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        #expect(manager.verifyAndRecoverActiveAuth() == .unrecoverable)
        #expect(ClaudeCodeManager.parseAccountId(from: store.data ?? Data()) == "org-live")
    }

    @Test
    func recoveryReportScopesUnrecoverableProfilesByProvider() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let codexAuthPath = tempDir
            .appendingPathComponent("codex")
            .appendingPathComponent("auth.json")
        let liveClaudeData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-live",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "live@example.com", "sub": "user-live"])
            ]
        ])
        let storedClaudeData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-claude",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "claude@example.com", "sub": "user-claude"])
            ]
        ])
        let manager = ProfileManager(
            baseDirectory: tempDir.appendingPathComponent("switcher"),
            codexAuthPath: codexAuthPath,
            claudeManager: ClaudeCodeManager(
                store: FakeClaudeCredentialsStore(data: liveClaudeData),
                authStatusLoader: { nil }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let codex = Profile(alias: "Codex", email: "codex@example.com", accountId: "acct-codex", addedAt: Date())
        let claude = Profile(alias: "Claude", email: "claude@example.com", accountId: "org-claude", addedAt: Date(), aiProvider: .claude)
        manager.saveConfig(AppConfig(
            profiles: [codex, claude],
            activeProfileId: claude.id,
            activeProfileIdsByProvider: [.codex: codex.id, .claude: claude.id],
            selectedProvider: .claude,
            roundRobinIndex: 0
        ))

        try FileManager.default.createDirectory(at: codexAuthPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"bad.jwt.value"}}"#.utf8).write(to: codexAuthPath)
        try storedClaudeData.write(to: manager.claudeAuthPath(for: claude))

        let report = manager.verifyAndRecoverActiveAuthReport()

        #expect(report.result == .unrecoverable)
        #expect(Set(report.unrecoverableProfileIds) == Set([codex.id, claude.id]))
        #expect(report.resultsByProfileId[claude.id] == .unrecoverable)
    }

    @Test
    func claudeVerificationUsesCredentialFileWithoutAuthStatusOverride() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let staleData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-active",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "active@example.com", "sub": "user-active"])
            ]
        ])
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(
                store: FakeClaudeCredentialsStore(data: staleData),
                metadataStore: ClaudeAccountMetadataStore(configDirectory: tempDir.appendingPathComponent(".claude")),
                authStatusLoader: {
                    ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "api_key",
                        apiProvider: "anthropic",
                        email: nil,
                        orgId: nil,
                        orgName: nil,
                        subscriptionType: nil
                    )
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )

        #expect(manager.verifyActiveAccount(for: claude, allowUserPrompt: true) == .verified)
    }

    @Test
    func silentClaudeVerificationUsesCredentialFileWithoutAuthStatusFallback() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let staleData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-active",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "active@example.com", "sub": "user-active"])
            ]
        ])
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(
                store: FakeClaudeCredentialsStore(data: staleData),
                metadataStore: ClaudeAccountMetadataStore(configDirectory: tempDir.appendingPathComponent(".claude")),
                authStatusLoader: {
                    ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "api_key",
                        apiProvider: "anthropic",
                        email: nil,
                        orgId: nil,
                        orgName: nil,
                        subscriptionType: nil
                    )
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )

        #expect(manager.verifyActiveAccount(for: claude, allowUserPrompt: false) == .verified)
    }

    @Test
    func claudeVerificationDoesNotUseAuthStatusToOverrideCredentialMismatch() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let staleData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "stale-org",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "stale@example.com", "sub": "stale-user"])
            ]
        ])
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(
                store: FakeClaudeCredentialsStore(data: staleData),
                authStatusLoader: {
                    ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "claude.ai",
                        apiProvider: "firstParty",
                        email: "active@example.com",
                        orgId: "org-active",
                        orgName: nil,
                        subscriptionType: "max"
                    )
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )

        #expect(
            manager.verifyActiveAccount(for: claude, allowUserPrompt: true) ==
            .failed(.mismatch(expected: "org-active", actual: "stale-org"))
        )
    }

    @Test
    func recoveryDoesNotRestoreOpaqueClaudeCredentialsUsingAuthStatus() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let liveData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "opaque-live-token"]
        ])
        let storedData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "opaque-active-token"]
        ])
        let store = FakeClaudeCredentialsStore(data: liveData)
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(
                store: store,
                authStatusLoader: {
                    let isActive = store.data == storedData
                    return ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "claude.ai",
                        apiProvider: "firstParty",
                        email: isActive ? "active@example.com" : "live@example.com",
                        orgId: isActive ? "org-active" : "org-live",
                        orgName: nil,
                        subscriptionType: "max"
                    )
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        manager.saveConfig(AppConfig(
            profiles: [claude],
            activeProfileId: claude.id,
            activeProfileIdsByProvider: [.claude: claude.id],
            selectedProvider: .claude,
            roundRobinIndex: 0
        ))
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        #expect(manager.verifyAndRecoverActiveAuth() == .unrecoverable)
        #expect(store.data == liveData)
    }

    @Test
    func recoveryDoesNotRestoreOpaqueClaudeCredentialsWhenLiveCredentialDiffers() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let liveData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "opaque-live-token"]
        ])
        let storedData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "opaque-stored-token"]
        ])
        let store = FakeClaudeCredentialsStore(data: liveData)
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(
                store: store,
                authStatusLoader: {
                    ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "claude.ai",
                        apiProvider: "firstParty",
                        email: "wrong@example.com",
                        orgId: "org-wrong",
                        orgName: nil,
                        subscriptionType: "max"
                    )
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        manager.saveConfig(AppConfig(
            profiles: [claude],
            activeProfileId: claude.id,
            activeProfileIdsByProvider: [.claude: claude.id],
            selectedProvider: .claude,
            roundRobinIndex: 0
        ))
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        #expect(manager.verifyAndRecoverActiveAuth() == .unrecoverable)
        #expect(store.data == liveData)
    }

    @Test
    func recoveryDoesNotCreateFreshOpaqueClaudeCredentials() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let storedData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "opaque-stored-token"]
        ])
        let store = FakeClaudeCredentialsStore()
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(
                store: store,
                authStatusLoader: {
                    ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "claude.ai",
                        apiProvider: "firstParty",
                        email: "wrong@example.com",
                        orgId: "org-wrong",
                        orgName: nil,
                        subscriptionType: "max"
                    )
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        manager.saveConfig(AppConfig(
            profiles: [claude],
            activeProfileId: claude.id,
            activeProfileIdsByProvider: [.claude: claude.id],
            selectedProvider: .claude,
            roundRobinIndex: 0
        ))
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        #expect(manager.verifyAndRecoverActiveAuth() == .unrecoverable)
        #expect(store.data == nil)
    }

    @Test
    func activationRejectsMismatchedClaudeCredentialsWithoutOverwritingLiveCredential() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let liveData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-live",
            "claudeAiOauth": ["accessToken": "live-token"]
        ])
        let storedData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-wrong",
            "claudeAiOauth": ["accessToken": "stored-token"]
        ])
        let store = FakeClaudeCredentialsStore(data: liveData)
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(store: store, authStatusLoader: { nil })
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        #expect(try manager.activate(profile: claude) == .failed(.mismatch(expected: "org-active", actual: "org-wrong")))
        #expect(store.data == liveData)
    }

    @Test
    func activationCopiesClaudeCredentialsAndPatchesClaudeRootMetadataOnly() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let liveConfigDir = tempDir.appendingPathComponent(".claude")
        let liveAccountDir = liveConfigDir
            .appendingPathComponent("accounts")
            .appendingPathComponent("iniciador")
        let liveCredentialPath = liveAccountDir.appendingPathComponent(".credentials.json")
        let settingsPath = liveConfigDir.appendingPathComponent("settings.json")
        let rootConfigPath = tempDir.appendingPathComponent(".claude.json")
        let liveData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-live",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "live@example.com", "sub": "user-live"])
            ]
        ])
        let storedData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-active",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "active@example.com", "sub": "user-active"])
            ]
        ])
        let settingsData = Data(#"{"managedBy":"nix"}"#.utf8)
        try FileManager.default.createDirectory(at: liveAccountDir, withIntermediateDirectories: true)
        try liveData.write(to: liveCredentialPath)
        try settingsData.write(to: settingsPath)
        try Data("""
        {
          "managed": "keep",
          "oauthAccount": {
            "emailAddress": "live@example.com",
            "organizationUuid": "org-live",
            "organizationName": "Live",
            "displayName": "Live",
            "accountUuid": "leave-alone"
          },
          "projects": {
            "/tmp/example": {
              "allowedTools": ["Bash"]
            }
          }
        }
        """.utf8).write(to: rootConfigPath)
        let manager = ProfileManager(
            baseDirectory: tempDir.appendingPathComponent("switcher"),
            claudeManager: ClaudeCodeManager(
                store: ClaudeCredentialsFileStore(configDirectory: liveConfigDir),
                metadataStore: ClaudeAccountMetadataStore(configDirectory: liveConfigDir),
                authStatusLoader: { nil }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        #expect(try manager.activate(profile: claude) == .verified)
        #expect(try Data(contentsOf: liveCredentialPath) == storedData)
        #expect(try Data(contentsOf: settingsPath) == settingsData)
        #expect(try String(contentsOf: rootConfigPath, encoding: .utf8) == """
        {
          "managed": "keep",
          "oauthAccount": {
            "emailAddress": "active@example.com",
            "organizationUuid": "org-active",
            "organizationName": "Claude",
            "displayName": "Claude",
            "accountUuid": "leave-alone"
          },
          "projects": {
            "/tmp/example": {
              "allowedTools": ["Bash"]
            }
          }
        }
        """)
    }

    @Test
    func verificationFailsWhenClaudeCredentialsMatchButRootMetadataIsStale() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let liveConfigDir = tempDir.appendingPathComponent(".claude")
        let rootConfigPath = tempDir.appendingPathComponent(".claude.json")
        let storedData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-active",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "active@example.com", "sub": "user-active"])
            ]
        ])
        try FileManager.default.createDirectory(at: liveConfigDir, withIntermediateDirectories: true)
        try Data("""
        {
          "oauthAccount": {
            "emailAddress": "stale@example.com",
            "organizationUuid": "org-stale"
          }
        }
        """.utf8).write(to: rootConfigPath)
        let manager = ProfileManager(
            baseDirectory: tempDir.appendingPathComponent("switcher"),
            claudeManager: ClaudeCodeManager(
                store: FakeClaudeCredentialsStore(data: storedData),
                metadataStore: ClaudeAccountMetadataStore(configDirectory: liveConfigDir),
                authStatusLoader: { nil }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        #expect(
            manager.verifyActiveAccount(for: claude, allowUserPrompt: false) ==
            .failed(.mismatch(expected: "org-active", actual: "org-stale"))
        )
    }

    @Test
    func verificationRejectsStaleClaudeRootOrganizationEvenWhenEmailMatches() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let liveConfigDir = tempDir.appendingPathComponent(".claude")
        let rootConfigPath = tempDir.appendingPathComponent(".claude.json")
        let storedData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-active",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "active@example.com", "sub": "user-active"])
            ]
        ])
        try FileManager.default.createDirectory(at: liveConfigDir, withIntermediateDirectories: true)
        try Data("""
        {
          "oauthAccount": {
            "emailAddress": "active@example.com",
            "organizationUuid": "org-stale"
          }
        }
        """.utf8).write(to: rootConfigPath)
        let manager = ProfileManager(
            baseDirectory: tempDir.appendingPathComponent("switcher"),
            claudeManager: ClaudeCodeManager(
                store: FakeClaudeCredentialsStore(data: storedData),
                metadataStore: ClaudeAccountMetadataStore(configDirectory: liveConfigDir),
                authStatusLoader: { nil }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        #expect(
            manager.verifyActiveAccount(for: claude, allowUserPrompt: false) ==
            .failed(.mismatch(expected: "org-active", actual: "org-stale"))
        )
    }

    @Test
    func activationCopiesFreshOpaqueClaudeCredentialsWithoutAuthStatusValidation() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let storedData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "opaque-stored-token"]
        ])
        let store = FakeClaudeCredentialsStore()
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(
                store: store,
                authStatusLoader: {
                    ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "claude.ai",
                        apiProvider: "firstParty",
                        email: "wrong@example.com",
                        orgId: "org-wrong",
                        orgName: nil,
                        subscriptionType: "max"
                    )
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        #expect(try manager.activate(profile: claude) == .verified)
        #expect(store.data == storedData)
    }

    @Test
    func activationOverwritesLiveOpaqueClaudeCredentialsWithoutAuthStatusValidation() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let liveData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "opaque-live-token"]
        ])
        let storedData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "opaque-stored-token"]
        ])
        let store = FakeClaudeCredentialsStore(data: liveData)
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(
                store: store,
                authStatusLoader: {
                    ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "claude.ai",
                        apiProvider: "firstParty",
                        email: "wrong@example.com",
                        orgId: "org-wrong",
                        orgName: nil,
                        subscriptionType: "max"
                    )
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        #expect(try manager.activate(profile: claude) == .verified)
        #expect(store.data == storedData)
    }

    @Test
    func activeClaudeUsageCredentialsUseStoredProfileWithoutFileAccess() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let liveData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "live-access-token",
                "refreshToken": "live-refresh-token",
                "expiresAt": 1_800_003_600_000
            ]
        ])
        let storedData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "stored-access-token",
                "refreshToken": "stored-refresh-token",
                "expiresAt": 1_800_000_000_000
            ]
        ])
        let store = FakeClaudeCredentialsStore(data: liveData)
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(
                store: store,
                authStatusLoader: {
                    ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "claude.ai",
                        apiProvider: "firstParty",
                        email: "active@example.com",
                        orgId: "org-active",
                        orgName: nil,
                        subscriptionType: "max"
                    )
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        let usageData = try #require(manager.readClaudeUsageCredentialsData(for: claude, isActive: true))

        #expect(usageData == storedData)
        #expect(store.readCount == 0)
        #expect(store.lastReadAllowedUserPrompt == nil)
        #expect(try Data(contentsOf: manager.claudeAuthPath(for: claude)) == storedData)
    }

    @Test
    func activeClaudeUsageCredentialsIgnoreLiveFileWhenAuthStatusIsNotClaudeAI() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let liveData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-active",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "active@example.com", "sub": "user-active"]),
                "refreshToken": "live-refresh-token"
            ]
        ])
        let storedData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-active",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "active@example.com", "sub": "user-active"]),
                "refreshToken": "stored-refresh-token"
            ]
        ])
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(
                store: FakeClaudeCredentialsStore(data: liveData),
                authStatusLoader: {
                    ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "api_key",
                        apiProvider: "anthropic",
                        email: nil,
                        orgId: nil,
                        orgName: nil,
                        subscriptionType: nil
                    )
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        let usageData = try #require(manager.readClaudeUsageCredentialsData(for: claude, isActive: true))

        #expect(usageData == storedData)
        #expect(try Data(contentsOf: manager.claudeAuthPath(for: claude)) == storedData)
    }

    @Test
    func activeClaudeUsageCredentialsKeepNewerStoredDataWhenLiveFileIsStale() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let liveData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "old-live-access-token",
                "refreshToken": "old-live-refresh-token",
                "expiresAt": 1_800_000_000_000
            ]
        ])
        let storedData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "new-stored-access-token",
                "refreshToken": "new-stored-refresh-token",
                "expiresAt": 1_800_003_600_000
            ]
        ])
        let store = FakeClaudeCredentialsStore(data: liveData)
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(
                store: store,
                authStatusLoader: {
                    ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "claude.ai",
                        apiProvider: "firstParty",
                        email: "active@example.com",
                        orgId: "org-active",
                        orgName: nil,
                        subscriptionType: "max"
                    )
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        let usageData = try #require(manager.readClaudeUsageCredentialsData(for: claude, isActive: true))

        #expect(usageData == storedData)
        #expect(try Data(contentsOf: manager.claudeAuthPath(for: claude)) == storedData)
    }

    @Test
    func activeClaudeUsageCredentialsKeepStoredDataWhenLiveFileIsDifferentAccount() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let liveData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "live-access-token", "refreshToken": "live-refresh-token"]
        ])
        let storedData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-active",
            "claudeAiOauth": [
                "accessToken": makeJWT(payload: ["email": "active@example.com", "sub": "user-active"])
            ]
        ])
        let store = FakeClaudeCredentialsStore(data: liveData)
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(
                store: store,
                authStatusLoader: {
                    ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "claude.ai",
                        apiProvider: "firstParty",
                        email: "other@example.com",
                        orgId: "org-other",
                        orgName: nil,
                        subscriptionType: "max"
                    )
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claude = Profile(
            alias: "Claude",
            email: "active@example.com",
            accountId: "org-active",
            addedAt: Date(),
            aiProvider: .claude
        )
        try storedData.write(to: manager.claudeAuthPath(for: claude))

        let usageData = try #require(manager.readClaudeUsageCredentialsData(for: claude, isActive: true))

        #expect(usageData == storedData)
        #expect(try Data(contentsOf: manager.claudeAuthPath(for: claude)) == storedData)
    }
}
