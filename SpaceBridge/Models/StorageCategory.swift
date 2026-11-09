import Foundation

/// Storage categories. Raw values are persisted in the scan database — never reorder.
enum StorageCategory: Int, CaseIterable, Sendable, Identifiable, Codable {
    case other = 0
    case applications = 1
    case documents = 2
    case downloads = 3
    case desktop = 4
    case photos = 5
    case videos = 6
    case music = 7
    case developer = 8
    case xcode = 9
    case docker = 10
    case nodeJS = 11
    case npm = 12
    case yarn = 13
    case pnpm = 14
    case git = 15
    case caches = 16
    case logs = 17
    case iOSBackups = 18
    case android = 19
    case virtualMachines = 20
    case archives = 21
    case system = 22
    case trash = 23
    case mail = 24
    case cloudStorage = 25

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .other: return "Other"
        case .applications: return "Applications"
        case .documents: return "Documents"
        case .downloads: return "Downloads"
        case .desktop: return "Desktop"
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .music: return "Music"
        case .developer: return "Developer Files"
        case .xcode: return "Xcode"
        case .docker: return "Docker"
        case .nodeJS: return "Node.js"
        case .npm: return "npm"
        case .yarn: return "Yarn"
        case .pnpm: return "pnpm"
        case .git: return "Git Repositories"
        case .caches: return "Caches"
        case .logs: return "Logs"
        case .iOSBackups: return "iOS Backups"
        case .android: return "Android"
        case .virtualMachines: return "Virtual Machines"
        case .archives: return "Archives & Disk Images"
        case .system: return "System"
        case .trash: return "Trash"
        case .mail: return "Mail & Messages"
        case .cloudStorage: return "iCloud & Cloud Storage"
        }
    }

    var symbolName: String {
        switch self {
        case .other: return "questionmark.folder"
        case .applications: return "square.grid.2x2"
        case .documents: return "doc.text"
        case .downloads: return "arrow.down.circle"
        case .desktop: return "menubar.dock.rectangle"
        case .photos: return "photo.on.rectangle"
        case .videos: return "film"
        case .music: return "music.note"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .xcode: return "hammer"
        case .docker: return "shippingbox"
        case .nodeJS: return "cube.box"
        case .npm: return "shippingbox.circle"
        case .yarn: return "circle.hexagongrid"
        case .pnpm: return "square.stack.3d.up"
        case .git: return "arrow.triangle.branch"
        case .caches: return "internaldrive"
        case .logs: return "list.bullet.rectangle"
        case .iOSBackups: return "iphone"
        case .android: return "apps.iphone"
        case .virtualMachines: return "pc"
        case .archives: return "archivebox"
        case .system: return "gearshape.2"
        case .trash: return "trash"
        case .mail: return "envelope"
        case .cloudStorage: return "icloud"
        }
    }

    /// How the category is determined, shown in the UI so users know it is a heuristic.
    var detectionNote: String {
        switch self {
        case .other: return "Files that didn't match any rule. SpaceBridge doesn't guess."
        case .applications: return "App bundles (.app) and their contents."
        case .documents, .downloads, .desktop: return "Files located in this folder (archives and VM images are counted separately)."
        case .photos: return "Image files, plus everything in ~/Pictures."
        case .videos: return "Video files, plus everything in ~/Movies."
        case .music: return "Audio files, plus everything in ~/Music."
        case .developer: return "Source code and developer tool folders (e.g. ~/Developer, ~/.cargo, Homebrew)."
        case .xcode: return "~/Library/Developer, Xcode caches and Xcode.app."
        case .docker: return "Known Docker Desktop, OrbStack, Colima, Rancher and Podman data folders."
        case .nodeJS: return "node_modules folders and Node version managers."
        case .npm: return "The npm cache (~/.npm)."
        case .yarn: return "Yarn caches."
        case .pnpm: return "The pnpm content-addressable store."
        case .git: return "Contents of .git directories."
        case .caches: return "Library/Caches folders and ~/.cache."
        case .logs: return "Library/Logs folders and system logs."
        case .iOSBackups: return "Finder/iTunes device backups (MobileSync)."
        case .android: return "Android SDK, Gradle, emulator and Android Studio data."
        case .virtualMachines: return "Virtual machine bundles and disk images (UTM, Parallels, VMware, VirtualBox)."
        case .archives: return "Archives and disk images (.zip, .dmg, .xip, .iso …)."
        case .system: return "macOS system folders (/System, /usr, /private, /Library …)."
        case .trash: return "Items in your Trash."
        case .mail: return "Mail and Messages data."
        case .cloudStorage: return "iCloud Drive and File Provider folders (may include files not stored locally)."
        }
    }

    /// Categories grouped under "Developer Storage".
    static let developerCategories: [StorageCategory] = [.xcode, .docker, .nodeJS, .npm, .yarn, .pnpm, .git, .android, .developer]
}

