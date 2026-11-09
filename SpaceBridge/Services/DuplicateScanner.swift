import CryptoKit
import Foundation

struct DuplicateGroup: Identifiable, Sendable, Hashable {
    var id: String { hash }
    var hash: String
    var size: Int64
    var files: [FileItem]
    /// Space freed if all but one copy were removed.
    var potentialSavings: Int64 { size * Int64(max(files.count - 1, 0)) }
    var totalSize: Int64 { size * Int64(files.count) }
}

struct DuplicateScanOptions: Sendable, Equatable {
    var minimumSize: Int64 = 1_000_000
    /// Limit the search to this folder (default: the home folder).
    var scope: String? = NSHomeDirectory()
    /// Folders to skip. ~/Library holds app data where "duplicates" are usually intentional.
    var excluded: [String] = [NSHomeDirectory() + "/Library", NSHomeDirectory() + "/.Trash"]
    var maxSizeGroups = 5_000
    var partialHashBytes = 64 * 1024
}

struct DuplicateScanProgress: Sendable, Equatable {
    var stage: String = ""
    var candidatesChecked = 0
    var candidatesTotal = 0
    var bytesHashed: Int64 = 0
    var groupsFound = 0
}

/// Finds identical files using the scan index, without hashing everything:
///
///     same size → same file type → partial hash (first + last 64 KB) → full SHA-256
///
/// Files are only read, never modified. Files whose size or date changed since the scan are skipped.
struct DuplicateScanner: Sendable {
    let database: StorageDatabase
    var options = DuplicateScanOptions()

    func findDuplicates(progress: @escaping @Sendable (DuplicateScanProgress) -> Void) async throws -> [DuplicateGroup] {
        var report = DuplicateScanProgress(stage: "Finding files with identical sizes…")
        progress(report)
        let sizes = try await database.duplicateCandidateSizes(
            minimumSize: options.minimumSize, within: options.scope, excluding: options.excluded, limit: options.maxSizeGroups)
        report.candidatesTotal = sizes.count
        var groups: [DuplicateGroup] = []

        for candidate in sizes {
            try Task.checkCancellation()
            report.candidatesChecked += 1
            report.stage = "Comparing \(ByteFormatter.string(candidate.size)) files…"
            if report.candidatesChecked % 10 == 0 { progress(report) }

            let rows = try await database.files(withSize: candidate.size, within: options.scope, excluding: options.excluded)
            // Hard links to the same inode share storage: keep one per inode.
            var seenInodes = Set<UInt64>()
            let files = rows.compactMap { row -> FileItem? in
                if row.inode != 0 && !seenInodes.insert(row.inode).inserted { return nil }
                return row.file.hasValidName ? row.file : nil
            }
            let byType = Dictionary(grouping: files, by: \.fileExtension).values.filter { $0.count > 1 }
            for sameType in byType {
                let found = try Self.confirm(sameType, partialBytes: options.partialHashBytes) { report.bytesHashed += $0 }
                groups.append(contentsOf: found)
                report.groupsFound = groups.count
            }
            await Task.yield()
        }
        report.stage = "Done"
        progress(report)
        return groups.sorted { $0.potentialSavings > $1.potentialSavings }
    }

    /// Splits same-size files into groups of identical content.
    static func confirm(_ files: [FileItem], partialBytes: Int, hashed: (Int64) -> Void = { _ in }) throws -> [DuplicateGroup] {
        var byPartial: [String: [FileItem]] = [:]
        for file in files {
            try Task.checkCancellation()
            guard isUnchanged(file), let digest = partialHash(of: file.path, size: file.size, bytes: partialBytes) else { continue }
            hashed(Int64(min(Int64(partialBytes) * 2, file.size)))
            byPartial[digest, default: []].append(file)
        }
        var result: [DuplicateGroup] = []
        for candidates in byPartial.values where candidates.count > 1 {
            var byFull: [String: [FileItem]] = [:]
            if candidates[0].size <= Int64(partialBytes) * 2 {
                // The partial hash already covered the whole file.
                let key = "p" + (partialHash(of: candidates[0].path, size: candidates[0].size, bytes: partialBytes) ?? UUID().uuidString)
                byFull[key] = candidates
            } else {
                for file in candidates {
                    try Task.checkCancellation()
                    guard let digest = fullHash(of: file.path) else { continue }
                    hashed(file.size)
                    byFull[digest, default: []].append(file)
                }
            }
            for (digest, group) in byFull where group.count > 1 {
                result.append(DuplicateGroup(hash: digest, size: group[0].size,
                                             files: group.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }))
            }
        }
        return result
    }

    /// Re-checks size and modification date so we never compare stale index data.
    static func isUnchanged(_ file: FileItem) -> Bool {
        guard case .success(let entry) = DirectoryReader.stat(path: file.path), entry.kind == .file else { return false }
        guard entry.size == file.size else { return false }
        if let modified = file.modified, abs(entry.modified - modified.timeIntervalSince1970) > 1 { return false }
        return true
    }

    static func partialHash(of path: String, size: Int64, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            if let head = try handle.read(upToCount: bytes) { hasher.update(data: head) }
            if size > Int64(bytes) * 2 {
                try handle.seek(toOffset: UInt64(size - Int64(bytes)))
                if let tail = try handle.read(upToCount: bytes) { hasher.update(data: tail) }
            } else if size > Int64(bytes), let rest = try handle.read(upToCount: bytes) {
                hasher.update(data: rest)
            }
        } catch {
            return nil
        }
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file in 1 MB chunks so memory stays flat for any file size.
    static func fullHash(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while true {
                if Task.isCancelled { return nil }
                let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
