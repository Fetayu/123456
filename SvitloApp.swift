import SwiftUI

@main
struct SvitloApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        Notifier.setup()
        BG.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(model.scheme)
        }
        .onChange(of: phase) { p in
            if p == .active {
                model.onActive()
            } else if p == .background {
                BG.schedule()
                Notifier.planBoundaries()
            }
        }
    }
}
