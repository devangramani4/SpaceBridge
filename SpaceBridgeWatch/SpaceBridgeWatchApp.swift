import Observation
import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct SpaceBridgeWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView().environment(model)
        }
    }
}

/// Receives the iPhone's storage summary over WatchConnectivity (directly between paired devices)
/// and reads the watch's own storage and battery.
@MainActor
@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    var phone: WatchSummary?
    var watchStorage: (total: Int64, available: Int64)?
    var batteryLevel: Float?

    override init() {
        super.init()
        if let saved = UserDefaults.standard.dictionary(forKey: "lastSummary") { phone = WatchSummary(dictionary: saved) }
        refreshLocal()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func refreshLocal() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        // (The "important usage" capacity key isn't available on watchOS.)
        if let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
           let total = values.volumeTotalCapacity, total > 0 {
            watchStorage = (Int64(total), Int64(values.volumeAvailableCapacity ?? 0))
        }
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        batteryLevel = device.batteryLevel >= 0 ? device.batteryLevel : nil
    }

    private func apply(_ context: [String: Any]) {
        guard let summary = WatchSummary(dictionary: context) else { return }
        phone = summary
        UserDefaults.standard.set(context, forKey: "lastSummary")
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        guard !context.isEmpty, let data = try? PropertyListSerialization.data(fromPropertyList: context, format: .binary, options: 0) else { return }
        Task { @MainActor in self.applyData(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: applicationContext, format: .binary, options: 0) else { return }
        Task { @MainActor in self.applyData(data) }
    }

    /// Dictionaries aren't Sendable, so the context crosses to the main actor as property-list data.
    private func applyData(_ data: Data) {
        if let context = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] { apply(context) }
    }
}

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        TabView {
            PhoneStoragePage()
            ReclaimPage()
            ThisWatchPage()
        }
        .tabViewStyle(.verticalPage)
        .onAppear { model.refreshLocal() }
    }
}

private struct PhoneStoragePage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            if let phone = model.phone {
                Gauge(value: phone.usedFraction) {
                    Image(systemName: "iphone")
                } currentValueLabel: {
                    Text(PercentFormatter.string(phone.usedFraction)).monospacedDigit()
                }
                .gaugeStyle(.accessoryCircular)
                .tint(Gradient(colors: [.green, .yellow, .red]))
                .scaleEffect(1.4)
                .padding(.vertical, 12)
                Text("\(ByteFormatter.string(phone.availableBytes)) free").font(.headline)
                Text("of \(ByteFormatter.string(phone.totalBytes))").font(.caption2).foregroundStyle(.secondary)
                Text("Updated \(phone.updated.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Image(systemName: "iphone.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.secondary)
                Text("Open SpaceBridge on your iPhone").multilineTextAlignment(.center).font(.footnote)
            }
        }
        .navigationTitle("iPhone")
        .containerBackground(Color.blue.gradient.opacity(0.35), for: .tabView)
    }
}

private struct ReclaimPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let phone = model.phone {
                    if !phone.isPro {
                        Label("Watch glance is part of SpaceBridge Pro", systemImage: "sparkles").font(.footnote).foregroundStyle(.purple)
                    } else if let reclaimable = phone.reclaimableBytes {
                        Text("Can free up").font(.caption).foregroundStyle(.secondary)
                        Text(ByteFormatter.string(reclaimable)).font(.title2.weight(.semibold))
                        if let duplicates = phone.duplicateCount { Label("\(duplicates) duplicate copies", systemImage: "square.on.square").font(.footnote) }
                        if let videos = phone.largeVideoCount { Label("\(videos) videos over 500 MB", systemImage: "film").font(.footnote) }
                        if let library = phone.photoLibraryBytes { Label("Library \(ByteFormatter.string(library))", systemImage: "photo").font(.footnote) }
                        Text("Clean up on your iPhone.").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Analyze Photos on your iPhone to see what you can free up.").font(.footnote)
                    }
                } else {
                    Text("No data yet.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Free Up")
        .containerBackground(Color.purple.gradient.opacity(0.35), for: .tabView)
    }
}

private struct ThisWatchPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let storage = model.watchStorage {
                Text("Watch storage").font(.caption).foregroundStyle(.secondary)
                Text("\(ByteFormatter.string(storage.available)) free").font(.headline)
                ProgressView(value: Double(storage.total - storage.available), total: Double(max(storage.total, 1)))
                Text("of \(ByteFormatter.string(storage.total))").font(.caption2).foregroundStyle(.secondary)
            }
            if let battery = model.batteryLevel {
                Label("\(Int(battery * 100))% battery", systemImage: "battery.75percent").font(.footnote)
            }
            Spacer()
            Label("Data only travels between your iPhone and Watch.", systemImage: "lock.shield.fill")
                .font(.caption2).foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("This Watch")
        .containerBackground(Color.green.gradient.opacity(0.3), for: .tabView)
    }
}
