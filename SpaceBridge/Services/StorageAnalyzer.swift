import Foundation

/// Capacity information for a mounted volume, from Apple's volume resource keys.
struct VolumeInfo: Identifiable, Sendable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var totalCapacity: Int64
    /// Free space including purgeable space macOS can reclaim on demand (what Finder shows).
    var availableForImportantUsage: Int64
    /// Strictly free space right now.
    var availableStrict: Int64
    var isInternal: Bool
    var isRemovable: Bool
    var isEjectable: Bool
    var isRootFileSystem: Bool
    var isReadOnly: Bool
    var isLocal: Bool
    var formatDescription: String?

    var available: Int64 { max(availableForImportantUsage, availableStrict) }
    var used: Int64 { max(totalCapacity - available, 0) }
    var purgeable: Int64 { max(availableForImportantUsage - availableStrict, 0) }
    var usedFraction: Double { totalCapacity > 0 ? Double(used) / Double(totalCapacity) : 0 }
}

enum VolumeService {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        .volumeIsEjectableKey, .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey, .volumeIsLocalKey,
        .volumeLocalizedFormatDescriptionKey,
    ]

    static func info(for url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        guard total > 0 else { return nil }
        return VolumeInfo(
            name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
            path: url.path,
            totalCapacity: total,
            availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0),
            availableStrict: Int64(values.volumeAvailableCapacity ?? 0),
            isInternal: values.volumeIsInternal ?? false,
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            isRootFileSystem: values.volumeIsRootFileSystem ?? false,
            isReadOnly: values.volumeIsReadOnly ?? false,
            isLocal: values.volumeIsLocal ?? true,
            formatDescription: values.volumeLocalizedFormatDescription)
    }

    /// The startup disk. Capacity covers the whole APFS container (System + Data volumes).
    static func startupVolume() -> VolumeInfo? {
        info(for: URL(fileURLWithPath: "/"))
    }

    static func mountedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { info(for: $0) }
    }

    /// External / additional volumes that can be scanned (mounted under /Volumes).
    static func externalVolumes(includeNetwork: Bool) -> [VolumeInfo] {
        mountedVolumes().filter { volume in
            !volume.isRootFileSystem && volume.path.hasPrefix("/Volumes/") && (includeNetwork || volume.isLocal)
        }
    }
}

/// A well-known location shown on the Storage screen with its size from the scan cache.
struct KnownLocation: Identifiable, Sendable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var symbolName: String
    var category: StorageCategory?

    static func standard(home: String = NSHomeDirectory()) -> [KnownLocation] {
        [
            KnownLocation(name: "Applications", path: "/Applications", symbolName: "square.grid.2x2", category: .applications),
            KnownLocation(name: "Applications (User)", path: home + "/Applications", symbolName: "square.grid.2x2", category: .applications),
            KnownLocation(name: "Downloads", path: home + "/Downloads", symbolName: "arrow.down.circle", category: .downloads),
            KnownLocation(name: "Documents", path: home + "/Documents", symbolName: "doc.text", category: .documents),
            KnownLocation(name: "Desktop", path: home + "/Desktop", symbolName: "menubar.dock.rectangle", category: .desktop),
            KnownLocation(name: "Pictures", path: home + "/Pictures", symbolName: "photo", category: .photos),
            KnownLocation(name: "Movies", path: home + "/Movies", symbolName: "film", category: .videos),
            KnownLocation(name: "Music", path: home + "/Music", symbolName: "music.note", category: .music),
            KnownLocation(name: "Library (User)", path: home + "/Library", symbolName: "building.columns", category: nil),
            KnownLocation(name: "Library", path: "/Library", symbolName: "building.columns", category: nil),
            KnownLocation(name: "System", path: "/System", symbolName: "gearshape.2", category: .system),
            KnownLocation(name: "Users", path: "/Users", symbolName: "person.2", category: nil),
        ]
    }
}

/// Combines the scan cache with live volume data into dashboard figures.
struct StorageSummary: Sendable, Equatable {
    var volume: VolumeInfo?
    var totals = ScanTotals()
    var categories: [CategoryUsage] = []
    var largestFile: FileItem?
    var largestFolder: FolderItem?
    var recentLargeFiles: [FileItem] = []
    var history: [StorageHistoryPoint] = []
    var lastScan: ScanRecord?
    var applicationCount: Int?

    /// Used space that the scan could not attribute to a file: APFS snapshots, purgeable data,
    /// macOS VM/Preboot/Recovery volumes and folders macOS didn't let SpaceBridge read.
    var unattributedBytes: Int64? {
        guard let volume, totals.allocatedBytes > 0 else { return nil }
        let startupScanned = categories.reduce(0) { $0 + $1.bytes }
        return max(volume.used - min(startupScanned, totals.allocatedBytes), 0)
    }

    var hasScanData: Bool { totals.fileCount > 0 }
}

enum StorageAnalyzer {
    @discardableResult
    static func loadSummary(database: StorageDatabase) async -> StorageSummary {
        var summary = StorageSummary()
        summary.volume = VolumeService.startupVolume()
        summary.totals = (try? await database.totals()) ?? ScanTotals()
        summary.categories = ((try? await database.categoryTotals()) ?? []).filter { $0.bytes > 0 }
        summary.largestFile = try? await database.largestFiles(limit: 1).first
        summary.largestFolder = try? await database.largestFolders(limit: 1, maxDepth: 6).first {
            // a meaningful folder rather than a scan root's direct child like /Users
            $0.path.split(separator: "/").count >= 3
        }
        let monthAgo = Date().addingTimeInterval(-30 * 24 * 3600)
        summary.recentLargeFiles = (try? await database.recentLargeFiles(since: monthAgo, minimumSize: 100_000_000, limit: 8)) ?? []
        summary.history = (try? await database.history()) ?? []
        summary.lastScan = try? await database.lastScan()
        return summary
    }
}
