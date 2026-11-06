import SwiftUI

import UIKit

/// iOS wakes the app when downloads finish in the background; they're handled, then iOS is told.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Fetcher.backgroundDone = completionHandler
        _ = Offline.shared
    }
}

@main
struct ADPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}
