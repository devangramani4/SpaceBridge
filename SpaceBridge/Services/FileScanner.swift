import Foundation

/// What to scan.
struct ScanConfiguration: Sendable, Equatable {
    var roots: [String]
    var excludedPaths: [String] = []
    /// Parallel directory workers. 4 is a good balance between SSD throughput and CPU use.
    var maxConcurrency: Int = 4
    var homeDirectory: String = NSHomeDirectory()

    /// Top-level folders that together cover the whole startup disk without double counting
    /// (APFS firmlinks make /Users, /Applications, /Library… appear under / and /System/Volumes/Data).
    static let systemRoots = ["/System", "/usr", "/bin", "/sbin", "/private", "/cores"]
    static let userRoots = ["/Applications", "/Users", "/Library", "/opt"]

    static func standard(includeSystem: Bool, externalVolumes: [String], excluded: [String] = []) -> ScanConfiguration {
        var roots = userRoots
        if includeSystem { roots += systemRoots }
        roots += externalVolumes
        return ScanConfiguration(roots: roots, excludedPaths: excluded)
    }

    /// Resolves symlinks (e.g. /tmp → /private/tmp), drops missing roots and roots nested in other roots.
    func normalizedRoots() -> [String] {
        var resolved: [String] = []
        for root in roots {
            guard let real = SecurityUtils.realPath(root) else { continue }
            if !resolved.contains(real) { resolved.append(real) }
        }
        return resolved.filter { candidate in
            !resolved.contains { other in other != candidate && SecurityUtils.isPath(candidate.lowercased(), within: other.lowercased()) }
        }
    }
}

enum ScanPhase: Equatable, Sendable {
    case idle, preparing, scanning, paused, finalizing, completed, cancelled
    case failed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .scanning, .paused, .finalizing: return true
        default: return false
        }
    }
}

struct ScanProgress: Sendable, Equatable {
    var phase: ScanPhase = .idle
    var filesScanned: Int64 = 0
    var foldersScanned: Int64 = 0
    var bytesAnalyzed: Int64 = 0
    var restrictedFolders: Int64 = 0
    var errors: Int64 = 0
    var newFiles: Int64 = 0
    var changedFiles: Int64 = 0
    var deletedFiles: Int64 = 0
    var currentPath: String = ""
    var startedAt: Date?
    var isResumed = false

    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
}

struct ScanOutcome: Sendable {
    var scanID: Int64
    var status: ScanRecord.Status
    var totals: ScanTotals
    var progress: ScanProgress
    var duration: TimeInterval
}

/// Lock-protected counters shared by all workers. Updated per directory, not per file.
final class ScanCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ScanProgress()

    func reset(startedAt: Date, resumed: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = ScanProgress(phase: .scanning, startedAt: startedAt, isResumed: resumed)
    }

    func update(_ body: (inout ScanProgress) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
    }

    func snapshot(phase: ScanPhase? = nil) -> ScanProgress {
        lock.lock(); defer { lock.unlock() }
        var copy = value
        if let phase { copy.phase = phase }
        return copy
    }
}

