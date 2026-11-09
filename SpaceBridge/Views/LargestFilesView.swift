import SwiftUI

struct LargestFilesView: View {
    @Environment(AppModel.self) private var model

    enum Limit: Hashable, CaseIterable, Identifiable {
        case top10, top50, top100, top500, custom
        var id: Self { self }
        var title: String {
            switch self {
            case .top10: return "Top 10"
            case .top50: return "Top 50"
            case .top100: return "Top 100"
            case .top500: return "Top 500"
            case .custom: return "Custom"
            }
        }
        var isPro: Bool { self == .top500 || self == .custom }
        var count: Int? {
            switch self {
            case .top10: return 10
            case .top50: return 50
            case .top100: return 100
            case .top500: return 500
            case .custom: return nil
            }
        }
    }

    @State private var limit: Limit = .top100
    @State private var customCount = 1000
    @State private var files: [FileItem] = []
    @State private var selection = Set<FileItem.ID>()
    @State private var showInspector = false
    @State private var showChart = true
    @State private var isLoading = false

    private var effectiveCount: Int { limit.count ?? min(max(customCount, 1), 10_000) }
    private var selectedFile: FileItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return files.first { $0.id == id }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Show", selection: $limit) {
                    ForEach(Limit.allCases) { option in
                        Text(option.isPro && !model.pro.isPro ? option.title + " ★" : option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
                if limit == .custom {
                    TextField("Count", value: $customCount, format: .number)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                    Stepper("", value: $customCount, in: 1...10_000, step: 100).labelsHidden()
                }
                Picker("Category", selection: $model.largestFilesCategory) {
                    Text("All Categories").tag(StorageCategory?.none)
                    Divider()
                    ForEach(StorageCategory.allCases) { category in
                        Label(category.displayName, systemImage: category.symbolName).tag(StorageCategory?.some(category))
                    }
                }
                .frame(maxWidth: 240)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Text("\(files.count) files · \(ByteFormatter.string(files.reduce(0) { $0 + $1.allocatedSize }))")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            if files.isEmpty && !isLoading {
                if model.scan.summary.hasScanData {
                    ContentUnavailableView("No files", systemImage: "doc", description: Text("No files match this filter."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScanRequiredView()
                }
            } else {
                VSplitView {
                    if showChart && !files.isEmpty {
                        SizeBarChart(items: files.prefix(10).map {
                            SizeBarItem(id: String($0.id), label: $0.name, bytes: $0.allocatedSize, color: $0.category.color)
                        }) { item in
                            if let id = Int64(item.id) { selection = [id] }
                        }
                        .padding(16)
                        .frame(minHeight: 160, idealHeight: 300)
                    }
                    FileTable(files: files, selection: $selection, showsRank: true)
                        .frame(minHeight: 200)
                }
            }
        }
        .navigationTitle(model.largestFilesCategory.map { "Largest Files — \($0.displayName)" } ?? "Largest Files")
        .inspector(isPresented: $showInspector) {
            Group {
                if let file = selectedFile {
                    FileDetailView(file: file)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Select a file to see its details. Double-click reveals it in Finder."))
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.requirePro(.exportReports) { ReportExporter.saveCSV(files: files, suggestedName: "SpaceBridge Largest Files") }
                } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                .help("Export this list to CSV (Pro)")
                .disabled(files.isEmpty)
                Toggle(isOn: $showChart) { Label("Chart", systemImage: "chart.bar.xaxis") }
                    .help("Show bar chart of the 10 largest files")
                Toggle(isOn: $showInspector) { Label("Details", systemImage: "sidebar.trailing") }
                    .help("Show file details")
            }
        }
        .onChange(of: selection) { _, newValue in
            if newValue.count == 1 { showInspector = true }
        }
        .onChange(of: limit) { oldValue, newValue in
            if newValue.isPro && !model.pro.isUnlocked(.unlimitedLists) {
                limit = oldValue.isPro ? .top100 : oldValue
                model.showPaywall(.unlimitedLists)
            }
        }
        .task(id: LoadKey(count: effectiveCount, category: model.largestFilesCategory, version: model.scan.dataVersion)) {
            await load()
        }
    }

    private struct LoadKey: Equatable {
        var count: Int
        var category: StorageCategory?
        var version: Int
    }

    private func load() async {
        guard let database = model.database else { return }
        isLoading = true
        try? await Task.sleep(for: .milliseconds(150)) // debounce typing in the custom field
        guard !Task.isCancelled else { return }
        files = (try? await database.largestFiles(limit: effectiveCount, category: model.largestFilesCategory)) ?? []
        selection = selection.filter { id in files.contains { $0.id == id } }
        isLoading = false
    }
}

/// File Details inspector.
struct FileDetailView: View {
    @Environment(AppModel.self) private var model
    var file: FileItem
    @State private var details: FileDetails?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(nsImage: FinderActions.icon(for: file.path)).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(file.name).font(.headline).lineLimit(3).textSelection(.enabled)
                        Text(details?.typeDescription ?? FileDetailsLoader.typeDescription(forExtension: file.fileExtension))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 8) {
                    row("Size", ByteFormatter.string(file.allocatedSize) + " on disk")
                    row("Logical size", "\(ByteFormatter.string(details?.logicalSize ?? file.size)) (\((details?.logicalSize ?? file.size).formatted()) bytes)")
                    row("Type", details?.typeIdentifier ?? file.displayType)
                    row("Category", file.category.displayName)
                    row("Created", date(details?.created ?? file.created))
                    row("Modified", date(details?.modified ?? file.modified))
                    row("Last opened", date(details?.accessed ?? file.accessed, unavailable: "Not available"))
                    row("Location", file.folderPath.abbreviatingHome)
                    row("Permissions", details?.posixPermissions ?? "—")
                    row("Owner", [details?.owner, details?.group].compactMap { $0 }.joined(separator: " / ").nonEmpty ?? "—")
                    row("Hidden", (details?.isHidden ?? file.isHidden) ? "Yes" : "No")
                    row("Symbolic link", (details?.isSymlink ?? file.isSymlink) ? "Yes → \(details?.symlinkDestination ?? "?")" : "No")
                    row("Alias", details.map { $0.isAlias ? "Yes" : "No" } ?? "—")
                    if file.isHardLinked {
                        row("Hard link", "Yes — shares storage with another path; counted once in totals")
                    }
                }
                if let details, !details.exists {
                    Label("This file no longer exists. Run a scan to update.", systemImage: "questionmark.folder").foregroundStyle(.orange)
                }
                Divider()
                let safety = details?.safety ?? SecurityUtils.evaluate(path: file.path, checkFileSystem: false)
                VStack(alignment: .leading, spacing: 8) {
                    Button { FinderActions.reveal(file.path) } label: { Label("Reveal in Finder", systemImage: "folder") }
                    Button { FinderActions.copyPaths([file.path]) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                    Button(role: .destructive) {
                        model.requestTrash([TrashCandidate(path: file.path, size: file.allocatedSize, isDirectory: false)])
                    } label: { Label("Move to Trash…", systemImage: "trash") }
                    .disabled(!safety.allowsDestructiveActions || !file.hasValidName)
                    if case .protected(let reason) = safety {
                        Label(reason, systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                    } else if case .caution(let reason) = safety {
                        Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
                .buttonStyle(.link)
            }
            .padding(16)
        }
        .task(id: file.id) {
            let path = file.path
            details = await Task.detached(priority: .userInitiated) { FileDetailsLoader.load(path: path) }.value
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func date(_ date: Date?, unavailable: String = "—") -> String {
        date.map { $0.formatted(date: .long, time: .shortened) } ?? unavailable
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
