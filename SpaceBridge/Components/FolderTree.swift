import SwiftUI

/// Lazily-loaded folder hierarchy backed by the scan database.
/// Children are fetched only when a folder is expanded, so trees with millions of folders stay cheap.
@MainActor
@Observable
final class FolderTreeModel {
    struct Row: Identifiable, Hashable {
        var folder: FolderItem
        var depth: Int
        var isExpanded: Bool
        var parentTotal: Int64
        var id: Int64 { folder.id }
        var fractionOfParent: Double { parentTotal > 0 ? Double(folder.totalAllocated) / Double(parentTotal) : 0 }
    }

    private(set) var rows: [Row] = []
    private(set) var roots: [FolderItem] = []
    private var childCache: [Int64: [FolderItem]] = [:]
    private var expanded: Set<Int64> = []
    var focusPath: String?
    var isLoading = false

    func load(database: StorageDatabase, focus: String?) async {
        isLoading = true
        childCache.removeAll()
        expanded.removeAll()
        focusPath = focus
        if let focus, let folder = try? await database.folder(path: focus) {
            roots = [folder]
            await expand(folder, database: database)
        } else {
            roots = (try? await database.rootFolders()) ?? []
            focusPath = nil
            if roots.count == 1, let only = roots.first { await expand(only, database: database) }
        }
        rebuild()
        isLoading = false
    }

    func toggle(_ folder: FolderItem, database: StorageDatabase) async {
        if expanded.contains(folder.id) {
            expanded.remove(folder.id)
            rebuild()
        } else {
            await expand(folder, database: database)
            rebuild()
        }
    }

    private func expand(_ folder: FolderItem, database: StorageDatabase) async {
        if childCache[folder.id] == nil {
            childCache[folder.id] = (try? await database.childFolders(of: folder.id, limit: 500)) ?? []
        }
        expanded.insert(folder.id)
    }

    func children(of folder: FolderItem) -> [FolderItem] { childCache[folder.id] ?? [] }

    private func rebuild() {
        var result: [Row] = []
        func add(_ folder: FolderItem, depth: Int, parentTotal: Int64) {
            let isOpen = expanded.contains(folder.id)
            result.append(Row(folder: folder, depth: depth, isExpanded: isOpen, parentTotal: parentTotal))
            guard isOpen else { return }
            for child in childCache[folder.id] ?? [] {
                add(child, depth: depth + 1, parentTotal: folder.totalAllocated)
            }
        }
        let rootTotal = roots.reduce(0) { $0 + $1.totalAllocated }
        for root in roots { add(root, depth: 0, parentTotal: rootTotal) }
        rows = result
    }
}

/// One row of the folder tree with disclosure, size bar and size.
struct FolderTreeRow: View {
    var row: FolderTreeModel.Row
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(row.folder.hasChildren ? 1 : 0)
            .disabled(!row.folder.hasChildren)
            .accessibilityLabel(row.isExpanded ? "Collapse" : "Expand")

            Image(systemName: row.folder.isRestricted ? "lock.fill" : "folder.fill")
                .foregroundStyle(row.folder.isRestricted ? Color.orange : Color.accentColor)
            Text(row.folder.depth0Name).lineLimit(1).truncationMode(.middle)
            if row.folder.isRestricted {
                Text("Access Restricted").font(.caption).foregroundStyle(.orange)
            }
            Spacer(minLength: 12)
            UsageBar(fraction: row.fractionOfParent, height: 6).frame(width: 90)
            Text(PercentFormatter.string(row.fractionOfParent)).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 40, alignment: .trailing)
            Text(ByteFormatter.string(row.folder.totalAllocated)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Text(row.folder.fileCount.formatted() + " files").font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .help(row.folder.path)
    }
}

extension FolderItem {
    /// Roots show their full path; others their name.
    var depth0Name: String { parentID == nil ? path : name }
}
