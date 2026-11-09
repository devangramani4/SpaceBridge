import Photos
import SwiftUI

struct PhotosHubView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        List {
            if let report = model.photoReport {
                Section {
                    NavigationLink { MediaListView(title: "Largest Videos", items: report.largestVideos) } label: {
                        HubRow(title: "Largest Videos", detail: "\(report.videoCount.formatted()) videos", bytes: report.videoBytes, symbol: "film", tint: .purple)
                    }
                    NavigationLink { MediaListView(title: "Largest Items", items: report.largestItems) } label: {
                        HubRow(title: "Largest Photos & Videos", detail: "Everything, biggest first", bytes: report.totalBytes, symbol: "arrow.up.arrow.down", tint: .pink)
                    }
                    NavigationLink { MediaListView(title: "Screenshots", items: report.screenshots, feature: .screenshots) } label: {
                        HubRow(title: "Screenshots", detail: "\(report.screenshotCount.formatted()) screenshots", bytes: report.screenshotBytes,
                               symbol: "camera.viewfinder", tint: .orange, isPro: !model.pro.isPro)
                    }
                    NavigationLink { DuplicateMediaView() } label: {
                        HubRow(title: "Duplicates", detail: "\(report.duplicateGroups.count) groups", bytes: report.duplicateSavings,
                               symbol: "square.on.square", tint: .blue, isPro: !model.pro.isPro)
                    }
                } footer: {
                    Text("Analyzed \(report.analyzedAt.formatted(.relative(presentation: .named))). Sizes are original files and may include iCloud originals not stored on this device.")
                }
                Section {
                    Button("Analyze Again") { model.analyzePhotos() }.disabled(model.isAnalyzingPhotos)
                }
            } else {
                Section { AnalyzePhotosCard().listRowInsets(EdgeInsets()) }
            }
            if model.isAnalyzingPhotos {
                Section { ProgressView(value: model.photoProgress) { Text("Analyzing your library…") } }
            }
        }
        .navigationTitle("Photos & Videos")
    }
}

private struct HubRow: View {
    var title: String
    var detail: String
    var bytes: Int64
    var symbol: String
    var tint: Color
    var isPro = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if isPro { MobileProBadge() }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormatter.string(bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Selectable list of media with thumbnails. Free users see the top 10 and delete one at a time.
struct MediaListView: View {
    @Environment(MobileModel.self) private var model
    var title: String
    var items: [MediaItem]
    var feature: MobileProFeature?
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var confirm: [String]?

    private var visible: [MediaItem] {
        let current = items.filter { item in model.photoReport.map { report in
            report.largestItems.contains { $0.id == item.id } || report.largestVideos.contains { $0.id == item.id } || report.screenshots.contains { $0.id == item.id }
        } ?? true }
        return model.pro.isPro ? current : Array(current.prefix(10))
    }

    var body: some View {
        Group {
            if let feature, !model.pro.isPro {
                MobileLockedView(feature: feature)
            } else {
                List(selection: $selection) {
                    ForEach(visible) { item in
                        MediaRow(item: item)
                            .swipeActions {
                                Button(role: .destructive) { confirm = [item.id] } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                    if !model.pro.isPro && items.count > 10 {
                        Button { model.showPaywall = true } label: {
                            Label("See all \(items.count.formatted()) items with Pro", systemImage: "sparkles")
                        }
                    }
                }
                .environment(\.editMode, $editMode)
            }
        }
        .navigationTitle(title)
        .toolbar {
            if model.pro.isPro {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode.isEditing ? "Done" : "Select") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        if !editMode.isEditing { selection.removeAll() }
                    }
                }
                if editMode.isEditing && !selection.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) { confirm = Array(selection) } label: {
                            Text("Delete \(selection.count) (\(ByteFormatter.string(bytes(of: selection))))")
                        }
                    }
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let ids = confirm ?? []
                confirm = nil
                selection.removeAll()
                Task { await model.deletePhotos(ids) }
            }
        } message: {
            Text("Items move to Recently Deleted in Photos, where you can recover them for 30 days.")
        }
    }

    private var confirmTitle: String {
        let ids = confirm ?? []
        return "Delete \(ids.count) item\(ids.count == 1 ? "" : "s") (\(ByteFormatter.string(bytes(of: Set(ids)))))?"
    }

    private func bytes(of ids: Set<String>) -> Int64 {
        items.filter { ids.contains($0.id) }.reduce(0) { $0 + ($1.bytes ?? 0) }
    }
}

