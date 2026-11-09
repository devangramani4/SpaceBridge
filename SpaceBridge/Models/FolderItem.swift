import Foundation

/// A folder record from the scan database with recursive totals.
struct FolderItem: Identifiable, Hashable, Sendable {
    var id: Int64
    var parentID: Int64?
    var path: String
    var name: String
    /// Recursive bytes allocated on disk (hard links counted once).
    var totalAllocated: Int64
    /// Recursive logical bytes.
    var totalSize: Int64
    /// Recursive number of files.
    var fileCount: Int64
    /// Recursive number of sub-folders.
    var folderCount: Int64
    var directAllocated: Int64
    var directFileCount: Int64
    var modified: Date?
    var isRestricted: Bool
    var lastScanned: Date?

    var url: URL { URL(fileURLWithPath: path) }
    var hasChildren: Bool { folderCount > 0 }
    var formattedSize: String { ByteFormatter.string(totalAllocated) }
}

/// Result of an on-demand recursive size calculation (used outside the main scan).
struct FolderSizeResult: Sendable, Equatable {
    var allocatedSize: Int64 = 0
    var logicalSize: Int64 = 0
    var fileCount: Int64 = 0
    var folderCount: Int64 = 0
    var restrictedFolderCount: Int = 0
    var exists = true
    var wasCancelled = false
    /// `true` if at least one folder could not be read, so the value is a lower bound.
    var isPartial: Bool { restrictedFolderCount > 0 || wasCancelled }
}