/// Suspends workers while the user has paused the scan.
actor PauseGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isPaused: Bool { paused }

    func pause() { paused = true }

    func resume() {
        paused = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitIfPaused() async {
        guard paused else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Shared LIFO queue of directories to visit. Depth-first order keeps the queue (and memory) small.
actor DirectoryWorkQueue {
    struct Job: Sendable {
        var path: String
        var name: String
        var parentID: Int64?
        var folderID: Int64?
        var depth: Int
        var device: Int32
    }

    private var jobs: [Job] = []
    private var active = 0
    private var cancelled = false
    private var waiters: [CheckedContinuation<Job?, Never>] = []

    func push(_ newJobs: [Job]) {
        guard !cancelled else { return }
        for job in newJobs {
            if let waiter = waiters.popLast() {
                active += 1
                waiter.resume(returning: job)
            } else {
                jobs.append(job)
            }
        }
    }

    /// Returns the next job, or `nil` when all work is done or the scan was cancelled.
    func next() async -> Job? {
        if cancelled { return nil }
        if let job = jobs.popLast() {
            active += 1
            return job
        }
        if active == 0 { finishAll(); return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Call after a job has been processed and its children pushed.
    func complete() {
        active -= 1
        if active == 0 && jobs.isEmpty { finishAll() }
    }

    func cancel() {
        cancelled = true
        jobs.removeAll()
        finishAll()
    }

    private func finishAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: nil) }
    }
}

/// Scans the filesystem into the `StorageDatabase` cache.
///
/// - Read-only: it only calls `opendir`, `readdir` and `lstat`. It never opens file contents,
///   never follows symlinks, never crosses into other volumes from inside a root, and never
///   modifies anything on disk.
/// - Incremental: each directory is diffed against the cache and only changes are written.
/// - Resumable: a cancelled scan can continue; directories already processed are skipped.
final class FileScanner: Sendable {
    let database: StorageDatabase
    let configuration: ScanConfiguration
    let counters = ScanCounters()
    private let pauseGate = PauseGate()
    private let categorizer: StorageCategorizer
    /// Counts each hard-linked file once. One scanner instance is used per scan.
    private let hardLinkTracker = HardLinkTracker()

    init(database: StorageDatabase, configuration: ScanConfiguration) {
        self.database = database
        self.configuration = configuration
        self.categorizer = StorageCategorizer(homeDirectory: configuration.homeDirectory)
    }

    func pause() async {
        await pauseGate.pause()
        counters.update { $0.phase = .paused }
    }

    func resume() async {
        await pauseGate.resume()
        counters.update { $0.phase = .scanning }
    }

    /// Runs a scan. Cancel the calling task to stop; partial results are kept and can be resumed.
    /// - Parameters:
    ///   - resumeScanID: continue a previously cancelled scan with this id.
    ///   - volumeUsage: provides (total, used) of the startup volume for the history chart.
    ///   - progress: called about 4 times per second from a background task.
    func scan(
        resumeScanID: Int64? = nil,
        volumeUsage: @escaping @Sendable () -> (total: Int64, used: Int64) = { (0, 0) },
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanOutcome {
        let started = Date()
        let roots = configuration.normalizedRoots()
        let excluded = configuration.excludedPaths.map { SecurityUtils.normalized($0, resolveParent: false).lowercased() }
        let resuming = resumeScanID != nil
        counters.reset(startedAt: started, resumed: resuming)
        progress(counters.snapshot(phase: .preparing))

        let scanID: Int64
        if let resumeScanID {
            scanID = resumeScanID
            try await database.markScanResumed(resumeScanID)
        } else {
            scanID = try await database.beginScan(roots: roots)
        }

        let queue = DirectoryWorkQueue()
        var rootJobs: [DirectoryWorkQueue.Job] = []
        for root in roots {
            switch DirectoryReader.stat(path: root) {
            case .success(let entry) where entry.kind == .directory:
                let id = try await database.ensureRoot(path: root, modified: entry.modified)
                rootJobs.append(DirectoryWorkQueue.Job(path: root, name: root.lastPathComponentString, parentID: nil, folderID: id, depth: 0, device: entry.device))
            case .success:
                await database.logError(path: root, message: "Scan location is not a folder")
            case .failure(let error):
                await database.logError(path: root, message: error.localizedDescription)
            }
        }
        await queue.push(rootJobs)

        let reporter = Task { [counters] in
            while !Task.isCancelled {
                progress(counters.snapshot())
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { reporter.cancel() }

        let workerCount = max(1, configuration.maxConcurrency)
        let gate = pauseGate
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<workerCount {
                    group.addTask {
                        while let job = await queue.next() {
                            if Task.isCancelled { await queue.complete(); break }
                            let children = await self.process(job, scanID: scanID, resuming: resuming, excluded: excluded)
                            await queue.push(children)
                            await queue.complete()
                        }
                    }
                }
            }
        } onCancel: {
            Task {
                await gate.resume()
                await queue.cancel()
            }
        }

        let cancelled = Task.isCancelled
        reporter.cancel()
        progress(counters.snapshot(phase: .finalizing))

        let usage = volumeUsage()
        let final = counters.snapshot()
        let status: ScanRecord.Status = cancelled ? .cancelled : .completed
        let totals = try await database.finishScan(
            scanID: scanID, roots: roots, status: status, volumeTotal: usage.total, volumeUsed: usage.used,
            newFiles: Int(final.newFiles), changedFiles: Int(final.changedFiles), deletedFiles: Int(final.deletedFiles))
        let finished = counters.snapshot(phase: cancelled ? .cancelled : .completed)
        progress(finished)
        return ScanOutcome(scanID: scanID, status: status, totals: totals, progress: finished, duration: Date().timeIntervalSince(started))
    }

    private func isExcluded(_ path: String, _ excluded: [String]) -> Bool {
        guard !excluded.isEmpty else { return false }
        let lower = path.lowercased()
        return excluded.contains { SecurityUtils.isPath(lower, within: $0) }
    }

    /// Processes one directory and returns its sub-directories as new jobs.
    private func process(_ job: DirectoryWorkQueue.Job, scanID: Int64, resuming: Bool, excluded: [String]) async -> [DirectoryWorkQueue.Job] {
        await pauseGate.waitIfPaused()
        if Task.isCancelled { return [] }
        counters.update { $0.currentPath = job.path }

        // Resume: reuse directories already processed by this scan without touching the disk.
        if resuming, let folderID = job.folderID,
           let visited = try? await database.visitedChildren(folderID: folderID, scanID: scanID) {
            counters.update {
                $0.foldersScanned += 1
                $0.filesScanned += visited.files
                $0.bytesAnalyzed += visited.bytes
            }
            return visited.children.compactMap { child in
                isExcluded(child.path, excluded) ? nil
                    : DirectoryWorkQueue.Job(path: child.path, name: child.name, parentID: folderID, folderID: child.id, depth: job.depth + 1, device: job.device)
            }
        }

        let context = categorizer.context(forFolder: job.path)
        var files: [ScannedFile] = []
        var subdirectories: [ScannedSubdirectory] = []
        var bytes: Int64 = 0
        let modified: TimeInterval
        if case .success(let me) = DirectoryReader.stat(path: job.path) { modified = me.modified } else { modified = 0 }
        let prefix = job.path == "/" ? "/" : job.path + "/"

        let result = DirectoryReader.read(path: job.path) { entry in
            switch entry.kind {
            case .directory:
                // Never cross into another mounted volume from inside a root.
                guard entry.device == job.device else { return }
                guard !isExcluded(prefix + entry.name, excluded) else { return }
                subdirectories.append(ScannedSubdirectory(name: entry.name, modified: entry.modified))
            case .file, .symlink:
                var flags: FileItem.Flags = []
                if entry.isHidden { flags.insert(.hidden) }
                if entry.kind == .symlink { flags.insert(.symlink) }
                if !entry.hasValidName { flags.insert(.invalidName) }
                var counted = entry.allocatedSize
                var inode: UInt64 = 0
                if entry.kind == .file && entry.linkCount > 1 {
                    flags.insert(.hardLinked)
                    inode = entry.inode
                    if !hardLinkTracker.firstOccurrence(device: entry.device, inode: entry.inode) { counted = 0 }
                }
                let ext = entry.kind == .symlink ? "" : (entry.name as NSString).pathExtension.lowercased()
                bytes += counted
                files.append(ScannedFile(
                    name: entry.name, fileExtension: ext, size: entry.size, allocatedSize: entry.allocatedSize,
                    countedAllocatedSize: counted, modified: entry.modified, created: entry.created, accessed: entry.accessed,
                    flags: flags, inode: inode, category: categorizer.category(forFileExtension: ext, in: context)))
            case .other:
                break // sockets, pipes and device nodes occupy no meaningful space
            }
        }

        var restricted = false
        switch result {
        case .success:
            break
        case .failure(.accessDenied):
            restricted = true
            counters.update { $0.restrictedFolders += 1 }
        case .failure(.vanished):
            // Deleted while scanning: nothing to record. The cache entry is cleaned up at the end.
            return []
        case .failure(let error):
            restricted = true
            counters.update { $0.errors += 1 }
            await database.logError(path: job.path, message: error.localizedDescription)
        }

        let snapshot = DirectorySnapshot(
            path: job.path, name: job.name, parentID: job.parentID, folderID: job.folderID, depth: job.depth,
            modified: modified, isRestricted: restricted, files: files, subdirectories: subdirectories,
            category: context.strong ?? context.location ?? .other)

        let sync: DirectorySyncResult
        do {
            sync = try await database.syncDirectory(snapshot, scanID: scanID)
        } catch {
            counters.update { $0.errors += 1 }
            await database.logError(path: job.path, message: "Cache write failed: \(error)")
            return []
        }

        let fileCount = Int64(files.count)
        counters.update {
            $0.foldersScanned += 1
            $0.filesScanned += fileCount
            $0.bytesAnalyzed += bytes
            $0.newFiles += Int64(sync.newFiles)
            $0.changedFiles += Int64(sync.changedFiles)
            $0.deletedFiles += Int64(sync.deletedFiles)
        }

        return subdirectories.map { sub in
            DirectoryWorkQueue.Job(path: prefix + sub.name, name: sub.name, parentID: sync.folderID, folderID: sync.childIDs[sub.name],
                  depth: job.depth + 1, device: job.device)
        }
    }

}
