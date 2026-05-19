//
//  WatchConnector.swift
//  cam cam
//
//  Bridges WatchConnectivity messages from the paired Apple Watch to the
//  CameraManager. Phase 1: remote shutter / burst toggle / quick state mirror.
//

import Foundation
import WatchConnectivity
import AVFoundation

@MainActor
final class WatchConnector: NSObject {
    static let shared = WatchConnector()

    /// Set by CameraContentView once the manager exists. Held weakly so the
    /// connector doesn't extend the manager's lifetime.
    weak var camera: CameraManager?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
    }

    /// Push a small state snapshot to the Watch so it can render the right pill colors.
    /// Throttled by the caller (typically: when a relevant @Observable property changes).
    func pushState() {
        guard WCSession.isSupported(), WCSession.default.isPaired,
              WCSession.default.activationState == .activated,
              let camera else { return }
        // Tuple-encode films as parallel arrays since dictionaries-of-strings travel cleanly via WC.
        let sims = FilmSimulation.allCases
        let simRaws  = sims.map { $0.rawValue }
        let simLabels = sims.map { $0.label }
        let presetMMs = focalPresets.map { $0.mm }
        let context: [String: Any] = [
            "isCapturing":   camera.isCapturing,
            "isBursting":    camera.isBursting,
            "isRecording":   camera.isRecording,
            "burstMode":     camera.burstMode,
            "currentMM":     camera.currentMM,
            "flashOn":       camera.flashMode != .off,
            "selectedSim":   camera.selectedSim.rawValue,
            "simRaws":       simRaws,
            "simLabels":     simLabels,
            "rawEnabled":    camera.rawEnabled,
            "evReading":     camera.evReading,
            "exposureBias":  camera.exposureBias,
            "presetMMs":     presetMMs,
            "selectedFocalIdx": camera.selectedFocalIndex
        ]
        try? WCSession.default.updateApplicationContext(context)
    }
}

extension WatchConnector: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) { }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) { }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // iPhone supports re-activating after pairing changes
        WCSession.default.activate()
    }

    /// Watch → iPhone commands (no reply expected).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        guard let cmd = message["cmd"] as? String else { return }
        // Use DispatchQueue.main.async (not Task @MainActor) — it skips the
        // executor scheduling overhead. Matters most for "shutter" latency.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let camera = WatchConnector.shared.camera else { return }
                switch cmd {
                case "shutter":
                    guard !camera.isCapturing else { return }
                    if camera.doubleExposureEnabled && camera.firstExposurePreview == nil {
                        camera.captureDoubleExposureFirst()
                    } else {
                        camera.capturePhoto()
                    }
                case "burstStart":
                camera.startBurst()
            case "burstStop":
                camera.stopBurst()
            case "recordToggle":
                if camera.isRecording {
                    camera.stopRecording()
                } else {
                    camera.startRecording()
                }
            case "toggleFlash":
                camera.toggleFlash()
            case "requestState":
                WatchConnector.shared.pushState()
            case "setSim":
                if let raw = message["raw"] as? String, let sim = FilmSimulation(rawValue: raw) {
                    camera.selectedSim = sim
                    WatchConnector.shared.pushState()
                }
            case "toggleRaw":
                camera.rawEnabled.toggle()
                WatchConnector.shared.pushState()
            case "setFocalPreset":
                if let idx = message["idx"] as? Int, idx >= 0, idx < focalPresets.count {
                    camera.selectFocalPreset(idx)
                    WatchConnector.shared.pushState()
                }
            case "setUnifiedZoom":
                if let on = message["on"] as? Bool {
                    camera.unifiedZoomMode = on
                    WatchConnector.shared.pushState()
                }
                default:
                    break
                }
            }
        }
    }
}
