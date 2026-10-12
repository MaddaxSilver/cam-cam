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

    init() {
        #if DEBUG
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-qualityAudit"),
           ProcessInfo.processInfo.arguments.count > i + 1 {
            let camera = CameraManager()
            var path = ProcessInfo.processInfo.arguments[i + 1]
            if !path.hasPrefix("/") {          // a file in the app's Documents (on the phone)
                path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(path).path
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                LookAudit.runQuality(camera: camera, path: path)
                print("[quality] done")
                exit(0)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-poseCards") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("posecards")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (i, pose) in PoseLibrary.all.enumerated() {
                    let card = PoseCard(pose: pose, index: i, count: PoseLibrary.all.count,
                                        match: Double(i % 4) / 3, matched: i % 4 == 3) {}
                        .padding(12).background(Color(white: 0.35))
                    let r = ImageRenderer(content: card); r.scale = 3
                    if let img = r.uiImage, let d = img.pngData() { try? d.write(to: dir.appendingPathComponent("\(i)-\(pose.id).png")) }
                }
                print("[poseCards] done", dir.path)
                exit(0)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-aeAudit") {
            let camera = CameraManager()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                camera.cachedActiveCustomSim = nil
                for sim in FilmSimulation.allCases {
                    camera.cachedSim = sim
                    let o = SmartExposure.measureLook(camera)
                    print(String(format: "[ae] %@ %+.2f", sim.rawValue, o ?? .nan))
                }
                exit(0)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-lookAudit") {
            let camera = CameraManager()
            // Let loadSettings' main-queue writes land first, then audit off-main.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                LookAudit.run(camera: camera)
                exit(0)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
