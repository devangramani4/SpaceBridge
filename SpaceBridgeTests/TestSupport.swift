import Foundation
import XCTest
@testable import SpaceBridge

/// Creates an isolated directory tree under the temporary directory and removes it afterwards.
/// Tests only ever create and delete files inside their own temporary folder — never user data.
final class TemporaryTree {
    let root: URL
    /// The root with symlinks resolved (/var → /private/var), as the scanner records it.
    var realRoot: String { SecurityUtils.realPath(root.path) ?? root.path }

    init(name: String = UUID().uuidString) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceBridgeTests-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { remove() }

    func remove() {
        // Restore permissions changed by tests so cleanup can succeed.
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in enumerator {
                chmod(root.appendingPathComponent(relative).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ relative: String, size: Int = 0, byte: UInt8 = 0x41) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: byte, count: size).write(to: url)
        return url
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func path(_ relative: String) -> String { realRoot + "/" + relative }
}

func makeDatabase() throws -> (StorageDatabase, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceBridgeTests-\(UUID().uuidString).sqlite")
    return (try StorageDatabase(url: url), url)
}

func removeDatabase(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
}

func makeScanner(_ tree: TemporaryTree, _ database: StorageDatabase, concurrency: Int = 2) -> FileScanner {
    FileScanner(database: database, configuration: ScanConfiguration(roots: [tree.root.path], maxConcurrency: concurrency, homeDirectory: "/nonexistent-home"))
}
