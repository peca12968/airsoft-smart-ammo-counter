import SwiftUI

@main struct AmmoPhoneApp: App {
    @StateObject private var store = LocalAmmoStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LocalPhoneRootView()
                .environmentObject(store)
                .onChange(of: scenePhase) { _, phase in store.setActive(phase == .active) }
        }
    }
}
