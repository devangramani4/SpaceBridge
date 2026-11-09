import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.includeSystemFolders) private var includeSystem = true
    @AppStorage(SettingsKey.includeExternalVolumes) private var includeExternal = true
    @AppStorage(SettingsKey.includeNetworkVolumes) private var includeNetwork = false
    @AppStorage(SettingsKey.scanConcurrency) private var concurrency = 4
    @AppStorage(SettingsKey.monitorInterval) private var monitorInterval = 2.0
    @State private var excluded: [String] = UserDefaults.standard.stringArray(forKey: SettingsKey.excludedPaths) ?? []
    @State private var databaseSize: Int64 = 0
    @State private var errors: [ScanErrorEntry] = []
    @State private var confirmClear = false

    var body: some View {
        Form {
            ProSettingsSection()
            Section("Scanning") {
                Toggle("Include macOS system folders (/System, /usr, /private …)", isOn: $includeSystem)
                HStack {
                    Toggle("Include external volumes", isOn: $includeExternal)
                        .disabled(!model.pro.isUnlocked(.externalVolumes))
                    if !model.pro.isUnlocked(.externalVolumes) {
                        Button { model.showPaywall(.externalVolumes) } label: { ProBadge() }.buttonStyle(.plain)
                    }
                }
                Toggle("Include network volumes (slow)", isOn: $includeNetwork)
                    .disabled(!includeExternal || !model.pro.isUnlocked(.externalVolumes))
                Stepper("Parallel folder readers: \(concurrency)", value: $concurrency, in: 1...8)
                    .help("More readers scan faster on SSDs but use more CPU while scanning.")
                VStack(alignment: .leading) {
                    Text("Excluded folders")
                    ForEach(excluded, id: \.self) { path in
                        HStack {
                            Text(path.abbreviatingHome).font(.callout.monospaced())
                            Spacer()
                            Button { excluded.removeAll { $0 == path }; saveExcluded() } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Folder…") { addExcluded() }
                }
            }
            Section("Monitoring") {
                Picker("Update interval", selection: $monitorInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
                Text("CPU and memory are sampled only while a monitoring screen is open.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Scan Cache") {
                LabeledContent("Cache size", value: ByteFormatter.string(databaseSize))
                LabeledContent("Location", value: model.database?.url.path.abbreviatingHome ?? "Unavailable")
                Text("The cache stores only file names, paths, sizes, dates and types — never file contents — so later scans only update what changed.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let url = model.database?.url {
                        Button("Reveal in Finder") { FinderActions.reveal(url.path) }
                    }
                    Button("Clear Cache…", role: .destructive) { confirmClear = true }
                        .disabled(model.scan.isScanning)
                }
            }
            Section("Diagnostics") {
                if errors.isEmpty {
                    Text("No scan errors recorded.").foregroundStyle(.secondary)
                } else {
                    List(errors.prefix(200)) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.path.abbreviatingHome).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            Text("\(entry.date.formatted(date: .abbreviated, time: .standard)) — \(entry.message)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 200)
                    HStack {
                        Button("Copy Log") {
                            FinderActions.copyPaths(errors.map { "\($0.date.ISO8601Format())\t\($0.path)\t\($0.message)" })
                        }
                        Button("Clear Log") {
                            Task { try? await model.database?.clearErrors(); await reload() }
                        }
                    }
                }
            }
            Section("Privacy") {
                PrivacyNotice()
                Text("Works offline. No account, no analytics, no tracking. Everything SpaceBridge learns about your files is stored only in the local cache above, and you can clear it at any time. The only network request is the Pro license check, which sends your license key and nothing else.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                LabeledContent("Developer", value: "Genius Bridge Technologies")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await reload() }
        .confirmationDialog("Clear the scan cache?", isPresented: $confirmClear) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    try? await model.database?.clearAll()
                    model.scan.resumableScanID = nil
                    await model.scan.dataChanged()
                    await reload()
                }
            }
        } message: {
            Text("This removes SpaceBridge's saved scan results only. Your files are not affected. The next scan starts from scratch.")
        }
    }

    private func reload() async {
        databaseSize = await model.database?.databaseFileSize() ?? 0
        errors = (try? await model.database?.recentErrors(limit: 500)) ?? []
    }

    private func saveExcluded() {
        UserDefaults.standard.set(excluded, forKey: SettingsKey.excludedPaths)
    }

    private func addExcluded() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        if panel.runModal() == .OK {
            for url in panel.urls where !excluded.contains(url.path) { excluded.append(url.path) }
            saveExcluded()
        }
    }
}
