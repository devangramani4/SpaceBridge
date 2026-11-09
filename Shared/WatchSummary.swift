import Foundation

/// The storage summary the iPhone shares with the Apple Watch.
/// Sent with WatchConnectivity directly between the paired devices — never to any server.
/// Contains only totals and counts: no file names, photos or paths.
struct WatchSummary: Equatable, Sendable {
    var totalBytes: Int64
    var usedBytes: Int64
    var availableBytes: Int64
    var photoLibraryBytes: Int64?
    var reclaimableBytes: Int64?
    var duplicateCount: Int?
    var largeVideoCount: Int?
    var isPro: Bool
    var updated: Date

    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    var dictionary: [String: Any] {
        var values: [String: Any] = [
            "totalBytes": totalBytes, "usedBytes": usedBytes, "availableBytes": availableBytes,
            "isPro": isPro, "updated": updated.timeIntervalSince1970,
        ]
        if let photoLibraryBytes { values["photoLibraryBytes"] = photoLibraryBytes }
        if let reclaimableBytes { values["reclaimableBytes"] = reclaimableBytes }
        if let duplicateCount { values["duplicateCount"] = duplicateCount }
        if let largeVideoCount { values["largeVideoCount"] = largeVideoCount }
        return values
    }

    init(totalBytes: Int64, usedBytes: Int64, availableBytes: Int64, photoLibraryBytes: Int64? = nil, reclaimableBytes: Int64? = nil,
         duplicateCount: Int? = nil, largeVideoCount: Int? = nil, isPro: Bool = false, updated: Date = Date()) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
        self.photoLibraryBytes = photoLibraryBytes
        self.reclaimableBytes = reclaimableBytes
        self.duplicateCount = duplicateCount
        self.largeVideoCount = largeVideoCount
        self.isPro = isPro
        self.updated = updated
    }

    init?(dictionary: [String: Any]) {
        func int64(_ key: String) -> Int64? { (dictionary[key] as? NSNumber)?.int64Value }
        guard let total = int64("totalBytes"), let used = int64("usedBytes"), let available = int64("availableBytes") else { return nil }
        self.init(totalBytes: total, usedBytes: used, availableBytes: available,
                  photoLibraryBytes: int64("photoLibraryBytes"), reclaimableBytes: int64("reclaimableBytes"),
                  duplicateCount: (dictionary["duplicateCount"] as? NSNumber)?.intValue,
                  largeVideoCount: (dictionary["largeVideoCount"] as? NSNumber)?.intValue,
                  isPro: (dictionary["isPro"] as? Bool) ?? false,
                  updated: Date(timeIntervalSince1970: (dictionary["updated"] as? NSNumber)?.doubleValue ?? 0))
    }
}
