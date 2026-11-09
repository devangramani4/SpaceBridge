import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var recommendations: [CleanupRecommendation] = []
    @State private var isLoading = false
    @State private var current = ""
    @State private var copiedCommand: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.blue)
                    Text("SpaceBridge never deletes anything automatically. Every action asks for confirmation and moves items to the Trash, where you can restore them. Items are never recommended just because they are large.")
                        .font(.callout)
                }
                .padding(12)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                if !model.pro.isUnlocked(.cleanup) {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(.purple)
                        Text("Free shows what can be cleaned. **SpaceBridge Pro** removes it safely in one click.")
                        Spacer()
                        Button("See Pro") { model.showPaywall(.cleanup) }
                    }
                    .padding(12)
                    .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if isLoading {
                    HStack { ProgressView().controlSize(.small); Text("Checking \(current)…").foregroundStyle(.secondary) }
                }
                ForEach(CleanupSafety.allCases) { safety in
                    let items = recommendations.filter { $0.safety == safety }
                    if !items.isEmpty {
                        SectionCard(safety.rawValue, systemImage: safety.symbolName) {
                            Text(ByteFormatter.string(items.reduce(0) { $0 + $1.bytes })).monospacedDigit().foregroundStyle(.secondary)
                        } content: {
                            ForEach(items) { item in
                                CleanupRow(item: item, copiedCommand: $copiedCommand)
                                if item.id != items.last?.id { Divider() }
                            }
                        }
                    }
                }
                if !isLoading && recommendations.isEmpty {
                    ContentUnavailableView("Nothing to recommend", systemImage: "sparkles", description: Text("No caches, logs or developer artifacts above the reporting thresholds were found."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
        }
        .navigationTitle("Cleanup")
        .toolbar {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(isLoading)
        }
        .task(id: model.scan.dataVersion) { await load() }
    }

    private func load() async {
        isLoading = true
        let analyzer = CleanupAnalyzer(database: model.database)
        recommendations = await analyzer.analyze { name in
            Task { @MainActor in current = name }
        }
        isLoading = false
    }
}

private struct CleanupRow: View {
    @Environment(AppModel.self) private var model
    var item: CleanupRecommendation
    @Binding var copiedCommand: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.symbolName).frame(width: 22).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).fontWeight(.medium)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(item.paths, id: \.self) { path in
                    Text(path.abbreviatingHome).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                if case .command(let command) = item.action {
                    HStack {
                        Text(command).font(.caption.monospaced()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            .textSelection(.enabled)
                        Button(copiedCommand == command ? "Copied" : "Copy Command") {
                            FinderActions.copyPaths([command])
                            copiedCommand = command
                        }
                        .controlSize(.small)
                    }
                    Text("Run this in Terminal. SpaceBridge doesn't run cleanup commands for you.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(ByteFormatter.string(item.bytes) + (item.isPartial ? "+" : "")).font(.headline).monospacedDigit()
                switch item.action {
                case .moveToTrash:
                    Button {
                        model.requirePro(.cleanup) {
                            model.requestTrash(item.paths.map { TrashCandidate(path: $0, size: item.paths.count == 1 ? item.bytes : nil, isDirectory: true, note: item.detail) })
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Move to Trash…")
                            if !model.pro.isUnlocked(.cleanup) { ProBadge() }
                        }
                    }
                    .controlSize(.small)
                case .openInFinder:
                    Button("Open Trash") { FinderActions.openTrash() }.controlSize(.small)
                case .command, .none:
                    EmptyView()
                }
                if let path = item.paths.first {
                    Button("Reveal") { FinderActions.reveal(path) }.buttonStyle(.link).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch item.safety {
        case .safe: return .green
        case .review: return .orange
        case .doNotRemove: return .red
        }
    }
}
