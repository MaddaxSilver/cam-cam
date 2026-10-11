//
//  VolumeButtonObserver.swift
//  cam cam
//
//  Hardware volume-button capture/override.
//

import SwiftUI
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import Observation
import CoreMotion
import MediaPlayer
import MetalKit
import UniformTypeIdentifiers
import CoreLocation

// MARK: - Volume Button EV Observer

final class VolumeButtonObserver {
    private var volumeObservation: NSKeyValueObservation?
    private var foregroundObserver: Any?
    private var didBecomeActiveObserver: Any?
    private var interruptionObserver: Any?
    private let session = AVAudioSession.sharedInstance()
    private var ignoreNextChange = false
    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?

    /// When non-nil, ALL instances of this observer reroute their callbacks
    /// to these closures instead of firing onVolumeUp/onVolumeDown.
    /// Used by SonyView to take exclusive control of the volume buttons
    /// (so they cycle film sims instead of triggering the underlying
    /// CameraView's zoom). SonyView sets these on .onAppear and clears
    /// them on .onDisappear.
    nonisolated(unsafe) static var overrideOnUp:   (() -> Void)? = nil
    nonisolated(unsafe) static var overrideOnDown: (() -> Void)? = nil

    // MPVolumeView owned here and added directly to the key window —
    // this is the only reliable way to suppress the system volume HUD.
    private var mpView: MPVolumeView?
    private var systemSlider: UISlider?

    init() {
        activateSession()
        startObserving()
        // Inject MPVolumeView into the key window on the next run-loop tick
        // (window may not be key yet during init)
        DispatchQueue.main.async { [weak self] in self?.installVolumeView() }

        // Re-activate audio session when app returns to foreground (background → foreground)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reactivate()
        }

        // Also reactivate on didBecomeActive — covers cold launch where the camera
        // session may have overridden our .playback category during startup.
        // Small delay ensures the camera session has finished configuring.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.reactivate()
            }
        }

        // Reactivate after audio session interruptions (calls, Siri, etc.)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.ended.rawValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.reactivate()
            }
        }
    }

    func reactivate() {
        activateSession()
        // Re-subscribe KVO — the old observation may be stale after background
        volumeObservation?.invalidate()
        ignoreNextChange = false
        startObserving()
        // Reset volume to midpoint so both directions work
        if let slider = systemSlider {
            ignoreNextChange = true
            setSystemVolume(0.5, on: slider)
        }
    }

    private func installVolumeView() {
        // Find the key window and add MPVolumeView directly to it.
        // This is the only reliable way to suppress the system HUD — SwiftUI's
        // view hierarchy sits behind an extra UIWindow layer that the HUD ignores.
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard let window = keyWindow else {
            // Window not ready yet — retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.installVolumeView()
            }
            return
        }
        if mpView?.window == window { return }   // already installed

        let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.alpha = 0.00001
        v.clipsToBounds = true
        v.isUserInteractionEnabled = false
        window.addSubview(v)
        mpView = v

        // Grab the internal slider immediately so we can reset volume after each press
        if let slider = v.subviews.first(where: { $0 is UISlider }) as? UISlider {
            ignoreNextChange = true
            setSystemVolume(0.5, on: slider)
            systemSlider = slider
        }
    }

    private func activateSession() {
        // AVAudioSession.setActive can block briefly while CoreAudio reconfigures
        // routes. Apple specifically warns against calling it on main — kick it
        // to a background queue. Category change is cheap and stays on main.
        try? session.setCategory(.playback, options: .mixWithOthers)
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            try? session.setActive(true, options: .notifyOthersOnDeactivation)
        }
    }

    private func startObserving() {
        volumeObservation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
            guard let self else { return }
            if self.ignoreNextChange {
                self.ignoreNextChange = false
                return
            }
            guard let oldVal = change.oldValue, let newVal = change.newValue, oldVal != newVal else { return }
            let wentUp = newVal > oldVal
            DispatchQueue.main.async {
                // If a global override is installed (e.g. SonyView is up),
                // route presses there INSTEAD of our local callbacks.
                if let up = VolumeButtonObserver.overrideOnUp,
                   let down = VolumeButtonObserver.overrideOnDown {
                    if wentUp { up() } else { down() }
                } else if wentUp {
                    self.onVolumeUp?()
                } else {
                    self.onVolumeDown?()
                }
                if let slider = self.systemSlider {
                    self.ignoreNextChange = true
                    self.setSystemVolume(0.5, on: slider)
                }
            }
        }
    }

    private func setSystemVolume(_ value: Float, on slider: UISlider) {
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
    }

    deinit {
        volumeObservation?.invalidate()
        if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = didBecomeActiveObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = interruptionObserver { NotificationCenter.default.removeObserver(obs) }
    }
}
