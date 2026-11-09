import SwiftUI

@main
struct SpaceBridgeMobileApp: App {
    @State private var model = MobileModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.refreshStorage() }
                }
        }
    }
}
