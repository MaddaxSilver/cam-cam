//
//  WatchPhoneConnector.swift
//  cam cam Watch App
//
//  Watch-side WCSessionDelegate. Sends commands to the iPhone and observes
//  the most recent state snapshot from the iPhone's applicationContext.
//

import Foundation
import WatchConnectivity
import Combine

final class WatchPhoneConnector: NSObject, ObservableObject, WCSessionDelegate {
    @Published var isReachable: Bool = false
    @Published var isCapturing: Bool = false
    @Published var isBursting: Bool = false
    @Published var isRecording: Bool = false
    @Published var burstMode: Bool = false
    @Published var currentMM: Int = 28
    @Published var flashOn: Bool = false
    @Published var selectedSim: String = "none"
    @Published var sims: [(raw: String, label: String)] = []
    @Published var rawEnabled: Bool = false
    @Published var evReading: Float = 0.0
    @Published var exposureBias: Float = 0.0
    @Published var presetMMs: [Int] = []
    @Published var selectedFocalIdx: Int = -1

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
    }

    // MARK: - Commands

    func sendShutter() {
        send(["cmd": "shutter"])
    }

    func sendBurstStart() {
        send(["cmd": "burstStart"])
    }

    func sendBurstStop() {
        send(["cmd": "burstStop"])
    }

    func sendRecordToggle() {
        send(["cmd": "recordToggle"])
    }

    func sendToggleFlash() {
        send(["cmd": "toggleFlash"])
    }

    func sendSetSim(_ raw: String) {
        send(["cmd": "setSim", "raw": raw])
    }

    func sendToggleRaw() {
        send(["cmd": "toggleRaw"])
    }

    func sendSetFocalPreset(_ idx: Int) {
        send(["cmd": "setFocalPreset", "idx": idx])
    }

    func sendSetUnifiedZoom(_ on: Bool) {
        send(["cmd": "setUnifiedZoom", "on": on])
    }

    func requestState() {
        send(["cmd": "requestState"])
    }

    private func send(_ payload: [String: Any]) {
        guard WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable {
            // Live message — fastest, requires phone foreground+app running
            WCSession.default.sendMessage(payload, replyHandler: nil) { _ in }
        } else {
            // Fallback — queues until phone wakes
            WCSession.default.transferUserInfo(payload)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        DispatchQueue.main.async { self.isReachable = session.isReachable }
        // Pull the latest state snapshot once we're up
        DispatchQueue.main.async { self.requestState() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.isReachable = session.isReachable }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        DispatchQueue.main.async { self.applyContext(applicationContext) }
    }

    private func applyContext(_ ctx: [String: Any]) {
        if let v = ctx["isCapturing"] as? Bool { isCapturing = v }
        if let v = ctx["isBursting"]  as? Bool { isBursting = v }
        if let v = ctx["isRecording"] as? Bool { isRecording = v }
        if let v = ctx["burstMode"]   as? Bool { burstMode = v }
        if let v = ctx["currentMM"]   as? Int  { currentMM = v }
        if let v = ctx["flashOn"]     as? Bool { flashOn = v }
        if let v = ctx["selectedSim"] as? String { selectedSim = v }
        if let raws = ctx["simRaws"] as? [String], let labels = ctx["simLabels"] as? [String], raws.count == labels.count {
            sims = zip(raws, labels).map { (raw: $0.0, label: $0.1) }
        }
        if let v = ctx["rawEnabled"]   as? Bool   { rawEnabled = v }
        if let v = ctx["evReading"]    as? Float  { evReading = v }
        if let v = ctx["exposureBias"] as? Float  { exposureBias = v }
        if let v = ctx["presetMMs"]    as? [Int]  { presetMMs = v }
        if let v = ctx["selectedFocalIdx"] as? Int { selectedFocalIdx = v }
    }
}
