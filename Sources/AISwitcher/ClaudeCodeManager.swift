import Dispatch
import Foundation

protocol ClaudeCredentialsStoring: Sendable {
    func readCredentialsData(allowUserPrompt: Bool) -> Data?
    func writeCredentialsData(_ data: Data, allowUserPrompt: Bool) -> Bool
    func deleteCredentialsData(allowUserPrompt: Bool) -> Bool
    func credentialsDataExists(allowUserPrompt: Bool) -> Bool
}

protocol ClaudeAccountMetadataStoring: Sendable {
    func readAccountMetadataData() -> Data?
    func writeAccountMetadataData(_ data: Data) -> Bool
}

struct ClaudeCredentialsFileStore: ClaudeCredentialsStoring {
    let configDirectory: URL
    let preferredCredentialPath: URL?

    init(
        configDirectory: URL = ClaudeCodeManager.defaultConfigDirectory,
        preferredCredentialPath: URL? = nil
    ) {
        self.configDirectory = configDirectory
        self.preferredCredentialPath = preferredCredentialPath
    }

    func readCredentialsData(allowUserPrompt: Bool = false) -> Data? {
        guard let path = credentialPath(requireExisting: true) else { return nil }
        return try? Data(contentsOf: path)
    }

    func writeCredentialsData(_ data: Data, allowUserPrompt: Bool = false) -> Bool {
        guard let path = credentialPathForWrite() else { return false }
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            return true
        } catch {
            return false
        }
    }

    func deleteCredentialsData(allowUserPrompt: Bool = false) -> Bool {
        guard let path = credentialPath(requireExisting: true) else { return true }
        do {
            try FileManager.default.removeItem(at: path)
            return true
        } catch {
            return false
        }
    }

    func credentialsDataExists(allowUserPrompt: Bool = false) -> Bool {
        credentialPath(requireExisting: true) != nil
    }

    func credentialPath(requireExisting: Bool = true) -> URL? {
        let fm = FileManager.default
        if let preferredCredentialPath,
           !requireExisting || fm.fileExists(atPath: preferredCredentialPath.path) {
            return preferredCredentialPath
        }

        if !requireExisting {
            return credentialPathForWrite()
        }

        let accountCredentialPaths = existingAccountCredentialPaths()
        if let active = activeAccountCredentialPath(in: accountCredentialPaths) {
            return active
        }
        if let activeAccountPath = activeAccountMetadataCredentialPath(requireExisting: true) {
            return activeAccountPath
        }
        if accountCredentialPaths.count == 1, let only = accountCredentialPaths.first {
            return only
        }
        if let newest = accountCredentialPaths.max(by: { modificationDate($0) < modificationDate($1) }) {
            return newest
        }

        let rootCredentials = configDirectory.appendingPathComponent(".credentials.json")
        if !requireExisting || fm.fileExists(atPath: rootCredentials.path) {
            return rootCredentials
        }

        return nil
    }

    private func credentialPathForWrite() -> URL? {
        let fm = FileManager.default
        if let preferredCredentialPath, fm.fileExists(atPath: preferredCredentialPath.path) {
            return preferredCredentialPath
        }

        let accountCredentialPaths = existingAccountCredentialPaths()
        if let active = activeAccountCredentialPath(in: accountCredentialPaths) {
            return active
        }
        if let activeAccountPath = activeAccountMetadataCredentialPath(requireExisting: false) {
            return activeAccountPath
        }
        if accountCredentialPaths.count == 1 {
            return accountCredentialPaths.first
        }

        let rootCredentials = configDirectory.appendingPathComponent(".credentials.json")
        if fm.fileExists(atPath: rootCredentials.path) {
            return rootCredentials
        }

        return rootCredentials
    }

    private func existingAccountCredentialPaths() -> [URL] {
        accountDirectories()
            .map { $0.appendingPathComponent(".credentials.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func accountDirectories() -> [URL] {
        let accountsDir = configDirectory.appendingPathComponent("accounts")
        guard let accounts = try? FileManager.default.contentsOfDirectory(
            at: accountsDir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return accounts.filter { isDirectory($0) }
    }

    private func activeAccountCredentialPath(in paths: [URL]) -> URL? {
        guard let activeOrganizationId = activeAccountMetadata()?.organizationId else { return nil }
        return paths.first { path in
            guard let data = try? Data(contentsOf: path) else { return false }
            return ClaudeCodeManager.parseAccountId(from: data) == activeOrganizationId
        }
    }

    private func activeAccountMetadataCredentialPath(requireExisting: Bool) -> URL? {
        guard let activeMetadata = activeAccountMetadata() else { return nil }
        let accountDirs = accountDirectories()
        if let matchingDir = accountDirs.first(where: { dir in
            guard let metadata = accountMetadata(at: dir.appendingPathComponent(".claude.json")) else { return false }
            return metadata.matches(activeMetadata)
        }) {
            let path = matchingDir.appendingPathComponent(".credentials.json")
            if !requireExisting || FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }
        if !requireExisting, accountDirs.count == 1, let only = accountDirs.first {
            return only.appendingPathComponent(".credentials.json")
        }
        return nil
    }

    private func activeAccountMetadata() -> ClaudeAccountMetadata? {
        for path in configJSONCandidates() {
            if let metadata = accountMetadata(at: path) { return metadata }
        }
        return nil
    }

    private func accountMetadata(at path: URL) -> ClaudeAccountMetadata? {
        guard let data = try? Data(contentsOf: path),
              let metadata = ClaudeAccountMetadata(data: data) else { return nil }
        return metadata
    }

    private func configJSONCandidates() -> [URL] {
        var candidates = [configDirectory.appendingPathComponent(".claude.json")]
        if configDirectory.lastPathComponent == ".claude" {
            candidates.append(configDirectory.deletingLastPathComponent().appendingPathComponent(".claude.json"))
        }
        return candidates
    }

    private func isDirectory(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

}

struct ClaudeAccountMetadata: Equatable, Sendable {
    let organizationId: String?
    let accountId: String?
    let email: String?
    let organizationName: String?
    let displayName: String?

    init(
        organizationId: String?,
        accountId: String?,
        email: String?,
        organizationName: String? = nil,
        displayName: String? = nil
    ) {
        self.organizationId = organizationId?.nilIfBlank
        self.accountId = accountId?.nilIfBlank
        self.email = email?.nilIfBlank
        self.organizationName = organizationName?.nilIfBlank
        self.displayName = displayName?.nilIfBlank
    }

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let account = (object["oauthAccount"] as? [String: Any]) ?? object
        self.init(
            organizationId: account["organizationUuid"] as? String,
            accountId: account["accountUuid"] as? String,
            email: account["emailAddress"] as? String,
            organizationName: account["organizationName"] as? String,
            displayName: account["displayName"] as? String
        )
        guard !isEmpty else { return nil }
    }

    var isEmpty: Bool {
        organizationId == nil && accountId == nil && email == nil
    }

    func matches(_ other: ClaudeAccountMetadata) -> Bool {
        if let organizationId, let otherOrganizationId = other.organizationId {
            return organizationId == otherOrganizationId
        }
        if organizationId != nil || other.organizationId != nil {
            return false
        }
        if let accountId, let otherAccountId = other.accountId {
            return accountId == otherAccountId
        }
        if accountId != nil || other.accountId != nil {
            return false
        }
        return email != nil && email == other.email
    }

    func matches(accountId expectedAccountId: String, email expectedEmail: String) -> Bool {
        if let organizationId { return organizationId == expectedAccountId }
        if let accountId { return accountId == expectedAccountId }
        return email == expectedEmail
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [:]
        if let organizationId { object["organizationUuid"] = organizationId }
        if let accountId { object["accountUuid"] = accountId }
        if let email { object["emailAddress"] = email }
        if let organizationName { object["organizationName"] = organizationName }
        if let displayName { object["displayName"] = displayName }
        return object
    }
}

final class InMemoryClaudeAccountMetadataStore: ClaudeAccountMetadataStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func readAccountMetadataData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func writeAccountMetadataData(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
        return true
    }
}

struct ClaudeAccountMetadataStore: ClaudeAccountMetadataStoring {
    let configDirectory: URL

    init(configDirectory: URL = ClaudeCodeManager.defaultConfigDirectory) {
        self.configDirectory = configDirectory
    }

    func readAccountMetadataData() -> Data? {
        guard let data = try? Data(contentsOf: configJSONPath()),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: account)
    }

    func writeAccountMetadataData(_ data: Data) -> Bool {
        guard let metadata = ClaudeAccountMetadata(data: data) else { return false }
        let fields = Self.oauthAccountPatchFields(from: metadata)
        guard !fields.isEmpty else { return false }

        let path = configJSONPath()

        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let updated: String
            if FileManager.default.fileExists(atPath: path.path) {
                let existing = try String(contentsOf: path, encoding: .utf8)
                updated = Self.patchingOAuthAccount(in: existing, fields: fields)
            } else {
                updated = Self.minimalConfigText(fields: fields)
            }
            try Data(updated.utf8).write(to: path, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func accountMetadataData(
        email: String,
        accountId: String,
        alias: String,
        subscriptionType: String?
    ) -> Data? {
        let name = alias.nilIfBlank ?? email
        let metadata = ClaudeAccountMetadata(
            organizationId: accountId,
            accountId: nil,
            email: email,
            organizationName: name,
            displayName: name
        )
        _ = subscriptionType
        return try? JSONSerialization.data(withJSONObject: metadata.jsonObject)
    }

    private func configJSONPath() -> URL {
        if configDirectory.lastPathComponent == ".claude" {
            return configDirectory.deletingLastPathComponent().appendingPathComponent(".claude.json")
        }
        return configDirectory.appendingPathComponent(".claude.json")
    }

    private static func oauthAccountPatchFields(from metadata: ClaudeAccountMetadata) -> [(key: String, value: String)] {
        [
            ("emailAddress", metadata.email),
            ("organizationUuid", metadata.organizationId),
            ("organizationName", metadata.organizationName),
            ("displayName", metadata.displayName)
        ].compactMap { key, value in
            guard let value else { return nil }
            return (key, value)
        }
    }

    private static func minimalConfigText(fields: [(key: String, value: String)]) -> String {
        """
        {
          "oauthAccount": {
        \(fieldLines(fields, indent: "    "))
          }
        }
        """
    }

    private static func patchingOAuthAccount(
        in text: String,
        fields: [(key: String, value: String)]
    ) -> String {
        guard let objectRange = objectRange(forKey: "oauthAccount", in: text) else {
            return insertingOAuthAccount(in: text, fields: fields) ?? minimalConfigText(fields: fields)
        }

        var updated = text
        let objectText = String(text[objectRange])
        let patchedObject = patchingObjectFields(in: objectText, fields: fields)
        updated.replaceSubrange(objectRange, with: patchedObject)
        return updated
    }

    private static func patchingObjectFields(
        in objectText: String,
        fields: [(key: String, value: String)]
    ) -> String {
        var updated = objectText
        var missing: [(key: String, value: String)] = []
        for field in fields {
            guard let range = valueRange(forKey: field.key, in: updated) else {
                missing.append(field)
                continue
            }
            updated.replaceSubrange(range, with: jsonStringLiteral(field.value))
        }
        guard !missing.isEmpty else { return updated }
        return insertingFields(missing, inObject: updated)
    }

    private static func insertingOAuthAccount(
        in text: String,
        fields: [(key: String, value: String)]
    ) -> String? {
        guard let rootStart = text.firstIndex(where: { !$0.isWhitespace }),
              text[rootStart] == "{",
              let rootRange = objectRange(startingAt: rootStart, in: text) else { return nil }

        let accountObject = """
        {
            \(fieldLines(fields, indent: "    "))
          }
        """
        let rootObject = String(text[rootRange])
        let patchedRoot = insertingRawField(
            key: "oauthAccount",
            rawValue: accountObject,
            inObject: rootObject
        )
        var updated = text
        updated.replaceSubrange(rootRange, with: patchedRoot)
        return updated
    }

    private static func insertingFields(
        _ fields: [(key: String, value: String)],
        inObject objectText: String
    ) -> String {
        insertingRawFields(
            fields.map { ($0.key, jsonStringLiteral($0.value)) },
            inObject: objectText
        )
    }

    private static func insertingRawField(
        key: String,
        rawValue: String,
        inObject objectText: String
    ) -> String {
        insertingRawFields([(key, rawValue)], inObject: objectText)
    }

    private static func insertingRawFields(
        _ fields: [(key: String, rawValue: String)],
        inObject objectText: String
    ) -> String {
        guard objectText.first == "{",
              let closingBrace = objectText.lastIndex(of: "}") else { return objectText }
        let innerRange = objectText.index(after: objectText.startIndex)..<closingBrace
        let inner = objectText[innerRange].trimmingCharacters(in: .whitespacesAndNewlines)
        let usesNewlines = objectText.contains("\n")
        let fieldIndent = firstFieldIndent(in: objectText) ?? (usesNewlines ? "  " : "")
        let rawLines = fields
            .map { "\(fieldIndent)\"\($0.key)\": \($0.rawValue)" }
            .joined(separator: usesNewlines ? ",\n" : ", ")

        if inner.isEmpty {
            if usesNewlines {
                let closingIndent = closingLineIndent(in: objectText) ?? ""
                return "{\n\(rawLines)\n\(closingIndent)}"
            }
            return "{\(rawLines)}"
        }

        if usesNewlines,
           let closingLineBreak = objectText[..<closingBrace].lastIndex(of: "\n") {
            var updated = objectText
            updated.insert(contentsOf: ",\n\(rawLines)", at: closingLineBreak)
            return updated
        }

        var updated = objectText
        updated.insert(contentsOf: ", \(rawLines)", at: closingBrace)
        return updated
    }

    private static func fieldLines(
        _ fields: [(key: String, value: String)],
        indent: String
    ) -> String {
        fields
            .map { "\(indent)\"\($0.key)\": \(jsonStringLiteral($0.value))" }
            .joined(separator: ",\n")
    }

    private static func objectRange(forKey key: String, in text: String) -> Range<String.Index>? {
        var cursor = text.startIndex
        var depth = 0
        var inString = false
        var escaped = false

        while cursor < text.endIndex {
            let char = text[cursor]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                cursor = text.index(after: cursor)
                continue
            }

            if char == "\"" {
                if depth == 1,
                   let token = stringToken(in: text, at: cursor) {
                    if token.value == key,
                       let colon = skipWhitespace(in: text, from: token.end),
                       colon < text.endIndex,
                       text[colon] == ":" {
                        let valueStart = skipWhitespace(in: text, from: text.index(after: colon))
                        if let valueStart,
                           valueStart < text.endIndex,
                           text[valueStart] == "{" {
                            return objectRange(startingAt: valueStart, in: text)
                        }
                    }
                    cursor = token.end
                    continue
                }
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
            }
            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func valueRange(forKey key: String, in objectText: String) -> Range<String.Index>? {
        var cursor = objectText.startIndex
        var depth = 0
        var inString = false
        var escaped = false

        while cursor < objectText.endIndex {
            let char = objectText[cursor]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                cursor = objectText.index(after: cursor)
                continue
            }

            if char == "\"" {
                if depth == 1,
                   let token = stringToken(in: objectText, at: cursor) {
                    if token.value == key,
                       let colon = skipWhitespace(in: objectText, from: token.end),
                       colon < objectText.endIndex,
                       objectText[colon] == ":",
                       let valueStart = skipWhitespace(in: objectText, from: objectText.index(after: colon)) {
                        return jsonValueRange(in: objectText, startingAt: valueStart)
                    }
                    cursor = token.end
                    continue
                }
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
            }
            cursor = objectText.index(after: cursor)
        }

        return nil
    }

    private static func objectRange(startingAt start: String.Index, in text: String) -> Range<String.Index>? {
        guard start < text.endIndex, text[start] == "{" else { return nil }
        var cursor = start
        var depth = 0
        var inString = false
        var escaped = false

        while cursor < text.endIndex {
            let char = text[cursor]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                cursor = text.index(after: cursor)
                continue
            }

            if char == "\"" {
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return start..<text.index(after: cursor)
                }
            }
            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func jsonValueRange(in text: String, startingAt start: String.Index) -> Range<String.Index>? {
        var cursor = start
        var objectDepth = 0
        var arrayDepth = 0
        var inString = false
        var escaped = false

        while cursor < text.endIndex {
            let char = text[cursor]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                cursor = text.index(after: cursor)
                continue
            }

            if char == "\"" {
                inString = true
            } else if char == "{" {
                objectDepth += 1
            } else if char == "}" {
                if objectDepth == 0 && arrayDepth == 0 {
                    return start..<cursor
                }
                objectDepth -= 1
            } else if char == "[" {
                arrayDepth += 1
            } else if char == "]" {
                arrayDepth -= 1
            } else if char == "," && objectDepth == 0 && arrayDepth == 0 {
                return start..<cursor
            }
            cursor = text.index(after: cursor)
        }

        return start..<cursor
    }

    private static func stringToken(in text: String, at quote: String.Index) -> (value: String, end: String.Index)? {
        guard quote < text.endIndex, text[quote] == "\"" else { return nil }
        var cursor = text.index(after: quote)
        var escaped = false

        while cursor < text.endIndex {
            let char = text[cursor]
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                let end = text.index(after: cursor)
                let literal = String(text[quote..<end])
                guard let data = "[\(literal)]".data(using: .utf8),
                      let value = (try? JSONSerialization.jsonObject(with: data)) as? [String] else { return nil }
                return (value[0], end)
            }
            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func skipWhitespace(in text: String, from start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private static func firstFieldIndent(in objectText: String) -> String? {
        guard let firstQuote = objectText.firstIndex(of: "\""),
              let lineStart = objectText[..<firstQuote].lastIndex(of: "\n").map({ objectText.index(after: $0) }) else {
            return nil
        }
        return String(objectText[lineStart..<firstQuote])
    }

    private static func closingLineIndent(in objectText: String) -> String? {
        guard let closingBrace = objectText.lastIndex(of: "}"),
              let lineStart = objectText[..<closingBrace].lastIndex(of: "\n").map({ objectText.index(after: $0) }) else {
            return nil
        }
        return String(objectText[lineStart..<closingBrace])
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.count >= 2 else { return "\"\"" }
        return String(arrayLiteral.dropFirst().dropLast())
    }
}

struct ClaudeCodeManager: Sendable {
    static let defaultConfigDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")

    let store: ClaudeCredentialsStoring
    let metadataStore: any ClaudeAccountMetadataStoring
    private let authStatusLoader: @Sendable () -> ClaudeAuthStatus?

    init(
        store: ClaudeCredentialsStoring = ClaudeCredentialsFileStore(),
        metadataStore: any ClaudeAccountMetadataStoring = ClaudeAccountMetadataStore(),
        authStatusLoader: @escaping @Sendable () -> ClaudeAuthStatus? = { ClaudeCodeManager.loadAuthStatusFromCLI() }
    ) {
        self.store = store
        self.metadataStore = metadataStore
        self.authStatusLoader = authStatusLoader
    }

    init(
        store: ClaudeCredentialsStoring,
        authStatusLoader: @escaping @Sendable () -> ClaudeAuthStatus?
    ) {
        self.store = store
        metadataStore = InMemoryClaudeAccountMetadataStore()
        self.authStatusLoader = authStatusLoader
    }

    init(configDirectory: URL) {
        store = ClaudeCredentialsFileStore(configDirectory: configDirectory)
        metadataStore = ClaudeAccountMetadataStore(configDirectory: configDirectory)
        authStatusLoader = { ClaudeCodeManager.loadAuthStatusFromCLI(configDirectory: configDirectory) }
    }

    func readCredentialsData(allowUserPrompt: Bool = false) -> Data? {
        store.readCredentialsData(allowUserPrompt: allowUserPrompt)
    }

    func writeCredentialsData(_ data: Data, allowUserPrompt: Bool = false) -> Bool {
        store.writeCredentialsData(data, allowUserPrompt: allowUserPrompt)
    }

    func deleteCredentialsData(allowUserPrompt: Bool = false) -> Bool {
        store.deleteCredentialsData(allowUserPrompt: allowUserPrompt)
    }

    func credentialsDataExists(allowUserPrompt: Bool = false) -> Bool {
        store.credentialsDataExists(allowUserPrompt: allowUserPrompt)
    }

    func readAuthStatus() -> ClaudeAuthStatus? {
        authStatusLoader()
    }

    func readAccountMetadataData() -> Data? {
        metadataStore.readAccountMetadataData()
    }

    func writeAccountMetadataData(_ data: Data) -> Bool {
        metadataStore.writeAccountMetadataData(data)
    }

    func currentIdentity(
        credentialsData data: Data? = nil,
        allowAuthStatusFallback: Bool = true,
        allowCredentialRead: Bool = false,
        preferAuthStatus: Bool = false
    ) -> ClaudeAccountIdentity? {
        if preferAuthStatus, allowAuthStatusFallback {
            if let status = readAuthStatus() {
                guard status.isClaudeAIOAuth,
                      let email = status.email?.nilIfBlank,
                      let accountId = status.orgId?.nilIfBlank else { return nil }
                return ClaudeAccountIdentity(email: email, accountId: accountId, subscriptionType: status.subscriptionType)
            }
        }

        if let data, let identity = Self.identity(from: data) {
            return identity
        }

        if allowAuthStatusFallback, let status = readAuthStatus() {
            guard status.isClaudeAIOAuth,
                  let email = status.email?.nilIfBlank,
                  let accountId = status.orgId?.nilIfBlank else { return nil }
            return ClaudeAccountIdentity(email: email, accountId: accountId, subscriptionType: status.subscriptionType)
        }

        guard data == nil,
              let data = readCredentialsData(allowUserPrompt: allowCredentialRead),
              let identity = Self.identity(from: data) else { return nil }
        return identity
    }

    private static func identity(from data: Data) -> ClaudeAccountIdentity? {
        guard
              let email = parseEmail(from: data)?.nilIfBlank,
              let accountId = parseAccountId(from: data)?.nilIfBlank else { return nil }
        return ClaudeAccountIdentity(
            email: email,
            accountId: accountId,
            subscriptionType: Self.parseSubscriptionType(from: data)
        )
    }

    func parseEmail(from data: Data) -> String? {
        Self.parseEmail(from: data)
    }

    func parseAccountId(from data: Data) -> String? {
        Self.parseAccountId(from: data)
    }

    static func parseEmail(from data: Data) -> String? {
        if let status = try? ClaudeAuthStatusParser.parse(data), let email = status.email {
            return email
        }
        guard let jwt = oauthAccessToken(from: data) else { return nil }
        return jwtClaim("email", in: jwt)
    }

    static func parseAccountId(from data: Data) -> String? {
        if let status = try? ClaudeAuthStatusParser.parse(data), let orgId = status.orgId {
            return orgId
        }
        if let json = jsonDict(from: data),
           let orgId = json["organizationUuid"] as? String,
           !orgId.isEmpty {
            return orgId
        }
        guard let jwt = oauthAccessToken(from: data) else { return nil }
        return jwtClaim("sub", in: jwt)
    }

    static func parseSubscriptionType(from data: Data) -> String? {
        if let status = try? ClaudeAuthStatusParser.parse(data) {
            return status.subscriptionType
        }
        guard let json = jsonDict(from: data),
              let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["subscriptionType"] as? String
    }

    private static func loadAuthStatusFromCLI(configDirectory: URL? = nil) -> ClaudeAuthStatus? {
        let claudePath = findClaudeExecutable()
        guard FileManager.default.isExecutableFile(atPath: claudePath) else { return nil }

        let escapedPath = claudePath.replacingOccurrences(of: "'", with: "'\"'\"'")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "exec '\(escapedPath)' auth status --json"]
        process.standardOutput = pipe
        process.standardError = nil
        if let configDirectory {
            var environment = ProcessInfo.processInfo.environment
            environment["CLAUDE_CONFIG_DIR"] = configDirectory.path
            environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = configDirectory.path
            process.environment = environment
        }

        do {
            try process.run()
            let exited = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                exited.signal()
            }
            guard exited.wait(timeout: .now() + 8) == .success else {
                process.terminate()
                _ = exited.wait(timeout: .now() + 2)
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return try? ClaudeAuthStatusParser.parse(data)
        } catch {
            return nil
        }
    }

    private static func findClaudeExecutable() -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", "which claude"]
        task.standardOutput = pipe
        task.standardError = nil
        try? task.run()
        task.waitUntilExit()

        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty { return raw }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? "/usr/local/bin/claude"
    }

    static func oauthAccessToken(from data: Data) -> String? {
        guard let json = jsonDict(from: data),
              let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }

    static func oauthRefreshToken(from data: Data) -> String? {
        guard let json = jsonDict(from: data),
              let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["refreshToken"] as? String
    }

    static func oauthExpiresAt(from data: Data) -> Date? {
        guard let json = jsonDict(from: data),
              let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
        let milliseconds = (oauth["expiresAt"] as? Int).map(Double.init)
            ?? (oauth["expiresAt"] as? Double)
        guard let milliseconds, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    static func updatingOAuthTokens(
        in data: Data,
        accessToken: String,
        refreshToken: String,
        expiresIn: Int,
        now: Date = Date()
    ) -> Data? {
        guard var json = jsonDict(from: data) else { return nil }
        var oauth = json["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = Int(now.addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970 * 1000)
        json["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: json)
    }

    private static func jsonDict(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func jwtClaim(_ key: String, in jwt: String) -> String? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = b64.count % 4
        if remainder != 0 { b64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict[key] as? String
    }
}

struct ClaudeAuthStatus: Codable, Equatable, Sendable {
    let loggedIn: Bool
    let authMethod: String?
    let apiProvider: String?
    let email: String?
    let orgId: String?
    let orgName: String?
    let subscriptionType: String?

    var isClaudeAIOAuth: Bool {
        loggedIn && authMethod == "claude.ai"
    }
}

struct ClaudeAccountIdentity: Equatable, Sendable {
    let email: String
    let accountId: String
    let subscriptionType: String?
}

enum ClaudeAuthStatusParser {
    static func parse(_ data: Data) throws -> ClaudeAuthStatus {
        try JSONDecoder().decode(ClaudeAuthStatus.self, from: data)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
