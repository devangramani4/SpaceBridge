import XCTest
@testable import SpaceBridge

final class DuplicateScannerTests: XCTestCase {
    func testFindsIdenticalFilesOnly() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let (database, url) = try makeDatabase()
        defer { removeDatabase(url) }

        try tree.file("photos/photo.jpg", size: 300_000, byte: 0x11)
        try tree.file("photos/photo-copy.jpg", size: 300_000, byte: 0x11)
        try tree.file("backup/photo-final.jpg", size: 300_000, byte: 0x11)
        // Same size, different content (differs only in the middle → partial hash matches, full hash doesn't).
        var different = Data(repeating: 0x11, count: 300_000)
        different[150_000] = 0x99
        try different.write(to: tree.root.appendingPathComponent("photos/almost.jpg"))
        // Same size and content but a different type is not grouped.
        try tree.file("photos/photo.png", size: 300_000, byte: 0x11)
        // Unique size.
        try tree.file("photos/unique.jpg", size: 123_456, byte: 0x11)
        _ = try await makeScanner(tree, database).scan(progress: { _ in })

        var options = DuplicateScanOptions()
        options.minimumSize = 1_000
        options.scope = tree.realRoot
        options.excluded = []
        let groups = try await DuplicateScanner(database: database, options: options).findDuplicates { _ in }
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(Set(group.files.map(\.name)), ["photo.jpg", "photo-copy.jpg", "photo-final.jpg"])
        XCTAssertEqual(group.potentialSavings, 600_000)
        XCTAssertEqual(group.totalSize, 900_000)
    }

    func testHashing() throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let a = try tree.file("a", size: 1_000_000, byte: 1)
        let b = try tree.file("b", size: 1_000_000, byte: 1)
        let c = try tree.file("c", size: 1_000_000, byte: 2)
        XCTAssertEqual(DuplicateScanner.fullHash(of: a.path), DuplicateScanner.fullHash(of: b.path))
        XCTAssertNotEqual(DuplicateScanner.fullHash(of: a.path), DuplicateScanner.fullHash(of: c.path))
        XCTAssertEqual(DuplicateScanner.partialHash(of: a.path, size: 1_000_000, bytes: 65_536),
                       DuplicateScanner.partialHash(of: b.path, size: 1_000_000, bytes: 65_536))
        XCTAssertNil(DuplicateScanner.fullHash(of: tree.root.path + "/missing"))
    }
}

final class ApplicationScannerTests: XCTestCase {
    func testDetectsBundlesAndReadsMetadata() throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        try makeApp(in: tree, relative: "Demo.app", name: "Demo", identifier: "com.example.demo", version: "1.2.3", machO: universalHeader())
        try makeApp(in: tree, relative: "Utilities/Tool.app", name: "Tool", identifier: "com.example.tool", version: "2.0", machO: thinARM64Header())
        try makeApp(in: tree, relative: "Deep/Deeper/Deepest/Hidden.app", name: "Hidden", identifier: "com.example.hidden", version: "1", machO: Data())
        try tree.folder("Demo.app/Contents/Resources/Nested.app") // apps inside bundles are not listed

        let apps = ApplicationScanner(searchDirectories: [tree.realRoot]).scanApplications()
        XCTAssertEqual(apps.map(\.name), ["Demo", "Tool"], "search depth is limited and bundles are never entered")
        let demo = try XCTUnwrap(apps.first)
        XCTAssertEqual(demo.bundleIdentifier, "com.example.demo")
        XCTAssertEqual(demo.version, "1.2.3")
        XCTAssertEqual(demo.architectureLabel, "Universal")
        XCTAssertEqual(apps[1].architectures, [.arm64])
        XCTAssertNotEqual(demo.signature, .notChecked)
    }

    func testMachOParsing() {
        XCTAssertEqual(MachOInspector.architectures(fromHeader: universalHeader()), [.x86_64, .arm64])
        XCTAssertEqual(MachOInspector.architectures(fromHeader: thinARM64Header()), [.arm64])
        XCTAssertEqual(MachOInspector.architectures(fromHeader: Data([0x00, 0x01, 0x02])), [])
        // Java class files share the 0xCAFEBABE magic; a huge "count" must be rejected.
        XCTAssertEqual(MachOInspector.architectures(fromHeader: Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x34])), [])
    }

    func testDeveloperNameParsing() {
        XCTAssertEqual(ApplicationScanner.developerName(fromCertificateSummary: "Developer ID Application: Google LLC (EQHXZ8M8AV)"), "Google LLC")
        XCTAssertEqual(ApplicationScanner.developerName(fromCertificateSummary: "Software Signing"), "Apple")
        XCTAssertNil(ApplicationScanner.developerName(fromCertificateSummary: "Apple Mac OS Application Signing"))
    }

    func testRealApplicationsFolderIsReadable() {
        let apps = ApplicationScanner().scanApplications()
        XCTAssertFalse(apps.isEmpty, "/System/Applications always contains apps")
        XCTAssertTrue(apps.contains { $0.isSystemApp && $0.developer == "Apple" })
    }

    private func makeApp(in tree: TemporaryTree, relative: String, name: String, identifier: String, version: String, machO: Data) throws {
        let plist: [String: Any] = ["CFBundleName": name, "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": name]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let contents = tree.root.appendingPathComponent(relative).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try machO.write(to: contents.appendingPathComponent("MacOS/\(name)"))
    }

    private func universalHeader() -> Data {
        var bytes: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2]
        bytes += [0x01, 0x00, 0x00, 0x07] + [UInt8](repeating: 0, count: 16) // x86_64
        bytes += [0x01, 0x00, 0x00, 0x0C] + [UInt8](repeating: 0, count: 16) // arm64
        return Data(bytes)
    }

    private func thinARM64Header() -> Data {
        Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0, 0, 0, 0])
    }
}

