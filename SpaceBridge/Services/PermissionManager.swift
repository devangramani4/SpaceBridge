import AppKit
import Foundation

enum AccessStatus: Sendable, Equatable {
    case granted
    case denied
    case notFound
    case notChecked

    var symbolName: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.triangle.fill"
        case .notFound: return "minus.circle"
        case .notChecked: return "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .granted: return "Accessible"
        case .denied: return "Access Restricted"
        case .notFound: return "Not present"
        case .notChecked: return "Not checked"
        }
    }
}

struct ProtectedLocation: Identifiable, Sendable, Hashable {
    enum Requirement: String, Sendable {
        /// macOS asks the user once ("SpaceBridge would like to access files in your Documents folder").
        case filesAndFolders = "Files & Folders"
        /// Only available by adding SpaceBridge under Full Disk Access in System Settings.
        case fullDiskAccess = "Full Disk Access"
        /// Normal POSIX permissions; admin/root-only folders stay restricted by design.
        case filePermissions = "File permissions"
    }

    var id: String { path }
    var name: String
    var path: String
    var requirement: Requirement
    var explanation: String
}

/// Checks access using only read-only calls (`opendir`/`open`). It never changes permissions
/// and never tries to bypass macOS privacy protection (TCC).
enum PermissionManager {
    static func locations(home: String = NSHomeDirectory()) -> [ProtectedLocation] {
        [
            ProtectedLocation(name: "Applications", path: "/Applications", requirement: .filePermissions,
                              explanation: "Installed apps. Readable by every user."),
            ProtectedLocation(name: "Documents", path: home + "/Documents", requirement: .filesAndFolders,
                              explanation: "macOS asks once before SpaceBridge can read this folder."),
            ProtectedLocation(name: "Desktop", path: home + "/Desktop", requirement: .filesAndFolders,
                              explanation: "macOS asks once before SpaceBridge can read this folder."),
            ProtectedLocation(name: "Downloads", path: home + "/Downloads", requirement: .filesAndFolders,
                              explanation: "macOS asks once before SpaceBridge can read this folder."),
            ProtectedLocation(name: "Pictures", path: home + "/Pictures", requirement: .filePermissions,
                              explanation: "Your pictures. The Photos library inside needs Full Disk Access to be measured."),
            ProtectedLocation(name: "Library", path: home + "/Library", requirement: .filePermissions,
                              explanation: "App data and caches. Some sub-folders (Mail, Messages, Safari) need Full Disk Access."),
            ProtectedLocation(name: "Mail", path: home + "/Library/Mail", requirement: .fullDiskAccess,
                              explanation: "Mail downloads can be large. Needs Full Disk Access."),
            ProtectedLocation(name: "Messages", path: home + "/Library/Messages", requirement: .fullDiskAccess,
                              explanation: "Message attachments. Needs Full Disk Access."),
            ProtectedLocation(name: "Safari", path: home + "/Library/Safari", requirement: .fullDiskAccess,
                              explanation: "Safari data. Needs Full Disk Access."),
            ProtectedLocation(name: "Trash", path: home + "/.Trash", requirement: .fullDiskAccess,
                              explanation: "Measuring the Trash needs Full Disk Access."),
            ProtectedLocation(name: "iOS Backups", path: home + "/Library/Application Support/MobileSync", requirement: .fullDiskAccess,
                              explanation: "iPhone and iPad backups. Needs Full Disk Access."),
            ProtectedLocation(name: "System Data", path: "/private/var/db", requirement: .filePermissions,
                              explanation: "System databases are readable only by macOS itself. SpaceBridge reports them as restricted."),
            ProtectedLocation(name: "Other Users", path: "/Users", requirement: .filePermissions,
                              explanation: "Other accounts' home folders are private to those users."),
        ]
    }

    /// Checks one location. Note: checking Documents/Desktop/Downloads can show the macOS consent prompt,
    /// so the UI only calls this when the user asks.
    static func check(_ path: String) -> AccessStatus {
        var info = stat()
        if lstat(path, &info) != 0 {
            return errno == ENOENT ? .notFound : .denied
        }
        if (info.st_mode & 0o170000) == 0o040000 {
            guard let directory = opendir(path) else { return .denied }
            closedir(directory)
            return .granted
        }
        let descriptor = Darwin.open(path, O_RDONLY)
        guard descriptor >= 0 else { return .denied }
        close(descriptor)
        return .granted
    }

    /// Detects Full Disk Access by attempting to read a file that only FDA-enabled apps can read.
    /// Returns `nil` if it can't be determined.
    static func hasFullDiskAccess(home: String = NSHomeDirectory()) -> Bool? {
        let probes = [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
            home + "/Library/Safari",
        ]
        for probe in probes {
            switch check(probe) {
            case .granted: return true
            case .denied: return false
            default: continue
            }
        }
        return nil
    }

    @MainActor
    static func openFullDiskAccessSettings() {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    @MainActor
    static func openFilesAndFoldersSettings() {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    }

    @MainActor
    private static func openSettingsURL(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    static let fullDiskAccessInstructions = """
    1. Click "Open System Settings".
    2. In Privacy & Security ▸ Full Disk Access, turn on SpaceBridge (use + to add it from your Applications folder if it isn't listed).
    3. Quit and reopen SpaceBridge, then run a new scan.

    Full Disk Access lets SpaceBridge measure folders such as Mail, Messages, Safari, the Trash and device backups. \
    SpaceBridge only reads file sizes and dates; it never reads file contents for analysis, and nothing leaves your Mac.
    """
}
