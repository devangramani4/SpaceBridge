import XCTest
@testable import SpaceBridge

final class FileScannerTests: XCTestCase {
    var tree: TemporaryTree!
    var database: StorageDatabase!
    var databaseURL: URL!

    override func setUp() async throws {
        tree = try TemporaryTree()
        let (db, url) = try makeDatabase()
        database = db
        databaseURL = url
    }

    override func tearDown() async throws {
        tree.remove()
        database = nil
        removeDatabase(databaseURL)
    }

    private func scan(concurrency: Int = 2) async throws -> ScanOutcome {
        try await makeScanner(tree, database, concurrency: concurrency).scan(progress: { _ in })
    }

    func testFileSizesAreRecorded() async throws {
        try tree.file("a.bin", size: 10_000)
        try tree.file("b.txt", size: 123)
        let outcome = try await scan()
        XCTAssertEqual(outcome.status, .completed)

        let files = try await database.largestFiles(limit: 10, within: tree.realRoot)
        XCTAssertEqual(files.count, 2)
        let a = try XCTUnwrap(files.first { $0.name == "a.bin" })
        XCTAssertEqual(a.size, 10_000)
        XCTAssertGreaterThanOrEqual(a.allocatedSize, 10_000, "allocated size is whole blocks")
        XCTAssertEqual(a.fileExtension, "bin")
        XCTAssertEqual(a.folderPath, tree.realRoot)
        XCTAssertNotNil(a.modified)
        XCTAssertEqual(files.first?.name, "a.bin", "sorted largest first")
    }

    func testFolderSizesAreRecursive() async throws {
        try tree.file("one/two/three/deep.bin", size: 50_000)
        try tree.file("one/two/mid.bin", size: 20_000)
        try tree.file("one/top.bin", size: 5_000)
        try tree.file("other/x.bin", size: 1_000)
        _ = try await scan()

        let root = try await XCTUnwrapAsync(try await database.folder(path: tree.realRoot))
        let one = try await XCTUnwrapAsync(try await database.folder(path: tree.path("one")))
        let two = try await XCTUnwrapAsync(try await database.folder(path: tree.path("one/two")))
        XCTAssertEqual(one.totalSize, 75_000)
        XCTAssertEqual(two.totalSize, 70_000)
        XCTAssertEqual(root.totalSize, 76_000)
        XCTAssertEqual(root.fileCount, 4)
        XCTAssertEqual(root.folderCount, 4) // one, two, three, other
        XCTAssertEqual(one.fileCount, 3)

        // On-demand calculator agrees with the scan.
        let calculated = FolderAnalyzer.size(of: tree.path("one"))
        XCTAssertEqual(calculated.logicalSize, 75_000)
        XCTAssertEqual(calculated.fileCount, 3)
        XCTAssertEqual(calculated.allocatedSize, one.totalAllocated)

        let children = try await database.childFolders(of: root.id)
        XCTAssertEqual(children.map(\.name), ["one", "other"], "children sorted by size")
    }

