import Foundation
import Photos

/// One photo or video, with the metadata needed for storage analysis (no image data).
struct MediaItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case photo = "Photo", video = "Video", livePhoto = "Live Photo", screenshot = "Screenshot" }
    var id: String
    var kind: Kind
    var created: Date?
    var duration: TimeInterval
    var pixelWidth: Int
    var pixelHeight: Int
    /// Size of the original file. `nil` if iOS doesn't report it for this item.
    var bytes: Int64?
    var filename: String?
    var isFavorite: Bool
}

struct MediaDuplicateGroup: Identifiable, Hashable, Sendable {
    var id: String
    var items: [MediaItem]
    var bytesEach: Int64
    var potentialSavings: Int64 { bytesEach * Int64(max(items.count - 1, 0)) }
}

struct PhotoLibraryReport: Sendable {
    var photoCount = 0
    var videoCount = 0
    var screenshotCount = 0
    var totalBytes: Int64 = 0
    var videoBytes: Int64 = 0
    var screenshotBytes: Int64 = 0
    /// Items whose size iOS didn't report (counted, but not in byte totals).
    var unknownSizeCount = 0
    var largestVideos: [MediaItem] = []
    var largestItems: [MediaItem] = []
    var screenshots: [MediaItem] = []
    var duplicateGroups: [MediaDuplicateGroup] = []
    var analyzedAt = Date()

    var duplicateSavings: Int64 { duplicateGroups.reduce(0) { $0 + $1.potentialSavings } }
}

/// Analyzes the Photos library on-device. Read-only; no network access (iCloud downloads are disabled).
enum PhotoLibraryAnalyzer {
    static func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Size of an asset's original resource. Uses the resource's `fileSize` value, which iOS reports
    /// for local and iCloud originals; returns `nil` when unavailable rather than guessing.
    static func fileSize(of asset: PHAsset) -> (bytes: Int64?, filename: String?) {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
        let resource = resources.first { preferred.contains($0.type) } ?? resources.first
        guard let resource else { return (nil, nil) }
        let size = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
        return (size.flatMap { $0 > 0 ? $0 : nil }, resource.originalFilename)
    }

    static func analyze(progress: @escaping @Sendable (Double) -> Void) async -> PhotoLibraryReport {
        await Task.detached(priority: .userInitiated) {
            analyzeSync(progress: progress)
        }.value
    }

    private static func analyzeSync(progress: @Sendable (Double) -> Void) -> PhotoLibraryReport {
        var report = PhotoLibraryReport()
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: options)
        let total = max(assets.count, 1)
        var items: [MediaItem] = []
        items.reserveCapacity(assets.count)

        assets.enumerateObjects { asset, index, stop in
            if Task.isCancelled { stop.pointee = true; return }
            let (bytes, filename) = fileSize(of: asset)
            let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
            let kind: MediaItem.Kind
            if asset.mediaType == .video { kind = .video }
            else if isScreenshot { kind = .screenshot }
            else if asset.mediaSubtypes.contains(.photoLive) { kind = .livePhoto }
            else { kind = .photo }
            items.append(MediaItem(id: asset.localIdentifier, kind: kind, created: asset.creationDate, duration: asset.duration,
                                   pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, bytes: bytes,
                                   filename: filename, isFavorite: asset.isFavorite))
            if index % 200 == 0 { progress(Double(index) / Double(total)) }
        }

        for item in items {
            switch item.kind {
            case .video: report.videoCount += 1
            case .screenshot: report.screenshotCount += 1; report.photoCount += 1
            default: report.photoCount += 1
            }
            guard let bytes = item.bytes else { report.unknownSizeCount += 1; continue }
            report.totalBytes += bytes
            if item.kind == .video { report.videoBytes += bytes }
            if item.kind == .screenshot { report.screenshotBytes += bytes }
        }
        let sized = items.filter { $0.bytes != nil }
        report.largestItems = Array(sized.sorted { $0.bytes! > $1.bytes! }.prefix(200))
        report.largestVideos = Array(sized.filter { $0.kind == .video }.sorted { $0.bytes! > $1.bytes! }.prefix(200))
        report.screenshots = items.filter { $0.kind == .screenshot }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        report.duplicateGroups = duplicates(in: sized)
        report.analyzedAt = Date()
        progress(1)
        return report
    }

    /// Likely exact duplicates: same type, pixel size, byte size and capture second.
    /// (Saved copies and re-imports match all four; different photos practically never do.)
    static func duplicates(in items: [MediaItem]) -> [MediaDuplicateGroup] {
        var groups: [String: [MediaItem]] = [:]
        for item in items {
            guard let bytes = item.bytes else { continue }
            let second = item.created.map { Int($0.timeIntervalSince1970) } ?? -1
            let key = "\(item.kind.rawValue)|\(item.pixelWidth)x\(item.pixelHeight)|\(bytes)|\(second)"
            groups[key, default: []].append(item)
        }
        return groups.compactMap { key, members in
            guard members.count > 1, let bytes = members[0].bytes else { return nil }
            // Keep favorites first so they're the default "keep" choice.
            let ordered = members.sorted { ($0.isFavorite ? 0 : 1) < ($1.isFavorite ? 0 : 1) }
            return MediaDuplicateGroup(id: key, items: ordered, bytesEach: bytes)
        }
        .sorted { $0.potentialSavings > $1.potentialSavings }
    }

    /// Deletes assets. iOS shows its own confirmation and moves them to "Recently Deleted" (30 days).
    static func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}
