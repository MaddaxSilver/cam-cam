//
//  cam_camApp.swift
//  cam cam
//
//  Created by maddax silver on 2026-04-07.
//

import SwiftUI

// Lock interface to portrait — device rotation is handled by rotating icons/text only
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .portrait
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