struct MediaRow: View {
    var item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            MediaThumbnail(id: item.id).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename ?? item.kind.rawValue).lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.kind.rawValue)
                    if item.kind == .video { Text(Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))) }
                    if let date = item.created { Text(date.formatted(date: .abbreviated, time: .omitted)) }
                    if item.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormatter.string(optional: item.bytes)).monospacedDigit().font(.subheadline.weight(.medium))
        }
    }
}

/// Loads a small thumbnail on demand. Never downloads from iCloud (offline by design).
struct MediaThumbnail: View {
    var id: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .task(id: id) { image = await Self.load(id) }
    }

    static func load(_ id: String) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat // single callback
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 160, height: 160), contentMode: .aspectFill, options: options) { image, _ in
                if resumed.claim() { continuation.resume(returning: image) }
            }
        }
    }
}

/// Guards a continuation against being resumed twice.
final class ResumeOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

struct DuplicateMediaView: View {
    @Environment(MobileModel.self) private var model
    @State private var selected = Set<String>()
    @State private var confirm = false

    var body: some View {
        Group {
            if !model.pro.isPro {
                MobileLockedView(feature: .duplicates)
            } else if let groups = model.photoReport?.duplicateGroups, !groups.isEmpty {
                List {
                    Section {
                        Button("Select All Extra Copies") {
                            selected = Set(groups.flatMap { $0.items.dropFirst().map(\.id) })
                        }
                    } footer: {
                        Text("Likely duplicates have the same type, dimensions, file size and capture time. The first item in each group (favorites first) is kept unless you change it.")
                    }
                    ForEach(groups) { group in
                        Section("\(group.items.count) copies · \(ByteFormatter.string(group.bytesEach)) each") {
                            ForEach(group.items) { item in
                                Button { toggle(item, in: group) } label: {
                                    HStack {
                                        Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected.contains(item.id) ? Color.red : Color.secondary)
                                        MediaRow(item: item)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if !selected.isEmpty {
                        Button(role: .destructive) { confirm = true } label: {
                            Text("Delete \(selected.count) Copies").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.large).padding()
                        .background(.bar)
                    }
                }
            } else {
                ContentUnavailableView("No Duplicates", systemImage: "checkmark.circle", description: Text("No exact duplicate photos or videos were found."))
            }
        }
        .navigationTitle("Duplicates")
        .confirmationDialog("Delete \(selected.count) duplicate copies?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let ids = Array(selected)
                selected.removeAll()
                Task { await model.deletePhotos(ids) }
            }
        } message: {
            Text("At least one copy of each is kept. Deleted items stay in Recently Deleted for 30 days.")
        }
    }

    /// Never allows selecting every copy in a group.
    private func toggle(_ item: MediaItem, in group: MediaDuplicateGroup) {
        if selected.contains(item.id) {
            selected.remove(item.id)
        } else if group.items.filter({ selected.contains($0.id) }).count < group.items.count - 1 {
            selected.insert(item.id)
        }
    }
}

struct MobileLockedView: View {
    @Environment(MobileModel.self) private var model
    var feature: MobileProFeature

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: feature.symbolName).font(.system(size: 44)).foregroundStyle(.purple)
            HStack { Text(feature.title).font(.title2.weight(.semibold)); MobileProBadge() }
            Text(feature.detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("See SpaceBridge Pro") { model.showPaywall = true }.buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
