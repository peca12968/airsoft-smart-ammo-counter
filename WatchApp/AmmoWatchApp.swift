import SwiftUI
import AmmoCore

@main struct AmmoWatchApp: App {
    @StateObject private var store = LocalAmmoStore()
    @Environment(\.scenePhase) private var scenePhase
    private func captureScene(_ phase:ScenePhase)->CaptureSceneState {
        switch phase {
        case .active:return .active
        case .inactive:return .inactive
        case .background:return .background
        @unknown default:return .background
        }
    }
    var body: some Scene {
        WindowGroup {
            LocalWatchRootView().environmentObject(store)
                .onAppear {store.setWatchScene(captureScene(scenePhase))}
                .onChange(of: scenePhase) { _, phase in store.setWatchScene(captureScene(phase)) }
        }
    }
}
