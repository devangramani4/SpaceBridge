import Foundation

enum CleanupSafety: String, CaseIterable, Sendable, Identifiable {
    case safe = "Safe to Remove"
    case review = "Review Before Removing"
    case doNotRemove = "Do Not Remove"
    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .safe: return "checkmark.shield"
        case .review: return "eye"
        case .doNotRemove: return "hand.raised"
        }
    }
}

/// A potentially removable item. Nothing is ever removed automatically.
struct CleanupRecommendation: Identifiable, Sendable, Hashable {
    enum Action: Sendable, Hashable {
        /// Can be moved to the Trash (after confirmation).
        case moveToTrash
        /// Should be cleaned with the owning tool; SpaceBridge shows the command but doesn't run it.
        case command(String)
        /// Can only be emptied via Finder.
        case openInFinder
        /// Informational only.
        case none
    }

    var id: String { title + "|" + paths.joined(separator: ",") }
    var title: String
    var detail: String
    var paths: [String]
    var bytes: Int64
    var isPartial: Bool
    var safety: CleanupSafety
    var action: Action
    var symbolName: String
}

/// Detects cleanup opportunities in well-known locations. Read-only.
struct CleanupAnalyzer: Sendable {
    var home: String = NSHomeDirectory()
    var database: StorageDatabase?

    private struct Rule: Sendable {
        var title: String
        var detail: String
        var relativePaths: [String]
        var safety: CleanupSafety
        var action: CleanupRecommendation.Action
        var symbol: String
        var minimumBytes: Int64 = 10_000_000
        /// Split into one recommendation per child folder (e.g. per-app caches).
        var perChild = false
    }

