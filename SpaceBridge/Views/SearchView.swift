import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var results = SearchResults()
    @State private var selection = Set<FileItem.ID>()
    @State private var isSearching = false
    @State private var needsPro = false

    private var selectedFile: FileItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return results.files.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchHelp()
            } else if needsPro {
                ProLockedView(feature: .advancedSearch)
            } else if !model.scan.summary.hasScanData && results.applications.isEmpty {
                ScanRequiredView(message: "Search runs against the local scan index — scan once and searches return instantly without walking the disk again.")
            } else {
                HStack {
                    if isSearching { ProgressView().controlSize(.small) }
                    Text("\(results.files.count) files, \(results.folders.count) folders, \(results.applications.count) apps")
                        .foregroundStyle(.secondary)
                    Text(String(format: "in %.0f ms", results.duration * 1000)).font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    if results.files.count >= results.query.limit {
                        Text("Showing the largest \(results.query.limit) matches").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
                if !results.applications.isEmpty || !results.folders.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(results.applications) { app in
                                Button { model.showApplication(app.path) } label: {
                                    Label(app.name, systemImage: "app")
                                }
                            }
                            ForEach(results.folders.prefix(40)) { folder in
                                Button { model.showFolder(folder.path) } label: {
                                    Label("\(folder.name) · \(ByteFormatter.string(folder.totalAllocated))", systemImage: "folder")
                                }
                                .help(folder.path)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    Divider()
                }
                FileTable(files: results.files, selection: $selection)
            }
        }
        .navigationTitle("Search")
        .inspector(isPresented: .constant(selectedFile != nil)) {
            if let file = selectedFile { FileDetailView(file: file).inspectorColumnWidth(min: 260, ideal: 300, max: 400) }
        }
        .task(id: "\(model.searchText)|\(model.scan.dataVersion)|\(model.pro.isPro)") {
            let text = model.searchText.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let database = model.database else { results = SearchResults(); return }
            try? await Task.sleep(for: .milliseconds(250)) // debounce
            guard !Task.isCancelled else { return }
            let parsed = SearchParser.parse(text)
            needsPro = parsed.isAdvanced && !model.pro.isUnlocked(.advancedSearch)
            guard !needsPro else { results = SearchResults(query: parsed); return }
            isSearching = true
            results = await SearchService.run(text, database: database, applications: model.apps.apps)
            isSearching = false
        }
    }
}

private struct SearchHelp: View {
    @Environment(AppModel.self) private var model
    private let examples: [(String, String)] = [
        ("*.zip", "All ZIP archives"),
        ("node_modules", "Files and folders named like node_modules"),
        ("size > 1 GB", "Files larger than 1 GB"),
        ("modified > 1 year ago", "Not modified in the last year"),
        ("ext:mov size > 500MB", "Large movies"),
        ("in:Downloads *.dmg", "Disk images in Downloads"),
        ("kind:folder .git", "Git folders"),
        ("app:Chrome", "Installed applications"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search your Mac").font(.title2.weight(.semibold))
            Text("Type in the search field in the toolbar. Searches use the local index from your last scan, so they're instant and never touch the disk.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(examples, id: \.0) { example in
                    GridRow {
                        Button(example.0) { model.searchText = example.0 }
                            .buttonStyle(.link).font(.body.monospaced())
                        Text(example.1).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(24)
    }
}
