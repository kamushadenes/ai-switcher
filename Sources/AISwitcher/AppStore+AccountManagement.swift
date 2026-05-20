import Foundation
import AppKit
import SwiftUI

enum ProfileOrdering {
    static func reordered(
        _ profiles: [Profile],
        moving draggedProfileId: UUID,
        toProviderDestinationIndex destinationIndex: Int
    ) -> [Profile] {
        var reorderedProfiles = profiles
        guard let sourceIndex = reorderedProfiles.firstIndex(where: { $0.id == draggedProfileId }) else {
            return profiles
        }

        let sourceProvider = reorderedProfiles[sourceIndex].provider
        let sourceProviderIndex = reorderedProfiles[..<sourceIndex].filter { $0.provider == sourceProvider }.count
        let providerCount = reorderedProfiles.filter { $0.provider == sourceProvider }.count
        let boundedDestination = max(0, min(destinationIndex, providerCount))
        let adjustedProviderDestination = sourceProviderIndex < boundedDestination
            ? boundedDestination - 1
            : boundedDestination

        let profile = reorderedProfiles.remove(at: sourceIndex)
        let providerIndices = reorderedProfiles.enumerated()
            .filter { $0.element.provider == profile.provider }
            .map(\.offset)
        let adjustedDestination: Int = {
            if adjustedProviderDestination >= providerIndices.count {
                return providerIndices.last.map { $0 + 1 } ?? reorderedProfiles.count
            }
            return providerIndices[adjustedProviderDestination]
        }()

        guard adjustedDestination != sourceIndex else {
            reorderedProfiles.insert(profile, at: sourceIndex)
            return reorderedProfiles
        }

        reorderedProfiles.insert(profile, at: adjustedDestination)
        return reorderedProfiles
    }
}

struct ProfileDeletionPlan {
    let config: AppConfig
    let replacementActiveProfile: Profile?
}

enum ProfileDeletion {
    static func planDeleting(_ profile: Profile, from config: AppConfig) -> ProfileDeletionPlan {
        var nextConfig = config
        var replacementActiveProfile: Profile?

        nextConfig.profiles.removeAll { $0.id == profile.id }
        if nextConfig.activeProfileIdsByProvider[profile.provider] == profile.id {
            if let next = nextConfig.profiles.first(where: { $0.provider == profile.provider }) {
                nextConfig.activeProfileIdsByProvider[profile.provider] = next.id
                replacementActiveProfile = next
            } else {
                nextConfig.activeProfileIdsByProvider[profile.provider] = nil
                if nextConfig.selectedProvider == profile.provider {
                    nextConfig.selectedProvider = nextConfig.profiles.first?.provider ?? .codex
                }
            }
        } else if nextConfig.selectedProvider == profile.provider,
                  !nextConfig.profiles.contains(where: { $0.provider == profile.provider }) {
            nextConfig.selectedProvider = nextConfig.profiles.first?.provider ?? .codex
        }

        nextConfig.normalizeActiveProfiles()
        return ProfileDeletionPlan(config: nextConfig, replacementActiveProfile: replacementActiveProfile)
    }
}

enum ProfileCancellationRestore {
    static func profileToRestore(
        pendingProvider: AIProvider,
        selectedActiveProfile: Profile?,
        profiles: [Profile],
        activeProfileIdsByProvider: [AIProvider: UUID]
    ) -> Profile? {
        if let providerActiveId = activeProfileIdsByProvider[pendingProvider],
           let providerActive = profiles.first(where: { $0.id == providerActiveId && $0.provider == pendingProvider }) {
            return providerActive
        }
        return selectedActiveProfile
    }
}

enum StatisticsResetCacheFiles {
    static let names = [
        "event-deltas-v2.json",
        "token-usage.json.mod",
        "session-meta-v3.json",
        "session-meta-v3.mod",
        "claude-session-meta-v2.json",
        "claude-session-meta-v2.mod"
    ]
}

// MARK: - Account Management (Add / Rename / Delete / Reset)

extension AppStore {

    // MARK: Add Account Window

