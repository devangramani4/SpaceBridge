import SwiftUI

struct DuplicateView: View {
    @Environment(AppModel.self) private var model
    @State private var groups: [DuplicateGroup] = []
    @State private var progress = DuplicateScanProgress()
    @State private var task: Task<Void, Never>?
    @State private var minimumSizeMB = 1.0
    @State private var includeLibrary = false
    @State private var selectedPaths = Set<String>()
    @State private var hasRun = false

    private var isRunning: Bool { task != nil }
    private var totalSavings: Int64 { groups.reduce(0) { $0 + $1.potentialSavings } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Minimum size")
                TextField("MB", value: $minimumSizeMB, format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                Text("MB")
                Toggle("Include ~/Library", isOn: $includeLibrary).toggleStyle(.checkbox)
                    .help("App data often contains intentional copies. Leave off unless you know what you're looking for.")
                Spacer()
                if isRunning {
                    ProgressView(value: Double(progress.candidatesChecked), total: Double(max(progress.candidatesTotal, 1))).frame(width: 140)
                    Text(progress.stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Stop") { task?.cancel() }
                } else {
                    Button("Find Duplicates") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.database == nil || !model.scan.summary.hasScanData)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            if !model.scan.summary.hasScanData {
                ScanRequiredView(message: "Duplicate detection uses the scan index to compare sizes first, so only likely duplicates are ever read.")
            } else if groups.isEmpty {
                ContentUnavailableView {
                    Label(hasRun ? "No duplicates found" : "Find duplicate files", systemImage: "square.on.square")
                } description: {
                    Text("Files are compared by size, then file type, then a partial hash, and only then a full SHA-256 hash. Nothing is ever deleted automatically.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        HStack {
                            Text("\(groups.count) duplicate groups")
                            Spacer()
                            Text("Potential savings: \(ByteFormatter.string(totalSavings))").fontWeight(.semibold)
                        }
                    }
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.files) { file in
                                HStack {
                                    Toggle(isOn: Binding(get: { selectedPaths.contains(file.path) }, set: { on in
                                        if on { selectedPaths.insert(file.path) } else { selectedPaths.remove(file.path) }
                                    })) { EmptyView() }
                                    .toggleStyle(.checkbox)
                                    .disabled(!canSelect(file, in: group))
                                    Image(systemName: file.category.symbolName).foregroundStyle(file.category.color)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(file.name)
                                        Text(file.folderPath.abbreviatingHome).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                    }
                                    Spacer()
                                    Text(file.modified?.formatted(date: .abbreviated, time: .omitted) ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                .contextMenu { FileContextMenu(files: [file]) }
                                .onTapGesture(count: 2) { FinderActions.reveal(file.path) }
                            }
                        } header: {
                            HStack {
                                Text("\(group.files.count) copies · \(ByteFormatter.string(group.size)) each")
                                Spacer()
                                Text("Total: \(ByteFormatter.string(group.totalSize)) · Potential savings: \(ByteFormatter.string(group.potentialSavings))")
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Text("Select copies to remove. At least one copy in every group is always kept.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Move \(selectedPaths.count) Selected to Trash…") { trashSelected() }
                        .disabled(selectedPaths.isEmpty)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .navigationTitle("Duplicates")
        .onDisappear { task?.cancel() }
    }

    /// Prevents selecting every copy in a group.
    private func canSelect(_ file: FileItem, in group: DuplicateGroup) -> Bool {
        if selectedPaths.contains(file.path) { return true }
        let selectedInGroup = group.files.filter { selectedPaths.contains($0.path) }.count
        return selectedInGroup < group.files.count - 1 && SecurityUtils.evaluate(path: file.path, checkFileSystem: false).allowsDestructiveActions
    }

    private func trashSelected() {
        var candidates: [TrashCandidate] = []
        for group in groups {
            let chosen = group.files.filter { selectedPaths.contains($0.path) }
            guard chosen.count < group.files.count else { continue } // never all copies
            candidates += chosen.map { TrashCandidate(path: $0.path, size: $0.allocatedSize, isDirectory: false, note: "Duplicate of \(group.files.count - 1) other cop\(group.files.count - 1 == 1 ? "y" : "ies")") }
        }
        model.requestTrash(candidates)
        selectedPaths.removeAll()
    }

    private func start() {
        guard let database = model.database else { return }
        var options = DuplicateScanOptions()
        options.minimumSize = Int64(max(minimumSizeMB, 0.001) * 1_000_000)
        if includeLibrary { options.excluded = [NSHomeDirectory() + "/.Trash"] }
        let scanner = DuplicateScanner(database: database, options: options)
        groups = []
        selectedPaths = []
        task = Task {
            let found = (try? await scanner.findDuplicates { update in
                Task { @MainActor in progress = update }
            }) ?? []
            groups = found
            hasRun = true
            task = nil
        }
    }
}
