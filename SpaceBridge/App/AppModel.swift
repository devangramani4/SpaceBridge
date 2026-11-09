import Foundation
import Observation
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard, storage, largestFiles, largestFolders, applications, runningApps, memory, cpu
    case developer, duplicates, cleanup, search, permissions, privacy, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .storage: return "Storage"
        case .largestFiles: return "Largest Files"
        case .largestFolders: return "Largest Folders"
        case .applications: return "Applications"
        case .runningApps: return "Running Apps"
        case .memory: return "Memory"
        case .cpu: return "CPU"
        case .developer: return "Developer Storage"
        case .duplicates: return "Duplicates"
        case .cleanup: return "Cleanup"
        case .search: return "Search"
        case .permissions: return "Storage Access"
        case .privacy: return "Privacy"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .storage: return "internaldrive"
        case .largestFiles: return "doc.badge.ellipsis"
        case .largestFolders: return "folder"
        case .applications: return "square.grid.2x2"
        case .runningApps: return "list.bullet.rectangle.portrait"
        case .memory: return "memorychip"
        case .cpu: return "cpu"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .duplicates: return "square.on.square"
        case .cleanup: return "sparkles"
        case .search: return "magnifyingglass"
        case .permissions: return "lock.shield"
        case .privacy: return "hand.raised"
        case .settings: return "gearshape"
        }
    }

    /// Screens that require SpaceBridge Pro.
    var proFeature: ProFeature? {
        switch self {
        case .duplicates: return .duplicates
        case .developer: return .developerStorage
        case .cleanup: return .cleanup
        default: return nil
        }
    }

    static let sections: [(title: String, items: [SidebarItem])] = [
        ("Overview", [.dashboard, .storage]),
        ("Disk", [.largestFiles, .largestFolders, .developer, .duplicates, .cleanup, .search]),
        ("System", [.applications, .runningApps, .memory, .cpu]),
        ("Preferences", [.permissions, .privacy, .settings]),
    ]
}

struct TrashRequest: Identifiable {
    let id = UUID()
    var candidates: [TrashCandidate]
}

struct PaywallRequest: Identifiable {
    let id = UUID()
    var feature: ProFeature?
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

enum SettingsKey {
    static let includeSystemFolders = "includeSystemFolders"
    static let includeExternalVolumes = "includeExternalVolumes"
    static let includeNetworkVolumes = "includeNetworkVolumes"
    static let excludedPaths = "excludedPaths"
    static let scanConcurrency = "scanConcurrency"
    static let monitorInterval = "monitorInterval"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            includeSystemFolders: true,
            includeExternalVolumes: true,
            includeNetworkVolumes: false,
            excludedPaths: [String](),
            scanConcurrency: 4,
            monitorInterval: 2.0,
        ])
    }
}

/// Root state object. Owns the services; views read it from the environment.
@MainActor
@Observable
final class AppModel {
    var selection: SidebarItem? = .dashboard
    /// Category filter applied when navigating from a chart to Largest Files.
    var largestFilesCategory: StorageCategory?
    /// Folder to focus in Largest Folders (drill-down).
    var largestFoldersFocus: String?
    var searchText = ""
    var trashRequest: TrashRequest?
    var alert: AppAlert?
    var selectedApplicationPath: String?
    var paywall: PaywallRequest?

    let database: StorageDatabase?
    let databaseError: String?
    let scan: ScanCoordinator
    let monitor = SystemMonitorStore()
    let apps = ApplicationsStore()
    let pro = ProStore()

    init(database: StorageDatabase? = nil) {
        var resolved = database
        var failure: String?
        if resolved == nil {
            do {
                resolved = try StorageDatabase(url: StorageDatabase.defaultURL())
            } catch {
                failure = "The scan cache could not be opened: \(error). Scans will not be saved."
            }
        }
        self.database = resolved
        self.databaseError = failure
        self.scan = ScanCoordinator(database: resolved)
        scan.pro = pro
    }

    func start() async {
        await pro.validateIfNeeded()
        await scan.loadInitial()
        await apps.loadIfNeeded(database: database)
        scan.summary.applicationCount = apps.apps.count
    }

    /// Runs `action` if Pro is unlocked, otherwise shows the upgrade sheet for that feature.
    func requirePro(_ feature: ProFeature, _ action: () -> Void) {
        if pro.isUnlocked(feature) { action() } else { paywall = PaywallRequest(feature: feature) }
    }

    func showPaywall(_ feature: ProFeature? = nil) {
        paywall = PaywallRequest(feature: feature)
    }

    func showCategory(_ category: StorageCategory?) {
        largestFilesCategory = category
        selection = .largestFiles
    }

