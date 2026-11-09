import Foundation

struct ScannedMobileFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var relativePath: String
    var bytes: Int64
    var modified: Date?
}

struct FolderScanReport: Sendable {
    var folderName: String
    var fileCount = 0
    var folderCount = 0
    var totalBytes: Int64 = 0
    var largest: [ScannedMobileFile] = []
    var unreadable = 0
    var scannedAt = Date()
}

/// Scans a folder the user picked in the Files app (iCloud Drive, On My iPhone, external drives).
/// iOS only grants access to folders the user explicitly chooses.
enum FolderScanner {
    private static let bookmarkKey = "lastScannedFolderBookmark"

    static func scan(_ url: URL, keepTop: Int = 300) async -> FolderScanReport {
        await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            var report = FolderScanReport(folderName: url.lastPathComponent)
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in
                true // keep going past unreadable items
            }) else { return report }
            var top: [ScannedMobileFile] = []
            var threshold: Int64 = -1 // smallest size still kept after the last trim
            let basePath = url.standardizedFileURL.path
            for case let item as URL in enumerator {
                if Task.isCancelled { break }
                guard let values = try? item.resourceValues(forKeys: Set(keys)) else { report.unreadable += 1; continue }
                if values.isDirectory == true { report.folderCount += 1; continue }
                if values.isSymbolicLink == true { continue }
                let bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                report.fileCount += 1
                report.totalBytes += bytes
                if bytes > threshold {
                    let path = item.standardizedFileURL.path
                    let relative = path.hasPrefix(basePath) ? String(path.dropFirst(basePath.count)) : path
                    top.append(ScannedMobileFile(name: item.lastPathComponent, path: path, relativePath: relative, bytes: bytes, modified: values.contentModificationDate))
                    if top.count > keepTop * 2 {
                        top.sort { $0.bytes > $1.bytes }
                        top.removeLast(top.count - keepTop)
                        threshold = top.last?.bytes ?? -1
                    }
                }
            }
            top.sort { $0.bytes > $1.bytes }
            report.largest = Array(top.prefix(keepTop))
            report.scannedAt = Date()
            return report
        }.value
    }

    static func rememberFolder(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    static func rememberedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Removes a file the user confirmed. Uses the Trash / "Recently Deleted" where the location
    /// supports it; otherwise `permanently` must be true (the UI asks a second time first).
    static func remove(_ file: ScannedMobileFile, in folder: URL, permanently: Bool) throws {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let url = URL(fileURLWithPath: file.path)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            guard permanently else { throw RemovalError.noTrash }
            try FileManager.default.removeItem(at: url)
        }
    }

    enum RemovalError: LocalizedError {
        case noTrash
        var errorDescription: String? { "This location has no Recently Deleted folder." }
    }
}
