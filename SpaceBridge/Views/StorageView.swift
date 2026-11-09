import SwiftUI

struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var locations: [(location: KnownLocation, folder: FolderItem?)] = []
    @State private var restricted: [FolderItem] = []
    @State private var volumes: [VolumeInfo] = []
    @State private var showPermissionHelp = false

    var body: some View {
        let summary = model.scan.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionCard("Volumes", systemImage: "externaldrive") {
                    ForEach(volumes) { volume in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: volume.isRootFileSystem ? "internaldrive.fill" : (volume.isRemovable || volume.isEjectable ? "externaldrive.fill" : "internaldrive"))
                                Text(volume.name).font(.headline)
                                Text(volume.path).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(ByteFormatter.string(volume.used)) of \(ByteFormatter.string(volume.totalCapacity)) used")
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            UsageBar(fraction: volume.usedFraction, tint: volume.usedFraction > 0.9 ? .red : .accentColor)
                        }
                        .padding(.vertical, 4)
                    }
                    Text("Available space includes purgeable space that macOS frees automatically when needed.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if summary.hasScanData {
                    SectionCard("Categories", systemImage: "chart.pie") {
                        CategoryOverview(summary: summary, limit: 12)
                        Divider()
                        CategoryTable(categories: summary.categories)
                    }
                    SectionCard("Locations", systemImage: "folder") {
                        ForEach(locations, id: \.location.id) { entry in
                            LocationRow(location: entry.location, folder: entry.folder) {
                                if entry.folder?.isRestricted == true { showPermissionHelp = true } else { model.showFolder(entry.location.path) }
                            }
                        }
                    }
                    SectionCard("Access Restricted", systemImage: "lock") {
                        if restricted.isEmpty {
                            Label("SpaceBridge could read every scanned folder.", systemImage: "checkmark.circle").foregroundStyle(.green)
                        } else {
                            Text("macOS didn't allow SpaceBridge to read these folders, so their sizes aren't included. SpaceBridge does not retry them during a scan.")
                                .foregroundStyle(.secondary)
                            ForEach(restricted.prefix(25)) { folder in
                                HStack {
                                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                                    Text(folder.path.abbreviatingHome).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("Access Restricted").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            if restricted.count > 25 {
                                Text("…and \(restricted.count - 25) more").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("How to Grant Access…") { showPermissionHelp = true }
                        }
                    }
                } else {
                    ScanRequiredView().frame(minHeight: 260)
                }
            }
            .padding(16)
        }
        .navigationTitle("Storage")
        .task(id: model.scan.dataVersion) { await reload() }
        .sheet(isPresented: $showPermissionHelp) { PermissionHelpSheet() }
    }

    private func reload() async {
        volumes = VolumeService.mountedVolumes()
        guard let database = model.database else { return }
        var loaded: [(location: KnownLocation, folder: FolderItem?)] = []
        for location in KnownLocation.standard() {
            let folder = try? await database.folder(path: location.path)
            if folder != nil || FileManager.default.fileExists(atPath: location.path) {
                loaded.append((location: location, folder: folder))
            }
        }
        locations = loaded
        restricted = (try? await database.restrictedFolders(limit: 200)) ?? []
    }
}

private struct CategoryTable: View {
    @Environment(AppModel.self) private var model
    var categories: [CategoryUsage]

    var body: some View {
        let total = max(categories.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Category").font(.caption).foregroundStyle(.secondary)
                Text("Size").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text("Files").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text("Share").font(.caption).foregroundStyle(.secondary)
                Text("How it's detected").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(categories) { usage in
                GridRow {
                    Button {
                        model.showCategory(usage.category)
                    } label: {
                        Label(usage.category.displayName, systemImage: usage.category.symbolName)
                            .labelStyle(TintedLabelStyle(tint: usage.category.color))
                    }
                    .buttonStyle(.link)
                    Text(ByteFormatter.string(usage.bytes)).monospacedDigit()
                    Text(usage.fileCount.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    UsageBar(fraction: Double(usage.bytes) / Double(total), tint: usage.category.color, height: 6).frame(width: 100)
                    Text(usage.category.detectionNote).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(usage.category.detectionNote)
                }
            }
        }
    }
}

private struct LocationRow: View {
    var location: KnownLocation
    var folder: FolderItem?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: location.symbolName).frame(width: 20).foregroundStyle(location.category?.color ?? .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(location.name)
                    Text(location.path.abbreviatingHome).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let folder {
                    if folder.isRestricted {
                        Label("Access Restricted", systemImage: "lock.fill").font(.caption).foregroundStyle(.orange)
                    }
                    Text(ByteFormatter.string(folder.totalAllocated)).monospacedDigit()
                    Text("\(folder.fileCount.formatted()) files").font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                } else {
                    Text("Not scanned").foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

/// Explains how to grant access instead of trying to work around macOS privacy protection.
struct PermissionHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Grant Full Disk Access", systemImage: "lock.shield").font(.title2.weight(.semibold))
            Text(PermissionManager.fullDiskAccessInstructions).fixedSize(horizontal: false, vertical: true)
            Text("Some locations (for example /private/var/db and other users' folders) are readable only by macOS or their owners. SpaceBridge will always show them as restricted — this is expected.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Files & Folders Settings") { PermissionManager.openFilesAndFoldersSettings() }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open System Settings") { PermissionManager.openFullDiskAccessSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
