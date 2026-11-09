import Foundation

/// SpaceBridge Pro commercial settings.
///
/// Sales go through Lemon Squeezy, a merchant of record: it charges US customers in USD, collects and
/// remits US sales tax, handles refunds and chargebacks, and issues a license key per subscription.
/// Replace the placeholders below with your store's values before shipping (see MONETIZATION.md).
enum ProConfiguration {
    static let priceText = "$99.99"
    static let billingPeriod = "year"
    static let trialDays = 14

    /// Checkout link for the yearly subscription product (Lemon Squeezy ▸ Products ▸ Share).
    static let checkoutURL = URL(string: "https://geniusbridge.lemonsqueezy.com/buy/REPLACE-WITH-VARIANT-ID")!
    /// Customer portal where subscribers update payment details or cancel.
    static let customerPortalURL = URL(string: "https://geniusbridge.lemonsqueezy.com/billing")!
    static let termsURL = URL(string: "https://geniusbridge.com/spacebridge/terms")!
    static let privacyURL = URL(string: "https://geniusbridge.com/spacebridge/privacy")!
    static let supportEmail = "support@geniusbridge.com"

    /// Lemon Squeezy store and product IDs. Keys from any other store or product are rejected.
    /// Leave `nil` only during development.
    static let storeID: Int? = nil
    static let productIDs: Set<Int> = []

    static var isConfigured: Bool { !checkoutURL.absoluteString.contains("REPLACE") && storeID != nil }

    /// How often an active license is re-checked online.
    static let revalidationInterval: TimeInterval = 7 * 24 * 3600
    /// How long Pro keeps working without reaching the license server (offline, travelling…).
    static let offlineGracePeriod: TimeInterval = 30 * 24 * 3600
}

/// Paid features. Free users can always scan, browse and monitor; Pro adds power tools.
enum ProFeature: String, CaseIterable, Identifiable, Sendable {
    case cleanup, duplicates, developerStorage, advancedSearch, unlimitedLists, externalVolumes, appStorageBreakdown, exportReports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanup: return "One-Click Cleanup"
        case .duplicates: return "Duplicate Finder"
        case .developerStorage: return "Developer Storage"
        case .advancedSearch: return "Advanced Search"
        case .unlimitedLists: return "Unlimited Largest Files"
        case .externalVolumes: return "External Drives"
        case .appStorageBreakdown: return "App Storage Breakdown"
        case .exportReports: return "Export Reports"
        }
    }

    var detail: String {
        switch self {
        case .cleanup: return "Move caches, logs, DerivedData and old builds to the Trash safely."
        case .duplicates: return "Find identical files with partial and full SHA-256 hashing."
        case .developerStorage: return "Xcode, node_modules, Docker, Android and Git storage in one place."
        case .advancedSearch: return "Filter by size, date, folder and type — e.g. size > 1 GB."
        case .unlimitedLists: return "Top 500 and custom-length lists of the largest files."
        case .externalVolumes: return "Scan external SSDs, USB drives and network volumes."
        case .appStorageBreakdown: return "See each app's hidden data, caches and logs in ~/Library."
        case .exportReports: return "Export largest files and folders to CSV for audits."
        }
    }

    var symbolName: String {
        switch self {
        case .cleanup: return "sparkles"
        case .duplicates: return "square.on.square"
        case .developerStorage: return "chevron.left.forwardslash.chevron.right"
        case .advancedSearch: return "line.3.horizontal.decrease.circle"
        case .unlimitedLists: return "list.number"
        case .externalVolumes: return "externaldrive"
        case .appStorageBreakdown: return "chart.bar.doc.horizontal"
        case .exportReports: return "square.and.arrow.up"
        }
    }
}

/// A license as last confirmed by the license server.
struct LicenseInfo: Codable, Equatable, Sendable {
    var key: String
    var instanceID: String
    var status: String
    var customerEmail: String?
    var productName: String?
    var expiresAt: Date?
    var lastValidated: Date

