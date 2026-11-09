import Foundation

/// On-demand recursive folder size calculation (used for app bundles, cleanup candidates and
/// developer folders when the scan cache doesn't have them). Read-only, never follows symlinks,
/// stays on the folder's own volume and checks for task cancellation regularly.
enum FolderAnalyzer {
    static func size(of path: String, stayOnVolume: Bool = true) -> FolderSizeResult {
        var result = FolderSizeResult()
        guard case .success(let root) = DirectoryReader.stat(path: path) else {
            result.exists = false
            return result
        }
        switch root.kind {
        case .file, .symlink:
            result.allocatedSize = root.allocatedSize
            result.logicalSize = root.size
            result.fileCount = 1
            return result
        case .other:
            return result
        case .directory:
            break
        }

        var seenInodes = Set<UInt64>()
        var stack = [path]
        var visited = 0
        while let current = stack.popLast() {
            visited += 1
            if visited % 256 == 0 && Task.isCancelled {
                result.wasCancelled = true
                return result
            }
            let prefix = current == "/" ? "/" : current + "/"
            let read = DirectoryReader.read(path: current) { entry in
                switch entry.kind {
                case .directory:
                    if stayOnVolume && entry.device != root.device { return }
                    result.folderCount += 1
                    stack.append(prefix + entry.name)
                case .file, .symlink:
                    result.fileCount += 1
                    result.logicalSize += entry.size
                    if entry.kind == .file && entry.linkCount > 1 && !seenInodes.insert(entry.inode).inserted { return }
                    result.allocatedSize += entry.allocatedSize
                case .other:
                    break
                }
            }
            if case .failure(let error) = read, error != .vanished {
                result.restrictedFolderCount += 1
            }
        }
        return result
    }

    /// Async wrapper that runs the calculation off the main thread at utility priority.
    static func sizeAsync(of path: String) async -> FolderSizeResult {
        let task = Task.detached(priority: .utility) {
            FolderAnalyzer.size(of: path)
        }
        // Forward cancellation from the caller to the detached work.
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Uses the scan cache when it has the folder, otherwise calculates it.
    static func cachedOrCalculatedSize(of path: String, database: StorageDatabase?) async -> FolderSizeResult {
        if let database, let folder = try? await database.folder(path: path), folder.lastScanned != nil {
            return FolderSizeResult(allocatedSize: folder.totalAllocated, logicalSize: folder.totalSize,
                                    fileCount: folder.fileCount, folderCount: folder.folderCount,
                                    restrictedFolderCount: folder.isRestricted ? 1 : 0)
        }
        return await sizeAsync(of: path)
    }
}
