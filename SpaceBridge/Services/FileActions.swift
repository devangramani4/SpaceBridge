import AppKit
import Foundation
import UniformTypeIdentifiers

/// An item the user asked to move to the Trash. Shown in the confirmation sheet first.
struct TrashCandidate: Identifiable, Sendable, Hashable {
    var path: String
    var name: String
    var size: Int64?
    var isDirectory: Bool
    var note: String?
    var id: String { path }

    init(path: String, size: Int64?, isDirectory: Bool, note: String? = nil) {
        self.path = path
        self.name = path.lastPathComponentString
        self.size = size
        self.isDirectory = isDirectory
        self.note = note
    }
}

struct TrashOutcome: Sendable {
    var trashed: [String] = []
    var failures: [(path: String, reason: String)] = []
    var freedBytes: Int64 = 0
}

/// The only code path in SpaceBridge that modifies the filesystem.
///
/// - Uses `FileManager.trashItem` (recoverable from the Trash). Never deletes permanently.
/// - Re-checks `SecurityUtils.evaluate` for every item immediately before acting.
/// - Must only be called after the user confirmed in `TrashConfirmationSheet`.
enum TrashService {
    static func moveToTrash(_ candidates: [TrashCandidate], database: StorageDatabase?) async -> TrashOutcome {
        var outcome = TrashOutcome()
        for candidate in candidates {
            let safety = SecurityUtils.evaluate(path: candidate.path)
            guard safety.allowsDestructiveActions else {
                outcome.failures.append((path: candidate.path, reason: safety.message ?? SecurityUtils.protectedLabel))
                continue
            }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: candidate.path), resultingItemURL: nil)
                outcome.trashed.append(candidate.path)
                outcome.freedBytes += candidate.size ?? 0
                try? await database?.removeItem(path: candidate.path)
            } catch {
                outcome.failures.append((path: candidate.path, reason: error.localizedDescription))
            }
        }
        return outcome
    }
}

@MainActor
enum FinderActions {
    static func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func reveal(_ path: String) { reveal([path]) }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copyPaths(_ paths: [String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    static func icon(for path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    static func openTrash() {
        let trash = (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
        NSWorkspace.shared.open(trash)
    }
}

enum FileDetailsLoader {
    static func load(path: String) -> FileDetails {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .localizedTypeDescriptionKey, .contentTypeKey, .creationDateKey, .contentModificationDateKey,
            .contentAccessDateKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isAliasFileKey, .isSymbolicLinkKey,
            .isHiddenKey, .isPackageKey,
        ]
        let exists = FileManager.default.fileExists(atPath: path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
        let values = try? url.resourceValues(forKeys: keys)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        var permissions: String?
        if let mode = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value {
            permissions = posixString(mode) + String(format: " (%o)", mode)
        }
        return FileDetails(
            typeDescription: values?.localizedTypeDescription,
            typeIdentifier: values?.contentType?.identifier,
            created: values?.creationDate,
            modified: values?.contentModificationDate,
            accessed: values?.contentAccessDate,
            logicalSize: values?.fileSize.map(Int64.init),
            allocatedSize: values?.totalFileAllocatedSize.map(Int64.init),
            isAlias: (values?.isAliasFile ?? false) && !(values?.isSymbolicLink ?? false),
            isSymlink: values?.isSymbolicLink ?? false,
            symlinkDestination: try? FileManager.default.destinationOfSymbolicLink(atPath: path),
            isHidden: values?.isHidden ?? path.lastPathComponentString.hasPrefix("."),
            isPackage: values?.isPackage ?? false,
            posixPermissions: permissions,
            owner: attributes?[.ownerAccountName] as? String,
            group: attributes?[.groupOwnerAccountName] as? String,
            exists: exists,
            safety: SecurityUtils.evaluate(path: path))
    }

    static func posixString(_ mode: UInt16) -> String {
        let flags: [(UInt16, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"), (0o004, "r"), (0o002, "w"), (0o001, "x")]
        return String(flags.map { mode & $0.0 != 0 ? $0.1 : "-" })
    }

    static func typeDescription(forExtension ext: String) -> String {
        guard !ext.isEmpty else { return "Document" }
        return UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased() + " file"
    }
}
