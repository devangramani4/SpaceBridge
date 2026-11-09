import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 12)]

    var body: some View {
        let summary = model.scan.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = model.databaseError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if model.scan.isScanning || model.scan.progress.phase == .cancelled {
                    ScanProgressView()
                }
                DiskOverviewCard(summary: summary)

                LazyVGrid(columns: columns, spacing: 12) {
                    MetricCard(title: "Files", value: summary.hasScanData ? CountFormatter.string(summary.totals.fileCount) : "—",
                               detail: summary.hasScanData ? nil : "Run a scan", systemImage: "doc.on.doc")
                    MetricCard(title: "Folders", value: summary.hasScanData ? CountFormatter.string(summary.totals.folderCount) : "—",
                               detail: summary.totals.restrictedFolders > 0 ? "\(summary.totals.restrictedFolders.formatted()) access restricted" : nil,
                               systemImage: "folder", tint: .blue)
                    MetricCard(title: "Applications", value: model.apps.isLoading ? "…" : CountFormatter.string(model.apps.apps.count),
                               detail: "Installed .app bundles", systemImage: "square.grid.2x2", tint: .purple) {
                        model.selection = .applications
                    }
                    MetricCard(title: "Largest File", value: summary.largestFile.map { ByteFormatter.string($0.allocatedSize) } ?? "—",
                               detail: summary.largestFile?.name, systemImage: "doc.badge.ellipsis", tint: .orange) {
                        model.showCategory(nil)
                    }
                    MetricCard(title: "Largest Folder", value: summary.largestFolder.map { ByteFormatter.string($0.totalAllocated) } ?? "—",
                               detail: summary.largestFolder?.path.abbreviatingHome, systemImage: "folder.badge.gearshape", tint: .teal) {
                        if let path = summary.largestFolder?.path { model.showFolder(path) }
                    }
                }

                if summary.hasScanData {
                    HStack(alignment: .top, spacing: 16) {
                        SectionCard("Storage by Category", systemImage: "chart.pie") {
                            CategoryOverview(summary: summary)
                        }
                        .frame(minWidth: 420)
                        SectionCard("Recently Modified Large Files", systemImage: "clock.arrow.circlepath") {
                            RecentFilesList(files: summary.recentLargeFiles)
                        }
                    }
                    SectionCard("Storage Trend", systemImage: "chart.xyaxis.line") {
                        if summary.history.count >= 2 {
                            StorageTrendChart(history: summary.history).frame(height: 160)
                        } else {
                            Text("A trend appears after two or more completed scans. Each scan records how much of your disk was used.")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !model.scan.isScanning {
                    SectionCard("Get Started", systemImage: "sparkle.magnifyingglass") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SpaceBridge scans the folders on your Mac to show exactly what uses space. The first scan may take a few minutes; later scans only update what changed.")
                            Text("macOS may ask for permission to read Documents, Desktop and Downloads. For a complete picture (Mail, Messages, Safari, backups), grant Full Disk Access.")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Scan Mac") { model.scan.startScan() }.buttonStyle(.borderedProminent)
                                Button("Storage Access…") { model.selection = .permissions }
                            }
                        }
                    }
                }
                PrivacyNotice().padding(.top, 4)
            }
            .padding(20)
        }
        .navigationTitle("Dashboard")
        .task { await model.scan.refreshSummary() }
    }
}

private struct DiskOverviewCard: View {
    var summary: StorageSummary

    var body: some View {
        SectionCard("Mac Storage", systemImage: "internaldrive") {
            if let volume = summary.volume {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(volume.name).font(.title2.weight(.semibold))
                        Text(volume.formatDescription ?? "").foregroundStyle(.secondary)
                        Spacer()
                        Text(PercentFormatter.string(volume.usedFraction) + " used").font(.title3).monospacedDigit()
                    }
                    StackedCapacityBar(volume: volume, categories: summary.categories)
                    HStack(spacing: 28) {
                        figure("Used", volume.used)
                        figure("Available", volume.available)
                        figure("Total", volume.totalCapacity)
                        if volume.purgeable > 0 {
                            figure("Purgeable", volume.purgeable).help("Space macOS can free automatically (included in Available).")
                        }
                        if let unattributed = summary.unattributedBytes {
                            figure("System & Unscanned", unattributed)
                                .help("Used space the scan could not attribute to files: macOS system volumes, APFS snapshots, purgeable data and folders macOS doesn't let SpaceBridge read.")
                        }
                    }
                }
            } else {
                Text("Disk capacity is unavailable.").foregroundStyle(.secondary)
            }
        }
    }

    private func figure(_ title: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(ByteFormatter.string(bytes)).font(.headline).monospacedDigit()
        }
    }
}