    private var rules: [Rule] {
        [
            Rule(title: "Xcode DerivedData", detail: "Build intermediates. Xcode rebuilds them as needed; the next build will be slower.",
                 relativePaths: ["Library/Developer/Xcode/DerivedData"], safety: .safe, action: .moveToTrash, symbol: "hammer"),
            Rule(title: "Xcode Previews & Simulator caches", detail: "Caches regenerated automatically.",
                 relativePaths: ["Library/Developer/Xcode/UserData/Previews", "Library/Developer/CoreSimulator/Caches"], safety: .safe, action: .moveToTrash, symbol: "iphone"),
            Rule(title: "Old device support files", detail: "Debug symbols for iOS/watchOS versions. Re-downloaded when you connect a device running that version.",
                 relativePaths: ["Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport", "Library/Developer/Xcode/tvOS DeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport"],
                 safety: .review, action: .moveToTrash, symbol: "cpu", perChild: true),
            Rule(title: "Unavailable iOS simulators", detail: "Simulator devices for runtimes you no longer have. Use the command so Xcode stays consistent.",
                 relativePaths: ["Library/Developer/CoreSimulator/Devices"], safety: .review, action: .command("xcrun simctl delete unavailable"), symbol: "iphone.slash"),
            Rule(title: "Xcode Archives", detail: "Needed to symbolicate crash reports and re-submit builds. Keep archives for releases you support.",
                 relativePaths: ["Library/Developer/Xcode/Archives"], safety: .review, action: .moveToTrash, symbol: "archivebox", perChild: true),
            Rule(title: "npm cache", detail: "Downloaded packages. npm re-downloads them when needed.",
                 relativePaths: [".npm/_cacache"], safety: .safe, action: .command("npm cache clean --force"), symbol: "shippingbox.circle"),
            Rule(title: "Yarn cache", detail: "Downloaded packages. Yarn re-downloads them when needed.",
                 relativePaths: ["Library/Caches/Yarn", ".yarn/berry/cache", ".cache/yarn"], safety: .safe, action: .command("yarn cache clean"), symbol: "circle.hexagongrid"),
            Rule(title: "pnpm store", detail: "Packages are hard-linked into projects, so trashing the store frees less than shown. Use pnpm's own prune.",
                 relativePaths: ["Library/pnpm/store", ".pnpm-store", ".local/share/pnpm/store"], safety: .review, action: .command("pnpm store prune"), symbol: "square.stack.3d.up"),
            Rule(title: "Gradle caches", detail: "Downloaded dependencies and build caches. Re-downloaded on next build.",
                 relativePaths: [".gradle/caches"], safety: .safe, action: .moveToTrash, symbol: "apps.iphone"),
            Rule(title: "CocoaPods & SwiftPM caches", detail: "Downloaded dependencies.",
                 relativePaths: ["Library/Caches/CocoaPods", "Library/Caches/org.swift.swiftpm"], safety: .safe, action: .moveToTrash, symbol: "shippingbox"),
            Rule(title: "Homebrew cache", detail: "Downloaded bottles.",
                 relativePaths: ["Library/Caches/Homebrew"], safety: .safe, action: .command("brew cleanup --prune=all"), symbol: "mug"),
            Rule(title: "Browser caches", detail: "Web page caches. Browsers rebuild them; quit the browser first.",
                 relativePaths: ["Library/Caches/Google/Chrome", "Library/Caches/Firefox", "Library/Caches/com.microsoft.edgemac",
                                 "Library/Caches/BraveSoftware", "Library/Caches/company.thebrowser.Browser", "Library/Caches/com.operasoftware.Opera"],
                 safety: .safe, action: .moveToTrash, symbol: "globe", perChild: false),
            Rule(title: "Application caches", detail: "Per-app caches in ~/Library/Caches. Apps recreate them; quit the app first.",
                 relativePaths: ["Library/Caches"], safety: .safe, action: .moveToTrash, symbol: "internaldrive", minimumBytes: 50_000_000, perChild: true),
            Rule(title: "User logs", detail: "Diagnostic logs. Safe to remove unless you're troubleshooting.",
                 relativePaths: ["Library/Logs"], safety: .safe, action: .moveToTrash, symbol: "list.bullet.rectangle", minimumBytes: 5_000_000, perChild: true),
            Rule(title: "Docker data", detail: "Docker's virtual disk. Never trash it manually — use Docker's own cleanup to remove unused images, containers and build cache.",
                 relativePaths: ["Library/Containers/com.docker.docker/Data/vms", ".orbstack", ".colima"], safety: .review, action: .command("docker system prune"), symbol: "shippingbox"),
            Rule(title: "iOS device backups", detail: "iPhone/iPad backups. Delete old ones from Finder ▸ your device ▸ Manage Backups.",
                 relativePaths: ["Library/Application Support/MobileSync/Backup"], safety: .review, action: .none, symbol: "iphone"),
            Rule(title: "Trash", detail: "Items you already moved to the Trash still use space until you empty it in Finder.",
                 relativePaths: [".Trash"], safety: .safe, action: .openInFinder, symbol: "trash", minimumBytes: 1),
            Rule(title: "Photos Library", detail: "Remove photos from within the Photos app. Never move the library itself.",
                 relativePaths: ["Pictures/Photos Library.photoslibrary"], safety: .doNotRemove, action: .none, symbol: "photo.on.rectangle", minimumBytes: 1),
            Rule(title: "Mail data", detail: "Managed by Mail. Remove large attachments from within Mail.",
                 relativePaths: ["Library/Mail"], safety: .doNotRemove, action: .none, symbol: "envelope", minimumBytes: 1),
            Rule(title: "iCloud Drive", detail: "Removing files here deletes them from iCloud on all your devices. Use Finder's “Remove Download” instead to free local space.",
                 relativePaths: ["Library/Mobile Documents"], safety: .doNotRemove, action: .none, symbol: "icloud", minimumBytes: 1),
            Rule(title: "Application Support", detail: "App data such as databases and settings. Removing it can break apps — uninstall the app instead.",
                 relativePaths: ["Library/Application Support"], safety: .doNotRemove, action: .none, symbol: "folder.badge.gearshape", minimumBytes: 1),
        ]
    }

