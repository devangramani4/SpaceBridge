import XCTest
@testable import SpaceBridge

final class ByteFormatterTests: XCTestCase {
    func testFormatsDecimalUnits() {
        XCTAssertEqual(ByteFormatter.string(0), "0 bytes")
        XCTAssertEqual(ByteFormatter.string(1), "1 byte")
        XCTAssertEqual(ByteFormatter.string(999), "999 bytes")
        XCTAssertEqual(ByteFormatter.string(1_500), "1.50 KB")
        XCTAssertEqual(ByteFormatter.string(18_400_000_000), "18.4 GB")
        XCTAssertEqual(ByteFormatter.string(500_000_000_000), "500.0 GB")
        XCTAssertEqual(ByteFormatter.string(2_000_000_000_000), "2.00 TB")
        XCTAssertEqual(ByteFormatter.string(650_000_000), "650.0 MB")
    }

    func testForcedUnits() {
        XCTAssertEqual(ByteFormatter.string(1_000_000_000, unit: .mb), "1000.0 MB")
        XCTAssertEqual(ByteFormatter.string(1_000, unit: .kb), "1.00 KB")
        XCTAssertEqual(ByteUnit.bestFit(for: 5_000_000), .mb)
    }

    func testParsing() {
        XCTAssertEqual(ByteFormatter.parse("1GB"), 1_000_000_000)
        XCTAssertEqual(ByteFormatter.parse("1.5 gb"), 1_500_000_000)
        XCTAssertEqual(ByteFormatter.parse("500 MB"), 500_000_000)
        XCTAssertEqual(ByteFormatter.parse("200k"), 200_000)
        XCTAssertEqual(ByteFormatter.parse("4096"), 4096)
        XCTAssertEqual(ByteFormatter.parse("2 TB"), 2_000_000_000_000)
        XCTAssertNil(ByteFormatter.parse("lots"))
        XCTAssertNil(ByteFormatter.parse(""))
    }
}

final class StorageCategorizerTests: XCTestCase {
    let categorizer = StorageCategorizer(homeDirectory: "/Users/dev")

    func category(_ path: String) -> StorageCategory { categorizer.category(forFilePath: path) }

    func testDeveloperPaths() {
        XCTAssertEqual(category("/Users/dev/Library/Developer/Xcode/DerivedData/App-abc/Build/x.o"), .xcode)
        XCTAssertEqual(category("/Users/dev/Library/Developer/CoreSimulator/Devices/X/data.img"), .xcode)
        XCTAssertEqual(category("/Users/dev/Projects/web/node_modules/react/index.js"), .nodeJS)
        XCTAssertEqual(category("/Users/dev/.npm/_cacache/content/abc"), .npm)
        XCTAssertEqual(category("/Users/dev/Library/Caches/Yarn/v6/pkg.tgz"), .yarn)
        XCTAssertEqual(category("/Users/dev/Library/pnpm/store/v3/files/00/abc"), .pnpm)
        XCTAssertEqual(category("/Users/dev/code/app/.git/objects/pack/pack-1.pack"), .git)
        XCTAssertEqual(category("/Users/dev/.gradle/caches/modules-2/x.jar"), .android)
        XCTAssertEqual(category("/Users/dev/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"), .docker)
        XCTAssertEqual(category("/Users/dev/.orbstack/data/img"), .docker)
    }

    func testSystemAndLibrary() {
        XCTAssertEqual(category("/System/Library/Frameworks/AppKit.framework/AppKit"), .system)
        XCTAssertEqual(category("/usr/lib/libSystem.dylib"), .system)
        XCTAssertEqual(category("/Users/dev/Library/Caches/com.spotify.client/data"), .caches)
        XCTAssertEqual(category("/Users/dev/Library/Logs/DiagnosticReports/crash.ips"), .logs)
        XCTAssertEqual(category("/Users/dev/Library/Application Support/MobileSync/Backup/ABC/Manifest.db"), .iOSBackups)
        XCTAssertEqual(category("/Applications/Safari.app/Contents/MacOS/Safari"), .applications)
        XCTAssertEqual(category("/Applications/Xcode.app/Contents/MacOS/Xcode"), .xcode)
    }

