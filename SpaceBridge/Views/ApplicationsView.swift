import AppKit
import SwiftUI

struct AppRow: Identifiable, Hashable {
    var info: ApplicationInfo
    var size: Int64?
    var usage: ApplicationUsage
    var id: String { info.id }
    var name: String { info.name }
    var sizeSortKey: Int64 { size ?? -1 }
    var memorySortKey: Int64 { usage.isRunning ? usage.memoryBytes : -1 }
    var cpuSortKey: Double { usage.isRunning ? usage.cpuPercent : -1 }
    var statusSortKey: Int { usage.isRunning ? 1 : 0 }
    var versionSortKey: String { info.version ?? "" }
    var developerSortKey: String { info.developer ?? "~" }
    var archSortKey: String { info.architectureLabel }

    static func == (lhs: AppRow, rhs: AppRow) -> Bool {
        lhs.id == rhs.id && lhs.size == rhs.size && lhs.usage == rhs.usage
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ApplicationsView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder: [KeyPathComparator<AppRow>] = [KeyPathComparator(\.sizeSortKey, order: .reverse)]
    @State private var selection: AppRow.ID?
    @State private var filter = ""
    @State private var showSystemApps = true
    @State private var showChart = false
    @State private var showInspector = false

    private var rows: [AppRow] {
        model.apps.apps
            .filter { showSystemApps || !$0.isSystemApp }
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(filter) ?? false) }
            .map { AppRow(info: $0, size: model.apps.size(of: $0), usage: model.monitor.usage(forAppAt: $0.path)) }
    }

    var body: some View {
        let rows = self.rows.sorted(using: sortOrder)
        VStack(spacing: 0) {
            ExplanationBanner()
            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 200)
                Toggle("Apple apps", isOn: $showSystemApps).toggleStyle(.checkbox).fixedSize()
                    .help("Include apps that ship with macOS")
                Spacer(minLength: 8)
                if model.apps.sizingProgress.done < model.apps.sizingProgress.total {
                    ProgressView(value: Double(model.apps.sizingProgress.done), total: Double(max(model.apps.sizingProgress.total, 1)))
                        .frame(width: 70)
                        .help("Measuring app sizes…")
                }
                Text("\(rows.count) apps · \(ByteFormatter.string(rows.reduce(0) { $0 + ($1.size ?? 0) }))")
                    .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            VSplitView {
                if showChart {
                    SizeBarChart(items: rows.sorted { $0.sizeSortKey > $1.sizeSortKey }.prefix(15).map {
                        SizeBarItem(id: $0.id, label: $0.name, bytes: $0.size ?? 0, color: .purple)
                    }) { item in selection = item.id }
                    .padding(16)
                    .frame(minHeight: 160, idealHeight: 320)
                }
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Application", value: \.name) { row in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: row.info.path)).resizable().frame(width: 18, height: 18)
                            Text(row.name).lineLimit(1)
                        }
                        .help(row.info.path)
                    }
                    .width(min: 130, ideal: 200)
                    TableColumn("Version", value: \.versionSortKey) { Text($0.info.displayVersion).foregroundStyle(.secondary).lineLimit(1) }
                        .width(min: 50, ideal: 80)
                    TableColumn("Developer", value: \.developerSortKey) { Text($0.info.developer ?? "—").foregroundStyle(.secondary).lineLimit(1) }
                        .width(min: 60, ideal: 120)
                    TableColumn("App Size", value: \.sizeSortKey) { row in
                        Text(row.size.map { ByteFormatter.string($0) } ?? "…").monospacedDigit()
                    }
                    .width(min: 62, ideal: 80).alignment(.trailing)
                    TableColumn("RAM", value: \.memorySortKey) { row in
                        usageText(row) { ByteFormatter.string($0.memoryBytes) }
                    }
                    .width(min: 70, ideal: 85).alignment(.trailing)
                    TableColumn("CPU", value: \.cpuSortKey) { row in
                        usageText(row) { String(format: "%.1f%%", $0.cpuPercent) }
                    }
                    .width(min: 50, ideal: 65).alignment(.trailing)
                    TableColumn("Status", value: \.statusSortKey) { row in
                        if row.usage.isRunning {
                            Label("Running", systemImage: "circle.fill").labelStyle(TintedLabelStyle(tint: .green)).font(.caption)
                        } else {
                            Text("Not Running").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 64, ideal: 84)
                    TableColumn("Architecture", value: \.archSortKey) { Text($0.info.architectureLabel).foregroundStyle(.secondary) }
                        .width(min: 60, ideal: 90)
                }
                .contextMenu(forSelectionType: AppRow.ID.self) { ids in
                    if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                        Button("Open") { FinderActions.open(row.info.path) }
                        Button("Reveal in Finder") { FinderActions.reveal(row.info.path) }
                        Button("Copy Path") { FinderActions.copyPaths([row.info.path]) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { FinderActions.reveal(id) }
                }
                .frame(minHeight: 240)
            }
        }
        .navigationTitle("Applications")
        .inspector(isPresented: $showInspector) {
            Group {
                if let id = selection, let row = rows.first(where: { $0.id == id }) {
                    AppDetailView(app: row.info)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "square.grid.2x2", description: Text("Select an app to see its details and storage breakdown."))
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showChart) { Label("Size Chart", systemImage: "chart.bar.xaxis") }
                Button { Task { await model.apps.reload(database: model.database) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.apps.isLoading)
                Toggle(isOn: $showInspector) { Label("Details", systemImage: "sidebar.trailing") }
            }
        }
        .onChange(of: selection) { _, newValue in
            if newValue != nil { showInspector = true }
        }
        .overlay { if model.apps.isLoading && model.apps.apps.isEmpty { ProgressView("Finding applications…") } }
        .onAppear {
            model.monitor.subscribe(processes: true)
            if let path = model.selectedApplicationPath { selection = path; model.selectedApplicationPath = nil }
        }
        .onDisappear { model.monitor.unsubscribe(processes: true) }
        .task { await model.apps.loadIfNeeded(database: model.database) }
    }

    @ViewBuilder
    private func usageText(_ row: AppRow, _ format: (ApplicationUsage) -> String) -> some View {
        if !row.usage.isRunning {
            Text("—").foregroundStyle(.tertiary)
        } else if row.usage.restrictedProcessCount == row.usage.processCount {
            RestrictedText(isRestricted: true)
        } else {
            Text(format(row.usage)).monospacedDigit()
        }
    }
}

