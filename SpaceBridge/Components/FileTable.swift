import SwiftUI

/// Sortable table of files with native context menu, double-click to reveal in Finder,
/// and confirmation-gated Move to Trash.
struct FileTable: View {
    @Environment(AppModel.self) private var model
    var files: [FileItem]
    @Binding var selection: Set<FileItem.ID>
    var showsRank = false

    @State private var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\.allocatedSize, order: .reverse)]

    private var sortedFiles: [FileItem] {
        files.sorted(using: sortOrder)
    }

    private var ranks: [FileItem.ID: Int] {
        Dictionary(uniqueKeysWithValues: files.sorted { $0.allocatedSize > $1.allocatedSize }.enumerated().map { ($1.id, $0 + 1) })
    }

    var body: some View {
        let ranks = showsRank ? self.ranks : [:]
        Table(sortedFiles, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { file in
                HStack(spacing: 6) {
                    if showsRank, let rank = ranks[file.id] {
                        Text("\(rank).").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 28, alignment: .trailing)
                    }
                    Image(systemName: file.isSymlink ? "link" : file.category.symbolName)
                        .foregroundStyle(file.category.color)
                        .frame(width: 16)
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    if file.isHidden {
                        Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.tertiary).help("Hidden file")
                    }
                }
                .help(file.path)
            }
            .width(min: 180, ideal: 300)

            TableColumn("Size", value: \.allocatedSize) { file in
                Text(ByteFormatter.string(file.allocatedSize)).monospacedDigit()
                    .help("\(file.allocatedSize.formatted()) bytes on disk · \(file.size.formatted()) bytes logical")
            }
            .width(min: 70, ideal: 90)
            .alignment(.trailing)

            TableColumn("Type", value: \.typeSortKey) { file in
                Text(file.displayType).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)

            TableColumn("Category", value: \.category.displayName) { file in
                Text(file.category.displayName).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Modified", value: \.modifiedSortKey) { file in
                Text(file.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140)

            TableColumn("Created", value: \.createdSortKey) { file in
                Text(file.created.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Location", value: \.folderPath) { file in
                Text(file.folderPath.abbreviatingHome).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .width(min: 160, ideal: 280)
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            let chosen = files.filter { ids.contains($0.id) }
            FileContextMenu(files: chosen)
        } primaryAction: { ids in
            FinderActions.reveal(files.filter { ids.contains($0.id) }.map(\.path))
        }
        .onDeleteCommand {
            let chosen = files.filter { selection.contains($0.id) }
            model.requestTrash(chosen.map { TrashCandidate(path: $0.path, size: $0.allocatedSize, isDirectory: false) })
        }
    }
}

/// Context menu actions shared by file lists.
struct FileContextMenu: View {
    @Environment(AppModel.self) private var model
    var files: [FileItem]

    var body: some View {
        if !files.isEmpty {
            Button("Reveal in Finder") { FinderActions.reveal(files.map(\.path)) }
            if files.count == 1 {
                Button("Open") { FinderActions.open(files[0].path) }
            }
            Button(files.count == 1 ? "Copy Path" : "Copy \(files.count) Paths") { FinderActions.copyPaths(files.map(\.path)) }
            Button("Show Enclosing Folder Size") { model.showFolder(files[0].folderPath) }
            Divider()
            let allowed = files.filter { SecurityUtils.evaluate(path: $0.path).allowsDestructiveActions && $0.hasValidName }
            Button(allowed.count == files.count ? "Move to Trash…" : "Move to Trash… (\(allowed.count) of \(files.count) allowed)") {
                model.requestTrash(allowed.map { TrashCandidate(path: $0.path, size: $0.allocatedSize, isDirectory: false) })
            }
            .disabled(allowed.isEmpty)
            if allowed.isEmpty {
                Text(SecurityUtils.protectedLabel)
            }
        }
    }
}