    func showFolder(_ path: String) {
        largestFoldersFocus = path
        selection = .largestFolders
    }

    func showApplication(_ path: String) {
        selectedApplicationPath = path
        selection = .applications
    }

    /// Opens the confirmation sheet. Nothing is moved until the user confirms.
    func requestTrash(_ candidates: [TrashCandidate]) {
        let allowed = candidates.filter { SecurityUtils.evaluate(path: $0.path).allowsDestructiveActions }
        guard !allowed.isEmpty else {
            alert = AppAlert(title: SecurityUtils.protectedLabel,
                             message: candidates.first.flatMap { SecurityUtils.evaluate(path: $0.path).message } ?? "This item can't be moved to the Trash.")
            return
        }
        trashRequest = TrashRequest(candidates: allowed)
    }

    /// Called only from the confirmation sheet's "Move to Trash" button.
    func confirmTrash(_ request: TrashRequest) async {
        trashRequest = nil
        let outcome = await TrashService.moveToTrash(request.candidates, database: database)
        if !outcome.failures.isEmpty {
            alert = AppAlert(title: "Some items weren't moved",
                             message: outcome.failures.map { "\($0.path.abbreviatingHome): \($0.reason)" }.joined(separator: "\n"))
        }
        if !outcome.trashed.isEmpty {
            await scan.dataChanged()
        }
    }
}

/// Owns scanning state and the dashboard summary.
@MainActor
@Observable
final class ScanCoordinator {
    var progress = ScanProgress()
    var summary = StorageSummary()
    var lastOutcome: ScanOutcome?
    var resumableScanID: Int64?
    var errorMessage: String?
    /// Increments whenever cached data changes so views can reload.
    var dataVersion = 0
    var isLoaded = false

    let database: StorageDatabase?
    /// External-volume scanning is a Pro feature.
    @ObservationIgnored weak var pro: ProStore?
    private var task: Task<Void, Never>?
    private var scanner: FileScanner?

    var isScanning: Bool { progress.phase.isActive }
    var isPaused: Bool { progress.phase == .paused }

    init(database: StorageDatabase?) {
        self.database = database
    }

    func loadInitial() async {
        guard let database, !isLoaded else { return }
        try? await database.recoverInterruptedScans()
        await refreshSummary()
        if let last = summary.lastScan, last.status == .cancelled {
            resumableScanID = last.id
        }
        isLoaded = true
    }

    func refreshSummary() async {
        guard let database else { return }
        let applications = summary.applicationCount
        summary = await StorageAnalyzer.loadSummary(database: database)
        summary.applicationCount = applications
    }

    func dataChanged() async {
        await refreshSummary()
        dataVersion += 1
    }

    func startScan(resume: Bool = false) {
        guard let database, !isScanning else { return }
        let defaults = UserDefaults.standard
        let externals = defaults.bool(forKey: SettingsKey.includeExternalVolumes) && (pro?.isUnlocked(.externalVolumes) ?? false)
            ? VolumeService.externalVolumes(includeNetwork: defaults.bool(forKey: SettingsKey.includeNetworkVolumes)).map(\.path)
            : []
        var configuration = ScanConfiguration.standard(
            includeSystem: defaults.bool(forKey: SettingsKey.includeSystemFolders),
            externalVolumes: externals,
            excluded: defaults.stringArray(forKey: SettingsKey.excludedPaths) ?? [])
        configuration.maxConcurrency = min(max(defaults.integer(forKey: SettingsKey.scanConcurrency), 1), 16)

        let scanner = FileScanner(database: database, configuration: configuration)
        self.scanner = scanner
        errorMessage = nil
        progress = ScanProgress(phase: .preparing, startedAt: Date(), isResumed: resume)
        let resumeID = resume ? resumableScanID : nil

        task = Task { [weak self] in
            do {
                let outcome = try await scanner.scan(
                    resumeScanID: resumeID,
                    volumeUsage: {
                        let volume = VolumeService.startupVolume()
                        return (volume?.totalCapacity ?? 0, volume?.used ?? 0)
                    },
                    progress: { [weak self] update in
                        Task { @MainActor [weak self] in
                            self?.apply(update, from: scanner)
                        }
                    })
                guard let self else { return }
                self.lastOutcome = outcome
                self.progress = outcome.progress
                self.resumableScanID = outcome.status == .cancelled ? outcome.scanID : nil
            } catch {
                guard let self else { return }
                self.progress.phase = .failed(String(describing: error))
                self.errorMessage = "The scan failed: \(error)"
            }
            guard let self else { return }
            self.scanner = nil
            self.task = nil
            await self.dataChanged()
        }
    }