    func testUserFoldersAndTypes() {
        XCTAssertEqual(category("/Users/dev/Downloads/setup.dmg"), .archives, "archives win over location")
        XCTAssertEqual(category("/Users/dev/Downloads/notes.txt"), .downloads)
        XCTAssertEqual(category("/Users/dev/Documents/report.pdf"), .documents)
        XCTAssertEqual(category("/Users/dev/Desktop/screenshot.png"), .desktop)
        XCTAssertEqual(category("/Users/dev/Pictures/whatever.bin"), .photos)
        XCTAssertEqual(category("/Users/dev/somewhere/clip.mov"), .videos)
        XCTAssertEqual(category("/Users/dev/somewhere/song.flac"), .music)
        XCTAssertEqual(category("/Users/dev/somewhere/disk.qcow2"), .virtualMachines)
        XCTAssertEqual(category("/Users/dev/somewhere/main.swift"), .developer)
    }

    func testUnknownIsOther() {
        XCTAssertEqual(category("/Users/dev/random/blob.xyz"), .other)
        XCTAssertEqual(category("/Users/dev/random/noextension"), .other)
    }

    func testCategoryRawValuesAreStable() {
        // Persisted in the database: changing these breaks existing caches.
        XCTAssertEqual(StorageCategory.other.rawValue, 0)
        XCTAssertEqual(StorageCategory.xcode.rawValue, 9)
        XCTAssertEqual(StorageCategory.system.rawValue, 22)
    }
}

final class SecurityUtilsTests: XCTestCase {
    let home = "/Users/dev"

    func evaluate(_ path: String) -> PathSafety {
        SecurityUtils.evaluate(path: path, homeDirectory: home, additionalProtected: ["/Applications/SpaceBridge.app"], checkFileSystem: false)
    }

    func testSystemPathsAreProtected() {
        for path in ["/System", "/System/Library/CoreServices/Finder.app", "/usr/bin/swift", "/bin/ls", "/sbin/launchd",
                     "/private/var/db/dyld", "/var/db/x", "/etc/hosts", "/usr", "/Library/LaunchDaemons/x.plist",
                     "/", "/Applications", "/Users", "/Library"] {
            XCTAssertFalse(evaluate(path).allowsDestructiveActions, path)
        }
    }

    func testCaseAndTraversalTricksAreProtected() {
        XCTAssertFalse(evaluate("/system/library/kernels/kernel").allowsDestructiveActions)
        XCTAssertFalse(evaluate("/Users/dev/Downloads/../../../usr/bin").allowsDestructiveActions)
        XCTAssertFalse(evaluate("/USR/BIN/ls").allowsDestructiveActions)
        XCTAssertFalse(evaluate("relative/path").allowsDestructiveActions)
    }

    func testStandardFoldersCannotBeTrashedButContentsCan() {
        XCTAssertFalse(evaluate("/Users/dev").allowsDestructiveActions)
        XCTAssertFalse(evaluate("/Users/dev/Documents").allowsDestructiveActions)
        XCTAssertFalse(evaluate("/Users/dev/Library/Caches").allowsDestructiveActions)
        XCTAssertEqual(evaluate("/Users/dev/Downloads/big.zip"), .allowed)
        XCTAssertEqual(evaluate("/Users/dev/Library/Caches/com.example.app"), .allowed)
        XCTAssertEqual(evaluate("/Users/dev/Library/Developer/Xcode/DerivedData"), .allowed)
    }

    func testAccountDataIsProtected() {
        XCTAssertFalse(evaluate("/Users/dev/Library/Keychains/login.keychain-db").allowsDestructiveActions)
        XCTAssertFalse(evaluate("/Users/dev/Library/Mail/V10").allowsDestructiveActions)
        XCTAssertFalse(evaluate("/Users/other/Documents/file.txt").allowsDestructiveActions)
        XCTAssertFalse(evaluate("/Applications/SpaceBridge.app").allowsDestructiveActions, "own bundle")
    }

