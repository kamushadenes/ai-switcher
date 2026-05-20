import Foundation
import Testing
@testable import AISwitcher

final class FakeClaudeCredentialsStore: ClaudeCredentialsStoring, @unchecked Sendable {
    var data: Data?
    var readCount = 0
    var writeCount = 0
    var lastReadAllowedUserPrompt: Bool?
    var lastWriteAllowedUserPrompt: Bool?

    init(data: Data? = nil) {
        self.data = data
    }

    func readCredentialsData(allowUserPrompt: Bool = true) -> Data? {
        readCount += 1
        lastReadAllowedUserPrompt = allowUserPrompt
        return data
    }

    func writeCredentialsData(_ data: Data, allowUserPrompt: Bool = true) -> Bool {
        writeCount += 1
        lastWriteAllowedUserPrompt = allowUserPrompt
        self.data = data
        return true
    }

    func deleteCredentialsData(allowUserPrompt: Bool = true) -> Bool {
        self.data = nil
        return true
    }

    func credentialsDataExists(allowUserPrompt: Bool = true) -> Bool {
        data != nil
    }
}

final class AuthStatusCounter: @unchecked Sendable {
    var count = 0
}

struct ClaudeCodeManagerTests {
    private func makeJWT(payload: [String: Any]) throws -> String {
        let header = Data(#"{"alg":"none"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadB64 = payloadData
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "\(header).\(payloadB64).fake"
    }

    @Test
    func fileStoreReadsAndWritesExistingAccountCredentialFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let accountDir = tempDir
            .appendingPathComponent("accounts")
            .appendingPathComponent("iniciador")
        let credentialPath = accountDir.appendingPathComponent(".credentials.json")
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        let originalData = Data(#"{"claudeAiOauth":{"accessToken":"original"}}"#.utf8)
        try originalData.write(to: credentialPath)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ClaudeCredentialsFileStore(configDirectory: tempDir)
        #expect(store.credentialPath()?.resolvingSymlinksInPath() == credentialPath.resolvingSymlinksInPath())
        #expect(store.readCredentialsData() == originalData)

        let updatedData = Data(#"{"claudeAiOauth":{"accessToken":"updated"}}"#.utf8)
        #expect(store.writeCredentialsData(updatedData))
        #expect(try Data(contentsOf: credentialPath) == updatedData)
    }

    @Test
    func fileStoreCreatesRootCredentialFileWhenNoLiveTargetExists() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ClaudeCredentialsFileStore(configDirectory: tempDir)
        let credentialPath = tempDir.appendingPathComponent(".credentials.json")
        let data = Data(#"{"claudeAiOauth":{"accessToken":"fresh"}}"#.utf8)

        #expect(store.credentialPath(requireExisting: true) == nil)
        #expect(store.credentialPath(requireExisting: false)?.resolvingSymlinksInPath() == credentialPath.resolvingSymlinksInPath())
        #expect(store.writeCredentialsData(data))
        #expect(try Data(contentsOf: credentialPath) == data)
    }

    @Test
    func fileStoreWritesCredentialMatchingActiveClaudeAccountMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let firstDir = tempDir.appendingPathComponent("accounts").appendingPathComponent("first")
        let secondDir = tempDir.appendingPathComponent("accounts").appendingPathComponent("second")
        let firstPath = firstDir.appendingPathComponent(".credentials.json")
        let secondPath = secondDir.appendingPathComponent(".credentials.json")
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-first",
            "claudeAiOauth": ["accessToken": try makeJWT(payload: ["email": "first@example.com"])]
        ]).write(to: firstPath)
        try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-second",
            "claudeAiOauth": ["accessToken": try makeJWT(payload: ["email": "second@example.com"])]
        ]).write(to: secondPath)
        try JSONSerialization.data(withJSONObject: [
            "oauthAccount": ["organizationUuid": "org-second"]
        ]).write(to: tempDir.appendingPathComponent(".claude.json"))
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ClaudeCredentialsFileStore(configDirectory: tempDir)
        let updated = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-active",
            "claudeAiOauth": ["accessToken": "updated"]
        ])

        #expect(store.credentialPath()?.resolvingSymlinksInPath() == secondPath.resolvingSymlinksInPath())
        #expect(store.writeCredentialsData(updated))
        #expect(try Data(contentsOf: firstPath) != updated)
        #expect(try Data(contentsOf: secondPath) == updated)
    }

    @Test
    func fileStoreReadsCredentialMatchingActiveAccountMetadataBeforeNewestOpaqueCredential() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let firstDir = tempDir.appendingPathComponent("accounts").appendingPathComponent("first")
        let secondDir = tempDir.appendingPathComponent("accounts").appendingPathComponent("second")
        let firstPath = firstDir.appendingPathComponent(".credentials.json")
        let secondPath = secondDir.appendingPathComponent(".credentials.json")
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        let firstData = Data(#"{"claudeAiOauth":{"accessToken":"opaque-first"}}"#.utf8)
        let secondData = Data(#"{"claudeAiOauth":{"accessToken":"opaque-second"}}"#.utf8)
        try firstData.write(to: firstPath)
        try secondData.write(to: secondPath)
        try JSONSerialization.data(withJSONObject: [
            "oauthAccount": [
                "accountUuid": "first-account",
                "emailAddress": "same@example.com",
                "organizationUuid": "org-first"
            ]
        ]).write(to: firstDir.appendingPathComponent(".claude.json"))
        try JSONSerialization.data(withJSONObject: [
            "oauthAccount": [
                "accountUuid": "second-account",
                "emailAddress": "same@example.com",
                "organizationUuid": "org-second"
            ]
        ]).write(to: secondDir.appendingPathComponent(".claude.json"))
        try JSONSerialization.data(withJSONObject: [
            "oauthAccount": [
                "accountUuid": "first-account",
                "emailAddress": "same@example.com",
                "organizationUuid": "org-first"
            ]
        ]).write(to: tempDir.appendingPathComponent(".claude.json"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: firstPath.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: secondPath.path)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ClaudeCredentialsFileStore(configDirectory: tempDir)

        #expect(store.credentialPath(requireExisting: true)?.resolvingSymlinksInPath() == firstPath.resolvingSymlinksInPath())
        #expect(store.readCredentialsData() == firstData)
    }

    @Test
    func accountMetadataMatchDoesNotUseEmailWhenIdsConflict() {
        let active = ClaudeAccountMetadata(
            organizationId: "org-active",
            accountId: "account-active",
            email: "same@example.com"
        )
        let stale = ClaudeAccountMetadata(
            organizationId: "org-stale",
            accountId: "account-stale",
            email: "same@example.com"
        )

        #expect(!stale.matches(active))
    }

    @Test
    func accountMetadataMatchDoesNotUseStaleAccountIdWhenOrganizationIdsConflict() {
        let active = ClaudeAccountMetadata(
            organizationId: "org-active",
            accountId: "stale-account",
            email: "same@example.com"
        )
        let stale = ClaudeAccountMetadata(
            organizationId: "org-stale",
            accountId: "stale-account",
            email: "same@example.com"
        )

        #expect(!stale.matches(active))
    }

    @Test
    func fileStoreCreatesCredentialForActiveAccountMetadataWhenNoCredentialExists() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let firstDir = tempDir.appendingPathComponent("accounts").appendingPathComponent("first")
        let secondDir = tempDir.appendingPathComponent("accounts").appendingPathComponent("second")
        let firstPath = firstDir.appendingPathComponent(".credentials.json")
        let secondPath = secondDir.appendingPathComponent(".credentials.json")
        let rootPath = tempDir.appendingPathComponent(".credentials.json")
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "oauthAccount": [
                "accountUuid": "account-first",
                "emailAddress": "first@example.com",
                "organizationUuid": "org-first"
            ]
        ]).write(to: firstDir.appendingPathComponent(".claude.json"))
        try JSONSerialization.data(withJSONObject: [
            "oauthAccount": [
                "accountUuid": "account-second",
                "emailAddress": "second@example.com",
                "organizationUuid": "org-second"
            ]
        ]).write(to: secondDir.appendingPathComponent(".claude.json"))
        try JSONSerialization.data(withJSONObject: [
            "oauthAccount": [
                "accountUuid": "account-second",
                "emailAddress": "second@example.com",
                "organizationUuid": "org-second"
            ]
        ]).write(to: tempDir.appendingPathComponent(".claude.json"))
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ClaudeCredentialsFileStore(configDirectory: tempDir)
        let data = Data(#"{"claudeAiOauth":{"accessToken":"fresh"}}"#.utf8)

        #expect(store.credentialPath(requireExisting: true) == nil)
        #expect(store.credentialPath(requireExisting: false)?.path.hasSuffix("/accounts/second/.credentials.json") == true)
        #expect(store.writeCredentialsData(data))
        #expect(!FileManager.default.fileExists(atPath: firstPath.path))
        #expect(!FileManager.default.fileExists(atPath: rootPath.path))
        #expect(try Data(contentsOf: secondPath) == data)
    }

    @Test
    func metadataStorePatchesOAuthAccountFieldsWithoutRewritingRootConfig() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent(".claude.json")
        let original = """
        {
          "keepBefore": "before",
          "oauthAccount": {
            "emailAddress": "old@example.com",
            "organizationUuid": "old-org",
            "organizationName": "Old Org",
            "displayName": "Old Name",
            "custom": "keep"
          },
          "keepAfter": {
            "line": "unchanged"
          }
        }
        """
        try Data(original.utf8).write(to: configPath)

        let data = try #require(ClaudeAccountMetadataStore.accountMetadataData(
            email: "new@example.com",
            accountId: "new-org",
            alias: "New Org",
            subscriptionType: "max"
        ))
        let store = ClaudeAccountMetadataStore(configDirectory: tempDir)

        #expect(store.writeAccountMetadataData(data))
        let updated = try String(contentsOf: configPath, encoding: .utf8)

        #expect(updated == """
        {
          "keepBefore": "before",
          "oauthAccount": {
            "emailAddress": "new@example.com",
            "organizationUuid": "new-org",
            "organizationName": "New Org",
            "displayName": "New Org",
            "custom": "keep"
          },
          "keepAfter": {
            "line": "unchanged"
          }
        }
        """)
    }

    @Test
    func parsesClaudeCredentialBlobFromFileData() throws {
        let token = try makeJWT(payload: [
            "email": "dev@example.com",
            "sub": "user-123"
        ])
        let data = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-123",
            "claudeAiOauth": [
                "accessToken": token,
                "subscriptionType": "max"
            ]
        ])

        #expect(ClaudeCodeManager.parseEmail(from: data) == "dev@example.com")
        #expect(ClaudeCodeManager.parseAccountId(from: data) == "org-123")
        #expect(ClaudeCodeManager.parseSubscriptionType(from: data) == "max")
    }

    @Test
    func parsesClaudeAuthStatusJSON() throws {
        let data = Data("""
        {
          "loggedIn": true,
          "authMethod": "claude.ai",
          "apiProvider": "claude",
          "email": "dev@example.com",
          "orgId": "org-123",
          "orgName": "Example",
          "subscriptionType": "pro"
        }
        """.utf8)

        let status = try ClaudeAuthStatusParser.parse(data)
        #expect(status.isClaudeAIOAuth)
        #expect(status.email == "dev@example.com")
        #expect(status.orgId == "org-123")
        #expect(ClaudeCodeManager.parseEmail(from: data) == "dev@example.com")
        #expect(ClaudeCodeManager.parseAccountId(from: data) == "org-123")
    }

    @Test
    func currentIdentityUsesParseableCredentialsBeforeAuthStatusFallback() throws {
        let credentialData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-123",
            "claudeAiOauth": [
                "accessToken": try makeJWT(payload: ["email": "dev@example.com", "sub": "user-123"]),
                "subscriptionType": "max"
            ]
        ])
        let counter = AuthStatusCounter()
        let manager = ClaudeCodeManager(
            store: FakeClaudeCredentialsStore(data: credentialData),
            authStatusLoader: {
                counter.count += 1
                return ClaudeAuthStatus(
                    loggedIn: true,
                    authMethod: "claude.ai",
                    apiProvider: "claude",
                    email: "other@example.com",
                    orgId: "org-status",
                    orgName: "Example",
                    subscriptionType: "pro"
                )
            }
        )

        let identity = try #require(manager.currentIdentity(credentialsData: credentialData))

        #expect(identity.email == "dev@example.com")
        #expect(identity.accountId == "org-123")
        #expect(identity.subscriptionType == "max")
        #expect(counter.count == 0)
    }

    @Test
    func capturesActivatesAndVerifiesClaudeCredentialsWithFakeStore() throws {
        let firstData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-123",
            "claudeAiOauth": [
                "accessToken": try makeJWT(payload: ["email": "dev@example.com", "sub": "user-123"])
            ]
        ])
        let secondData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "org-456",
            "claudeAiOauth": [
                "accessToken": try makeJWT(payload: ["email": "other@example.com", "sub": "user-456"])
            ]
        ])
        let store = FakeClaudeCredentialsStore(data: firstData)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(store: store, authStatusLoader: { nil })
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let profile = try #require(manager.captureCurrentAuth(alias: "Claude", provider: .claude))
        #expect(profile.provider == .claude)
        #expect(profile.email == "dev@example.com")
        #expect(profile.accountId == "org-123")
        #expect(FileManager.default.fileExists(atPath: manager.claudeAuthPath(for: profile).path))

        store.data = secondData
        let result = try manager.activate(profile: profile)
        #expect(result == .verified)
        #expect(ClaudeCodeManager.parseAccountId(from: store.data ?? Data()) == "org-123")
        #expect(manager.verifyActiveAccount(for: profile, allowUserPrompt: true) == .verified)
    }

    @Test
    func capturesClaudeCredentialsUsingAuthStatusWhenFileTokenIsOpaque() throws {
        let credentialData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "opaque-access-token",
                "refreshToken": "opaque-refresh-token",
                "subscriptionType": "max"
            ]
        ])
        let store = FakeClaudeCredentialsStore(data: credentialData)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)")
        let manager = ProfileManager(
            baseDirectory: tempDir,
            claudeManager: ClaudeCodeManager(
                store: store,
                authStatusLoader: {
                    ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "claude.ai",
                        apiProvider: "firstParty",
                        email: "dev@example.com",
                        orgId: "org-status",
                        orgName: "Example",
                        subscriptionType: "max"
                    )
                }
            )
        )
        manager.bootstrap()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let profile = try #require(manager.captureCurrentAuth(alias: "Claude", provider: .claude))

        #expect(profile.email == "dev@example.com")
        #expect(profile.accountId == "org-status")
        #expect(profile.subscriptionType == "max")
        #expect(try Data(contentsOf: manager.claudeAuthPath(for: profile)) == credentialData)
    }

    @Test
    func exposesClaudeOAuthAccessTokenForUsagePolling() throws {
        let credentialData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "opaque-access-token",
                "refreshToken": "opaque-refresh-token"
            ]
        ])

        #expect(ClaudeCodeManager.oauthAccessToken(from: credentialData) == "opaque-access-token")
    }

    @Test
    func updatesClaudeOAuthTokensWhilePreservingCredentialMetadata() throws {
        let credentialData = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "old-access-token",
                "refreshToken": "old-refresh-token",
                "expiresAt": 1_700_000_000_000,
                "subscriptionType": "max",
                "scopes": ["user:inference"]
            ],
            "mcpOAuth": [
                "accessToken": "mcp-token"
            ]
        ])

        let updated = try #require(ClaudeCodeManager.updatingOAuthTokens(
            in: credentialData,
            accessToken: "new-access-token",
            refreshToken: "new-refresh-token",
            expiresIn: 3600,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        let json = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let oauth = try #require(json["claudeAiOauth"] as? [String: Any])
        let mcp = try #require(json["mcpOAuth"] as? [String: Any])

        #expect(oauth["accessToken"] as? String == "new-access-token")
        #expect(oauth["refreshToken"] as? String == "new-refresh-token")
        #expect(oauth["expiresAt"] as? Int == 1_800_003_600_000)
        #expect(oauth["subscriptionType"] as? String == "max")
        #expect((oauth["scopes"] as? [String]) == ["user:inference"])
        #expect(mcp["accessToken"] as? String == "mcp-token")
        #expect(ClaudeCodeManager.oauthExpiresAt(from: updated) == Date(timeIntervalSince1970: 1_800_003_600))
    }

    @Test
    func profileVerificationDoesNotUseAuthStatusToOverrideCredentialFile() throws {
        let staleData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "stale-org",
            "claudeAiOauth": [
                "accessToken": try makeJWT(payload: ["email": "dev@example.com", "sub": "user-123"])
            ]
        ])
        let manager = ProfileManager(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("AISwitcherTests-\(UUID().uuidString)"),
            claudeManager: ClaudeCodeManager(
                store: FakeClaudeCredentialsStore(data: staleData),
                authStatusLoader: {
                    ClaudeAuthStatus(
                        loggedIn: true,
                        authMethod: "claude.ai",
                        apiProvider: "claude",
                        email: "dev@example.com",
                        orgId: "org-status",
                        orgName: "Example",
                        subscriptionType: "pro"
                    )
                }
            )
        )

        let profile = Profile(
            alias: "Claude",
            email: "dev@example.com",
            accountId: "org-status",
            addedAt: Date(),
            aiProvider: .claude
        )

        #expect(
            manager.verifyActiveAccount(for: profile, allowUserPrompt: true) ==
            .failed(.mismatch(expected: "org-status", actual: "stale-org"))
        )
    }

    @Test
    func nonClaudeAIAuthStatusDoesNotFallBackToStaleOAuthFileData() throws {
        let staleData = try JSONSerialization.data(withJSONObject: [
            "organizationUuid": "stale-org",
            "claudeAiOauth": [
                "accessToken": try makeJWT(payload: ["email": "stale@example.com", "sub": "stale-user"])
            ]
        ])
        let manager = ClaudeCodeManager(
            store: FakeClaudeCredentialsStore(data: staleData),
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

        #expect(manager.currentIdentity(credentialsData: staleData, preferAuthStatus: true) == nil)
    }
}
