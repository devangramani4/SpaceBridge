import Foundation

/// Local metadata cache of the filesystem (SQLite, WAL mode).
///
/// Stores only metadata — paths, sizes, dates, types. Never file contents. Nothing leaves the Mac.
/// All access is serialized by the actor; scanning writes are batched into large transactions.
actor StorageDatabase {
    static let schemaVersion = 1

    let url: URL
    private let db: SQLiteConnection
    private var inTransaction = false
    private var pendingOperations = 0
    private var lastCommit = Date()

    static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("SpaceBridge", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func defaultURL() throws -> URL {
        try defaultDirectory().appendingPathComponent("ScanCache.sqlite")
    }

    init(url: URL) throws {
        self.url = url
        let connection = try SQLiteConnection(path: url.path)
        try Self.migrate(connection)
        db = connection
    }

    private static func migrate(_ db: SQLiteConnection) throws {
        try db.execute("PRAGMA journal_mode=WAL;")
        try db.execute("PRAGMA synchronous=NORMAL;")
        try db.execute("PRAGMA temp_store=MEMORY;")
        try db.execute("PRAGMA cache_size=-16000;") // ~16 MB page cache cap
        try db.execute("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS folders(
            id INTEGER PRIMARY KEY,
            parent_id INTEGER,
            path TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            depth INTEGER NOT NULL DEFAULT 0,
            modified REAL,
            restricted INTEGER NOT NULL DEFAULT 0,
            scan_id INTEGER NOT NULL DEFAULT 0,
            scanned_at REAL,
            category INTEGER NOT NULL DEFAULT 0,
            direct_alloc INTEGER NOT NULL DEFAULT 0,
            direct_size INTEGER NOT NULL DEFAULT 0,
            direct_files INTEGER NOT NULL DEFAULT 0,
            direct_dirs INTEGER NOT NULL DEFAULT 0,
            total_alloc INTEGER NOT NULL DEFAULT 0,
            total_size INTEGER NOT NULL DEFAULT 0,
            total_files INTEGER NOT NULL DEFAULT 0,
            total_dirs INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS folders_parent ON folders(parent_id, total_alloc DESC);
        CREATE INDEX IF NOT EXISTS folders_name ON folders(name);
        CREATE INDEX IF NOT EXISTS folders_total ON folders(total_alloc DESC);
        CREATE TABLE IF NOT EXISTS files(
            id INTEGER PRIMARY KEY,
            folder_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            ext TEXT NOT NULL,
            size INTEGER NOT NULL,
            alloc INTEGER NOT NULL,
            counted_alloc INTEGER NOT NULL,
            modified REAL,
            created REAL,
            accessed REAL,
            flags INTEGER NOT NULL DEFAULT 0,
            inode INTEGER NOT NULL DEFAULT 0,
            category INTEGER NOT NULL DEFAULT 0,
            scanned_at REAL
        );
        CREATE INDEX IF NOT EXISTS files_folder ON files(folder_id);
        CREATE INDEX IF NOT EXISTS files_alloc ON files(alloc DESC);
        CREATE INDEX IF NOT EXISTS files_size ON files(size);
        CREATE INDEX IF NOT EXISTS files_ext ON files(ext);
        CREATE INDEX IF NOT EXISTS files_category ON files(category, alloc DESC);
        CREATE TABLE IF NOT EXISTS scans(
            id INTEGER PRIMARY KEY, started REAL, finished REAL, status TEXT, roots TEXT,
            files INTEGER DEFAULT 0, folders INTEGER DEFAULT 0, bytes INTEGER DEFAULT 0,
            new_files INTEGER DEFAULT 0, changed_files INTEGER DEFAULT 0, deleted_files INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS history(
            id INTEGER PRIMARY KEY, timestamp REAL, volume_total INTEGER, volume_used INTEGER, scanned_bytes INTEGER
        );
        CREATE TABLE IF NOT EXISTS category_totals(category INTEGER PRIMARY KEY, bytes INTEGER, files INTEGER);
        CREATE TABLE IF NOT EXISTS errors(id INTEGER PRIMARY KEY, timestamp REAL, path TEXT, message TEXT);
        """)
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)", [.text(String(schemaVersion))])
    }

    // MARK: - Transactions

    private func beginIfNeeded() throws {
        guard !inTransaction else { return }
        try db.execute("BEGIN IMMEDIATE;")
        inTransaction = true
        lastCommit = Date()
    }

    /// Commits the running batch when it is large or old enough.
    private func commitIfNeeded() throws {
        guard inTransaction else { return }
        if pendingOperations >= 20_000 || Date().timeIntervalSince(lastCommit) > 1.0 {
            try commit()
        }
    }

    func commit() throws {
        guard inTransaction else { return }
        try db.execute("COMMIT;")
        inTransaction = false
        pendingOperations = 0
        lastCommit = Date()
    }

    // MARK: - Scan lifecycle

    func beginScan(roots: [String]) throws -> Int64 {
        try commit()
        try db.run("INSERT INTO scans(started, status, roots) VALUES(?, 'running', ?)",
                   [.double(Date().timeIntervalSince1970), .text(roots.joined(separator: "\n"))])
        return db.lastInsertRowID
    }

    func markScanResumed(_ scanID: Int64) throws {
        try db.run("UPDATE scans SET status = 'running', finished = NULL WHERE id = ?", [.int(scanID)])
    }

    /// Returns the id of the root folder row for `path`, creating it if necessary.
    func ensureRoot(path: String, modified: TimeInterval) throws -> Int64 {
        try beginIfNeeded()
        if let id = try db.query("SELECT id FROM folders WHERE path = ?", [.text(path)], map: { $0.int64(0) }).first {
            try db.run("UPDATE folders SET parent_id = NULL, depth = 0 WHERE id = ?", [.int(id)])
            return id
        }
        try db.run("INSERT INTO folders(parent_id, path, name, depth, modified) VALUES(NULL, ?, ?, 0, ?)",
                   [.text(path), .text(path.lastPathComponentString), .double(modified)])
        pendingOperations += 1
        return db.lastInsertRowID
    }

    /// For resuming: whether the folder was already fully processed by `scanID`.
    func visitedChildren(folderID: Int64, scanID: Int64) throws -> (files: Int64, bytes: Int64, children: [(id: Int64, path: String, name: String)])? {
        let rows = try db.query("SELECT scan_id, direct_files, direct_alloc FROM folders WHERE id = ?", [.int(folderID)]) {
            ($0.int64(0), $0.int64(1), $0.int64(2))
        }
        guard let row = rows.first, row.0 == scanID else { return nil }
        let children = try db.query("SELECT id, path, name FROM folders WHERE parent_id = ?", [.int(folderID)]) {
            (id: $0.int64(0), path: $0.text(1), name: $0.text(2))
        }
        return (row.1, row.2, children)
    }

    /// Applies one directory's observed state, writing only what changed since the last scan.
    func syncDirectory(_ snapshot: DirectorySnapshot, scanID: Int64) throws -> DirectorySyncResult {
        try beginIfNeeded()
        let now = Date().timeIntervalSince1970

        // 1. Resolve the folder row.
        var folderID = snapshot.folderID
        if folderID == nil {
            folderID = try db.query("SELECT id FROM folders WHERE path = ?", [.text(snapshot.path)]) { $0.int64(0) }.first
        }
        if folderID == nil {
            try db.run("INSERT INTO folders(parent_id, path, name, depth) VALUES(?, ?, ?, ?)",
                       [.optional(snapshot.parentID), .text(snapshot.path), .text(snapshot.name), .integer(snapshot.depth)])
            folderID = db.lastInsertRowID
        }
        let id = folderID!

        var directAlloc: Int64 = 0
        var directSize: Int64 = 0
        for file in snapshot.files {
            directAlloc += file.countedAllocatedSize
            directSize += file.size
        }
        try db.run("""
            UPDATE folders SET parent_id = ?, name = ?, depth = ?, modified = ?, restricted = ?, scan_id = ?,
                scanned_at = ?, category = ?, direct_alloc = ?, direct_size = ?, direct_files = ?, direct_dirs = ?
            WHERE id = ?
            """, [.optional(snapshot.parentID), .text(snapshot.name), .integer(snapshot.depth), .double(snapshot.modified),
                  .bool(snapshot.isRestricted), .int(scanID), .double(now), .integer(snapshot.category.rawValue),
                  .int(directAlloc), .int(directSize), .integer(snapshot.files.count), .integer(snapshot.subdirectories.count),
                  .int(id)])
        pendingOperations += 1

        // 2. Diff files against the cache.
        struct Cached { var id: Int64; var size: Int64; var alloc: Int64; var modified: Double; var counted: Int64 }
        var cached: [String: Cached] = [:]
        for row in try db.query("SELECT id, name, size, alloc, modified, counted_alloc FROM files WHERE folder_id = ?", [.int(id)], map: {
            (name: $0.text(1), value: Cached(id: $0.int64(0), size: $0.int64(2), alloc: $0.int64(3), modified: $0.double(4), counted: $0.int64(5)))
        }) {
            cached[row.name] = row.value
        }

        var newFiles = 0, changedFiles = 0
        for file in snapshot.files {
            if let existing = cached.removeValue(forKey: file.name) {
                if existing.size != file.size || existing.alloc != file.allocatedSize
                    || abs(existing.modified - file.modified) > 0.000_5 || existing.counted != file.countedAllocatedSize {
                    try db.run("""
                        UPDATE files SET size = ?, alloc = ?, counted_alloc = ?, modified = ?, created = ?, accessed = ?,
                            flags = ?, inode = ?, category = ?, scanned_at = ? WHERE id = ?
                        """, Self.fileValues(file, now: now) + [.int(existing.id)])
                    changedFiles += 1
                    pendingOperations += 1
                }
            } else {
                try db.run("""
                    INSERT INTO files(folder_id, name, ext, size, alloc, counted_alloc, modified, created, accessed, flags, inode, category, scanned_at)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.int(id), .text(file.name), .text(file.fileExtension)] + Self.fileValues(file, now: now))
                newFiles += 1
                pendingOperations += 1
            }
        }
        for stale in cached.values {
            try db.run("DELETE FROM files WHERE id = ?", [.int(stale.id)])
            pendingOperations += 1
        }

        // 3. Diff child folders.
        var existingChildren: [String: (id: Int64, path: String)] = [:]
        for row in try db.query("SELECT id, name, path FROM folders WHERE parent_id = ?", [.int(id)], map: { ($0.int64(0), $0.text(1), $0.text(2)) }) {
            existingChildren[row.1] = (row.0, row.2)
        }
        var childIDs: [String: Int64] = [:]
        childIDs.reserveCapacity(snapshot.subdirectories.count)
        for sub in snapshot.subdirectories {
            if let existing = existingChildren.removeValue(forKey: sub.name) {
                childIDs[sub.name] = existing.id
            } else {
                let childPath = snapshot.path == "/" ? "/" + sub.name : snapshot.path + "/" + sub.name
                if let other = try db.query("SELECT id FROM folders WHERE path = ?", [.text(childPath)], map: { $0.int64(0) }).first {
                    try db.run("UPDATE folders SET parent_id = ? WHERE id = ?", [.int(id), .int(other)])
                    childIDs[sub.name] = other
                } else {
                    try db.run("INSERT INTO folders(parent_id, path, name, depth, modified) VALUES(?, ?, ?, ?, ?)",
                               [.int(id), .text(childPath), .text(sub.name), .integer(snapshot.depth + 1), .double(sub.modified)])
                    childIDs[sub.name] = db.lastInsertRowID
                }
                pendingOperations += 1
            }
        }
        // A restricted folder's children are unknown, not deleted: keep nothing stale either.
        var deletedFolders = 0
        for (_, stale) in existingChildren {
            deletedFolders += try deleteSubtree(path: stale.path)
        }

        try commitIfNeeded()
        return DirectorySyncResult(folderID: id, childIDs: childIDs, newFiles: newFiles, changedFiles: changedFiles,
                                   deletedFiles: cached.count, deletedFolders: deletedFolders)
    }

    private static func fileValues(_ file: ScannedFile, now: Double) -> [SQLValue] {
        [.int(file.size), .int(file.allocatedSize), .int(file.countedAllocatedSize), .double(file.modified),
         .double(file.created), .double(file.accessed), .integer(file.flags.rawValue),
         .int(Int64(bitPattern: file.inode)), .integer(file.category.rawValue), .double(now)]
    }

    private static func subtreeBounds(_ path: String) -> (lower: String, upper: String) {
        path == "/" ? ("/", "0") : (path + "/", path + "0")
    }

    /// Removes a folder and everything below it from the cache. Returns the number of folders removed.
    @discardableResult
    func deleteSubtree(path: String) throws -> Int {
        try beginIfNeeded()
        let bounds = Self.subtreeBounds(path)
        let values: [SQLValue] = [.text(path), .text(bounds.lower), .text(bounds.upper)]
        try db.run("DELETE FROM files WHERE folder_id IN (SELECT id FROM folders WHERE path = ? OR (path >= ? AND path < ?))", values)
        let removed = try db.run("DELETE FROM folders WHERE path = ? OR (path >= ? AND path < ?)", values)
        pendingOperations += removed
        return removed
    }

    /// Finalizes a scan: removes folders that no longer exist, recomputes recursive totals,
    /// refreshes category totals and records a history point.
    func finishScan(scanID: Int64, roots: [String], status: ScanRecord.Status, volumeTotal: Int64, volumeUsed: Int64,
                    newFiles: Int, changedFiles: Int, deletedFiles: Int) throws -> ScanTotals {
        try beginIfNeeded()
        if status == .completed {
            // Folders under scanned roots that were never reached were removed from disk.
            for root in roots {
                let bounds = Self.subtreeBounds(root)
                let stale = try db.query("SELECT path FROM folders WHERE scan_id <> ? AND (path = ? OR (path >= ? AND path < ?))",
                                         [.int(scanID), .text(root), .text(bounds.lower), .text(bounds.upper)]) { $0.text(0) }
                for path in stale.sorted(by: { $0.count < $1.count }) {
                    try deleteSubtree(path: path)
                }
            }
            // Roots that are no longer part of the scan (e.g. a disconnected external disk).
            let rootRows = try db.query("SELECT path FROM folders WHERE parent_id IS NULL") { $0.text(0) }
            for path in rootRows where !roots.contains(path) {
                try deleteSubtree(path: path)
            }
        }
        try recomputeTotals()
        try db.run("DELETE FROM category_totals")
        try db.run("INSERT INTO category_totals(category, bytes, files) SELECT category, SUM(counted_alloc), COUNT(*) FROM files GROUP BY category")

        let totals = try totalsLocked()
        try db.run("""
            UPDATE scans SET finished = ?, status = ?, files = ?, folders = ?, bytes = ?, new_files = ?, changed_files = ?, deleted_files = ?
            WHERE id = ?
            """, [.double(Date().timeIntervalSince1970), .text(status.rawValue), .int(totals.fileCount), .int(totals.folderCount),
                  .int(totals.allocatedBytes), .integer(newFiles), .integer(changedFiles), .integer(deletedFiles), .int(scanID)])
        if status == .completed {
            try db.run("INSERT INTO history(timestamp, volume_total, volume_used, scanned_bytes) VALUES(?, ?, ?, ?)",
                       [.double(Date().timeIntervalSince1970), .int(volumeTotal), .int(volumeUsed), .int(totals.allocatedBytes)])
        }
        try commit()
        return totals
    }

    /// Bottom-up recursive totals. Memory: ~80 bytes per folder for the duration of the call.
    private func recomputeTotals() throws {
        struct Row { var id: Int64; var parent: Int64; var depth: Int; var alloc: Int64; var size: Int64; var files: Int64
                     var oldAlloc: Int64; var oldSize: Int64; var oldFiles: Int64; var oldDirs: Int64; var dirs: Int64 = 0 }
        var rows = try db.query("""
            SELECT id, IFNULL(parent_id, 0), depth, direct_alloc, direct_size, direct_files, total_alloc, total_size, total_files, total_dirs
            FROM folders
            """) {
            Row(id: $0.int64(0), parent: $0.int64(1), depth: $0.int(2), alloc: $0.int64(3), size: $0.int64(4), files: $0.int64(5),
                oldAlloc: $0.int64(6), oldSize: $0.int64(7), oldFiles: $0.int64(8), oldDirs: $0.int64(9))
        }
        var index: [Int64: Int] = [:]
        index.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() { index[row.id] = offset }
        let order = rows.indices.sorted { rows[$0].depth > rows[$1].depth }
        for position in order {
            let row = rows[position]
            guard row.parent != 0, let parentIndex = index[row.parent], parentIndex != position else { continue }
            rows[parentIndex].alloc += row.alloc
            rows[parentIndex].size += row.size
            rows[parentIndex].files += row.files
            rows[parentIndex].dirs += row.dirs + 1
        }
        for row in rows where row.alloc != row.oldAlloc || row.size != row.oldSize || row.files != row.oldFiles || row.dirs != row.oldDirs {
            try db.run("UPDATE folders SET total_alloc = ?, total_size = ?, total_files = ?, total_dirs = ? WHERE id = ?",
                       [.int(row.alloc), .int(row.size), .int(row.files), .int(row.dirs), .int(row.id)])
        }
    }

    // MARK: - Updates after user actions

    /// Updates the cache after the user moved an item to the Trash.
    func removeItem(path: String) throws {
        try beginIfNeeded()
        if let folder = try folderLocked(path: path) {
            try adjustAncestors(from: folder.parentID, alloc: -folder.totalAllocated, size: -folder.totalSize,
                                files: -folder.fileCount, dirs: -(folder.folderCount + 1))
            if let parent = folder.parentID {
                try db.run("UPDATE folders SET direct_dirs = MAX(direct_dirs - 1, 0) WHERE id = ?", [.int(parent)])
            }
            try deleteSubtree(path: path)
        } else {
            let folderPath = path.deletingLastPathComponentString
            let name = path.lastPathComponentString
            if let folderID = try db.query("SELECT id FROM folders WHERE path = ?", [.text(folderPath)], map: { $0.int64(0) }).first,
               let file = try db.query("SELECT id, counted_alloc, size FROM files WHERE folder_id = ? AND name = ?",
                                       [.int(folderID), .text(name)], map: { ($0.int64(0), $0.int64(1), $0.int64(2)) }).first {
                try db.run("DELETE FROM files WHERE id = ?", [.int(file.0)])
                try db.run("UPDATE folders SET direct_alloc = direct_alloc - ?, direct_size = direct_size - ?, direct_files = direct_files - 1 WHERE id = ?",
                           [.int(file.1), .int(file.2), .int(folderID)])
                try adjustAncestors(from: folderID, alloc: -file.1, size: -file.2, files: -1, dirs: 0)
            }
        }
        try db.run("DELETE FROM category_totals")
        try db.run("INSERT INTO category_totals(category, bytes, files) SELECT category, SUM(counted_alloc), COUNT(*) FROM files GROUP BY category")
        try commit()
    }

    private func adjustAncestors(from folderID: Int64?, alloc: Int64, size: Int64, files: Int64, dirs: Int64) throws {
        var current = folderID
        var guardCounter = 0
        while let id = current, guardCounter < 4096 {
            try db.run("UPDATE folders SET total_alloc = total_alloc + ?, total_size = total_size + ?, total_files = total_files + ?, total_dirs = total_dirs + ? WHERE id = ?",
                       [.int(alloc), .int(size), .int(files), .int(dirs), .int(id)])
            current = try db.query("SELECT parent_id FROM folders WHERE id = ?", [.int(id)]) { $0.optionalInt64(0) }.first ?? nil
            guardCounter += 1
        }
    }

    // MARK: - Errors

    func logError(path: String, message: String) {
        do {
            try beginIfNeeded()
            try db.run("INSERT INTO errors(timestamp, path, message) VALUES(?, ?, ?)",
                       [.double(Date().timeIntervalSince1970), .text(path), .text(message)])
            pendingOperations += 1
            if db.lastInsertRowID % 500 == 0 {
                try db.run("DELETE FROM errors WHERE id <= (SELECT MAX(id) FROM errors) - 5000")
            }
        } catch {
            // The error log must never break scanning.
        }
    }

    func recentErrors(limit: Int = 500) throws -> [ScanErrorEntry] {
        try commit()
        return try db.query("SELECT id, timestamp, path, message FROM errors ORDER BY id DESC LIMIT ?", [.integer(limit)]) {
            ScanErrorEntry(id: $0.int64(0), date: Date(timeIntervalSince1970: $0.double(1)), path: $0.text(2), message: $0.text(3))
        }
    }

    func clearErrors() throws {
        try commit()
        try db.run("DELETE FROM errors")
    }

    // MARK: - Queries

    private static let fileColumns = "f.id, f.name, d.path, f.ext, f.size, f.alloc, f.created, f.modified, f.accessed, f.flags, f.category"

    private static func mapFile(_ s: SQLiteConnection.Statement) -> FileItem {
        FileItem(id: s.int64(0), name: s.text(1), folderPath: s.text(2), fileExtension: s.text(3), size: s.int64(4),
                 allocatedSize: s.int64(5), created: s.optionalDate(6), modified: s.optionalDate(7), accessed: s.optionalDate(8),
                 flags: FileItem.Flags(rawValue: s.int(9)), category: StorageCategory(rawValue: s.int(10)) ?? .other)
    }

    private static let folderColumns = "id, parent_id, path, name, total_alloc, total_size, total_files, total_dirs, direct_alloc, direct_files, modified, restricted, scanned_at"

    private static func mapFolder(_ s: SQLiteConnection.Statement) -> FolderItem {
        FolderItem(id: s.int64(0), parentID: s.optionalInt64(1), path: s.text(2), name: s.text(3), totalAllocated: s.int64(4),
                   totalSize: s.int64(5), fileCount: s.int64(6), folderCount: s.int64(7), directAllocated: s.int64(8),
                   directFileCount: s.int64(9), modified: s.optionalDate(10), isRestricted: s.int(11) != 0, lastScanned: s.optionalDate(12))
    }

    func largestFiles(limit: Int, category: StorageCategory? = nil, within folder: String? = nil, minimumSize: Int64 = 0) throws -> [FileItem] {
        try commit()
        var sql = "SELECT \(Self.fileColumns) FROM files f JOIN folders d ON d.id = f.folder_id WHERE f.alloc >= ?"
        var values: [SQLValue] = [.int(minimumSize)]
        if let category {
            sql += " AND f.category = ?"
            values.append(.integer(category.rawValue))
        }
        if let folder {
            let bounds = Self.subtreeBounds(folder)
            sql += " AND (d.path = ? OR (d.path >= ? AND d.path < ?))"
            values += [.text(folder), .text(bounds.lower), .text(bounds.upper)]
        }
        sql += " ORDER BY f.alloc DESC LIMIT ?"
        values.append(.integer(limit))
        return try db.query(sql, values, map: Self.mapFile)
    }

    func recentLargeFiles(since: Date, minimumSize: Int64, limit: Int) throws -> [FileItem] {
        try commit()
        return try db.query("""
            SELECT \(Self.fileColumns) FROM files f JOIN folders d ON d.id = f.folder_id
            WHERE f.alloc >= ? AND f.modified >= ? ORDER BY f.alloc DESC LIMIT ?
            """, [.int(minimumSize), .double(since.timeIntervalSince1970), .integer(limit)], map: Self.mapFile)
    }

    func files(inFolder folderID: Int64, limit: Int = 200) throws -> [FileItem] {
        try commit()
        return try db.query("SELECT \(Self.fileColumns) FROM files f JOIN folders d ON d.id = f.folder_id WHERE f.folder_id = ? ORDER BY f.alloc DESC LIMIT ?",
                            [.int(folderID), .integer(limit)], map: Self.mapFile)
    }

    func rootFolders() throws -> [FolderItem] {
        try commit()
        return try db.query("SELECT \(Self.folderColumns) FROM folders WHERE parent_id IS NULL ORDER BY total_alloc DESC", map: Self.mapFolder)
    }

    func childFolders(of parentID: Int64, limit: Int = 1_000) throws -> [FolderItem] {
        try commit()
        return try db.query("SELECT \(Self.folderColumns) FROM folders WHERE parent_id = ? ORDER BY total_alloc DESC LIMIT ?",
                            [.int(parentID), .integer(limit)], map: Self.mapFolder)
    }

    func folder(path: String) throws -> FolderItem? {
        try commit()
        return try folderLocked(path: path)
    }

    private func folderLocked(path: String) throws -> FolderItem? {
        try db.query("SELECT \(Self.folderColumns) FROM folders WHERE path = ?", [.text(path)], map: Self.mapFolder).first
    }

    func folder(id: Int64) throws -> FolderItem? {
        try commit()
        return try db.query("SELECT \(Self.folderColumns) FROM folders WHERE id = ?", [.int(id)], map: Self.mapFolder).first
    }

    /// Largest folders at a given depth range (excludes roots), e.g. for the bar chart.
    func largestFolders(limit: Int, maxDepth: Int = 3) throws -> [FolderItem] {
        try commit()
        return try db.query("SELECT \(Self.folderColumns) FROM folders WHERE depth BETWEEN 1 AND ? ORDER BY total_alloc DESC LIMIT ?",
                            [.integer(maxDepth), .integer(limit)], map: Self.mapFolder)
    }

    /// Folders with an exact name. With `outermostOnly`, nested matches (node_modules inside node_modules) are excluded.
    func folders(named name: String, outermostOnly: Bool, limit: Int = 500) throws -> [FolderItem] {
        try commit()
        var sql = "SELECT \(Self.folderColumns) FROM folders WHERE name = ?"
        var values: [SQLValue] = [.text(name)]
        if outermostOnly {
            sql += " AND instr(substr(path, 1, length(path) - length(?) - 1) || '/', ?) = 0"
            values += [.text(name), .text("/" + name + "/")]
        }
        sql += " ORDER BY total_alloc DESC LIMIT ?"
        values.append(.integer(limit))
        return try db.query(sql, values, map: Self.mapFolder)
    }

    func restrictedFolders(limit: Int = 200) throws -> [FolderItem] {
        try commit()
        return try db.query("SELECT \(Self.folderColumns) FROM folders WHERE restricted = 1 ORDER BY depth ASC, path ASC LIMIT ?",
                            [.integer(limit)], map: Self.mapFolder)
    }

    func categoryTotals() throws -> [CategoryUsage] {
        try commit()
        return try db.query("SELECT category, bytes, files FROM category_totals ORDER BY bytes DESC") {
            CategoryUsage(category: StorageCategory(rawValue: $0.int(0)) ?? .other, bytes: $0.int64(1), fileCount: $0.int(2))
        }
    }

    func totals() throws -> ScanTotals {
        try commit()
        return try totalsLocked()
    }

    private func totalsLocked() throws -> ScanTotals {
        let row = try db.query("SELECT IFNULL(SUM(total_files),0), IFNULL(SUM(total_dirs),0), IFNULL(SUM(total_alloc),0), COUNT(*) FROM folders WHERE parent_id IS NULL") {
            ($0.int64(0), $0.int64(1), $0.int64(2), $0.int64(3))
        }.first ?? (0, 0, 0, 0)
        let restricted = try db.scalarInt("SELECT COUNT(*) FROM folders WHERE restricted = 1")
        return ScanTotals(fileCount: row.0, folderCount: row.1 + row.3, allocatedBytes: row.2, restrictedFolders: restricted)
    }

    func lastScan() throws -> ScanRecord? {
        try commit()
        return try db.query("SELECT id, started, finished, status, roots, files, folders, bytes, new_files, changed_files, deleted_files FROM scans ORDER BY id DESC LIMIT 1", map: Self.mapScan).first
    }

    func lastCompletedScan() throws -> ScanRecord? {
        try commit()
        return try db.query("SELECT id, started, finished, status, roots, files, folders, bytes, new_files, changed_files, deleted_files FROM scans WHERE status = 'completed' ORDER BY id DESC LIMIT 1", map: Self.mapScan).first
    }

    /// Marks scans left "running" by a previous app session (e.g. after a crash) as cancelled.
    func recoverInterruptedScans() throws {
        try commit()
        try db.run("UPDATE scans SET status = 'cancelled' WHERE status = 'running'")
    }

    private static func mapScan(_ s: SQLiteConnection.Statement) -> ScanRecord {
        ScanRecord(id: s.int64(0), started: Date(timeIntervalSince1970: s.double(1)), finished: s.optionalDate(2),
                   status: ScanRecord.Status(rawValue: s.text(3)) ?? .failed,
                   roots: s.text(4).split(separator: "\n").map(String.init), fileCount: s.int64(5), folderCount: s.int64(6),
                   bytes: s.int64(7), newFiles: s.int64(8), changedFiles: s.int64(9), deletedFiles: s.int64(10))
    }

    func history(limit: Int = 365) throws -> [StorageHistoryPoint] {
        try commit()
        let points = try db.query("SELECT id, timestamp, volume_total, volume_used, scanned_bytes FROM history ORDER BY timestamp DESC LIMIT ?", [.integer(limit)]) {
            StorageHistoryPoint(id: $0.int64(0), date: Date(timeIntervalSince1970: $0.double(1)), volumeTotal: $0.int64(2),
                                volumeUsed: $0.int64(3), scannedBytes: $0.int64(4))
        }
        return Array(points.reversed())
    }

    // MARK: - Search

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    func searchFiles(_ query: SearchQuery) throws -> [FileItem] {
        try commit()
        var clauses: [String] = []
        var values: [SQLValue] = []
        if let glob = query.nameGlob { clauses.append("lower(f.name) GLOB ?"); values.append(.text(glob.lowercased())) }
        if let text = query.nameContains { clauses.append("f.name LIKE ? ESCAPE '\\'"); values.append(.text("%" + Self.escapeLike(text) + "%")) }
        if let ext = query.fileExtension { clauses.append("f.ext = ?"); values.append(.text(ext.lowercased())) }
        if let folder = query.folderContains { clauses.append("d.path LIKE ? ESCAPE '\\'"); values.append(.text("%" + Self.escapeLike(folder) + "%")) }
        if let min = query.minSize { clauses.append("f.alloc >= ?"); values.append(.int(min)) }
        if let max = query.maxSize { clauses.append("f.alloc <= ?"); values.append(.int(max)) }
        if let before = query.modifiedBefore { clauses.append("f.modified < ?"); values.append(.double(before.timeIntervalSince1970)) }
        if let after = query.modifiedAfter { clauses.append("f.modified >= ?"); values.append(.double(after.timeIntervalSince1970)) }
        if let category = query.category { clauses.append("f.category = ?"); values.append(.integer(category.rawValue)) }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        values.append(.integer(query.limit))
        return try db.query("SELECT \(Self.fileColumns) FROM files f JOIN folders d ON d.id = f.folder_id \(whereClause) ORDER BY f.alloc DESC LIMIT ?",
                            values, map: Self.mapFile)
    }

    func searchFolders(_ query: SearchQuery) throws -> [FolderItem] {
        try commit()
        // Extension and category filters only apply to files.
        guard query.fileExtension == nil, query.category == nil else { return [] }
        var clauses: [String] = []
        var values: [SQLValue] = []
        if let glob = query.nameGlob { clauses.append("lower(name) GLOB ?"); values.append(.text(glob.lowercased())) }
        if let text = query.nameContains { clauses.append("name LIKE ? ESCAPE '\\'"); values.append(.text("%" + Self.escapeLike(text) + "%")) }
        if let folder = query.folderContains { clauses.append("path LIKE ? ESCAPE '\\'"); values.append(.text("%" + Self.escapeLike(folder) + "%")) }
        if let min = query.minSize { clauses.append("total_alloc >= ?"); values.append(.int(min)) }
        if let max = query.maxSize { clauses.append("total_alloc <= ?"); values.append(.int(max)) }
        if let before = query.modifiedBefore { clauses.append("modified < ?"); values.append(.double(before.timeIntervalSince1970)) }
        if let after = query.modifiedAfter { clauses.append("modified >= ?"); values.append(.double(after.timeIntervalSince1970)) }
        guard !clauses.isEmpty else { return [] }
        values.append(.integer(query.limit))
        return try db.query("SELECT \(Self.folderColumns) FROM folders WHERE \(clauses.joined(separator: " AND ")) ORDER BY total_alloc DESC LIMIT ?",
                            values, map: Self.mapFolder)
    }

    // MARK: - Duplicates

    /// Sizes shared by more than one regular file, largest first.
    func duplicateCandidateSizes(minimumSize: Int64, within folder: String?, excluding excluded: [String], limit: Int) throws -> [DuplicateCandidateSize] {
        try commit()
        var sql = "SELECT f.size, COUNT(*) AS c FROM files f"
        var values: [SQLValue] = []
        var clauses = ["f.size >= ?", "(f.flags & \(FileItem.Flags.symlink.rawValue)) = 0"]
        values.append(.int(minimumSize))
        if folder != nil || !excluded.isEmpty {
            sql += " JOIN folders d ON d.id = f.folder_id"
        }
        if let folder {
            let bounds = Self.subtreeBounds(folder)
            clauses.append("(d.path = ? OR (d.path >= ? AND d.path < ?))")
            values += [.text(folder), .text(bounds.lower), .text(bounds.upper)]
        }
        for path in excluded {
            let bounds = Self.subtreeBounds(path)
            clauses.append("NOT (d.path = ? OR (d.path >= ? AND d.path < ?))")
            values += [.text(path), .text(bounds.lower), .text(bounds.upper)]
        }
        sql += " WHERE " + clauses.joined(separator: " AND ") + " GROUP BY f.size HAVING c > 1 ORDER BY f.size DESC LIMIT ?"
        values.append(.integer(limit))
        return try db.query(sql, values) { DuplicateCandidateSize(size: $0.int64(0), count: $0.int(1)) }
    }

    /// Files with an exact logical size, with their inode (0 if not hard-linked).
    func files(withSize size: Int64, within folder: String?, excluding excluded: [String]) throws -> [(file: FileItem, inode: UInt64)] {
        try commit()
        var sql = "SELECT \(Self.fileColumns), f.inode FROM files f JOIN folders d ON d.id = f.folder_id WHERE f.size = ? AND (f.flags & \(FileItem.Flags.symlink.rawValue)) = 0"
        var values: [SQLValue] = [.int(size)]
        if let folder {
            let bounds = Self.subtreeBounds(folder)
            sql += " AND (d.path = ? OR (d.path >= ? AND d.path < ?))"
            values += [.text(folder), .text(bounds.lower), .text(bounds.upper)]
        }
        for path in excluded {
            let bounds = Self.subtreeBounds(path)
            sql += " AND NOT (d.path = ? OR (d.path >= ? AND d.path < ?))"
            values += [.text(path), .text(bounds.lower), .text(bounds.upper)]
        }
        return try db.query(sql, values) { (file: Self.mapFile($0), inode: UInt64(bitPattern: $0.int64(11))) }
    }

    // MARK: - Maintenance

    func databaseFileSize() -> Int64 {
        let paths = [url.path, url.path + "-wal", url.path + "-shm"]
        return paths.reduce(0) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    /// Deletes all cached metadata (the next scan starts fresh).
    func clearAll() throws {
        try commit()
        try db.execute("DELETE FROM files; DELETE FROM folders; DELETE FROM scans; DELETE FROM history; DELETE FROM category_totals; DELETE FROM errors;")
        try db.execute("VACUUM;")
    }
}