/// Sizes per category, as computed from the scan database.
struct CategoryUsage: Identifiable, Sendable, Hashable {
    var category: StorageCategory
    var bytes: Int64
    var fileCount: Int
    var id: Int { category.rawValue }
}

/// Classifies files into categories from their real path and extension.
///
/// Rules are evaluated once per directory (path rules) and once per file (extension rules), so
/// classification adds negligible cost to scanning.
struct StorageCategorizer: Sendable {
    let home: String

    init(homeDirectory: String = NSHomeDirectory()) {
        home = homeDirectory.lowercased()
    }

    /// Result of evaluating a folder's path.
    struct FolderContext: Sendable, Equatable {
        /// A category that applies to everything in the folder regardless of extension.
        var strong: StorageCategory?
        /// A location category used when no extension rule matches (e.g. Downloads).
        var location: StorageCategory?
    }

    func context(forFolder folderPath: String) -> FolderContext {
        let path = folderPath.lowercased()
        func under(_ prefix: String) -> Bool { SecurityUtils.isPath(path, within: prefix) }
        func underHome(_ relative: String) -> Bool { under(home + "/" + relative) }
        func hasComponent(_ name: String) -> Bool {
            path.hasSuffix("/" + name) || path.contains("/" + name + "/")
        }
        func hasComponentSuffix(_ suffix: String) -> Bool {
            path.split(separator: "/").contains { $0.hasSuffix(suffix) }
        }

        // Most specific developer rules first.
        if hasComponent("node_modules") || underHome(".nvm") || underHome(".node-gyp") || underHome(".volta") || underHome(".fnm") {
            return FolderContext(strong: .nodeJS)
        }
        if underHome(".npm") { return FolderContext(strong: .npm) }
        if underHome("library/caches/yarn") || underHome(".yarn") || underHome(".cache/yarn") || hasComponent(".yarn/cache") {
            return FolderContext(strong: .yarn)
        }
        if underHome("library/pnpm") || hasComponent(".pnpm-store") || underHome(".local/share/pnpm") || underHome(".cache/pnpm") {
            return FolderContext(strong: .pnpm)
        }
        if hasComponent(".git") { return FolderContext(strong: .git) }
        if underHome("library/developer/xcode") || underHome("library/developer/coresimulator")
            || underHome("library/developer/xcpgdevices") || underHome("library/developer/dvtdownloads")
            || underHome("library/caches/com.apple.dt.xcode") || under("/applications/xcode.app")
            || (under("/applications") && path.split(separator: "/").contains { $0.hasPrefix("xcode") && $0.hasSuffix(".app") })
            || under("/library/developer/coresimulator") {
            return FolderContext(strong: .xcode)
        }
        if underHome("library/containers/com.docker.docker") || underHome("library/group containers/group.com.docker")
            || underHome(".docker") || underHome(".orbstack") || underHome("library/group containers/hug.orbstack")
            || underHome(".colima") || underHome(".lima") || underHome(".rd") || underHome("library/application support/rancher-desktop")
            || underHome(".local/share/containers") || underHome("library/application support/docker desktop")
            || under("/applications/docker.app") || under("/applications/orbstack.app") {
            return FolderContext(strong: .docker)
        }
        if underHome(".android") || underHome(".gradle") || underHome("library/android")
            || path.contains("/google/androidstudio") || under("/applications/android studio.app") {
            return FolderContext(strong: .android)
        }
        if underHome("library/application support/mobilesync/backup") { return FolderContext(strong: .iOSBackups) }
        if underHome("library/containers/com.utmapp.utm") || underHome("parallels") || underHome("virtual machines.localized")
            || underHome("virtualbox vms") || hasComponentSuffix(".vmwarevm") || hasComponentSuffix(".pvm")
            || hasComponentSuffix(".utm") || underHome("library/containers/com.apple.virtualization") {
            return FolderContext(strong: .virtualMachines)
        }
        if underHome(".trash") || under("/.trashes") || hasComponent(".trashes") { return FolderContext(strong: .trash) }
        if underHome("library/mail") || underHome("library/messages") || underHome("library/containers/com.apple.mail") {
            return FolderContext(strong: .mail)
        }
        if underHome("library/mobile documents") || underHome("library/cloudstorage") {
            return FolderContext(strong: .cloudStorage)
        }
        if underHome("library/caches") || under("/library/caches") || underHome(".cache") || under("/private/var/folders")
            || hasComponent("deriveddata") {
            return FolderContext(strong: .caches)
        }
        if underHome("library/logs") || under("/library/logs") || under("/private/var/log") || under("/private/var/logs") {
            return FolderContext(strong: .logs)
        }
        if hasComponentSuffix(".app") || under("/applications") || underHome("applications") {
            return FolderContext(strong: .applications)
        }
        if under("/system") || under("/usr") || under("/bin") || under("/sbin") || under("/private")
            || under("/cores") || under("/library") {
            return FolderContext(strong: .system)
        }
        if under("/opt/homebrew") || under("/usr/local") || underHome(".cargo") || underHome(".rustup")
            || underHome(".pyenv") || underHome(".rbenv") || underHome(".m2") || underHome("go/pkg")
            || underHome("developer") || underHome(".conda") || underHome("miniconda3") || underHome("anaconda3")
            || underHome(".bun") || underHome(".deno") || underHome(".swiftpm") || underHome("library/caches/org.swift.swiftpm") {
            return FolderContext(strong: .developer)
        }
        if underHome("downloads") { return FolderContext(location: .downloads) }
        if underHome("desktop") { return FolderContext(location: .desktop) }
        if underHome("documents") { return FolderContext(location: .documents) }
        if underHome("pictures") { return FolderContext(location: .photos) }
        if underHome("movies") { return FolderContext(location: .videos) }
        if underHome("music") { return FolderContext(location: .music) }
        return FolderContext()
    }

