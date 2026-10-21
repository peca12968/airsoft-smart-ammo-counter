import SwiftUI

@main struct AmmoWatchApp: App {
    @StateObject private var store = LocalAmmoStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            LocalWatchRootView().environmentObject(store)
                .onAppear {store.setActive(scenePhase == .active)}
                .onChange(of: scenePhase) { _, phase in store.setActive(phase == .active) }
        }
    }
}
