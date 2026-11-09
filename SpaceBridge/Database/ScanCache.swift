import Foundation

// Value types exchanged between the scanner and the database actor.

/// A file observed during a scan.
struct ScannedFile: Sendable {
    var name: String
    var fileExtension: String
    var size: Int64
    var allocatedSize: Int64
    /// `allocatedSize`, or 0 for the second and later occurrences of a hard-linked file.
    var countedAllocatedSize: Int64
    var modified: TimeInterval
    var created: TimeInterval
    var accessed: TimeInterval
    var flags: FileItem.Flags
    /// Inode for hard-linked files (link count > 1), otherwise 0.
    var inode: UInt64
    var category: StorageCategory
}

/// A sub-directory observed during a scan.
struct ScannedSubdirectory: Sendable {
    var name: String
    var modified: TimeInterval
}

/// Everything learned about one directory in one pass. Only metadata — never file contents.
struct DirectorySnapshot: Sendable {
    var path: String
    var name: String
    var parentID: Int64?
    /// Known database id (root or placeholder created by the parent), if any.
    var folderID: Int64?
    var depth: Int
    var modified: TimeInterval
    var isRestricted: Bool
    var files: [ScannedFile]
    var subdirectories: [ScannedSubdirectory]
    var category: StorageCategory
}

struct DirectorySyncResult: Sendable {
    var folderID: Int64
    /// Child directory name → database id (placeholders are created for new folders).
    var childIDs: [String: Int64]
    var newFiles: Int
    var changedFiles: Int
    var deletedFiles: Int
    var deletedFolders: Int
}

struct ScanRecord: Sendable, Identifiable, Equatable {
    enum Status: String, Sendable { case running, completed, cancelled, failed }
    var id: Int64
    var started: Date
    var finished: Date?
    var status: Status
    var roots: [String]
    var fileCount: Int64
    var folderCount: Int64
    var bytes: Int64
    var newFiles: Int64
    var changedFiles: Int64
    var deletedFiles: Int64
}

struct StorageHistoryPoint: Sendable, Identifiable, Hashable {
    var id: Int64
    var date: Date
    var volumeTotal: Int64
    var volumeUsed: Int64
    var scannedBytes: Int64
}

struct ScanErrorEntry: Sendable, Identifiable, Hashable {
    var id: Int64
    var date: Date
    var path: String
    var message: String
}

/// Aggregate figures for the dashboard.
struct ScanTotals: Sendable, Equatable {
    var fileCount: Int64 = 0
    var folderCount: Int64 = 0
    var allocatedBytes: Int64 = 0
    var restrictedFolders: Int64 = 0
}

/// A parsed search request executed against the scan index.
struct SearchQuery: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable { case all = "All", files = "Files", folders = "Folders" }

    /// Case-insensitive glob on the name (e.g. `*.zip`, `report-??.pdf`).
    var nameGlob: String?
    /// Case-insensitive substring match on the name.
    var nameContains: String?
    var fileExtension: String?
    /// Substring that must appear in the containing folder's path.
    var folderContains: String?
    var minSize: Int64?
    var maxSize: Int64?
    var modifiedBefore: Date?
    var modifiedAfter: Date?
    var category: StorageCategory?
    var kind: Kind = .all
    /// Application name filter (searched in the app list, not the file index).
    var applicationName: String?
    var limit: Int = 500

    /// Filters beyond a plain name / extension search (a Pro feature).
    var isAdvanced: Bool {
        minSize != nil || maxSize != nil || modifiedBefore != nil || modifiedAfter != nil
            || folderContains != nil || category != nil
    }

    var isEmpty: Bool {
        nameGlob == nil && nameContains == nil && fileExtension == nil && folderContains == nil
            && minSize == nil && maxSize == nil && modifiedBefore == nil && modifiedAfter == nil
            && category == nil && applicationName == nil
    }
}

struct DuplicateCandidateSize: Sendable, Hashable {
    var size: Int64
    var count: Int
}