private struct ExplanationBanner: View {
    @AppStorage("hideAppSizeExplanation") private var hidden = false

    var body: some View {
        if !hidden {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Size and RAM are different things.").font(.subheadline.weight(.semibold))
                    Text("**App Size** = disk space of the .app bundle. **RAM** = memory its running processes use right now.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button { hidden = true } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.blue.opacity(0.08))
        }
    }
}

struct AppDetailView: View {
    @Environment(AppModel.self) private var model
    var app: ApplicationInfo
    @State private var breakdown: ApplicationStorageBreakdown?
    @State private var confirmQuit: (force: Bool, app: NSRunningApplication)?

    var body: some View {
        let usage = model.monitor.usage(forAppAt: app.path)
        let bundleSize = model.apps.bundleSizes[app.path]
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.title3.weight(.semibold))
                        Text(app.displayVersion).foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 6) {
                    detail("Developer", app.developer ?? (app.isAppStoreApp ? "Mac App Store (developer name not in signature)" : "Unknown"))
                    detail("Bundle ID", app.bundleIdentifier ?? "—")
                    detail("Team ID", app.teamIdentifier ?? "—")
                    detail("Architecture", app.architectureLabel)
                    detail("Minimum macOS", app.minimumSystemVersion ?? "—")
                    detail("Last opened", app.lastUsed.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not available (Spotlight has no record)")
                    detail("Location", app.path.abbreviatingHome)
                    detail("Signature", (model.apps.signatureChecks[app.path] ?? app.signature).label)
                }
                Button("Verify Code Signature") { Task { await model.apps.validateSignature(app) } }
                    .controlSize(.small)
                    .help("Checks the whole bundle against its signature. Can take a while for large apps.")

                SectionCard("Disk", systemImage: "internaldrive") {
                    metric("Application Bundle Size", bundleSize.map { ByteFormatter.string($0.allocatedSize) + ($0.isPartial ? " (partial)" : "") } ?? "Measuring…",
                           note: "Space the .app bundle occupies on disk.")
                }
                SectionCard("Memory & CPU — right now", systemImage: "memorychip") {
                    if usage.isRunning {
                        metric("RAM", usage.restrictedProcessCount == usage.processCount ? "Restricted" : ByteFormatter.string(usage.memoryBytes),
                               note: "Physical memory footprint of \(usage.processCount) process\(usage.processCount == 1 ? "" : "es")\(usage.restrictedProcessCount > 0 ? " (\(usage.restrictedProcessCount) not readable)" : "").")
                        metric("CPU", String(format: "%.1f%%", usage.cpuPercent), note: "100% = one full CPU core.")
                        metric("Processes", "\(usage.processCount)", note: nil)
                    } else {
                        Text("Not running — it uses no RAM or CPU.").foregroundStyle(.secondary)
                    }
                }
                SectionCard("Storage Breakdown", systemImage: "chart.bar.doc.horizontal") {
                    if !model.pro.isUnlocked(.appStorageBreakdown) {
                        Text("See how much data, cache and logs this app keeps in ~/Library.").foregroundStyle(.secondary)
                        Button { model.showPaywall(.appStorageBreakdown) } label: {
                            HStack { Text("Unlock with Pro"); ProBadge() }
                        }
                    } else if let breakdown {
                        let bundle = bundleSize?.allocatedSize ?? 0
                        metric("Application", ByteFormatter.string(bundle), note: nil)
                        ForEach(breakdown.entries) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.kind.rawValue)
                                    Text(entry.path.abbreviatingHome).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(ByteFormatter.string(entry.bytes) + (entry.isPartial ? "+" : "")).monospacedDigit()
                            }
                            .contextMenu {
                                Button("Reveal in Finder") { FinderActions.reveal(entry.path) }
                            }
                        }
                        Divider()
                        HStack {
                            Text("Total").fontWeight(.semibold)
                            Spacer()
                            Text(ByteFormatter.string(bundle + breakdown.total)).monospacedDigit().fontWeight(.semibold)
                        }
                        Text("Application data is matched by bundle ID and name in ~/Library. Apps may store data elsewhere too.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button { FinderActions.open(app.path) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                    Button { FinderActions.reveal(app.path) } label: { Label("Reveal in Finder", systemImage: "folder") }
                    if let running = usage.pids.lazy.compactMap({ NSRunningApplication(processIdentifier: $0) }).first {
                        Button { confirmQuit = (force: false, app: running) } label: { Label("Quit…", systemImage: "xmark.circle") }
                        Button { confirmQuit = (force: true, app: running) } label: { Label("Force Quit…", systemImage: "exclamationmark.octagon") }
                    }
                    let safety = SecurityUtils.evaluate(path: app.path)
                    Button(role: .destructive) {
                        model.requestTrash([TrashCandidate(path: app.path, size: bundleSize?.allocatedSize, isDirectory: true,
                                                           note: usage.isRunning ? "Quit the app before moving it to the Trash." : nil)])
                    } label: { Label("Move App to Trash…", systemImage: "trash") }
                    .disabled(!safety.allowsDestructiveActions || app.isSystemApp || usage.isRunning)
                    if app.isSystemApp { Text(SecurityUtils.protectedLabel).font(.caption).foregroundStyle(.secondary) }
                }
                .buttonStyle(.link)
            }
            .padding(16)
        }
        .task(id: "\(app.path)|\(model.pro.isPro)") {
            if model.pro.isUnlocked(.appStorageBreakdown) { await loadBreakdown() }
        }
        .confirmationDialog(confirmQuit?.force == true ? "Force quit \(app.name)?" : "Quit \(app.name)?",
                            isPresented: Binding(get: { confirmQuit != nil }, set: { if !$0 { confirmQuit = nil } })) {
            if let pending = confirmQuit {
                Button(pending.force ? "Force Quit" : "Quit", role: pending.force ? .destructive : nil) {
                    _ = pending.force ? pending.app.forceTerminate() : pending.app.terminate()
                    confirmQuit = nil
                }
            }
            Button("Cancel", role: .cancel) { confirmQuit = nil }
        } message: {
            Text(confirmQuit?.force == true ? "Unsaved changes in \(app.name) will be lost." : "\(app.name) may ask you to save changes.")
        }
    }

    private func loadBreakdown() async {
        breakdown = nil
        let locations = ApplicationScanner.dataLocations(for: app)
        var entries: [ApplicationStorageBreakdown.Entry] = []
        for location in locations {
            if Task.isCancelled { return }
            let size = await FolderAnalyzer.cachedOrCalculatedSize(of: location.path, database: model.database)
            entries.append(.init(kind: location.kind, path: location.path, bytes: size.allocatedSize, isPartial: size.isPartial))
        }
        breakdown = ApplicationStorageBreakdown(entries: entries.sorted { $0.bytes > $1.bytes })
    }

    @ViewBuilder
    private func detail(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metric(_ title: String, _ value: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value).font(.headline).monospacedDigit()
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