    func openAddAccountWindow() {
        addingStep = .idle
        isAddingAccount = false
        addAccountErrorMessage = nil
        pendingProvider = selectedProvider
        pendingProfileEmail = ""
        reloginTargetId = nil
        pendingClaudeCredentialsData = nil
        pendingClaudeIdentity = nil
        profileManager.removeClaudeLoginDirectory(pendingClaudeLoginDirectory)
        pendingClaudeLoginDirectory = nil
        aliasText = ""

        if let w = addAccountWindow, w.isVisible {
            w.makeKeyAndOrderFront(NSApp)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: AddAccountView().environmentObject(self))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 320)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        let isDark = UserDefaults.standard.object(forKey: "isDarkMode") as? Bool ?? true
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.backgroundColor = isDark
            ? NSColor.black.withAlphaComponent(0.85)
            : NSColor.white.withAlphaComponent(0.85)
        window.center()
        window.makeKeyAndOrderFront(NSApp)
        NSApp.activate(ignoringOtherApps: true)
        addAccountWindow = window
    }

    func closeAddAccountWindow() { addAccountWindow?.close() }

    func dismissAddAccountFlow(closeWindow: Bool = false) {
        cancelLoginTimeout()
        stopLoginProcess(suppressFailureFeedback: true)
        isAddingAccount = false
        addingStep = .idle
        reloginTargetId = nil
        addAccountErrorMessage = nil
        pendingProfileEmail = ""
        pendingClaudeCredentialsData = nil
        pendingClaudeIdentity = nil
        profileManager.removeClaudeLoginDirectory(pendingClaudeLoginDirectory)
        pendingClaudeLoginDirectory = nil
        aliasText = ""
        stopAuthWatcher()
        if closeWindow { closeAddAccountWindow() }
    }

    // MARK: Add Account Flow

    func beginAddAccount(provider: AIProvider? = nil) {
        let provider = provider ?? pendingProvider
        pendingProvider = provider
        reloginTargetId = nil
        addAccountErrorMessage = nil
        pendingProfileEmail = ""
        pendingClaudeCredentialsData = nil
        pendingClaudeIdentity = nil
        profileManager.removeClaudeLoginDirectory(pendingClaudeLoginDirectory)
        pendingClaudeLoginDirectory = nil
        isAddingAccount = true
        addingStep = .waitingLogin

        switch provider {
        case .codex:
            watchAuthFileForNewLogin()
        case .claude:
            break
        }

        guard startProviderLogin(provider) else {
            stopAuthWatcher()
            return
        }

        scheduleLoginTimeout()
    }

    func confirmPendingProfile(alias: String) {
        let capturedProfile: Profile?
        if pendingProvider == .claude,
           let credentialsData = pendingClaudeCredentialsData,
           let identity = pendingClaudeIdentity {
            capturedProfile = profileManager.captureClaudeCodeAuth(
                alias: alias,
                credentialsData: credentialsData,
                identity: identity
            )
        } else {
            capturedProfile = profileManager.captureCurrentAuth(alias: alias, provider: pendingProvider)
        }

        guard let newProfile = capturedProfile else {
            cancelAddAccount()
            return
        }
        stopLoginProcess(suppressFailureFeedback: true)
        var config = profileManager.loadConfig()
        var profile = newProfile
        let previousActive = config.profiles.first {
            $0.id == config.activeProfileIdsByProvider[profile.provider] && $0.provider == profile.provider
        }
        let shouldActivate = previousActive == nil
        var deferredClaudeActivation: Profile?
        if shouldActivate { profile.activatedAt = Date() }
        config.profiles.append(profile)
        if shouldActivate {
            config.setActiveProfile(profile)
            if profile.provider != .claude {
                _ = try? profileManager.activate(profile: profile)
            } else {
                deferredClaudeActivation = profile
            }
            activeProfile = profile
        } else if let previousActive {
            if previousActive.provider == .claude {
                if selectedProvider == previousActive.provider {
                    activeProfile = previousActive
                }
            } else {
                let restoreResult = try? profileManager.activate(profile: previousActive)
                if restoreResult == .verified {
                    if selectedProvider == previousActive.provider {
                        activeProfile = previousActive
                    }
                } else {
                    if let index = config.profiles.firstIndex(where: { $0.id == profile.id }) {
                        config.profiles[index].activatedAt = Date()
                        profile = config.profiles[index]
                    }
                    config.setActiveProfile(profile)
                    activeProfile = profile
                }
            }
        }
        profileManager.saveConfig(config)
        profiles = config.profiles
        selectedProvider = config.selectedProvider
        activeProfileIdsByProvider = config.activeProfileIdsByProvider
        refreshSelectedExhaustionFlag()
        if let deferredClaudeActivation {
            activateStoredCredential(for: deferredClaudeActivation) { restoreResult in
                guard let restoreResult, restoreResult != .verified else { return }
                self.staleProfileIds.insert(profile.id)
                self.notifyProfileChanged()
                self.sendNotification(
                    title: L("Claude hesabı etkinleştirilemedi", "Claude account could not be activated"),
                    body: L(
                        "Claude credential dosyası bulunamadı. Claude'da bir kez giriş yapıp tekrar deneyin.",
                        "No Claude credential file was found. Sign in with Claude once and try again."
                    )
                )
            }
        }
        addingStep = .done
        isAddingAccount = false
        addAccountErrorMessage = nil
        pendingClaudeCredentialsData = nil
        pendingClaudeIdentity = nil
        profileManager.removeClaudeLoginDirectory(pendingClaudeLoginDirectory)
        pendingClaudeLoginDirectory = nil
        stopAuthWatcher()
        closeAddAccountWindow()
        notifyProfileChanged()
        sendNotification(title: "Hesap eklendi", body: profile.displayName)
        Task { await fetchAllRateLimits() }
    }

    func cancelAddAccount() {
        cancelLoginTimeout()
        stopLoginProcess(suppressFailureFeedback: true)
        isAddingAccount = false
        addingStep = .idle
        reloginTargetId = nil
        addAccountErrorMessage = nil
        pendingProfileEmail = ""
        pendingClaudeCredentialsData = nil
        pendingClaudeIdentity = nil
        profileManager.removeClaudeLoginDirectory(pendingClaudeLoginDirectory)
        pendingClaudeLoginDirectory = nil
        aliasText = ""
        stopAuthWatcher()
        closeAddAccountWindow()
        restorePendingProviderActiveCredential()
    }

    // MARK: Rename

    func renameProfile(_ profile: Profile, alias: String) {
        var config = profileManager.loadConfig()
        guard let i = config.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        config.profiles[i].alias = alias
        profileManager.saveConfig(config)
        profiles = config.profiles
        if activeProfile?.id == profile.id {
            activeProfile = config.profiles[i]
            activeProfileIdsByProvider[profile.provider] = profile.id
            notifyProfileChanged()
        }
    }

    func moveProfile(_ draggedProfileId: UUID, to destinationIndex: Int) {
        var config = profileManager.loadConfig()
        guard let movedProvider = config.profiles.first(where: { $0.id == draggedProfileId })?.provider else { return }
        let reorderedProfiles = ProfileOrdering.reordered(
            config.profiles,
            moving: draggedProfileId,
            toProviderDestinationIndex: destinationIndex
        )
        guard reorderedProfiles != config.profiles else { return }

        config.profiles = reorderedProfiles
        config.roundRobinIndex = min(config.roundRobinIndex, max(config.profiles.filter { $0.provider == movedProvider }.count - 1, 0))
        config.normalizeActiveProfiles()

        profileManager.saveConfig(config)
        profiles = config.profiles
        activeProfileIdsByProvider = config.activeProfileIdsByProvider
        activeProfile = config.profiles.first(where: { $0.id == config.activeProfileId })
        notifyProfileChanged()
    }

    func showRenameDialog(for profile: Profile) {
        let alert = NSAlert()
        alert.messageText = Str.renameTitle
        alert.informativeText = profile.email
        alert.addButton(withTitle: Str.save)
        alert.addButton(withTitle: Str.cancel)

        if let url = Bundle.appResources.url(forResource: "codex", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            alert.icon = icon
        }

        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        tf.stringValue = profile.alias
        tf.placeholderString = profile.email
        tf.bezelStyle = .roundedBezel
        alert.accessoryView = tf

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newAlias = tf.stringValue.trimmingCharacters(in: .whitespaces)
            renameProfile(profile, alias: newAlias)
        }
    }

    // MARK: Delete

    func delete(profile: Profile) {
        profileManager.deleteProfile(profile)
        rateLimits.removeValue(forKey: profile.id)
        let plan = ProfileDeletion.planDeleting(profile, from: profileManager.loadConfig())
        let config = plan.config
        if let replacement = plan.replacementActiveProfile {
            activateStoredCredential(for: replacement)
        }
        profileManager.saveConfig(config)
        profiles = config.profiles
        selectedProvider = config.selectedProvider
        activeProfileIdsByProvider = config.activeProfileIdsByProvider
        activeProfile = config.profiles.first(where: { $0.id == config.activeProfileId })
        refreshSelectedExhaustionFlag()
        notifyProfileChanged()
    }

    // MARK: Statistics Reset

    func resetStatistics() {
        let alert = NSAlert()
        alert.messageText = L("İstatistikleri sıfırla?", "Reset statistics?")
        alert.informativeText = L(
            "Tüm token ve maliyet geçmişi silinecek. Bu işlem geri alınamaz.",
            "All token and cost history will be deleted. This cannot be undone.")
        alert.addButton(withTitle: L("Sıfırla", "Reset"))
        alert.addButton(withTitle: L("İptal", "Cancel"))
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ai-switcher/cache")
        for name in StatisticsResetCacheFiles.names {
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(name))
        }

        tokenUsage         = [:]
        costs              = [:]
        forecasts          = [:]
        analyticsSnapshot  = .empty(for: analyticsTimeRange)
        paceHistory        = []
        rateLimitAuditSamples = [:]
        warned80PercentIds = []

        refreshTokenUsage()
    }

    // MARK: Re-login

    func beginRelogin(for profile: Profile) {
        reloginTargetId = profile.id
        pendingProvider = profile.provider
        addAccountErrorMessage = nil
        isAddingAccount = false
        addingStep = .waitingLogin
        switch profile.provider {
        case .codex:
            watchAuthFileForRelogin()
        case .claude:
            pendingClaudeCredentialsData = nil
            pendingClaudeIdentity = nil
            profileManager.removeClaudeLoginDirectory(pendingClaudeLoginDirectory)
            pendingClaudeLoginDirectory = nil
        }
        guard startProviderLogin(profile.provider) else {
            reloginTargetId = nil
            stopAuthWatcher()
            return
        }
        scheduleLoginTimeout()
    }
}
