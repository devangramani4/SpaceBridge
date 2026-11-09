import Foundation

/// One directory entry, read with a single `lstat` call (symlinks are never followed).
struct RawDirectoryEntry: Sendable {
    enum Kind: Sendable { case file, directory, symlink, other }

    var name: String
    /// `false` if the on-disk name is not valid UTF-8. Such entries are counted but no actions are offered.
    var hasValidName: Bool
    var kind: Kind
    /// Logical size (`st_size`).
    var size: Int64
    /// Space actually allocated on disk (`st_blocks * 512`).
    var allocatedSize: Int64
    var modified: TimeInterval
    var created: TimeInterval
    var accessed: TimeInterval
    var linkCount: UInt16
    var inode: UInt64
    var device: Int32
    var flags: UInt32

    static let hiddenFlag: UInt32 = 0x0000_8000 // UF_HIDDEN

    var isHidden: Bool { name.hasPrefix(".") || flags & Self.hiddenFlag != 0 }
}

enum DirectoryReadError: Error, Equatable, Sendable {
    /// EACCES / EPERM: macOS privacy protection or file permissions.
    case accessDenied
    /// ENOENT / ENOTDIR: deleted or replaced while scanning.
    case vanished
    case other(Int32)

    init(errno code: Int32) {
        switch code {
        case EACCES, EPERM: self = .accessDenied
        case ENOENT, ENOTDIR: self = .vanished
        default: self = .other(code)
        }
    }

    var localizedDescription: String {
        switch self {
        case .accessDenied: return "Access restricted"
        case .vanished: return "Removed during scan"
        case .other(let code): return String(cString: strerror(code))
        }
    }
}

/// Low-level, allocation-light directory reader built on `opendir`/`readdir`/`fstatat`.
///
/// This avoids creating a `URL` and resource-value dictionary for every one of potentially
/// millions of files, which keeps memory use and CPU time low during a full-disk scan.
enum DirectoryReader {
    /// Reads metadata of the item at `path` itself without following symlinks.
    static func stat(path: String) -> Result<RawDirectoryEntry, DirectoryReadError> {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return .failure(DirectoryReadError(errno: errno)) }
        let name = (path as NSString).lastPathComponent
        return .success(entry(name: name, validName: true, info: info))
    }

    /// Lists a directory. Calls `body` for each entry; never throws for individual entries
    /// (an entry that vanishes between `readdir` and `fstatat` is silently skipped).
    static func read(path: String, _ body: (RawDirectoryEntry) -> Void) -> Result<Void, DirectoryReadError> {
        guard let directory = opendir(path) else {
            return .failure(DirectoryReadError(errno: errno))
        }
        defer { closedir(directory) }
        let descriptor = dirfd(directory)

        while true {
            errno = 0
            guard let pointer = readdir(directory) else {
                // errno != 0 means a read error mid-directory; return what we have.
                break
            }
            let nameLength = Int(pointer.pointee.d_namlen)
            var info = Darwin.stat()
            var resolvedName = ""
            var valid = true
            var statOK = false

            withUnsafeBytes(of: pointer.pointee.d_name) { raw in
                guard let base = raw.baseAddress else { return }
                let bytes = UnsafeRawBufferPointer(start: base, count: min(nameLength, raw.count))
                // Skip "." and ".."
                if nameLength == 1 && bytes[0] == 0x2E { return }
                if nameLength == 2 && bytes[0] == 0x2E && bytes[1] == 0x2E { return }

                let decoded = String(decoding: bytes, as: UTF8.self)
                valid = decoded.utf8.count == nameLength && !decoded.contains("\u{FFFD}")
                resolvedName = decoded
                let cName = base.assumingMemoryBound(to: CChar.self)
                statOK = fstatat(descriptor, cName, &info, AT_SYMLINK_NOFOLLOW) == 0
            }
            guard statOK else { continue }
            body(entry(name: resolvedName, validName: valid, info: info))
        }
        return .success(())
    }

    private static func entry(name: String, validName: Bool, info: Darwin.stat) -> RawDirectoryEntry {
        let kind: RawDirectoryEntry.Kind
        switch info.st_mode & 0o170000 {
        case 0o040000: kind = .directory
        case 0o100000: kind = .file
        case 0o120000: kind = .symlink
        default: kind = .other
        }
        return RawDirectoryEntry(
            name: name,
            hasValidName: validName,
            kind: kind,
            size: Int64(info.st_size),
            allocatedSize: Int64(info.st_blocks) * 512,
            modified: interval(info.st_mtimespec),
            created: interval(info.st_birthtimespec),
            accessed: interval(info.st_atimespec),
            linkCount: UInt16(info.st_nlink),
            inode: UInt64(info.st_ino),
            device: Int32(info.st_dev),
            flags: UInt32(info.st_flags)
        )
    }

    private static func interval(_ spec: timespec) -> TimeInterval {
        TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000
    }
}

/// Thread-safe set used to count hard-linked files only once.
final class HardLinkTracker: @unchecked Sendable {
    private struct Key: Hashable { let device: Int32; let inode: UInt64 }
    private var seen = Set<Key>()
    private let lock = NSLock()

    /// Returns `true` the first time a (device, inode) pair is seen.
    func firstOccurrence(device: Int32, inode: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(Key(device: device, inode: inode)).inserted
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.count
    }
}
