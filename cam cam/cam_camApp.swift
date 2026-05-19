//
//  cam_camApp.swift
//  cam cam
//
//  Created by maddax silver on 2026-04-07.
//

import SwiftUI

// Default to portrait, but allow specific views (e.g. SonyView's "rotation
// unlock" toggle) to temporarily widen this to .all so iOS auto-rotates the UI
// when the phone is tilted. The view is responsible for resetting to .portrait
// when it disappears.
class AppDelegate: NSObject, UIApplicationDelegate {
    /// Mutable so individual screens can opt in/out of system rotation.
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return Self.orientationLock
    }
}

@main
struct cam_camApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