    private func apply(_ update: ScanProgress, from source: FileScanner) {
        guard scanner === source else { return }
        if progress.phase == .completed || progress.phase == .cancelled { return }
        var update = update
        // Keep the user's pause state visible while workers report.
        if progress.phase == .paused && update.phase == .scanning { update.phase = .paused }
        progress = update
    }

    func pause() {
        guard let scanner, progress.phase == .scanning else { return }
        progress.phase = .paused
        Task { await scanner.pause() }
    }

    func resume() {
        guard let scanner, progress.phase == .paused else { return }
        progress.phase = .scanning
        Task { await scanner.resume() }
    }

    func cancel() {
        task?.cancel()
    }
}

/// Live CPU / memory / process sampling. Runs only while at least one view is subscribed,
/// so SpaceBridge uses no CPU for monitoring when those screens are closed.
@MainActor
@Observable
final class SystemMonitorStore {
    var memory: MemorySnapshot?
    var cpu: CPUSnapshot?
    var processes: [ProcessSnapshot] = []
    var memoryHistory: [MemorySnapshot] = []
    var cpuHistory: [CPUSnapshot] = []
    var lastProcessSample: Date?

    static let historyLength = 150

    private var subscribers = 0
    private var processSubscribers = 0
    private var task: Task<Void, Never>?
    private let memoryMonitor = MemoryMonitor()
    private let cpuMonitor = CPUMonitor()
    private let processMonitor = ProcessMonitor()

    var isRunning: Bool { task != nil }

    func subscribe(processes: Bool = false) {
        subscribers += 1
        if processes { processSubscribers += 1 }
        if task == nil { start() }
    }

    func unsubscribe(processes: Bool = false) {
        subscribers = max(subscribers - 1, 0)
        if processes { processSubscribers = max(processSubscribers - 1, 0) }
        if subscribers == 0 {
            task?.cancel()
            task = nil
        }
    }

    private func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let seconds = max(UserDefaults.standard.double(forKey: SettingsKey.monitorInterval), 1)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    /// Takes one sample immediately (used by tests and on first appearance).
    func tick() async {
        if let memory = memoryMonitor.sample() {
            self.memory = memory
            memoryHistory.append(memory)
            if memoryHistory.count > Self.historyLength { memoryHistory.removeFirst(memoryHistory.count - Self.historyLength) }
        }
        if let cpu = await cpuMonitor.sample() {
            self.cpu = cpu
            cpuHistory.append(cpu)
            if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst(cpuHistory.count - Self.historyLength) }
        }
        if processSubscribers > 0 {
            processes = await processMonitor.sample()
            lastProcessSample = Date()
        }
    }

    func usage(forAppAt path: String) -> ApplicationUsage {
        ProcessMonitor.usage(forAppAt: path, in: processes)
    }
}

/// Installed applications and their (lazily computed) bundle sizes.
@MainActor
@Observable
final class ApplicationsStore {
    var apps: [ApplicationInfo] = []
    var bundleSizes: [String: FolderSizeResult] = [:]
    var isLoading = false
    var sizingProgress: (done: Int, total: Int) = (0, 0)
    var signatureChecks: [String: CodeSignatureStatus] = [:]
    private var sizingTask: Task<Void, Never>?
    private var loaded = false

    func loadIfNeeded(database: StorageDatabase?) async {
        guard !loaded else { return }
        await reload(database: database)
    }

    func reload(database: StorageDatabase?) async {
        isLoading = true
        let found = await Task.detached(priority: .userInitiated) {
            ApplicationScanner().scanApplications()
        }.value
        apps = found
        isLoading = false
        loaded = true
        startSizing(database: database)
    }

    private func startSizing(database: StorageDatabase?) {
        sizingTask?.cancel()
        let paths = apps.map(\.path).filter { bundleSizes[$0] == nil }
        sizingProgress = (0, paths.count)
        sizingTask = Task { [weak self] in
            for path in paths {
                if Task.isCancelled { return }
                let size = await FolderAnalyzer.cachedOrCalculatedSize(of: path, database: database)
                guard let self else { return }
                self.bundleSizes[path] = size
                self.sizingProgress.done += 1
            }
        }
    }

    func size(of app: ApplicationInfo) -> Int64? {
        bundleSizes[app.path]?.allocatedSize
    }

    func validateSignature(_ app: ApplicationInfo) async {
        signatureChecks[app.path] = .notChecked
        let path = app.path
        let result = await Task.detached(priority: .userInitiated) {
            ApplicationScanner.validateSignature(for: path)
        }.value
        signatureChecks[app.path] = result
    }
}