/// Capacity bar segmented by the largest categories.
struct StackedCapacityBar: View {
    var volume: VolumeInfo
    var categories: [CategoryUsage]

    var body: some View {
        GeometryReader { geometry in
            let total = max(Double(volume.totalCapacity), 1)
            let top = Array(categories.prefix(8))
            let attributed = top.reduce(Int64(0)) { $0 + $1.bytes }
            let rest = max(volume.used - attributed, 0)
            HStack(spacing: 1) {
                ForEach(top) { usage in
                    Rectangle().fill(usage.category.color)
                        .frame(width: geometry.size.width * Double(min(usage.bytes, volume.totalCapacity)) / total)
                        .help("\(usage.category.displayName): \(ByteFormatter.string(usage.bytes))")
                }
                Rectangle().fill(Color.gray.opacity(0.5))
                    .frame(width: geometry.size.width * Double(rest) / total)
                    .help("Other used space: \(ByteFormatter.string(rest))")
                Rectangle().fill(.quaternary)
            }
            .clipShape(Capsule())
        }
        .frame(height: 14)
    }
}

/// Donut chart plus legend; clicking opens Largest Files filtered by that category.
struct CategoryOverview: View {
    @Environment(AppModel.self) private var model
    var summary: StorageSummary
    var limit = 10

    var body: some View {
        let shown = Array(summary.categories.prefix(limit))
        let total = summary.categories.reduce(Int64(0)) { $0 + $1.bytes }
        HStack(alignment: .top, spacing: 20) {
            CategoryDonutChart(usages: shown, centerTitle: "Scanned", centerValue: ByteFormatter.string(total)) { category in
                model.showCategory(category)
            }
            .frame(width: 200, height: 200)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown) { usage in
                    Button {
                        model.showCategory(usage.category)
                    } label: {
                        HStack {
                            Circle().fill(usage.category.color).frame(width: 9, height: 9)
                            Text(usage.category.displayName)
                            Spacer()
                            Text(ByteFormatter.string(usage.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(usage.category.detectionNote)
                }
                Text("Categories come from folder locations and file types. Unmatched files are counted as Other.")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
            }
        }
    }
}

private struct RecentFilesList: View {
    @Environment(AppModel.self) private var model
    var files: [FileItem]

    var body: some View {
        if files.isEmpty {
            Text("No files over 100 MB were modified in the last 30 days.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(files) { file in
                    HStack {
                        Image(systemName: file.category.symbolName).foregroundStyle(file.category.color).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                            Text(file.modified.map { $0.formatted(.relative(presentation: .named)) } ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteFormatter.string(file.allocatedSize)).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { FinderActions.reveal(file.path) }
                    .contextMenu { FileContextMenu(files: [file]) }
                    .help(file.path)
                }
            }
        }
    }
}

struct ScanProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.scan.progress
        SectionCard(title, systemImage: "magnifyingglass") {
            HStack(spacing: 12) {
                if progress.phase == .cancelled {
                    Button("Resume") { model.scan.startScan(resume: true) }.disabled(model.scan.resumableScanID == nil)
                } else {
                    Button(model.scan.isPaused ? "Continue" : "Pause") {
                        model.scan.isPaused ? model.scan.resume() : model.scan.pause()
                    }
                    Button("Cancel", role: .cancel) { model.scan.cancel() }
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if progress.phase.isActive {
                    ProgressView().progressViewStyle(.linear)
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        stat("Files scanned", CountFormatter.string(progress.filesScanned))
                        stat("Folders scanned", CountFormatter.string(progress.foldersScanned))
                        stat("Storage analyzed", ByteFormatter.string(progress.bytesAnalyzed))
                        stat("Elapsed", Duration.seconds(progress.elapsed).formatted(.time(pattern: .minuteSecond)))
                    }
                    GridRow {
                        stat("New", CountFormatter.string(progress.newFiles))
                        stat("Changed", CountFormatter.string(progress.changedFiles))
                        stat("Removed", CountFormatter.string(progress.deletedFiles))
                        stat("Access restricted", CountFormatter.string(progress.restrictedFolders))
                    }
                }
                if !progress.currentPath.isEmpty && progress.phase.isActive {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current location:").font(.caption).foregroundStyle(.secondary)
                        Text(progress.currentPath.abbreviatingHome).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                }
                if progress.phase == .cancelled {
                    Text("The scan was stopped. Results so far are saved; Resume continues where it left off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var title: String {
        switch model.scan.progress.phase {
        case .preparing: return "Preparing scan…"
        case .scanning: return model.scan.progress.isResumed ? "Resuming scan…" : "Scanning…"
        case .paused: return "Scan paused"
        case .finalizing: return "Calculating folder totals…"
        case .cancelled: return "Scan stopped"
        default: return "Scan"
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }
}