final class SystemMonitorTests: XCTestCase {
    func testMemoryFiguresAreConsistent() throws {
        let memory = try XCTUnwrap(MemoryMonitor().sample())
        XCTAssertEqual(memory.total, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(memory.used, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
        XCTAssertLessThanOrEqual(memory.wired, memory.total)
        XCTAssertEqual(memory.available + memory.used, memory.total)
        XCTAssertTrue([4096, 16384].contains(memory.pageSize))
        XCTAssertNotNil(memory.swapTotal, "vm.swapusage is readable without privileges")
        XCTAssertNotEqual(memory.pressure, .unknown)
    }

    func testCPUSnapshotMath() {
        let previous = [CoreTicks(user: 100, system: 50, idle: 850, nice: 0), CoreTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        let current = [CoreTicks(user: 160, system: 70, idle: 870, nice: 0), CoreTicks(user: 10, system: 10, idle: 1080, nice: 0)]
        let snapshot = CPUMonitor.snapshot(previous: previous, current: current)
        // Core 0: 80 busy of 100; core 1: 20 busy of 100.
        XCTAssertEqual(snapshot.perCore[0], 0.8, accuracy: 0.0001)
        XCTAssertEqual(snapshot.perCore[1], 0.2, accuracy: 0.0001)
        XCTAssertEqual(snapshot.user, 70.0 / 200.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.system, 30.0 / 200.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.idle, 100.0 / 200.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.total, 0.5, accuracy: 0.0001)
    }

    func testCPUCounterResetIsIgnored() {
        let previous = [CoreTicks(user: 500, system: 500, idle: 500, nice: 0)]
        let current = [CoreTicks(user: 10, system: 10, idle: 10, nice: 0)]
        let snapshot = CPUMonitor.snapshot(previous: previous, current: current)
        XCTAssertEqual(snapshot.perCore, [0])
        XCTAssertEqual(snapshot.total, 0)
    }

    func testLiveCPUSampling() async throws {
        let monitor = CPUMonitor()
        let first = await monitor.sample()
        XCTAssertNil(first, "the first call only primes the counters")
        try await Task.sleep(for: .milliseconds(300))
        let second = try await XCTUnwrapAsync(await monitor.sample())
        XCTAssertEqual(second.perCore.count, CPUMonitor.readTicks()?.count)
        XCTAssertEqual(second.user + second.system + second.idle + second.nice, 1, accuracy: 0.01)
        XCTAssertGreaterThan(second.logicalCores, 0)
    }

    func testProcessMonitorSeesItself() async throws {
        let monitor = ProcessMonitor()
        _ = await monitor.sample()
        // Burn a little CPU so the delta is non-zero.
        var x = 0.0
        for i in 0..<3_000_000 { x += sin(Double(i)) }
        XCTAssertTrue(x.isFinite)
        try await Task.sleep(for: .milliseconds(200))
        let processes = await monitor.sample()
        let me = try XCTUnwrap(processes.first { $0.pid == getpid() })
        XCTAssertNotNil(me.memoryBytes)
        XCTAssertGreaterThan(me.memoryBytes ?? 0, 1_000_000)
        XCTAssertNotNil(me.cpuPercent)
        XCTAssertGreaterThan(me.threadCount ?? 0, 0)
        XCTAssertEqual(me.ownerUID, getuid())
        XCTAssertTrue(processes.contains { $0.pid == 1 }, "launchd is always listed, even if its metrics are restricted")
    }

    func testAppUsageAggregatesHelpers() {
        let main = ProcessSnapshot(pid: 10, parentPID: 1, name: "Browser", executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
                                   ownerUID: 501, cpuPercent: 5, memoryBytes: 100, state: .running)
        let helper = ProcessSnapshot(pid: 11, parentPID: 10, name: "Helper", executablePath: "/Applications/Browser.app/Contents/Frameworks/H.app/Contents/MacOS/H",
                                     ownerUID: 501, cpuPercent: 2.5, memoryBytes: 50, state: .running)
        let other = ProcessSnapshot(pid: 12, parentPID: 1, name: "BrowserX", executablePath: "/Applications/BrowserX.app/Contents/MacOS/BrowserX",
                                    ownerUID: 501, cpuPercent: 50, memoryBytes: 999, state: .running)
        let usage = ProcessMonitor.usage(forAppAt: "/Applications/Browser.app", in: [main, helper, other])
        XCTAssertEqual(usage.processCount, 2)
        XCTAssertEqual(usage.memoryBytes, 150)
        XCTAssertEqual(usage.cpuPercent, 7.5, accuracy: 0.001)
        XCTAssertEqual(main.appBundlePath, "/Applications/Browser.app")
    }
}

final class PermissionTests: XCTestCase {
    func testCheckReportsStatuses() throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        try tree.folder("readable")
        XCTAssertEqual(PermissionManager.check(tree.path("readable")), .granted)
        XCTAssertEqual(PermissionManager.check(tree.path("missing")), .notFound)
        try tree.file("file.txt", size: 1)
        XCTAssertEqual(PermissionManager.check(tree.path("file.txt")), .granted)
    }

    func testSystemDatabasesAreRestricted() throws {
        try XCTSkipIf(getuid() == 0)
        // /private/var/db/sudo is root-only on every macOS install.
        XCTAssertEqual(PermissionManager.check("/private/var/db/sudo"), .denied)
    }
}