    func testCautionLocations() {
        if case .caution = evaluate("/Applications/Some.app") {} else { XCTFail("apps need a warning") }
        if case .caution = evaluate("/Users/dev/Library/Mobile Documents/com~apple~CloudDocs/file") {} else { XCTFail("iCloud needs a warning") }
    }

    func testFileSystemChecksRejectMissingItems() {
        let result = SecurityUtils.evaluate(path: "/Users/dev/definitely-missing-\(UUID().uuidString)", homeDirectory: home, additionalProtected: [], checkFileSystem: true)
        XCTAssertFalse(result.allowsDestructiveActions)
    }

    func testCriticalProcessesAreProtected() {
        let uid = getuid()
        XCTAssertFalse(SecurityUtils.evaluateProcess(pid: 1, name: "launchd", executablePath: "/sbin/launchd", ownerUID: 0, currentUID: uid).canTerminate)
        XCTAssertFalse(SecurityUtils.evaluateProcess(pid: 400, name: "WindowServer", executablePath: nil, ownerUID: uid, currentUID: uid).canTerminate)
        XCTAssertFalse(SecurityUtils.evaluateProcess(pid: 500, name: "helper", executablePath: "/usr/libexec/helper", ownerUID: uid, currentUID: uid).canTerminate)
        XCTAssertFalse(SecurityUtils.evaluateProcess(pid: 501, name: "other", executablePath: "/Applications/X.app/Contents/MacOS/X", ownerUID: uid + 1, currentUID: uid).canTerminate)
        XCTAssertFalse(SecurityUtils.evaluateProcess(pid: getpid(), name: "SpaceBridge", executablePath: nil, ownerUID: uid, currentUID: uid).canTerminate)
        XCTAssertTrue(SecurityUtils.evaluateProcess(pid: 99_999, name: "TextEdit", executablePath: "/Applications/TextEdit.app/Contents/MacOS/TextEdit", ownerUID: uid, currentUID: uid).canTerminate)
    }
}

final class SearchParserTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testExtensionGlob() {
        let query = SearchParser.parse("*.zip", now: now)
        XCTAssertEqual(query.fileExtension, "zip")
        XCTAssertNil(query.nameGlob)
    }

    func testComplexGlob() {
        XCTAssertEqual(SearchParser.parse("report-??.pdf").nameGlob, "report-??.pdf")
    }

    func testNameContains() {
        XCTAssertEqual(SearchParser.parse("node_modules").nameContains, "node_modules")
        XCTAssertEqual(SearchParser.parse("\"my report\"").nameContains, "my report")
    }

    func testSizeFilters() {
        XCTAssertEqual(SearchParser.parse("Size > 1 GB").minSize, 1_000_000_000)
        XCTAssertEqual(SearchParser.parse("size<500MB").maxSize, 500_000_000)
        let combined = SearchParser.parse("ext:mov size >= 2gb")
        XCTAssertEqual(combined.fileExtension, "mov")
        XCTAssertEqual(combined.minSize, 2_000_000_000)
        XCTAssertNil(combined.nameContains)
    }

    func testDateFilters() {
        let old = SearchParser.parse("Modified > 1 year ago", now: now)
        XCTAssertNotNil(old.modifiedBefore)
        XCTAssertNil(old.nameContains, "no leftover tokens")
        XCTAssertEqual(old.modifiedBefore!.timeIntervalSince1970, Calendar.current.date(byAdding: .year, value: -1, to: now)!.timeIntervalSince1970, accuracy: 1)
        let recent = SearchParser.parse("modified < 7 days ago", now: now)
        XCTAssertEqual(recent.modifiedAfter!.timeIntervalSince1970, now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970, accuracy: 3_600)
        XCTAssertNotNil(SearchParser.parse("modified > 3 months ago", now: now).modifiedBefore)
    }

    func testPrefixes() {
        let query = SearchParser.parse("in:Downloads kind:folder app:Chrome")
        XCTAssertEqual(query.folderContains, "Downloads")
        XCTAssertEqual(query.kind, .folders)
        XCTAssertEqual(query.applicationName, "Chrome")
    }
}