    func category(forFileExtension ext: String, in context: FolderContext) -> StorageCategory {
        if let strong = context.strong { return strong }
        if Self.virtualMachineExtensions.contains(ext) { return .virtualMachines }
        if Self.archiveExtensions.contains(ext) { return .archives }
        if let location = context.location { return location }
        if Self.photoExtensions.contains(ext) { return .photos }
        if Self.videoExtensions.contains(ext) { return .videos }
        if Self.audioExtensions.contains(ext) { return .music }
        if Self.sourceExtensions.contains(ext) { return .developer }
        if Self.documentExtensions.contains(ext) { return .documents }
        return .other
    }

    func category(forFilePath filePath: String) -> StorageCategory {
        let folder = (filePath as NSString).deletingLastPathComponent
        let ext = (filePath as NSString).pathExtension.lowercased()
        return category(forFileExtension: ext, in: context(forFolder: folder))
    }

    static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "raf", "rw2", "webp", "bmp", "psd", "avif", "jxl"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "wmv", "flv", "webm", "mpg", "mpeg", "3gp", "mts", "m2ts", "braw", "r3d", "vob"]
    static let audioExtensions: Set<String> = ["mp3", "aac", "m4a", "flac", "wav", "aif", "aiff", "alac", "ogg", "opus", "mid", "midi", "caf", "wma"]
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "7z", "rar", "dmg", "iso", "xip", "pkg", "mpkg", "sparseimage", "cpgz", "lz4", "jar", "ipa", "apk", "aab", "img"]
    static let virtualMachineExtensions: Set<String> = ["vmdk", "vdi", "qcow2", "vhd", "vhdx", "hdd", "ova", "ovf"]
    static let sourceExtensions: Set<String> = ["swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cxx", "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "pyc", "rb", "go", "rs", "java", "kt", "kts", "scala", "cs", "php", "dart", "lua", "sh", "zsh", "o", "a", "dylib", "so", "xcarchive", "dsym", "pbxproj", "gradle", "class", "wasm"]
    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "rtfd", "md", "csv", "epub", "odt", "ods", "odp"]
}
