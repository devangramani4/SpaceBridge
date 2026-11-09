import Foundation
import Observation
import StoreKit

/// SpaceBridge Pro on iPhone/iPad, sold as an auto-renewable subscription through the App Store
/// (Apple requires in-app purchase for digital features in App Store apps).
/// The price is set in App Store Connect, not in code.
@MainActor
@Observable
final class MobileProStore {
    /// Create these in App Store Connect ▸ your app ▸ Subscriptions (group "SpaceBridge Pro").
    static let productIDs = ["com.geniusbridge.spacebridge.pro.yearly", "com.geniusbridge.spacebridge.pro.monthly"]
    static let groupID = "SpaceBridgePro" // replace with the subscription group ID from App Store Connect

    private(set) var isPro = false
    private(set) var expiration: Date?
    private(set) var activeProductID: String?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { [weak self] in await self?.refresh() }
    }

    /// Recomputes entitlement from StoreKit's signed, on-device transaction records.
    func refresh() async {
        var active = false
        var expires: Date?
        var product: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if let date = transaction.expirationDate, date < Date() { continue }
            active = true
            expires = transaction.expirationDate
            product = transaction.productID
        }
        isPro = active
        expiration = expires
        activeProductID = product
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }
}

/// Paid features on iPhone/iPad.
enum MobileProFeature: String, CaseIterable, Identifiable {
    case duplicates, screenshots, bulkDelete, folderScan, unlimitedLists, watchApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duplicates: return "Duplicate Photos & Videos"
        case .screenshots: return "Screenshot Cleanup"
        case .bulkDelete: return "Bulk Delete"
        case .folderScan: return "Files & iCloud Drive Scanner"
        case .unlimitedLists: return "Full Largest-Items Lists"
        case .watchApp: return "Apple Watch Storage Glance"
        }
    }

    var detail: String {
        switch self {
        case .duplicates: return "Find exact copies and remove extras in one tap."
        case .screenshots: return "Review and clear old screenshots fast."
        case .bulkDelete: return "Select many videos or photos at once."
        case .folderScan: return "Find the biggest files in any folder you choose."
        case .unlimitedLists: return "See every large video, not just the top 10."
        case .watchApp: return "Your iPhone storage at a glance on your wrist."
        }
    }

    var symbolName: String {
        switch self {
        case .duplicates: return "square.on.square"
        case .screenshots: return "camera.viewfinder"
        case .bulkDelete: return "checklist"
        case .folderScan: return "folder.badge.gearshape"
        case .unlimitedLists: return "list.number"
        case .watchApp: return "applewatch"
        }
    }
}
