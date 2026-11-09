import AppKit
import Foundation
import Observation

enum ProStatus: Equatable {
    case free(trialAvailable: Bool)
    case trial(endsAt: Date)
    case pro(LicenseInfo)
    /// Subscription ended or was refunded/disabled.
    case lapsed(LicenseInfo)

    var isPro: Bool {
        switch self {
        case .trial, .pro: return true
        case .free, .lapsed: return false
        }
    }
}

/// Owns Pro entitlement state: free trial, license activation and periodic validation.
@MainActor
@Observable
final class ProStore {
    private(set) var status: ProStatus = .free(trialAvailable: true)
    var isWorking = false
    var lastError: String?

    private let keychain: KeychainStore
    private let service: LicenseService
    private let now: () -> Date

    private static let licenseAccount = "license"
    private static let trialAccount = "trial-start"

    init(keychain: KeychainStore = KeychainStore(), service: LicenseService = LemonSqueezyLicenseService(), now: @escaping () -> Date = Date.init) {
        self.keychain = keychain
        self.service = service
        self.now = now
        refreshLocalStatus()
    }

    var isPro: Bool { status.isPro }

    var trialDaysLeft: Int? {
        guard case .trial(let endsAt) = status else { return nil }
        return max(Int(ceil(endsAt.timeIntervalSince(now()) / 86_400)), 0)
    }

    func isUnlocked(_ feature: ProFeature) -> Bool { isPro }

    /// Recomputes status from the Keychain without any network access.
    func refreshLocalStatus() {
        if let license = keychain.value(LicenseInfo.self, for: Self.licenseAccount) {
            let offlineTooLong = now().timeIntervalSince(license.lastValidated) > ProConfiguration.offlineGracePeriod
            status = license.isActive && !offlineTooLong ? .pro(license) : .lapsed(license)
            return
        }
        if let start = keychain.value(Date.self, for: Self.trialAccount) {
            let end = start.addingTimeInterval(TimeInterval(ProConfiguration.trialDays) * 86_400)
            status = end > now() ? .trial(endsAt: end) : .free(trialAvailable: false)
        } else {
            status = .free(trialAvailable: true)
        }
    }

    /// Starts the one-time free trial (no account or card needed).
    func startTrial() {
        guard case .free(let available) = status, available else { return }
        keychain.setValue(now(), for: Self.trialAccount)
        refreshLocalStatus()
    }

    func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { lastError = "Enter your license key."; return }
        guard ProConfiguration.isConfigured else { lastError = LicenseError.notConfigured.errorDescription; return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let instanceName = "SpaceBridge-" + String(UUID().uuidString.prefix(8))
            let license = try await service.activate(key: key, instanceName: instanceName)
            keychain.setValue(license, for: Self.licenseAccount)
            refreshLocalStatus()
            if !license.isActive { lastError = "This subscription is \(license.status). Renew it to unlock Pro." }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Called at launch. Re-checks the license weekly; network failures never lock out a paying user
    /// until the 30-day offline grace period has passed.
    func validateIfNeeded(force: Bool = false) async {
        guard let license = keychain.value(LicenseInfo.self, for: Self.licenseAccount) else { refreshLocalStatus(); return }
        guard force || now().timeIntervalSince(license.lastValidated) > ProConfiguration.revalidationInterval else { return }
        do {
            let updated = try await service.validate(license)
            keychain.setValue(updated, for: Self.licenseAccount)
        } catch LicenseError.network {
            // Offline: keep the cached license; grace period applies in refreshLocalStatus().
        } catch {
            var invalid = license
            invalid.status = "invalid"
            keychain.setValue(invalid, for: Self.licenseAccount)
        }
        refreshLocalStatus()
    }

    /// Frees this Mac's activation so the key can be used on another Mac.
    func deactivate() async {
        guard let license = keychain.value(LicenseInfo.self, for: Self.licenseAccount) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.deactivate(license)
        } catch LicenseError.network(let reason) {
            lastError = "Removed from this Mac, but the server couldn't be reached (\(reason)). Contact support if activation limits block you."
        } catch {
            lastError = error.localizedDescription
        }
        keychain.remove(Self.licenseAccount)
        refreshLocalStatus()
    }

    func openCheckout() { NSWorkspace.shared.open(ProConfiguration.checkoutURL) }
    func openCustomerPortal() { NSWorkspace.shared.open(ProConfiguration.customerPortalURL) }
}
