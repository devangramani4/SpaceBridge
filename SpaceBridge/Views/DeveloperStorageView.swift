import SwiftUI

struct DeveloperStorageView: View {
    @Environment(AppModel.self) private var model
    @State private var groups: [DeveloperStorageGroup] = []
    @State private var isLoading = false

    var body: some View {
        let total = groups.reduce(Int64(0)) { $0 + $1.total }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionCard("Developer Storage", systemImage: "chevron.left.forwardslash.chevron.right") {
                    if isLoading && groups.isEmpty {
                        ProgressView("Measuring developer folders…")
                    } else {
                        SizeBarChart(items: groups.filter { $0.total > 0 }.map {
                            SizeBarItem(id: $0.name, label: $0.name, bytes: $0.total, color: color(for: $0.name))
                        })
                        HStack {
                            Text("Total").font(.headline)
                            Spacer()
                            Text(ByteFormatter.string(total)).font(.headline).monospacedDigit()
                        }
                    }
                }
                ForEach(groups) { group in
                    SectionCard(group.name, systemImage: group.symbolName) {
                        Text(group.total > 0 ? ByteFormatter.string(group.total) : group.detected ? "" : "Not found")
                            .monospacedDigit().foregroundStyle(.secondary)
                    } content: {
                        if let note = group.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        ForEach(group.items) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                    Text(item.detail ?? item.path.abbreviatingHome).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if item.bytes > 0 {
                                    Text(ByteFormatter.string(item.bytes) + (item.isPartial ? "+" : "")).monospacedDigit()
                                        .help(item.isPartial ? "Some sub-folders couldn't be read; the real size may be larger." : "")
                                }
                            }
                            .contextMenu {
                                if !item.path.isEmpty {
                                    Button("Reveal in Finder") { FinderActions.reveal(item.path) }
                                    Button("Show in Largest Folders") { model.showFolder(item.path) }
                                    Button("Copy Path") { FinderActions.copyPaths([item.path]) }
                                }
                            }
                        }
                    }
                }
                Text("To clean developer storage safely, see Cleanup — it recommends the tool's own commands (for example `docker system prune`) where manual deletion would be risky.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .navigationTitle("Developer Storage")
        .toolbar {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(isLoading)
        }
        .task(id: model.scan.dataVersion) { await load() }
    }

    private func load() async {
        isLoading = true
        groups = await DeveloperStorageAnalyzer(database: model.database).analyze()
        isLoading = false
    }

    private func color(for name: String) -> Color {
        switch name {
        case "Xcode": return StorageCategory.xcode.color
        case "Node.js": return StorageCategory.nodeJS.color
        case "Android": return StorageCategory.android.color
        case "Docker": return StorageCategory.docker.color
        case "Git Repositories": return StorageCategory.git.color
        default: return StorageCategory.developer.color
        }
    }
}
