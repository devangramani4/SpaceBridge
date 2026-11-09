import Foundation

/// The result of evaluating whether a destructive action (Move to Trash, Quit) may be offered.
enum PathSafety: Equatable, Sendable {
    /// The item can be moved to the Trash after explicit confirmation.
    case allowed
    /// The item can be moved to the Trash, but the user must read a warning first.
    case caution(String)
    /// Destructive actions are disabled. The UI shows "Protected by macOS".
    case protected(String)

    var allowsDestructiveActions: Bool {
        if case .protected = self { return false }
        return true
    }

    var message: String? {
        switch self {
        case .allowed: return nil
        case .caution(let message), .protected(let message): return message
        }
    }
}

/// Central policy for every destructive action in the app.
///
/// SpaceBridge never deletes anything permanently. The only destructive operation it performs is
/// `FileManager.trashItem`, and only for items this policy allows, after the user confirms.
enum SecurityUtils {
    static let protectedLabel = "Protected by macOS"

    /// Locations that are never touched, including everything below them.
    /// Compared case-insensitively because APFS volumes are usually case-insensitive.
    static let protectedTrees: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/private", "/var", "/etc", "/tmp",
        "/dev", "/cores", "/Volumes/Recovery", "/Library/Apple",
        "/Library/Extensions", "/Library/Filesystems", "/Library/Frameworks",
        "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/Preferences",
        "/Library/PrivilegedHelperTools", "/Library/Security", "/Library/StagedExtensions",
        "/Library/SystemExtensions", "/Library/Keychains", "/Library/Updates",
        "/Library/CoreMediaIO", "/Library/DirectoryServices", "/Library/OSAnalytics",
        "/Library/Apple/System", "/Library/Receipts", "/Library/Audio/Plug-Ins/HAL",
    ]

    /// Home-relative locations that are never touched.
    static let protectedHomeTrees: [String] = [
        "Library/Keychains", "Library/Accounts", "Library/Mail", "Library/Messages",
        "Library/Application Support/com.apple.TCC", "Library/Cookies",
        "Library/IdentityServices", "Library/Sharing", "Library/Biome",
        "Library/Daemon Containers", "Library/Autosave Information", "Library/Calendars",
        "Library/Suggestions", "Library/Metadata", "Library/Application Support/AddressBook",
        "Library/Application Support/CallHistoryDB", "Library/Application Support/Knowledge",
        "Library/Application Support/com.apple.sharedfilelist",
        "Library/Group Containers/group.com.apple.notes", "Library/Safari",
    ]

    /// Exact containers that must not be trashed as a whole (their contents may be).
    static let protectedExactPaths: [String] = [
        "/", "/Applications", "/Library", "/Users", "/Users/Shared", "/Volumes", "/opt",
        "/Library/Application Support", "/Library/Caches", "/Library/Logs",
    ]

    static let protectedHomeExact: [String] = [
        "", "Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
        "Applications", "Public", "Developer", ".Trash", "Library/Caches", "Library/Logs",
        "Library/Application Support", "Library/Containers", "Library/Group Containers",
        "Library/Preferences", "Library/Developer", "Library/Developer/Xcode",
        "Library/Mobile Documents", "Library/CloudStorage", "Library/LaunchAgents",
        ".ssh", ".gnupg", ".config",
    ]

    /// Home-relative trees where removal is possible but deserves a warning.
    static let cautionHomeTrees: [(path: String, reason: String)] = [
        ("Library/Mobile Documents", "This item is in iCloud Drive. Moving it to the Trash removes it from all your devices."),
        ("Library/CloudStorage", "This item is in a cloud storage folder. Removing it may delete it from the cloud provider too."),
        ("Library/Containers", "This is an app's private data. Removing it can reset or break that app."),
        ("Library/Group Containers", "This is shared app data. Removing it can reset or break one or more apps."),
        ("Library/Application Support", "This is app support data. Removing it can reset or break the app that owns it."),
        ("Library/Preferences", "This is an app's settings file. Removing it resets that app's preferences."),
        ("Library/LaunchAgents", "This launch agent may belong to an app you rely on. Remove it only if you know what it is."),
        ("Pictures/Photos Library.photoslibrary", "This is your Photos library. Remove photos from the Photos app instead."),
        ("Library/Application Support/MobileSync/Backup", "This is an iPhone or iPad backup. Make sure you have a newer backup before removing it."),
        (".ssh", "This folder contains SSH keys."),
    ]

    // File flags from <sys/stat.h>.
    private static let ufImmutable: UInt32 = 0x0000_0002
    private static let ufAppend: UInt32 = 0x0000_0004
    private static let sfImmutable: UInt32 = 0x0002_0000
    private static let sfAppend: UInt32 = 0x0004_0000
    private static let sfRestricted: UInt32 = 0x0008_0000   // SIP protected
    private static let sfNoUnlink: UInt32 = 0x0010_0000
    private static let sfFirmlink: UInt32 = 0x0080_0000

    /// Evaluates whether `path` may be moved to the Trash.
    ///
    /// - Parameters:
    ///   - homeDirectory: injectable for tests.
    ///   - additionalProtected: extra protected trees (e.g. the app's own bundle and database).
    ///   - checkFileSystem: when `true`, also inspects SIP flags and write permission on disk.
    static func evaluate(
        path rawPath: String,
        homeDirectory: String = NSHomeDirectory(),
        additionalProtected: [String] = SecurityUtils.appOwnedPaths,
        checkFileSystem: Bool = true
    ) -> PathSafety {
        guard rawPath.hasPrefix("/") else {
            return .protected("Only absolute paths can be modified.")
        }
        let path = normalized(rawPath, resolveParent: checkFileSystem)
        let lower = path.lowercased()
        let home = normalized(homeDirectory, resolveParent: false).lowercased()

        for exact in protectedExactPaths where lower == exact.lowercased() {
            return .protected("\(protectedLabel): this is a top-level system folder.")
        }
        for tree in protectedTrees where isPath(lower, within: tree.lowercased()) {
            return .protected("\(protectedLabel): items in \(tree) are part of the operating system.")
        }
        for tree in additionalProtected where isPath(lower, within: normalized(tree, resolveParent: false).lowercased()) {
            return .protected("SpaceBridge does not modify its own application or database files.")
        }
        for relative in protectedHomeExact {
            let candidate = relative.isEmpty ? home : home + "/" + relative.lowercased()
            if lower == candidate {
                return .protected("\(protectedLabel): this is a standard folder macOS expects to exist. You can remove items inside it instead.")
            }
        }
        for relative in protectedHomeTrees where isPath(lower, within: home + "/" + relative.lowercased()) {
            return .protected("\(protectedLabel): this location holds system or account data managed by macOS.")
        }
        // Other users' home folders.
        if isPath(lower, within: "/users"), !isPath(lower, within: home), !isPath(lower, within: "/users/shared") {
            return .protected("This item belongs to another user account.")
        }
        // Apple's apps shipped in /Applications (e.g. Safari) are SIP protected.
        if lower.hasPrefix("/applications/safari.app") {
            return .protected("\(protectedLabel): Safari is part of macOS.")
        }

        if checkFileSystem {
            if let failure = fileSystemProtection(for: path) {
                return failure
            }
        }

        for entry in cautionHomeTrees where isPath(lower, within: home + "/" + entry.path.lowercased()) {
            return .caution(entry.reason)
        }
        if isPath(lower, within: "/applications") || isPath(lower, within: home + "/applications") {
            return .caution("Moving an app to the Trash uninstalls it. Its settings and data in ~/Library are not removed.")
        }
        if isPath(lower, within: "/library") {
            return .caution("This item is in the system-wide Library and may be used by apps for all users.")
        }
        return .allowed
    }

    /// Paths owned by SpaceBridge itself.
    static var appOwnedPaths: [String] {
        var paths = [Bundle.main.bundlePath]
        if let support = try? StorageDatabase.defaultDirectory().path {
            paths.append(support)
        }
        return paths
    }

    /// `true` if `path` equals `ancestor` or is inside it. Both should already be normalized.
    static func isPath(_ path: String, within ancestor: String) -> Bool {
        if ancestor == "/" { return true }
        return path == ancestor || path.hasPrefix(ancestor + "/")
    }

    /// Standardizes `..` and `.` and, optionally, resolves symlinks in the parent directory
    /// (never the item itself, so trashing a symlink only ever trashes the link).
    static func normalized(_ path: String, resolveParent: Bool) -> String {
        var standardized = (path as NSString).standardizingPath
        while standardized.count > 1 && standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        guard resolveParent, standardized != "/" else { return standardized }
        let parent = (standardized as NSString).deletingLastPathComponent
        let name = (standardized as NSString).lastPathComponent
        guard let resolved = realPath(parent) else { return standardized }
        return resolved == "/" ? "/" + name : resolved + "/" + name
    }

    static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static func fileSystemProtection(for path: String) -> PathSafety? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return .protected("The item no longer exists or cannot be read.")
        }
        let flags = UInt32(info.st_flags)
        if flags & sfRestricted != 0 || flags & sfFirmlink != 0 {
            return .protected("\(protectedLabel): this item is protected by System Integrity Protection.")
        }
        if flags & (ufImmutable | sfImmutable | sfNoUnlink | ufAppend | sfAppend) != 0 {
            return .protected("This item is locked and cannot be moved.")
        }
        let parent = (path as NSString).deletingLastPathComponent
        if access(parent, W_OK) != 0 {
            return .protected("You don't have permission to modify the folder that contains this item.")
        }
        if let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return .protected("This item is on a read-only volume.")
        }
        return nil
    }

    /// Process names that are never offered Quit / Force Quit.
    static let criticalProcessNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "logind", "opendirectoryd",
        "securityd", "trustd", "syspolicyd", "tccd", "mds", "mds_stores", "configd",
        "powerd", "coreservicesd", "notifyd", "distnoted", "cfprefsd", "UserEventAgent",
        "SystemUIServer", "Dock", "Finder", "ControlCenter", "kextd", "kernelmanagerd",
        "diskarbitrationd", "fseventsd", "hidd", "coreaudiod", "bluetoothd", "airportd",
        "watchdogd", "sandboxd", "amfid", "endpointsecurityd", "runningboardd", "backupd",
        "lsd", "apsd", "usbd", "mDNSResponder", "softwareupdated", "spindump",
    ]

    enum ProcessSafety: Equatable, Sendable {
        case allowed
        case protected(String)
        var canTerminate: Bool { self == .allowed }
    }

    /// Decides whether Quit / Force Quit may be offered for a process.
    static func evaluateProcess(pid: Int32, name: String, executablePath: String?, ownerUID: UInt32?, currentUID: UInt32 = getuid()) -> ProcessSafety {
        if pid <= 1 { return .protected("\(protectedLabel): core system process.") }
        if pid == getpid() { return .protected("This is SpaceBridge itself. Use SpaceBridge ▸ Quit instead.") }
        if criticalProcessNames.contains(name) { return .protected("\(protectedLabel): macOS needs this process.") }
        if let ownerUID, ownerUID != currentUID {
            return .protected("This process belongs to another user or to the system.")
        }
        if ownerUID == nil { return .protected("SpaceBridge can't read who owns this process.") }
        if let executablePath {
            let lower = executablePath.lowercased()
            for tree in ["/system", "/usr/libexec", "/usr/sbin", "/usr/bin", "/sbin", "/bin", "/library/apple"] where isPath(lower, within: tree) {
                return .protected("\(protectedLabel): this is a macOS system component.")
            }
        }
        return .allowed
    }
}