    func testIncrementalRescanDetectsNewChangedAndDeletedFiles() async throws {
        try tree.file("keep.bin", size: 1_000)
        try tree.file("change.bin", size: 1_000)
        try tree.file("delete.bin", size: 1_000)
        try tree.file("gone/inner.bin", size: 2_000)
        let first = try await scan()
        XCTAssertEqual(first.progress.newFiles, 4)

        // Second scan with no changes writes nothing.
        let unchanged = try await scan()
        XCTAssertEqual(unchanged.progress.newFiles, 0)
        XCTAssertEqual(unchanged.progress.changedFiles, 0)
        XCTAssertEqual(unchanged.progress.deletedFiles, 0)

        try tree.file("change.bin", size: 9_000)
        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("delete.bin"))
        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("gone"))
        try tree.file("new/added.bin", size: 3_000)
        let third = try await scan()
        XCTAssertEqual(third.progress.newFiles, 1)
        XCTAssertEqual(third.progress.changedFiles, 1)
        XCTAssertEqual(third.progress.deletedFiles, 1)

        let root = try await XCTUnwrapAsync(try await database.folder(path: tree.realRoot))
        XCTAssertEqual(root.totalSize, 1_000 + 9_000 + 3_000)
        let goneFolder = try await database.folder(path: tree.path("gone"))
        XCTAssertNil(goneFolder, "deleted folders are removed from the cache")
        let names = try await database.largestFiles(limit: 10, within: tree.realRoot).map(\.name).sorted()
        XCTAssertEqual(names, ["added.bin", "change.bin", "keep.bin"])
    }

    func testRestrictedFolderIsMarkedAndScanContinues() async throws {
        try XCTSkipIf(getuid() == 0, "root can read everything")
        try tree.file("open/visible.bin", size: 4_000)
        try tree.file("locked/secret.bin", size: 4_000)
        chmod(tree.root.appendingPathComponent("locked").path, 0o000)
        defer { chmod(tree.root.appendingPathComponent("locked").path, 0o755) }

        let outcome = try await scan()
        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.progress.restrictedFolders, 1)
        let locked = try await XCTUnwrapAsync(try await database.folder(path: tree.path("locked")))
        XCTAssertTrue(locked.isRestricted)
        XCTAssertEqual(locked.fileCount, 0)
        let open = try await XCTUnwrapAsync(try await database.folder(path: tree.path("open")))
        XCTAssertEqual(open.totalSize, 4_000)
        let restricted = try await database.restrictedFolders()
        XCTAssertTrue(restricted.contains { $0.path == tree.path("locked") })
        XCTAssertEqual(PermissionManager.check(tree.path("locked")), .denied)
    }

    func testSymlinksAreNotFollowedAndBrokenLinksDontCrash() async throws {
        try tree.file("real/data.bin", size: 100_000)
        try FileManager.default.createSymbolicLink(atPath: tree.root.appendingPathComponent("link-to-real").path, withDestinationPath: tree.path("real"))
        try FileManager.default.createSymbolicLink(atPath: tree.root.appendingPathComponent("broken").path, withDestinationPath: "/nonexistent/\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: tree.root.appendingPathComponent("loop").path, withDestinationPath: tree.realRoot)
        let outcome = try await scan()
        XCTAssertEqual(outcome.status, .completed)

        let root = try await XCTUnwrapAsync(try await database.folder(path: tree.realRoot))
        XCTAssertLessThan(root.totalSize, 200_000, "the symlinked folder isn't counted twice")
        let files = try await database.largestFiles(limit: 10, within: tree.realRoot)
        let links = files.filter(\.isSymlink).map(\.name).sorted()
        XCTAssertEqual(links, ["broken", "link-to-real", "loop"])
    }

    func testHardLinksAreCountedOnce() async throws {
        let original = try tree.file("original.bin", size: 200_000)
        try FileManager.default.linkItem(at: original, to: tree.root.appendingPathComponent("hardlink.bin"))
        _ = try await scan()
        let root = try await XCTUnwrapAsync(try await database.folder(path: tree.realRoot))
        XCTAssertEqual(root.totalSize, 400_000, "logical size counts both names")
        XCTAssertLessThan(root.totalAllocated, 400_000, "allocated space counts the data once")
        let files = try await database.largestFiles(limit: 10, within: tree.realRoot)
        XCTAssertTrue(files.allSatisfy(\.isHardLinked))
    }

    func testCancellationKeepsPartialResultsAndResumeCompletes() async throws {
        for index in 0..<50 { try tree.file("dir\(index)/file.bin", size: 1_000) }
        let scanner = makeScanner(tree, database)
        await scanner.pause() // workers block before reading any folder
        let task = Task { try await scanner.scan(progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let cancelled = try await task.value
        XCTAssertEqual(cancelled.status, .cancelled)
        let last = try await database.lastScan()
        XCTAssertEqual(last?.status, .cancelled)

        let resumed = try await makeScanner(tree, database).scan(resumeScanID: cancelled.scanID, progress: { _ in })
        XCTAssertEqual(resumed.status, .completed)
        XCTAssertEqual(resumed.scanID, cancelled.scanID)
        let root = try await XCTUnwrapAsync(try await database.folder(path: tree.realRoot))
        XCTAssertEqual(root.totalSize, 50_000)
        XCTAssertEqual(root.fileCount, 50)
    }

    func testResumeSkipsAlreadyScannedFolders() async throws {
        for index in 0..<20 { try tree.file("d\(index)/f.bin", size: 500) }
        let full = try await scan()
        // Resuming a scan whose folders are all processed must not re-read or rewrite anything.
        let resumed = try await makeScanner(tree, database).scan(resumeScanID: full.scanID, progress: { _ in })
        XCTAssertEqual(resumed.status, .completed)
        XCTAssertEqual(resumed.progress.newFiles, 0)
        XCTAssertEqual(resumed.progress.changedFiles, 0)
        XCTAssertEqual(resumed.progress.filesScanned, 20)
        XCTAssertEqual(resumed.totals.allocatedBytes, full.totals.allocatedBytes)
    }

    func testPauseAndResume() async throws {
        for index in 0..<10 { try tree.file("p\(index)/f.bin", size: 100) }
        let scanner = makeScanner(tree, database)
        await scanner.pause()
        let task = Task { try await scanner.scan(progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(scanner.counters.snapshot().foldersScanned, 0, "nothing is read while paused")
        await scanner.resume()
        let outcome = try await task.value
        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.progress.foldersScanned, 11)
    }

    func testFileDeletedDuringScanIsHandled() async throws {
        // A folder that disappears between listing and reading must not fail the scan.
        try tree.file("vanishing/a.bin", size: 10)
        let scanner = makeScanner(tree, database, concurrency: 1)
        await scanner.pause()
        let task = Task { try await scanner.scan(progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(100))
        await scanner.resume()
        try? FileManager.default.removeItem(at: tree.root.appendingPathComponent("vanishing"))
        let outcome = try await task.value
        XCTAssertEqual(outcome.status, .completed)
    }

    func testExcludedPathsAreSkipped() async throws {
        try tree.file("include/a.bin", size: 1_000)
        try tree.file("exclude/b.bin", size: 1_000)
        let scanner = FileScanner(database: database, configuration: ScanConfiguration(
            roots: [tree.root.path], excludedPaths: [tree.path("exclude")], maxConcurrency: 2, homeDirectory: "/nonexistent"))
        _ = try await scanner.scan(progress: { _ in })
        let excluded = try await database.folder(path: tree.path("exclude"))
        XCTAssertNil(excluded)
        let root = try await XCTUnwrapAsync(try await database.folder(path: tree.realRoot))
        XCTAssertEqual(root.totalSize, 1_000)
    }

    func testRemovingItemUpdatesCachedTotals() async throws {
        try tree.file("a/x.bin", size: 4_000)
        try tree.file("a/y.bin", size: 6_000)
        try tree.file("b/z.bin", size: 1_000)
        _ = try await scan()
        let y = try await database.largestFiles(limit: 10, within: tree.realRoot).first { $0.name == "y.bin" }!
        try await database.removeItem(path: y.path) // cache-only update; file stays on disk
        var root = try await XCTUnwrapAsync(try await database.folder(path: tree.realRoot))
        XCTAssertEqual(root.totalSize, 5_000)
        try await database.removeItem(path: tree.path("b"))
        root = try await XCTUnwrapAsync(try await database.folder(path: tree.realRoot))
        XCTAssertEqual(root.totalSize, 4_000)
        XCTAssertEqual(root.folderCount, 1)
    }

    func testSearchUsesIndex() async throws {
        try tree.file("downloads/backup.zip", size: 3_000_000)
        try tree.file("downloads/small.zip", size: 10)
        try tree.file("project/node_modules/pkg/index.js", size: 100)
        _ = try await scan()
        let zips = try await database.searchFiles(SearchParser.parse("*.zip"))
            .filter { $0.folderPath.hasPrefix(tree.realRoot) }
        XCTAssertEqual(zips.map(\.name).sorted(), ["backup.zip", "small.zip"])
        let large = try await database.searchFiles(SearchParser.parse("*.zip size > 1 MB")).filter { $0.folderPath.hasPrefix(tree.realRoot) }
        XCTAssertEqual(large.map(\.name), ["backup.zip"])
        let modules = try await database.searchFolders(SearchParser.parse("node_modules")).filter { $0.path.hasPrefix(tree.realRoot) }
        XCTAssertEqual(modules.map(\.name), ["node_modules"])
        let outermost = try await database.folders(named: "node_modules", outermostOnly: true)
        XCTAssertTrue(outermost.contains { $0.path == tree.path("project/node_modules") })
    }

    func testCategoryTotalsAndHistory() async throws {
        try tree.file("clip.mov", size: 50_000)
        try tree.file("archive.zip", size: 20_000)
        _ = try await scan()
        let totals = try await database.categoryTotals()
        // The temp folder lives under /private/var/folders, which is categorized as caches.
        XCTAssertFalse(totals.isEmpty)
        XCTAssertEqual(totals.reduce(0) { $0 + $1.fileCount }, 2)
        _ = try await scan()
        let history = try await database.history()
        XCTAssertEqual(history.count, 2)
    }

    /// Scales with SPACEBRIDGE_LARGE_TEST_FILES (e.g. 1000000). Default: 30,000 files in 300 folders.
    func testLargeDirectoryTreePerformance() async throws {
        let total = Int(ProcessInfo.processInfo.environment["SPACEBRIDGE_LARGE_TEST_FILES"] ?? "") ?? 30_000
        let perFolder = 100
        for folder in 0..<(total / perFolder) {
            let directory = try tree.folder("big/\(folder / 50)/\(folder)")
            for index in 0..<perFolder {
                FileManager.default.createFile(atPath: directory.appendingPathComponent("f\(index).dat").path, contents: nil)
            }
        }
        let start = Date()
        let outcome = try await scan(concurrency: 4)
        let first = Date().timeIntervalSince(start)
        XCTAssertEqual(outcome.progress.filesScanned, Int64(total))

        let rescanStart = Date()
        let rescan = try await scan(concurrency: 4)
        let second = Date().timeIntervalSince(rescanStart)
        XCTAssertEqual(rescan.progress.newFiles, 0)
        print("Scanned \(total) files: first \(String(format: "%.2f", first))s, incremental \(String(format: "%.2f", second))s")
        XCTAssertLessThan(second, first * 1.5 + 1, "an unchanged rescan shouldn't be slower than the first scan")
    }
}

/// `XCTUnwrap` for values produced by async expressions.
func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