    func analyze(progress: @escaping @Sendable (String) -> Void = { _ in }) async -> [CleanupRecommendation] {
        var results: [CleanupRecommendation] = []
        for rule in rules {
            if Task.isCancelled { break }
            progress(rule.title)
            let paths = rule.relativePaths.map { home + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
            guard !paths.isEmpty else { continue }

            if rule.perChild {
                var children: [String] = []
                for parent in paths {
                    _ = DirectoryReader.read(path: parent) { entry in
                        if entry.kind == .directory || entry.kind == .file, entry.hasValidName, entry.name != ".DS_Store" {
                            children.append(parent + "/" + entry.name)
                        }
                    }
                }
                // Browser caches are reported separately.
                let browserPaths = Set(rules.first { $0.title == "Browser caches" }?.relativePaths.map { (home + "/" + $0).lowercased() } ?? [])
                for child in children {
                    if Task.isCancelled { break }
                    if browserPaths.contains(where: { SecurityUtils.isPath(child.lowercased(), within: $0) || SecurityUtils.isPath($0, within: child.lowercased()) }) && rule.title == "Application caches" { continue }
                    let size = await FolderAnalyzer.cachedOrCalculatedSize(of: child, database: database)
                    guard size.allocatedSize >= rule.minimumBytes else { continue }
                    let safety = SecurityUtils.evaluate(path: child)
                    results.append(CleanupRecommendation(
                        title: "\(rule.title): \(child.lastPathComponentString)", detail: rule.detail, paths: [child],
                        bytes: size.allocatedSize, isPartial: size.isPartial,
                        safety: safety.allowsDestructiveActions ? rule.safety : .doNotRemove,
                        action: safety.allowsDestructiveActions ? rule.action : .none, symbolName: rule.symbol))
                }
            } else {
                var total: Int64 = 0
                var partial = false
                for path in paths {
                    let size = await FolderAnalyzer.cachedOrCalculatedSize(of: path, database: database)
                    total += size.allocatedSize
                    partial = partial || size.isPartial
                }
                guard total >= rule.minimumBytes || (partial && rule.minimumBytes <= 1) else { continue }
                results.append(CleanupRecommendation(
                    title: rule.title, detail: rule.detail + (partial ? " (Size may be incomplete: some folders are restricted.)" : ""),
                    paths: paths, bytes: total, isPartial: partial, safety: rule.safety, action: rule.action, symbolName: rule.symbol))
            }
        }

        // Large or old items in Downloads (from the scan index — no extra disk walk).
        if let database {
            let downloads = home + "/Downloads"
            let large = (try? await database.largestFiles(limit: 25, within: downloads, minimumSize: 500_000_000)) ?? []
            for file in large {
                results.append(CleanupRecommendation(
                    title: "Large download: \(file.name)", detail: "Downloaded files are often installers or archives you no longer need.",
                    paths: [file.path], bytes: file.allocatedSize, isPartial: false, safety: .review, action: .moveToTrash, symbolName: "arrow.down.circle"))
            }
            // Old build artifacts: node_modules not touched in 90 days.
            let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
            let modules = (try? await database.folders(named: "node_modules", outermostOnly: true, limit: 50)) ?? []
            for folder in modules where (folder.modified ?? .distantFuture) < cutoff && folder.totalAllocated >= 50_000_000 {
                results.append(CleanupRecommendation(
                    title: "Old node_modules: \(folder.path.deletingLastPathComponentString.lastPathComponentString)",
                    detail: "Not modified in 90+ days. Reinstall with npm/yarn/pnpm install when you return to the project.",
                    paths: [folder.path], bytes: folder.totalAllocated, isPartial: folder.isRestricted, safety: .review,
                    action: .moveToTrash, symbolName: "cube.box"))
            }
        }
        return results.sorted { $0.bytes > $1.bytes }
    }
}
