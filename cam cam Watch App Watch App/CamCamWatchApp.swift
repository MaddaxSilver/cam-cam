//
//  CamCamWatchApp.swift
//  cam cam Watch App
//
//  Phase 1: remote shutter only. Pairs to the iPhone app via WatchConnectivity
//  and sends "cmd" messages; receives small ApplicationContext snapshots back.
//

import SwiftUI

@main
struct CamCamWatchApp: App {
    @StateObject private var connector = WatchPhoneConnector()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(connector)
                .onAppear { connector.activate() }
        }
    }
}
