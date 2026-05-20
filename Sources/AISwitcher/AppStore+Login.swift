import Foundation
import AppKit

enum ClaudeReloginRestore {
    static func profileToRestoreAfterRelogin(
        targetId: UUID,
        matchedTarget: Bool,
        profiles: [Profile],
        activeProfileIdsByProvider: [AIProvider: UUID]
    ) -> Profile? {
        guard let activeId = activeProfileIdsByProvider[.claude],
              let active = profiles.first(where: { $0.id == activeId && $0.provider == .claude }) else {
            return nil
        }
        return matchedTarget && active.id == targetId ? nil : active
    }
}

// MARK: - Login Process Management

extension AppStore {

    // MARK: CLI Path Discovery

    func findCLIPath(_ name: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", "which \(name)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = nil
        try? task.run()
        task.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty { return raw }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? "/usr/local/bin/\(name)"
    }

    // MARK: Timeout

    func cancelLoginTimeout() {
        loginTimeout?.cancel()
        loginTimeout = nil
    }

    func scheduleLoginTimeout(after timeoutInterval: TimeInterval = 120) {
        cancelLoginTimeout()
        let timeout = DispatchWorkItem { [weak self] in self?.loginTimedOut() }
        loginTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval, execute: timeout)
    }

    func loginTimedOut() {
        guard addingStep == .waitingLogin else { return }
        cancelLoginTimeout()
        stopLoginProcess(suppressFailureFeedback: true)
        restorePendingProviderActiveCredential()
        addingStep = .idle
        isAddingAccount = false
        reloginTargetId = nil
        pendingClaudeCredentialsData = nil
        pendingClaudeIdentity = nil
        profileManager.removeClaudeLoginDirectory(pendingClaudeLoginDirectory)
        pendingClaudeLoginDirectory = nil
        addAccountErrorMessage = L("Login zaman aşımına uğradı. Tekrar deneyin.", "Login timed out. Please try again.")
        stopAuthWatcher()
    }

    // MARK: Start / Stop

    @discardableResult
    func startCodexLogin() -> Bool {
        startProviderLogin(.codex)
    }

    @discardableResult
    func startProviderLogin(_ provider: AIProvider) -> Bool {
        stopLoginProcess(suppressFailureFeedback: true)

        let executablePath = findCLIPath(provider.loginExecutableName)
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            isAddingAccount = false
            addingStep = .idle
            addAccountErrorMessage = missingLoginCommandMessage(for: provider)
            sendNotification(
                title: L("Login başlatılamadı", "Login could not start"),
                body: missingLoginCommandMessage(for: provider)
            )
            return false
        }
        let claudeLoginDirectory: URL?
        if provider == .claude {
            if let existing = pendingClaudeLoginDirectory {
                claudeLoginDirectory = existing
            } else if let created = profileManager.makeClaudeLoginDirectory() {
                pendingClaudeLoginDirectory = created
                claudeLoginDirectory = created
            } else {
                isAddingAccount = false
                addingStep = .idle
                addAccountErrorMessage = L(
                    "Claude login klasörü oluşturulamadı.",
                    "Could not create a Claude login directory."
                )
                return false
            }
        } else {
            claudeLoginDirectory = nil
        }

        let command = CodexLoginCommand.shellWrapped(
            executablePath: executablePath,
            shellCommand: provider.loginShellCommand
        )
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: command.executablePath)
        task.arguments = command.arguments
        task.standardInput = nil
        task.standardOutput = pipe
        task.standardError = pipe
        if let claudeLoginDirectory {
            var environment = ProcessInfo.processInfo.environment
            environment["CLAUDE_CONFIG_DIR"] = claudeLoginDirectory.path
            environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = claudeLoginDirectory.path
            task.environment = environment
        }

        loginOutputPipe = pipe
        loginOutputBuffer = ""
        didOpenLoginBrowser = false
        suppressLoginFailureFeedback = false

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.handleProviderLoginOutput(data, provider: provider) }
        }

        task.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.handleProviderLoginTermination(status: process.terminationStatus, provider: provider)
            }
        }

        do {
            try task.run()
            loginProcess = task
            return true
        } catch {
            stopLoginProcess(suppressFailureFeedback: true)
            if provider == .claude {
                profileManager.removeClaudeLoginDirectory(pendingClaudeLoginDirectory)
                pendingClaudeLoginDirectory = nil
            }
            isAddingAccount = false
            addingStep = .idle
            addAccountErrorMessage = error.localizedDescription
            sendNotification(
                title: L("Login başlatılamadı", "Login could not start"),
                body: error.localizedDescription
            )
            return false
        }
    }

    func stopCodexLoginProcess(suppressFailureFeedback: Bool) {
        stopLoginProcess(suppressFailureFeedback: suppressFailureFeedback)
    }

    func stopLoginProcess(suppressFailureFeedback: Bool) {
        if suppressFailureFeedback { self.suppressLoginFailureFeedback = true }
        loginOutputPipe?.fileHandleForReading.readabilityHandler = nil
        loginOutputPipe = nil
        if let process = loginProcess, process.isRunning { process.terminate() }
        loginProcess = nil
        loginOutputBuffer = ""
        didOpenLoginBrowser = false
    }

    // MARK: Output / Termination Handlers

    private func handleProviderLoginOutput(_ data: Data, provider: AIProvider) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        loginOutputBuffer += chunk

        if provider == .codex,
           !didOpenLoginBrowser,
           CodexLoginOutputParser.authorizationURL(in: loginOutputBuffer) != nil {
            didOpenLoginBrowser = true
        }
    }

    private func handleProviderLoginTermination(status: Int32, provider: AIProvider) {
        guard loginProcess != nil else { return }
        let shouldReportFailure = status != 0 && !suppressLoginFailureFeedback && addingStep == .waitingLogin

        stopLoginProcess(suppressFailureFeedback: true)

        if status == 0, provider == .claude {
            if !completeClaudeLoginFromCurrentState() {
                handleClaudeLoginCompletionUnavailable()
            }
            return
        }

        if shouldReportFailure {
            cancelLoginTimeout()
            isAddingAccount = false
            addingStep = .idle
            reloginTargetId = nil
            stopAuthWatcher()
            if provider == .claude {
                profileManager.removeClaudeLoginDirectory(pendingClaudeLoginDirectory)
                pendingClaudeLoginDirectory = nil
            }
            addAccountErrorMessage = L(
                "\(provider.displayName) login süreci tamamlanamadı.",
                "\(provider.displayName) login did not complete."
            )
            sendNotification(
                title: L("Login başlatılamadı", "Login could not start"),
                body: L("\(provider.displayName) login süreci tamamlanamadı.", "\(provider.displayName) login did not complete.")
            )
        }
    }

    private func missingLoginCommandMessage(for provider: AIProvider) -> String {
        L(
            "`\(provider.loginExecutableName)` komutu bulunamadı.",
            "`\(provider.loginExecutableName)` command was not found."
        )
    }

    // MARK: Claude Login Capture

    private func completeClaudeLoginFromCurrentState() -> Bool {
        guard let pendingClaudeLoginDirectory else { return false }
        let manager = ClaudeCodeManager(configDirectory: pendingClaudeLoginDirectory)
        guard let data = manager.readCredentialsData(),
              let identity = manager.currentIdentity(credentialsData: data, allowAuthStatusFallback: true) else { return false }
        handleClaudeCredentialsData(data, identity: identity)
        return true
    }

    private func handleClaudeLoginCompletionUnavailable() {
        cancelLoginTimeout()
        isAddingAccount = false
        addingStep = .idle
        reloginTargetId = nil
        pendingClaudeCredentialsData = nil
        pendingClaudeIdentity = nil
        profileManager.removeClaudeLoginDirectory(pendingClaudeLoginDirectory)
        pendingClaudeLoginDirectory = nil
        stopAuthWatcher()
        restorePendingProviderActiveCredential()
        addAccountErrorMessage = L(
            "Claude login tamamlandı ama hesap bilgisi doğrulanamadı.",
            "Claude login completed, but account details could not be verified."
        )
        sendNotification(
            title: L("Claude login doğrulanamadı", "Claude login could not be verified"),
            body: addAccountErrorMessage ?? ""
        )
    }

    private func handleClaudeCredentialsData(_ data: Data, identity providedIdentity: ClaudeAccountIdentity? = nil) {
        guard let identity = providedIdentity ?? ClaudeCodeManager().currentIdentity(credentialsData: data) else { return }

        if let targetId = reloginTargetId {
            handleClaudeRelogin(data: data, identity: identity, targetId: targetId)
            return
        }

        guard isAddingAccount else { return }
        pendingClaudeCredentialsData = data
        pendingClaudeIdentity = identity
        pendingProfileEmail = identity.email
        addingStep = .confirmProfile
        profileManager.removeClaudeLoginDirectory(pendingClaudeLoginDirectory)
        pendingClaudeLoginDirectory = nil
        cancelLoginTimeout()
        stopLoginProcess(suppressFailureFeedback: true)
    }

    private func handleClaudeRelogin(data: Data, identity: ClaudeAccountIdentity, targetId: UUID) {
        reloginTargetId = nil
        addingStep = .idle
        profileManager.removeClaudeLoginDirectory(pendingClaudeLoginDirectory)
        pendingClaudeLoginDirectory = nil
        stopLoginProcess(suppressFailureFeedback: true)

        guard let profile = profiles.first(where: { $0.id == targetId }) else { return }
        if profile.accountId == identity.accountId {
            let dest = profileManager.claudeAuthPath(for: profile)
            try? data.write(to: dest, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            updateClaudeProfileMetadata(targetId: targetId, identity: identity)
            staleProfileIds.remove(targetId)
            activateClaudeTargetAfterReloginIfNeeded(targetId: targetId)
            sendNotification(
                title: L("Giriş yenilendi", "Re-login successful"),
                body: profile.displayName
            )
        } else {
            sendNotification(
                title: L("Hatalı hesap", "Wrong account"),
                body: L("Farklı bir hesaba giriş yapıldı. Tekrar deneyin.", "A different account was detected. Please try again.")
            )
        }
    }

    private func updateClaudeProfileMetadata(targetId: UUID, identity: ClaudeAccountIdentity) {
        var config = profileManager.loadConfig()
        guard let index = config.profiles.firstIndex(where: { $0.id == targetId }) else { return }
        config.profiles[index].email = identity.email
        config.profiles[index].subscriptionType = identity.subscriptionType
        profileManager.saveConfig(config)
        profiles = config.profiles
        activeProfileIdsByProvider = config.activeProfileIdsByProvider
        if activeProfile?.id == targetId {
            activeProfile = config.profiles[index]
        }
    }

    private func activateClaudeTargetAfterReloginIfNeeded(targetId: UUID) {
        guard activeProfileIdsByProvider[.claude] == targetId,
              let profile = profiles.first(where: { $0.id == targetId && $0.provider == .claude }) else {
            return
        }
        activateStoredCredential(for: profile)
    }

    func restorePendingProviderActiveCredential() {
        guard pendingProvider != .claude else { return }
        guard let restore = ProfileCancellationRestore.profileToRestore(
            pendingProvider: pendingProvider,
            selectedActiveProfile: activeProfile,
            profiles: profiles,
            activeProfileIdsByProvider: activeProfileIdsByProvider
        ) else { return }
        activateStoredCredential(for: restore)
    }

    func activateStoredCredential(
        for profile: Profile,
        completion: (@MainActor @Sendable (VerifyResult?) -> Void)? = nil
    ) {
        guard ActivationInProgressGate.begin(profileId: profile.id, active: &activationInProgressProfileIds) else {
            completion?(nil)
            return
        }
        lastAuthWriteDate = Date()

        if ActivationInProgressGate.shouldRunOffMain(provider: profile.provider) {
            let profileManager = self.profileManager
            Task.detached(priority: .userInitiated) {
                let result = try? profileManager.activate(profile: profile)
                await MainActor.run {
                    ActivationInProgressGate.finish(profileId: profile.id, active: &self.activationInProgressProfileIds)
                    completion?(result)
                }
            }
            return
        }

        let result = try? profileManager.activate(profile: profile)
        ActivationInProgressGate.finish(profileId: profile.id, active: &activationInProgressProfileIds)
        completion?(result)
    }
}
