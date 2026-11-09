import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @Environment(MobileModel.self) private var model
    @State private var picking = false
    @State private var pendingDelete: ScannedMobileFile?
    @State private var confirmPermanent: ScannedMobileFile?

    var body: some View {
        Group {
            if !model.pro.isPro {
                MobileLockedView(feature: .folderScan)
            } else {
                List {
                    Section {
                        Button { picking = true } label: { Label("Choose a Folder…", systemImage: "folder.badge.plus") }
                        if let url = model.folderURL {
                            Button { model.scanFolder(url) } label: { Label("Rescan “\(url.lastPathComponent)”", systemImage: "arrow.clockwise") }
                                .disabled(model.isScanningFolder)
                        }
                    } footer: {
                        Text("Pick iCloud Drive, On My iPhone, or a connected drive in the Files picker. iOS only lets SpaceBridge read folders you choose.")
                    }
                    if model.isScanningFolder { Section { ProgressView("Scanning…") } }
                    if let report = model.folderReport {
                        Section("\(report.folderName) — \(ByteFormatter.string(report.totalBytes)) in \(report.fileCount.formatted()) files") {
                            ForEach(report.largest) { file in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(file.name).lineLimit(1)
                                        Spacer()
                                        Text(ByteFormatter.string(file.bytes)).monospacedDigit().fontWeight(.medium)
                                    }
                                    Text(file.relativePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                .swipeActions {
                                    Button(role: .destructive) { pendingDelete = file } label: { Label("Delete", systemImage: "trash") }
                                }
                                .contextMenu {
                                    Button { UIPasteboard.general.string = file.relativePath } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                                    Button(role: .destructive) { pendingDelete = file } label: { Label("Delete…", systemImage: "trash") }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Files")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.scanFolder(url) }
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) { remove(pendingDelete, permanently: false) }
        } message: {
            Text("\(ByteFormatter.string(pendingDelete?.bytes ?? 0)). In iCloud Drive and On My iPhone you can recover it from Files ▸ Recently Deleted.")
        }
        .confirmationDialog("This location has no Recently Deleted folder", isPresented: Binding(get: { confirmPermanent != nil }, set: { if !$0 { confirmPermanent = nil } }), titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) { remove(confirmPermanent, permanently: true) }
        } message: {
            Text("“\(confirmPermanent?.name ?? "")” will be deleted and can't be recovered.")
        }
    }

    private func remove(_ file: ScannedMobileFile?, permanently: Bool) {
        guard let file, let folder = model.folderURL else { return }
        pendingDelete = nil
        confirmPermanent = nil
        do {
            try FolderScanner.remove(file, in: folder, permanently: permanently)
            model.folderReport?.largest.removeAll { $0.id == file.id }
            model.folderReport?.totalBytes -= file.bytes
            model.refreshStorage()
        } catch FolderScanner.RemovalError.noTrash {
            confirmPermanent = file
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

struct DeviceView: View {
    @Environment(MobileModel.self) private var model
    @State private var memory = DeviceInfoService.memory()
    @State private var status: DeviceStatus?
    @State private var cpu: Double?
    private let sampler = DeviceCPUSampler()

    var body: some View {
        List {
            Section("Memory (whole device)") {
                row("Total RAM", ByteFormatter.string(memory.total))
                row("In use", memory.used.map { ByteFormatter.string($0) } ?? "Unavailable")
                row("Wired", memory.wired.map { ByteFormatter.string($0) } ?? "Unavailable")
                row("Compressed", memory.compressed.map { ByteFormatter.string($0) } ?? "Unavailable")
                row("Free", memory.free.map { ByteFormatter.string($0) } ?? "Unavailable")
            }
            Section {
                row("CPU (all cores)", cpu.map { PercentFormatter.string($0) } ?? "Measuring…")
                row("Cores", "\(status?.processorCount ?? Foundation.ProcessInfo.processInfo.activeProcessorCount)")
                row("SpaceBridge memory", memory.appFootprint.map { ByteFormatter.string($0) } ?? "—")
            } header: {
                Text("Processor")
            } footer: {
                Text("iOS doesn't let apps see other apps' CPU or memory use. For battery use per app, see Settings ▸ Battery.")
            }
            if let status {
                Section("Device") {
                    row("Model", "\(status.model) (\(status.hardwareIdentifier))")
                    row("System", "\(status.systemName) \(status.systemVersion)")
                    row("Battery", status.batteryLevel.map { "\(Int($0 * 100))% · \(status.batteryState)" } ?? status.batteryState)
                    row("Low Power Mode", status.lowPowerMode ? "On" : "Off")
                    row("Thermal state", status.thermalState)
                    row("Up time", Duration.seconds(status.uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                }
            }
        }
        .navigationTitle("Device")
        .task {
            // Sample every 2 seconds only while this screen is visible.
            _ = sampler.sample()
            while !Task.isCancelled {
                status = DeviceInfoService.status()
                memory = DeviceInfoService.memory()
                try? await Task.sleep(for: .seconds(2))
                cpu = sampler.sample()
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).monospacedDigit() }
    }
}

struct TipsView: View {
    private let tips: [(String, String, String)] = [
        ("photo.on.rectangle", "Empty Recently Deleted", "Photos ▸ Albums ▸ Recently Deleted keeps deleted items for 30 days. Delete them there to free the space now."),
        ("icloud", "Optimize iPhone Storage", "Settings ▸ Photos ▸ Optimize iPhone Storage keeps full-size originals in iCloud and smaller versions on your device."),
        ("square.stack.3d.down.right", "Offload Unused Apps", "Settings ▸ General ▸ iPhone Storage ▸ Offload Unused Apps removes apps you don't use but keeps their data."),
        ("message", "Auto-delete old messages", "Settings ▸ Messages ▸ Keep Messages ▸ 1 Year. Large attachments: iPhone Storage ▸ Messages ▸ Review Large Attachments."),
        ("safari", "Clear Safari data", "Settings ▸ Apps ▸ Safari ▸ Clear History and Website Data."),
        ("music.note", "Downloaded music & podcasts", "Settings ▸ General ▸ iPhone Storage ▸ Music or Podcasts to remove downloads you've already listened to."),
        ("film", "Record video at a lower resolution", "Settings ▸ Camera ▸ Record Video. 4K 60 fps uses about 4× the space of 1080p 30 fps."),
        ("folder", "Files ▸ Recently Deleted", "Files you delete in iCloud Drive or On My iPhone stay there for 30 days."),
    ]

    var body: some View {
        List(tips, id: \.1) { tip in
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tip.1).fontWeight(.semibold)
                    Text(tip.2).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: tip.0).foregroundStyle(.blue) }
            .padding(.vertical, 4)
        }
        .navigationTitle("Storage Tips")
    }
}

struct MobilePrivacyView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 44)).foregroundStyle(.green)
                    Text("Your data stays on this device").font(.title2.weight(.bold))
                    Text("SpaceBridge works completely offline. No one — not even Genius Bridge Technologies, the developer — can see, collect or share your photos, files or information.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section {
                point("wifi.slash", "Works offline", "Analysis never uses the internet. Thumbnails of iCloud-only photos aren't downloaded.")
                point("eye.slash", "Nothing is uploaded", "Photo info, file names, sizes and device data never leave this device.")
                point("person.crop.circle.badge.xmark", "No account, no tracking", "No sign-up, analytics, ads or third-party SDKs.")
                point("applewatch", "Apple Watch", "Only storage totals are sent directly to your paired watch — never file names or photos.")
                point("creditcard", "Purchases", "Pro is handled by Apple's App Store. We never see your payment details.")
                point("trash.slash", "You stay in control", "Nothing is deleted without your confirmation; photos go to Recently Deleted.")
            }
        }
        .navigationTitle("Privacy")
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: symbol).foregroundStyle(.green) }
    }
}

struct MobileSettingsView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        List {
            Section("SpaceBridge Pro") {
                if model.pro.isPro {
                    LabeledContent("Status", value: "Active")
                    if let expiration = model.pro.expiration {
                        LabeledContent("Renews", value: expiration.formatted(date: .abbreviated, time: .omitted))
                    }
                    Button("Manage Subscription") {
                        if let url = URL(string: "https://apps.apple.com/account/subscriptions") { UIApplication.shared.open(url) }
                    }
                } else {
                    Button { model.showPaywall = true } label: { Label("Upgrade to Pro", systemImage: "sparkles") }
                }
                Button("Restore Purchases") { Task { await model.pro.restore() } }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                LabeledContent("Developer", value: "Genius Bridge Technologies")
            }
        }
        .navigationTitle("Settings")
    }
}
