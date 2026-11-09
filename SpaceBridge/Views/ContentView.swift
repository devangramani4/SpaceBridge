import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showWelcome = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(SidebarItem.sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            HStack {
                                Label(item.title, systemImage: item.symbolName)
                                if let feature = item.proFeature, !model.pro.isUnlocked(feature) {
                                    Spacer()
                                    ProBadge()
                                }
                            }
                            .tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .safeAreaInset(edge: .top) { SidebarHeader() }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    SidebarProCard()
                    SidebarScanStatus()
                }
                .padding(10)
            }
        } detail: {
            DetailRouter(item: model.selection ?? .dashboard)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(model.selection)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search: *.zip, node_modules, size > 1 GB")
        .onSubmit(of: .search) { model.selection = .search }
        .toolbar { ScanToolbar() }
        .sheet(item: $model.trashRequest) { request in
            TrashConfirmationSheet(request: request)
        }
        .sheet(item: $model.paywall) { request in
            ProUpgradeView(highlighted: request.feature)
        }
        .sheet(isPresented: $showWelcome) { WelcomeSheet() }
        .onAppear { if !hasSeenWelcome { showWelcome = true; hasSeenWelcome = true } }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }
}

private struct DetailRouter: View {
    var item: SidebarItem

    var body: some View {
        switch item {
        case .dashboard: DashboardView()
        case .storage: StorageView()
        case .largestFiles: LargestFilesView()
        case .largestFolders: LargestFoldersView()
        case .applications: ApplicationsView()
        case .runningApps: RunningAppsView()
        case .memory: MemoryView()
        case .cpu: CPUView()
        case .developer: ProGate(feature: .developerStorage) { DeveloperStorageView() }
        case .duplicates: ProGate(feature: .duplicates) { DuplicateView() }
        case .cleanup: CleanupView()
        case .search: SearchView()
        case .permissions: PermissionsView()
        case .privacy: PrivacyView()
        case .settings: SettingsView()
        }
    }
}

struct ScanToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.scan.isScanning {
                ProgressView().controlSize(.small)
                Button {
                    model.scan.isPaused ? model.scan.resume() : model.scan.pause()
                } label: {
                    Label(model.scan.isPaused ? "Continue" : "Pause", systemImage: model.scan.isPaused ? "play.fill" : "pause.fill")
                }
                .help(model.scan.isPaused ? "Continue scanning" : "Pause scanning")
                Button(role: .cancel) {
                    model.scan.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .help("Stop scanning. Results so far are kept and the scan can be resumed.")
            } else {
                if model.scan.resumableScanID != nil {
                    Button {
                        model.scan.startScan(resume: true)
                    } label: {
                        Label("Resume Scan", systemImage: "arrow.clockwise.circle")
                    }
                    .help("Continue the previous, unfinished scan")
                }
                Button {
                    model.scan.startScan()
                } label: {
                    Label("Scan Mac", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Scan your Mac (⌘R). Only changes since the last scan are written.")
                .disabled(model.database == nil)
            }
        }
    }
}

private struct SidebarHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text("SpaceBridge").font(.headline)
                    if model.pro.isPro { ProBadge() }
                }
                Text("Genius Bridge Technologies").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct SidebarScanStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.scan.progress
        VStack(alignment: .leading, spacing: 4) {
            if progress.phase.isActive {
                HStack {
                    Text(progress.phase == .paused ? "Paused" : progress.phase == .finalizing ? "Finishing…" : "Scanning…")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(CountFormatter.string(progress.filesScanned)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            } else if let last = model.scan.summary.lastScan, let finished = last.finished {
                Text("Last scan: \(finished.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
                if last.status == .cancelled {
                    Text("Incomplete — resume available").font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Text("Not scanned yet").font(.caption).foregroundStyle(.secondary)
            }
            PrivacyNotice(compact: true).padding(.top, 4)
        }
    }
}

/// The mandatory confirmation step before anything is moved to the Trash.
struct TrashConfirmationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var request: TrashRequest
    @State private var isWorking = false

    private var total: Int64 { request.candidates.reduce(0) { $0 + ($1.size ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "trash").font(.system(size: 28)).foregroundStyle(.red)
                Text("You are about to remove:").font(.title3.weight(.semibold))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(request.candidates) { candidate in
                        let safety = SecurityUtils.evaluate(path: candidate.path)
                        HStack(alignment: .top, spacing: 10) {
                            Image(nsImage: FinderActions.icon(for: candidate.path)).resizable().frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.name).font(.headline)
                                Text("Size: \(ByteFormatter.string(optional: candidate.size, placeholder: "Unknown"))").monospacedDigit()
                                Text("Location: \(candidate.path.abbreviatingHome)").foregroundStyle(.secondary).textSelection(.enabled)
                                if let note = candidate.note {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                                if case .caution(let warning) = safety {
                                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            if request.candidates.count > 1 {
                Text("Total: \(ByteFormatter.string(total)) in \(request.candidates.count) items").font(.subheadline.weight(.medium))
            }
            Text("Items are moved to the Trash, not deleted. You can put them back from the Trash until you empty it.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) {
                    isWorking = true
                    Task {
                        await model.confirmTrash(request)
                        isWorking = false
                    }
                }
                .disabled(isWorking)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
