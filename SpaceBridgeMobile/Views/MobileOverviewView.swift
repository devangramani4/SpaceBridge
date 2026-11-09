import Photos
import SwiftUI

struct MobileOverviewView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StorageRingCard(storage: model.storage)
                if let report = model.photoReport {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        Tile(title: "Photo Library", value: ByteFormatter.string(report.totalBytes),
                             detail: "\(report.photoCount.formatted()) photos · \(report.videoCount.formatted()) videos", symbol: "photo.on.rectangle", tint: .pink)
                        Tile(title: "Videos", value: ByteFormatter.string(report.videoBytes), detail: "Usually the biggest win", symbol: "film", tint: .purple)
                        Tile(title: "Screenshots", value: ByteFormatter.string(report.screenshotBytes),
                             detail: "\(report.screenshotCount.formatted()) screenshots", symbol: "camera.viewfinder", tint: .orange)
                        Tile(title: "Duplicates", value: ByteFormatter.string(report.duplicateSavings),
                             detail: "\(report.duplicateGroups.count) groups to review", symbol: "square.on.square", tint: .blue)
                    }
                    if report.unknownSizeCount > 0 {
                        Text("iOS didn't report a size for \(report.unknownSizeCount.formatted()) items; they aren't included in the totals.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    AnalyzePhotosCard()
                }
                CardView {
                    Label("What this app can see", systemImage: "info.circle").font(.headline)
                    Text("iOS keeps every app in its own sandbox, so SpaceBridge can't see other apps' data or the system. It analyzes what you allow — your Photos library and folders you pick in Files — which is where most personal storage goes. For per-app sizes, use Settings ▸ General ▸ iPhone Storage.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                PrivacyFooter()
            }
            .padding()
        }
        .navigationTitle("Overview")
        .refreshable { model.refreshStorage() }
    }
}

struct StorageRingCard: View {
    var storage: DeviceStorage?

    var body: some View {
        CardView {
            if let storage {
                HStack(spacing: 20) {
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 14)
                        Circle()
                            .trim(from: 0, to: storage.usedFraction)
                            .stroke(storage.usedFraction > 0.9 ? Color.red.gradient : Color.accentColor.gradient,
                                    style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text(PercentFormatter.string(storage.usedFraction)).font(.title2.weight(.bold)).monospacedDigit()
                            Text("used").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 110, height: 110)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(UIDevice.current.model + " Storage").font(.headline)
                        figure("Used", storage.used)
                        figure("Available", storage.available)
                        figure("Total", storage.total)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("Storage information is unavailable.").foregroundStyle(.secondary)
            }
        }
    }

    private func figure(_ title: String, _ bytes: Int64) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(ByteFormatter.string(bytes)).monospacedDigit().fontWeight(.medium)
        }
        .font(.subheadline)
    }
}

struct AnalyzePhotosCard: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        CardView {
            Label("Analyze Photos & Videos", systemImage: "sparkle.magnifyingglass").font(.headline)
            Text("Find your largest videos, screenshots and duplicate photos. Analysis happens entirely on this device.")
                .font(.subheadline).foregroundStyle(.secondary)
            if model.isAnalyzingPhotos {
                ProgressView(value: model.photoProgress) { Text("Analyzing…").font(.caption) }
            } else if model.photoAccess == .denied || model.photoAccess == .restricted {
                Text("Photos access is off. Turn it on in Settings ▸ SpaceBridge ▸ Photos.").font(.footnote).foregroundStyle(.orange)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } else {
                Button { model.analyzePhotos() } label: {
                    Text("Analyze Library").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }
}

struct Tile: View {
    var title: String
    var value: String
    var detail: String
    var symbol: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(tint)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct CardView<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct PrivacyFooter: View {
    var body: some View {
        Label("Works offline. Your photos, files and data never leave this device — not even to the developer.", systemImage: "lock.shield.fill")
            .font(.footnote)
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
