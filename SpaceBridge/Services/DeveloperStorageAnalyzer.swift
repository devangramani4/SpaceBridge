import Foundation

struct DeveloperStorageItem: Identifiable, Sendable, Hashable {
    var id: String { group + "|" + name + "|" + path }
    var group: String
    var name: String
    var path: String
    var bytes: Int64
    var isPartial: Bool
    var detail: String?
}

struct DeveloperStorageGroup: Identifiable, Sendable, Hashable {
    var id: String { name }
    var name: String
    var symbolName: String
    var items: [DeveloperStorageItem]
    /// Whether the tool appears to be installed/used on this Mac.
    var detected: Bool
    var note: String?
    var total: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

/// Measures storage used by developer tools. Fixed locations are measured directly;
/// repository-wide items (node_modules, .git) come from the scan index.
struct DeveloperStorageAnalyzer: Sendable {
    var home: String = NSHomeDirectory()
    var database: StorageDatabase?

    private func measure(_ group: String, _ entries: [(String, String, String?)]) async -> [DeveloperStorageItem] {
        var items: [DeveloperStorageItem] = []
        for (name, relative, detail) in entries {
            if Task.isCancelled { break }
            let path = relative.hasPrefix("/") ? relative : home + "/" + relative
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let size = await FolderAnalyzer.cachedOrCalculatedSize(of: path, database: database)
            items.append(DeveloperStorageItem(group: group, name: name, path: path, bytes: size.allocatedSize, isPartial: size.isPartial, detail: detail))
        }
        return items
    }

    func analyze() async -> [DeveloperStorageGroup] {
        var groups: [DeveloperStorageGroup] = []

        let xcode = await measure("Xcode", [
            ("DerivedData", "Library/Developer/Xcode/DerivedData", "Build intermediates"),
            ("Archives", "Library/Developer/Xcode/Archives", "App archives (.xcarchive)"),
            ("Simulators (CoreSimulator)", "Library/Developer/CoreSimulator", "Simulator devices, runtimes and caches"),
            ("Device Support", "Library/Developer/Xcode/iOS DeviceSupport", "Symbols for connected devices"),
            ("Xcode Caches", "Library/Caches/com.apple.dt.Xcode", nil),
            ("Simulator Runtimes", "/Library/Developer/CoreSimulator", "System-wide runtimes (managed by Xcode)"),
            ("Xcode.app", "/Applications/Xcode.app", "The application bundle"),
        ])
        groups.append(DeveloperStorageGroup(name: "Xcode", symbolName: "hammer", items: xcode, detected: !xcode.isEmpty))

        var node = await measure("Node.js", [
            ("npm cache", ".npm", nil),
            ("Yarn cache", "Library/Caches/Yarn", nil),
            ("Yarn Berry cache", ".yarn/berry", nil),
            ("pnpm store", "Library/pnpm", "Hard-linked into projects"),
            ("nvm versions", ".nvm", nil),
            ("Volta", ".volta", nil),
            ("Bun", ".bun", nil),
        ])
        var nodeNote: String? = "Run a scan to find node_modules folders across your disk."
        if let database, let modules = try? await database.folders(named: "node_modules", outermostOnly: true, limit: 200), !modules.isEmpty {
            nodeNote = nil
            let total = modules.reduce(Int64(0)) { $0 + $1.totalAllocated }
            node.append(DeveloperStorageItem(group: "Node.js", name: "node_modules (\(modules.count) projects)", path: modules[0].path,
                                             bytes: total, isPartial: false, detail: "Largest: \(modules[0].path.abbreviatingHome)"))
            for module in modules.prefix(15) {
                node.append(DeveloperStorageItem(group: "Node.js", name: module.path.deletingLastPathComponentString.lastPathComponentString + "/node_modules",
                                                 path: module.path, bytes: 0, isPartial: false, detail: ByteFormatter.string(module.totalAllocated)))
            }
        }
        groups.append(DeveloperStorageGroup(name: "Node.js", symbolName: "cube.box", items: node, detected: !node.isEmpty, note: nodeNote))

        let android = await measure("Android", [
            ("Gradle", ".gradle", "Dependency and build caches"),
            ("Android user data (AVDs)", ".android", "Emulators and keys"),
            ("Android SDK", "Library/Android/sdk", nil),
            ("Android Studio caches", "Library/Caches/Google", nil),
            ("Android Studio settings", "Library/Application Support/Google", nil),
            ("Android Studio.app", "/Applications/Android Studio.app", nil),
        ])
        groups.append(DeveloperStorageGroup(name: "Android", symbolName: "apps.iphone", items: android, detected: !android.isEmpty))

        // Docker: probe every known engine rather than assuming one location.
        let docker = await measure("Docker", [
            ("Docker Desktop data", "Library/Containers/com.docker.docker", "Virtual disk with images, containers and volumes"),
            ("Docker Desktop group data", "Library/Group Containers/group.com.docker", nil),
            ("Docker CLI config & contexts", ".docker", nil),
            ("OrbStack", ".orbstack", nil),
            ("OrbStack data", "Library/Group Containers/HUAQ24HBR6.dev.orbstack", nil),
            ("Colima", ".colima", nil),
            ("Lima", ".lima", nil),
            ("Rancher Desktop", "Library/Application Support/rancher-desktop", nil),
            ("Podman", ".local/share/containers", nil),
        ])
        groups.append(DeveloperStorageGroup(name: "Docker", symbolName: "shippingbox", items: docker, detected: !docker.isEmpty,
                                            note: docker.isEmpty ? "No Docker, OrbStack, Colima, Rancher Desktop or Podman data found." :
                                                "The virtual disk size is space allocated on disk. Use `docker system df` to see what's inside it."))

        var git: [DeveloperStorageItem] = []
        var gitNote: String? = "Run a scan to find Git repositories."
        if let database, let repos = try? await database.folders(named: ".git", outermostOnly: false, limit: 500), !repos.isEmpty {
            gitNote = "\(repos.count) repositories found. Sizes are the .git folders only (history and objects)."
            for repo in repos.prefix(50) {
                git.append(DeveloperStorageItem(group: "Git", name: repo.path.deletingLastPathComponentString.lastPathComponentString,
                                                path: repo.path, bytes: repo.totalAllocated, isPartial: repo.isRestricted,
                                                detail: repo.path.deletingLastPathComponentString.abbreviatingHome))
            }
            let rest = repos.dropFirst(50).reduce(Int64(0)) { $0 + $1.totalAllocated }
            if rest > 0 {
                git.append(DeveloperStorageItem(group: "Git", name: "\(repos.count - 50) more repositories", path: "", bytes: rest, isPartial: false, detail: nil))
            }
        }
        groups.append(DeveloperStorageGroup(name: "Git Repositories", symbolName: "arrow.triangle.branch", items: git, detected: !git.isEmpty, note: gitNote))

        let other = await measure("Other", [
            ("Homebrew", "/opt/homebrew", nil),
            ("Homebrew (Intel)", "/usr/local/Homebrew", nil),
            ("Rust (cargo)", ".cargo", nil),
            ("Rust toolchains", ".rustup", nil),
            ("Python (pyenv)", ".pyenv", nil),
            ("Conda", "miniconda3", nil),
            ("Maven", ".m2", nil),
            ("Go modules", "go/pkg", nil),
            ("CocoaPods", ".cocoapods", nil),
            ("SwiftPM cache", "Library/Caches/org.swift.swiftpm", nil),
        ])
        groups.append(DeveloperStorageGroup(name: "Other Toolchains", symbolName: "wrench.and.screwdriver", items: other, detected: !other.isEmpty))
        return groups
    }
}
