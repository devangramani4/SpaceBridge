import SwiftUI

@main
struct SpaceBridgeApp: App {
    @State private var model: AppModel

    init() {
        SettingsKey.registerDefaults()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("SpaceBridge", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
                .task { await model.start() }
        }
        // The window can't shrink below the content's minimum, so nothing is ever clipped.
        .windowResizability(.contentMinSize)
        // Designed for a normal (non-full-screen) window; everything adapts down to 720 × 480.
        .defaultSize(width: 1000, height: 660)
        .windowToolbarStyle(.unified)
        .commands { SpaceBridgeCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 600, height: 500)
        }
    }
}

struct SpaceBridgeCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .appInfo) {
            Button("SpaceBridge Pro…") { model.showPaywall() }
        }
        CommandMenu("Scan") {
            Button("Scan Mac") { model.scan.startScan() }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.scan.isScanning)
            Button("Resume Previous Scan") { model.scan.startScan(resume: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.scan.isScanning || model.scan.resumableScanID == nil)
            Button(model.scan.isPaused ? "Continue Scan" : "Pause Scan") {
                model.scan.isPaused ? model.scan.resume() : model.scan.pause()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!model.scan.isScanning)
            Button("Cancel Scan") { model.scan.cancel() }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!model.scan.isScanning)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(navigationShortcuts.enumerated()), id: \.offset) { index, item in
                Button(item.title) { model.selection = item }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
            }
            Button("Search") { model.selection = .search }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }
    }

    private var navigationShortcuts: [SidebarItem] {
        [.dashboard, .storage, .largestFiles, .largestFolders, .applications, .runningApps, .memory, .cpu, .cleanup]
    }
}
