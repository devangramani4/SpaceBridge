import Foundation

/// A file record from the scan database. Lightweight: details such as the localized type
/// description and permissions are loaded on demand by `FileDetailsLoader`.
struct FileItem: Identifiable, Hashable, Sendable {
    struct Flags: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let hidden = Flags(rawValue: 1 << 0)
        static let symlink = Flags(rawValue: 1 << 1)
        static let hardLinked = Flags(rawValue: 1 << 2)
        static let invalidName = Flags(rawValue: 1 << 3)
    }

    var id: Int64
    var name: String
    var folderPath: String
    /// Lower-cased extension without the dot. Empty if none.
    var fileExtension: String
    /// Logical size in bytes (what Finder calls "size").
    var size: Int64
    /// Bytes allocated on disk. This is the number used for storage totals.
    var allocatedSize: Int64
    var created: Date?
    var modified: Date?
    var accessed: Date?
    var flags: Flags
    var category: StorageCategory

    var path: String { folderPath == "/" ? "/" + name : folderPath + "/" + name }
    var url: URL { URL(fileURLWithPath: path) }
    var parentFolder: String { folderPath }
    var isHidden: Bool { flags.contains(.hidden) }
    var isSymlink: Bool { flags.contains(.symlink) }
    var isHardLinked: Bool { flags.contains(.hardLinked) }
    var hasValidName: Bool { !flags.contains(.invalidName) }
    var formattedSize: String { ByteFormatter.string(allocatedSize) }

    // Non-optional sort keys for SwiftUI `Table`.
    var modifiedSortKey: Date { modified ?? .distantPast }
    var createdSortKey: Date { created ?? .distantPast }
    var typeSortKey: String { fileExtension.isEmpty ? "~" : fileExtension }
    var displayType: String { fileExtension.isEmpty ? "File" : fileExtension.uppercased() }
}

enum FileSortField: String, CaseIterable, Identifiable, Sendable {
    case size = "Size"
    case name = "Name"
    case modified = "Date Modified"
    case created = "Date Created"
    case type = "File Type"
    var id: String { rawValue }
}

extension Array where Element == FileItem {
    func sorted(by field: FileSortField, ascending: Bool) -> [FileItem] {
        sorted { lhs, rhs in
            let ordered: Bool
            switch field {
            case .size:
                ordered = lhs.allocatedSize == rhs.allocatedSize ? lhs.name < rhs.name : lhs.allocatedSize < rhs.allocatedSize
            case .name:
                ordered = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .modified:
                ordered = lhs.modifiedSortKey < rhs.modifiedSortKey
            case .created:
                ordered = lhs.createdSortKey < rhs.createdSortKey
            case .type:
                ordered = lhs.typeSortKey == rhs.typeSortKey ? lhs.allocatedSize > rhs.allocatedSize : lhs.typeSortKey < rhs.typeSortKey
            }
            return ascending ? ordered : !ordered
        }
    }
}

/// Extended details for the File Details panel, read from disk when the user selects a file.
struct FileDetails: Sendable {
    var typeDescription: String?
    var typeIdentifier: String?
    var created: Date?
    var modified: Date?
    var accessed: Date?
    var logicalSize: Int64?
    var allocatedSize: Int64?
    var isAlias: Bool
    var isSymlink: Bool
    var symlinkDestination: String?
    var isHidden: Bool
    var isPackage: Bool
    var posixPermissions: String?
    var owner: String?
    var group: String?
    var exists: Bool
    var safety: PathSafety
}
