import SwiftUI
import UIKit

@MainActor final class AmmoPhoneDelegate:NSObject,UIApplicationDelegate {
    func application(_ application:UIApplication,didFinishLaunchingWithOptions launchOptions:[UIApplication.LaunchOptionsKey:Any]?=nil)->Bool {
        _ = LocalAmmoStore.phoneShared
        return true
    }
}

@main struct AmmoPhoneApp: App {
    @UIApplicationDelegateAdaptor(AmmoPhoneDelegate.self) private var appDelegate
    @StateObject private var store = LocalAmmoStore.phoneShared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LocalPhoneRootView()
                .environmentObject(store)
                .onAppear {store.setActive(scenePhase == .active)}
                .onChange(of: scenePhase) { _, phase in store.setActive(phase == .active) }
        }
    }
}