    var maskedKey: String {
        guard key.count > 8 else { return key }
        return String(key.prefix(4)) + "••••" + String(key.suffix(4))
    }

    /// `active` and `on_trial`-style statuses unlock Pro; expired/disabled don't.
    var isActive: Bool {
        if let expiresAt, expiresAt < Date() { return false }
        return status == "active"
    }
}

enum LicenseError: LocalizedError, Equatable {
    case notConfigured
    case invalidKey(String)
    case wrongProduct
    case network(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Purchasing isn't configured in this build yet."
        case .invalidKey(let reason): return reason.isEmpty ? "This license key isn't valid." : reason
        case .wrongProduct: return "This license key is for a different product."
        case .network(let reason): return "Couldn't reach the license server: \(reason)"
        case .server(let reason): return reason
        }
    }
}

protocol LicenseService: Sendable {
    func activate(key: String, instanceName: String) async throws -> LicenseInfo
    func validate(_ license: LicenseInfo) async throws -> LicenseInfo
    func deactivate(_ license: LicenseInfo) async throws
}

/// Lemon Squeezy License API (https://docs.lemonsqueezy.com/api/license-api).
/// Only the license key and an anonymous instance name are sent — never any file or system data.
struct LemonSqueezyLicenseService: LicenseService {
    var baseURL = URL(string: "https://api.lemonsqueezy.com/v1/licenses")!
    var session: URLSession = .shared

    private struct LicenseKey: Decodable { var status: String?; var key: String?; var expires_at: String? }
    private struct Instance: Decodable { var id: String? }
    private struct Meta: Decodable { var store_id: Int?; var product_id: Int?; var product_name: String?; var customer_email: String? }
    private struct Response: Decodable {
        var activated: Bool?
        var valid: Bool?
        var deactivated: Bool?
        var error: String?
        var license_key: LicenseKey?
        var instance: Instance?
        var meta: Meta?
    }

    private func post(_ endpoint: String, _ fields: [String: String]) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)

        let data: Data
        do {
            let result = try await session.data(for: request)
            data = result.0
        } catch {
            throw LicenseError.network(error.localizedDescription)
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw LicenseError.server("Unexpected response from the license server.")
        }
        return response
    }

    private func checkProduct(_ meta: Meta?) throws {
        if let expected = ProConfiguration.storeID, meta?.store_id != expected { throw LicenseError.wrongProduct }
        if !ProConfiguration.productIDs.isEmpty, !ProConfiguration.productIDs.contains(meta?.product_id ?? -1) {
            throw LicenseError.wrongProduct
        }
    }

    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    func activate(key: String, instanceName: String) async throws -> LicenseInfo {
        let response = try await post("activate", ["license_key": key, "instance_name": instanceName])
        guard response.activated == true, let instanceID = response.instance?.id else {
            throw LicenseError.invalidKey(response.error ?? "")
        }
        try checkProduct(response.meta)
        return LicenseInfo(key: key, instanceID: instanceID, status: response.license_key?.status ?? "active",
                           customerEmail: response.meta?.customer_email, productName: response.meta?.product_name,
                           expiresAt: Self.date(response.license_key?.expires_at), lastValidated: Date())
    }

    func validate(_ license: LicenseInfo) async throws -> LicenseInfo {
        let response = try await post("validate", ["license_key": license.key, "instance_id": license.instanceID])
        try checkProduct(response.meta)
        var updated = license
        updated.status = response.valid == true ? (response.license_key?.status ?? "active") : (response.license_key?.status ?? "invalid")
        updated.expiresAt = Self.date(response.license_key?.expires_at)
        updated.customerEmail = response.meta?.customer_email ?? license.customerEmail
        updated.lastValidated = Date()
        return updated
    }

    func deactivate(_ license: LicenseInfo) async throws {
        let response = try await post("deactivate", ["license_key": license.key, "instance_id": license.instanceID])
        if response.deactivated != true { throw LicenseError.server(response.error ?? "The license couldn't be deactivated.") }
    }
}
