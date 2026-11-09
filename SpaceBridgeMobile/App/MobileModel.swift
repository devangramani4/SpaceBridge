import Foundation
import Observation
import Photos
import SwiftUI

enum MobileSection: String, CaseIterable, Identifiable, Hashable {
    case overview, photos, files, device, tips, privacy, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .photos: return "Photos & Videos"
        case .files: return "Files"
        case .device: return "Device"
        case .tips: return "Storage Tips"
        case .privacy: return "Privacy"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .photos: return "photo.on.rectangle.angled"
        case .files: return "folder"
        case .device: return "cpu"
        case .tips: return "lightbulb"
        case .privacy: return "hand.raised"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
@Observable
final class MobileModel {
    var selection: MobileSection? = .overview
    var storage: DeviceStorage?
    var photoAccess: PHAuthorizationStatus = PhotoLibraryAnalyzer.authorizationStatus()
    var photoReport: PhotoLibraryReport?
    var isAnalyzingPhotos = false
    var photoProgress = 0.0
    var folderURL: URL?
    var folderReport: FolderScanReport?
    var isScanningFolder = false
    var showPaywall = false
    var errorMessage: String?

    let pro = MobileProStore()
    @ObservationIgnored private var photoTask: Task<Void, Never>?

    init() {
        WatchSync.shared.activate()
        refreshStorage()
        folderURL = FolderScanner.rememberedFolder()
    }

    func refreshStorage() {
        storage = DeviceInfoService.storage()
        pushWatchSummary()
    }

    /// Runs `action` with Pro, otherwise shows the subscription screen.
    func requirePro(_ action: () -> Void) {
        if pro.isPro { action() } else { showPaywall = true }
    }

    func analyzePhotos() {
        guard !isAnalyzingPhotos else { return }
        photoTask = Task {
            if photoAccess == .notDetermined { photoAccess = await PhotoLibraryAnalyzer.requestAccess() }
            guard photoAccess == .authorized || photoAccess == .limited else { return }
            isAnalyzingPhotos = true
            photoProgress = 0
            let report = await PhotoLibraryAnalyzer.analyze { value in
                Task { @MainActor [weak self] in self?.photoProgress = value }
            }
            photoReport = report
            isAnalyzingPhotos = false
            refreshStorage()
        }
    }

    func deletePhotos(_ ids: [String]) async {
        do {
            try await PhotoLibraryAnalyzer.delete(ids: ids)
            // Update the report locally instead of re-reading the whole library.
            if var report = photoReport {
                let removed = Set(ids)
                report.largestItems.removeAll { removed.contains($0.id) }
                report.largestVideos.removeAll { removed.contains($0.id) }
                report.screenshots.removeAll { removed.contains($0.id) }
                report.duplicateGroups = report.duplicateGroups.compactMap { group in
                    var group = group
                    group.items.removeAll { removed.contains($0.id) }
                    return group.items.count > 1 ? group : nil
                }
                photoReport = report
            }
            refreshStorage()
        } catch {
            // The user tapped "Don't Allow" in the iOS confirmation, or iOS refused.
            let nsError = error as NSError
            if nsError.code != 3072 { errorMessage = error.localizedDescription } // 3072 = user cancelled
        }
    }

    func scanFolder(_ url: URL) {
        folderURL = url
        FolderScanner.rememberFolder(url)
        isScanningFolder = true
        Task {
            folderReport = await FolderScanner.scan(url)
            isScanningFolder = false
        }
    }

    func pushWatchSummary() {
        guard let storage else { return }
        let report = photoReport
        WatchSync.shared.send(WatchSummary(
            totalBytes: storage.total, usedBytes: storage.used, availableBytes: storage.available,
            photoLibraryBytes: report?.totalBytes,
            reclaimableBytes: report.map { $0.duplicateSavings + $0.screenshotBytes },
            duplicateCount: report.map { $0.duplicateGroups.reduce(0) { $0 + $1.items.count - 1 } },
            largeVideoCount: report?.largestVideos.filter { ($0.bytes ?? 0) > 500_000_000 }.count,
            isPro: pro.isPro))
    }
}
