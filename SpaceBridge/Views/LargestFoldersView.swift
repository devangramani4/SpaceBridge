import SwiftUI

struct LargestFoldersView: View {
    @Environment(AppModel.self) private var model
    @State private var tree = FolderTreeModel()
    @State private var selection: FolderItem.ID?
    @State private var showChart = true
    @State private var showPermissionHelp = false

    private var selectedFolder: FolderItem? {
        tree.rows.first { $0.id == selection }?.folder
    }

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(path: tree.focusPath) { path in
                model.largestFoldersFocus = path
            }
            Divider()
            if tree.rows.isEmpty && !tree.isLoading {
                ScanRequiredView()
            } else {
                VSplitView {
                    if showChart, let root = tree.roots.first {
                        let children = tree.focusPath == nil && tree.roots.count > 1 ? tree.roots : tree.children(of: root)
                        SizeBarChart(items: children.prefix(12).map {
                            SizeBarItem(id: $0.path, label: $0.depth0Name, bytes: $0.totalAllocated, color: $0.isRestricted ? .orange : .accentColor)
                        }) { item in
                            model.largestFoldersFocus = item.id
                        }
                        .padding(16)
                        .frame(minHeight: 160, idealHeight: 280)
                    }
                    List(selection: $selection) {
                        ForEach(tree.rows) { row in
                            FolderTreeRow(row: row) { toggle(row.folder) }
                                .tag(row.id)
                                .contextMenu { folderMenu(row.folder) }
                        }
                    }
                    .onKeyPress(.rightArrow) {
                        guard let folder = selectedFolder, tree.rows.first(where: { $0.id == folder.id })?.isExpanded == false else { return .ignored }
                        toggle(folder); return .handled
                    }
                    .onKeyPress(.leftArrow) {
                        guard let folder = selectedFolder, tree.rows.first(where: { $0.id == folder.id })?.isExpanded == true else { return .ignored }
                        toggle(folder); return .handled
                    }
                    .contextMenu(forSelectionType: FolderItem.ID.self) { _ in } primaryAction: { ids in
                        if let id = ids.first, let folder = tree.rows.first(where: { $0.id == id })?.folder {
                            if folder.isRestricted { showPermissionHelp = true } else { model.largestFoldersFocus = folder.path }
                        }
                    }
                    .frame(minHeight: 220)
                }
            }
        }
        .navigationTitle("Largest Folders")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showChart) { Label("Chart", systemImage: "chart.bar.xaxis") }
                if let folder = selectedFolder {
                    Button { FinderActions.reveal(folder.path) } label: { Label("Reveal in Finder", systemImage: "folder") }
                }
            }
        }
        .overlay { if tree.isLoading { ProgressView() } }
        .task(id: "\(model.largestFoldersFocus ?? "")|\(model.scan.dataVersion)") {
            guard let database = model.database else { return }
            await tree.load(database: database, focus: model.largestFoldersFocus)
        }
        .sheet(isPresented: $showPermissionHelp) { PermissionHelpSheet() }
    }

    private func toggle(_ folder: FolderItem) {
        guard let database = model.database else { return }
        Task { await tree.toggle(folder, database: database) }
    }

    @ViewBuilder
    private func folderMenu(_ folder: FolderItem) -> some View {
        Button("Show Contents") { model.largestFoldersFocus = folder.path }
        Button("Reveal in Finder") { FinderActions.reveal(folder.path) }
        Button("Copy Path") { FinderActions.copyPaths([folder.path]) }
        Button("Largest Files in This Folder") {
            model.largestFilesCategory = nil
            model.selection = .search
            model.searchText = "in:\"\(folder.path)\""
        }
        Divider()
        let safety = SecurityUtils.evaluate(path: folder.path)
        Button("Move to Trash…") {
            model.requestTrash([TrashCandidate(path: folder.path, size: folder.totalAllocated, isDirectory: true,
                                               note: "\(folder.fileCount.formatted()) files in \(folder.folderCount.formatted()) folders")])
        }
        .disabled(!safety.allowsDestructiveActions)
        if !safety.allowsDestructiveActions { Text(SecurityUtils.protectedLabel) }
    }
}

private struct BreadcrumbBar: View {
    var path: String?
    var onSelect: (String?) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button("All Locations") { onSelect(nil) }.buttonStyle(.link)
            if let path {
                let components = path.split(separator: "/").map(String.init)
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    let target = "/" + components[0...index].joined(separator: "/")
                    if index == components.count - 1 {
                        Text(component).fontWeight(.semibold)
                    } else {
                        Button(component) { onSelect(target) }.buttonStyle(.link)
                    }
                }
                Spacer()
                Button { onSelect(path.deletingLastPathComponentString == "/" ? nil : path.deletingLastPathComponentString) } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
