//
//  CameraManager.swift
//  cam cam
//
//  CameraManager: capture session, settings, the recipe-driven look pipeline, and the capture delegates.
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

// MARK: - CameraManager

@Observable final class CameraManager: NSObject, AVCaptureMetadataOutputObjectsDelegate, AVCaptureDepthDataOutputDelegate {

    var isAuthorized = false
    var isDenied = false
    var selectedSim: FilmSimulation = .none {
        didSet {
            cachedSim = selectedSim
            UserDefaults.standard.set(selectedSim.rawValue, forKey: "cc_selectedSim")
            // Night shot auto-manages flash: enable on entry, restore off on exit
            if selectedSim == .nightShot {
                flashMode = .on
                if flashStrength < 0.8 { flashStrength = 1.0 }
            } else if oldValue == .nightShot {
                flashMode = .off
            }
        }
    }
    var selectedAspectRatio: AspectRatio = .widescreen {
        didSet { UserDefaults.standard.set(selectedAspectRatio.rawValue, forKey: "cc_aspectRatio") }
    }
    var isLandscape: Bool = false
    var deviceAngle: Double = 0
    /// Look strength (0…1): how much of the film look is applied.
    var lookStrength: Float = UserDefaults.standard.object(forKey: "cc_lookStrength") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(lookStrength, forKey: "cc_lookStrength")
            cachedLookStrength = lookStrength
        }
    }
    @ObservationIgnored nonisolated(unsafe) var cachedLookStrength: Float = UserDefaults.standard.object(forKey: "cc_lookStrength") as? Float ?? 1
    @ObservationIgnored nonisolated(unsafe) var pendingLookStrength: Float = 1
    var grainAmount: Float = 0.0 {
        didSet {
            UserDefaults.standard.set(grainAmount, forKey: "cc_grainAmount")
            cachedGrainAmount = grainAmount
            grainPreviewTextures = []   // invalidate — rebuilt lazily on next preview frame
        }
    }
    var grainEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(grainEnabled, forKey: "cc_grainEnabled")
            cachedGrainEnabled = grainEnabled
        }
    }
    var contextAwareGrainEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(contextAwareGrainEnabled, forKey: "cc_contextAwareGrain")
            cachedContextAwareGrain = contextAwareGrainEnabled
        }
    }
    var exposureBias: Float = 0.0
    var isoValue: Float = 100.0
    var shutterSpeed: Double = 1.0 / 60.0
    var isCapturing = false {
        didSet { if oldValue != isCapturing { WatchConnector.shared.pushState() } }
    }
    /// Transient user-visible error from save / library operations. Cleared by the UI.
    var saveErrorMessage: String? = nil
    /// Small graded preview of the latest shot, shown in the thumbnail long
    /// before the full-res photo has rendered and reached Photos.
    var lastShotPreview: UIImage? = nil
    var flashMode: AVCaptureDevice.FlashMode = .off
    var flashStrength: Float = 1.0 {
        didSet { UserDefaults.standard.set(flashStrength, forKey: "cc_flashStrength") }
    }
    var isFocusing: Bool = false          // true while camera is hunting for focus
    var faceDetected: Bool = false {      // true when ≥1 face is in frame
        didSet { SmartExposure.shared.faceHint = faceDetected }
    }
    var manualFocusEnabled: Bool = false
    var manualFocusValue: Float = 0.5 {
        didSet { cachedManualFocusValue = manualFocusValue }
    }
    /// Nonisolated mirror of manualFocusValue, safe for sample-buffer/swap callbacks.
    @ObservationIgnored nonisolated(unsafe) var cachedManualFocusValue: Float = 0.5

    // Portrait mode
    var portraitModeEnabled: Bool = false {
        didSet {
            portraitSessionWanted = portraitNeedsDepthCamera
            if portraitModeEnabled { MonoDepth.prewarm() }
            applyPortraitModeSession()
            if portraitModeEnabled != oldValue { routeForPortrait() }
        }
    }
    /// Portrait needs the multi-lens camera's 12MP depth format — unless
    /// Depth Anything is bundled and we're at Max: then Portrait stays on the
    /// 48MP main lens and the depth comes from the photo itself.
    var portraitNeedsDepthCamera: Bool { portraitModeEnabled && !(full48 && MonoDepth.available) }
    /// Portrait wanted (read on the session queue when picking formats).
    @ObservationIgnored nonisolated(unsafe) var portraitSessionWanted = false
    /// The phone has a multi-lens back camera, which is what produces depth.
    nonisolated static let hasDepthCamera: Bool =
        [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]
            .contains { AVCaptureDevice.default($0, for: .video, position: .back) != nil }
    var portraitFStop: Float = 2.8        // f/1.4 → f/16
    var portraitModeAvailable: Bool = false
    /// True if the currently active device's format produces depth data.
    /// Updated on every lens swap; portrait toggle is hidden when false.
    var currentDeviceSupportsDepth: Bool = false
    var selectedFocalIndex: Int = 1 {
        didSet { UserDefaults.standard.set(selectedFocalIndex, forKey: "cc_focalIndex") }
    }
    var isLongExposure: Bool = false
    var longExposureMode: LongExposureMode = .frameStack {
        didSet { UserDefaults.standard.set(longExposureMode.rawValue, forKey: "cc_longExposureMode") }
    }
    var longExposureDuration: Double = 2.0 {
        didSet { UserDefaults.standard.set(longExposureDuration, forKey: "cc_longExposureDuration") }
    }
    var doubleExposureEnabled: Bool = false
    var doubleExposureMaskEnabled: Bool = false
    var doubleExposureMask: UIImage? = nil
    var maskBrushSize: CGFloat = 40 {
        didSet { UserDefaults.standard.set(Double(maskBrushSize), forKey: "cc_maskBrushSize") }
    }
    var pushPullEnabled: Bool = false {
        didSet { UserDefaults.standard.set(pushPullEnabled, forKey: "cc_pushPullEnabled"); cachedPushPullEnabled = pushPullEnabled }
    }
    var pushPullAmount: Float = 0.0 {
        didSet { UserDefaults.standard.set(pushPullAmount, forKey: "cc_pushPullAmount"); cachedPushPullAmount = pushPullAmount }
    }
    var anamorphicFlareEnabled: Bool = false {
        didSet { UserDefaults.standard.set(anamorphicFlareEnabled, forKey: "cc_anamorphicFlare"); cachedAnamorphicFlare = anamorphicFlareEnabled }
    }
    var lightArtifactsEnabled: Bool = false {
        didSet { UserDefaults.standard.set(lightArtifactsEnabled, forKey: "cc_lightArtifacts"); cachedLightArtifacts = lightArtifactsEnabled }
    }
    var filmScratchesEnabled: Bool = false {
        didSet { UserDefaults.standard.set(filmScratchesEnabled, forKey: "cc_filmScratches"); cachedFilmScratches = filmScratchesEnabled }
    }
    var filmRandomizationEnabled: Bool = false {
        didSet { UserDefaults.standard.set(filmRandomizationEnabled, forKey: "cc_filmRando"); cachedFilmRandomization = filmRandomizationEnabled }
    }
    // Thread-safe mirrors of the four toggles above, read off-main when
    // building a live ShotRecipe (Sony live view / Sony captures).
    @ObservationIgnored nonisolated(unsafe) var cachedAnamorphicFlare = false
    @ObservationIgnored nonisolated(unsafe) var cachedLightArtifacts = false
    @ObservationIgnored nonisolated(unsafe) var cachedFilmScratches = false
    @ObservationIgnored nonisolated(unsafe) var cachedFilmRandomization = false
    var maskBrushOpacity: Double = 1.0 // 1 = expose more, 0 = erase mask
    var showGrid: Bool = false {
        didSet { UserDefaults.standard.set(showGrid, forKey: "cc_showGrid") }
    }
    var showLevel: Bool = false {
        didSet { UserDefaults.standard.set(showLevel, forKey: "cc_showLevel") }
    }
    /// Zebra stripes on anything about to clip (display only, never saved).
    var showZebras: Bool = UserDefaults.standard.bool(forKey: "cc_showZebras") {
        didSet { cachedZebras = showZebras; UserDefaults.standard.set(showZebras, forKey: "cc_showZebras") }
    }
    @ObservationIgnored nonisolated(unsafe) var cachedThermalCritical = false
    @ObservationIgnored nonisolated(unsafe) var cachedZebras = UserDefaults.standard.bool(forKey: "cc_showZebras")
    var showPeaking: Bool = false {
        didSet { UserDefaults.standard.set(showPeaking, forKey: "cc_showPeaking") }
    }
    var evReading: Float = 0.0
    var crosstalkAmount: Float = 0.1 {
        didSet { UserDefaults.standard.set(crosstalkAmount, forKey: "cc_crosstalkAmount"); cachedCrosstalkAmount = crosstalkAmount }
    }
    var crosstalkEnabled: Bool = false {
        didSet { UserDefaults.standard.set(crosstalkEnabled, forKey: "cc_crosstalkEnabled"); cachedCrosstalkEnabled = crosstalkEnabled }
    }
    var halationAmount: Float = 0.2 {
        didSet { UserDefaults.standard.set(halationAmount, forKey: "cc_halationAmount"); cachedHalationAmount = halationAmount }
    }
    var halationEnabled: Bool = false {
        didSet { UserDefaults.standard.set(halationEnabled, forKey: "cc_halationEnabled"); cachedHalationEnabled = halationEnabled }
    }
    /// DigiCam quality 5...20. Low = crustier (more noise, fewer posterize
    /// levels, deeper crush). High = cleaner (closer to a modern compact).
    /// Only relevant when `.digiCam` is the active sim — slider is hidden
    /// in the menu otherwise.
    var digiCamQuality: Float = 12 {
        didSet { UserDefaults.standard.set(digiCamQuality, forKey: "cc_digiCamQuality"); cachedDigiCamQuality = digiCamQuality }
    }
    var rolloffEnabled: Bool = false {
        didSet { UserDefaults.standard.set(rolloffEnabled, forKey: "cc_rolloffEnabled"); cachedRolloffEnabled = rolloffEnabled }
    }
    var rolloffThreshold: Float = 0.9 {
        didSet { UserDefaults.standard.set(rolloffThreshold, forKey: "cc_rolloffThreshold"); cachedRolloffThreshold = rolloffThreshold }
    }
    var rawEnabled: Bool = false {
        didSet { UserDefaults.standard.set(rawEnabled, forKey: "cc_rawEnabled") }
    }
    var doubleExposureOpacity: Double = 0.5
    var firstExposurePreview: CGImage?
    var burstMode: Bool = false {
        didSet { UserDefaults.standard.set(burstMode, forKey: "cc_burstMode") }
    }
    /// When true, the shutter cluster (flash · shutter · zoom) moves to where
    /// the EV dial sits and the EV dial moves to the center. Lefty / one-handed mode.
    var shutterOnLeft: Bool = false {
        didSet { UserDefaults.standard.set(shutterOnLeft, forKey: "cc_shutterOnLeft") }
    }
    /// When true, all presets (except 13mm ultrawide) and slider zoom route through the
    /// virtual triple camera — single device, no preset swaps, iOS handles wide↔tele
    /// internally. When false (default), 28-70mm presets snap to the physical wide lens
    /// for explicit lens control.
    var unifiedZoomMode: Bool = false {
        didSet {
            UserDefaults.standard.set(unifiedZoomMode, forKey: "cc_unifiedZoom")
            if oldValue != unifiedZoomMode, currentDevice != nil { routeForPortrait() }
        }
    }
    /// One lens in use right now. iOS caps the multi-lens camera at 24MP, so
    /// Max and Natural (48MP) use each lens directly instead.
    var oneLensActive: Bool { unifiedZoomMode && photoQuality < 2 }
    /// Max / Natural: every photo is saved at 48MP (crops, telephoto and
    /// ultra-wide shots are upscaled before the film, so grain matches).
    var full48: Bool { photoQuality >= 2 }
    /// Macro mode — forces the physical ultrawide lens whose minimum focus distance is ~2cm.
    /// Disabling does not auto-swap back; the user navigates via focal presets / slider as normal.
    var macroModeEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(macroModeEnabled, forKey: "cc_macroMode")
            if macroModeEnabled && oldValue == false {
                // Swap to physical ultrawide so close subjects can focus
                selectFocalPreset(0)
            }
        }
    }
    var isBursting: Bool = false
    var isRecording: Bool = false {
        didSet { cachedIsRecording = isRecording }
    }
    var recordingDuration: TimeInterval = 0
    var burstCount: Int = 0
    var showZoomSlider: Bool = false
    var zoom: Double = 1.0
    /// When both manual zoom and double exposure are active, tapping the
    /// blend pill shifts volume buttons from zoom to blend control.
    var volumeControlsBlend: Bool = false
    /// When the zoom slider is open, tapping the EV dial shifts volume
    /// buttons from zoom to exposure control.
    var volumeControlsEV: Bool = false
    /// When ON, the volume up button fires the shutter instead of zoom/EV/blend.
    var volumeShutterEnabled: Bool = false {
        didSet { UserDefaults.standard.set(volumeShutterEnabled, forKey: "cc_volumeShutter") }
    }
    var currentMM: Int = 28
    var maxManualZoom: Double = 25.0
    var isFrontCamera: Bool = false
    var photoQuality: Int = 2 { // 0 speed, 1 balanced, 2 quality (Max), 3 natural (ProRAW, no Apple processing)
        didSet {
            UserDefaults.standard.set(photoQuality, forKey: "cc_photoQuality")
            if (oldValue >= 2) != (photoQuality >= 2), currentDevice != nil, unifiedZoomMode || portraitModeEnabled {
                portraitSessionWanted = portraitNeedsDepthCamera
                routeForPortrait()
            }
        }
    }
    /// Observable so the UI follows it; the capture/render queues read the mirror.
    var activeCustomSim: CustomSimulation? {
        didSet {
            cachedActiveCustomSim = activeCustomSim
            // A saved camera brings its grain and aspect with it.
            if let c = activeCustomSim, c.id != oldValue?.id {
                if let g = c.grainAmount { grainEnabled = g > 0; if g > 0 { grainAmount = g } }
                if let a = c.aspect.flatMap(AspectRatio.init(rawValue:)) { selectedAspectRatio = a }
            }
        }
    }
    @ObservationIgnored nonisolated(unsafe) var cachedActiveCustomSim: CustomSimulation?
    // Live-cached effect flags for preview rendering (updated via didSet)
    @ObservationIgnored nonisolated(unsafe) var cachedCrosstalkEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var cachedCrosstalkAmount: Float = 0.1
    @ObservationIgnored nonisolated(unsafe) var cachedHalationEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var cachedHalationAmount: Float = 0.2
    @ObservationIgnored nonisolated(unsafe) var cachedDigiCamQuality: Float = 12
    @ObservationIgnored nonisolated(unsafe) var cachedRolloffEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var cachedRolloffThreshold: Float = 0.9
    @ObservationIgnored nonisolated(unsafe) var cachedPushPullEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var cachedPushPullAmount: Float = 0.0
    /// Development: 0 = agitated (normal) … 1 = stand development.
    var development: Float = UserDefaults.standard.float(forKey: "cc_development") {
        didSet { UserDefaults.standard.set(development, forKey: "cc_development"); cachedDevelopment = development }
    }
    @ObservationIgnored nonisolated(unsafe) var cachedDevelopment: Float = UserDefaults.standard.float(forKey: "cc_development")
    @ObservationIgnored nonisolated(unsafe) var pendingDevelopment: Float = 0

    // Cached rainbow gradient for the circuit-bent thermal LUT. Built once
    // (CGContext draw is expensive) and reused every frame via CIColorMap.
    @ObservationIgnored nonisolated(unsafe) var cachedThermalGradient: CIImage? = nil

    // Grain preview cache — 8 pre-baked textures cycled per frame so the
    // preview path never generates filter graphs at render time.
    @ObservationIgnored nonisolated(unsafe) var cachedGrainEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var cachedGrainAmount: Float = 0.0
    @ObservationIgnored nonisolated(unsafe) var cachedContextAwareGrain: Bool = false
    @ObservationIgnored nonisolated(unsafe) var grainPreviewTextures: [CIImage] = []
    @ObservationIgnored nonisolated(unsafe) var grainPreviewFrameIdx: Int = 0
    @ObservationIgnored nonisolated(unsafe) var grainPreviewSize: CGFloat = 1
    /// Live sensor ISO (context-aware grain in the preview), updated by Smart AE's tick.
    @ObservationIgnored nonisolated(unsafe) var cachedLiveISO: Float?
    /// Mean display brightness of the live frame (from Smart AE's metering).
    @ObservationIgnored nonisolated(unsafe) var cachedFrameLuma: Float?
    /// ISO of the shot being rendered (set per shot before its recipe is built).
    @ObservationIgnored nonisolated(unsafe) var pendingSceneISO: Float?

    /// ISO from a photo's EXIF.
    nonisolated static func captureISO(_ metadata: [String: Any]) -> Float? {
        guard let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let v = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first else { return nil }
        return v.floatValue
    }
    @ObservationIgnored nonisolated(unsafe) var grainPreviewExtent: CGRect = .zero
    @ObservationIgnored nonisolated(unsafe) var grainPreviewBuilding: Bool = false
    @ObservationIgnored nonisolated(unsafe) var grainPreviewLuma: Float = 0.5
    @ObservationIgnored nonisolated(unsafe) var grainPreviewLumaCounter: Int = 0

    /// Reference field-of-view (degrees) of the physical wide-angle lens.
    /// Used to compute per-device FOV compensation for virtual cameras.
    /// Refreshed any time we have a clean opportunity to query the physical wide.
    @ObservationIgnored nonisolated(unsafe) var physicalWideFOV: Float = 73.0

    // MARK: nonisolated(unsafe) stored properties
    nonisolated(unsafe) let session = AVCaptureSession()

    /// Stop the AVCaptureSession when the iPhone camera isn't being used —
    /// e.g. while SonyView is presented and the user is shooting via the
    /// Sony body's WiFi. The capture pipeline drains a real amount of
    /// battery (multiple watts), so stopping it during Sony mode is a big
    /// win. AVFoundation requires startRunning/stopRunning off the main
    /// thread to avoid blocking the UI.
    /// Runs on `sessionQueue` (the same serial queue as configureSession) so a
    /// pause can't race an in-flight configuration.
    @MainActor
    func pauseForExternalUse() {
        pausedForExternalUse = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Resume the AVCaptureSession after SonyView dismisses. Takes ~1 s for
    /// the camera to come back up, which is acceptable since the user is
    /// transitioning back into the phone-camera UI anyway.
    @MainActor
    func resumeFromExternalUse() {
        pausedForExternalUse = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    // MARK: Interruptions, runtime errors, thermal

    /// Shown over the viewfinder while the camera is interrupted (call,
    /// another app using the camera, Split View, overheating). nil = normal.
    var interruptionMessage: String? = nil
    /// Shown while live effects are reduced because the phone is hot.
    var thermalWarning: String? = nil
    @ObservationIgnored nonisolated(unsafe) var pausedForExternalUse = false
    /// Read per frame by the live path: drop expensive extras when hot.
    @ObservationIgnored nonisolated(unsafe) var cachedThermalThrottle = false
    @ObservationIgnored nonisolated(unsafe) private var sessionObserverTokens: [NSObjectProtocol] = []
    @ObservationIgnored nonisolated(unsafe) private var runtimeRestartCount = 0

    /// Without these the viewfinder froze for good after a phone call,
    /// FaceTime, another app grabbing the camera, or a media-services reset —
    /// only relaunching the app recovered.
    nonisolated func installSessionObservers() {
        let nc = NotificationCenter.default
        sessionObserverTokens.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            CameraManager.backgroundEpoch += 1
            CameraManager.inBackground = true
        })
        sessionObserverTokens.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            CameraManager.inBackground = false
        })
        sessionObserverTokens.append(nc.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
            let msg: String? = switch AVCaptureSession.InterruptionReason(rawValue: raw) {
            case .videoDeviceInUseByAnotherClient:                  "Camera in use by another app"
            case .videoDeviceNotAvailableWithMultipleForegroundApps: "Camera unavailable in Split View"
            case .videoDeviceNotAvailableDueToSystemPressure:        "Camera paused — iPhone is too hot"
            case .audioDeviceInUseByAnotherClient:                   "Microphone in use (call?)"
            case .videoDeviceNotAvailableInBackground:               nil   // normal backgrounding
            default:                                                 "Camera interrupted"
            }
            MainActor.assumeIsolated { self?.interruptionMessage = msg }
        })
        sessionObserverTokens.append(nc.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.interruptionMessage = nil }
        })
        sessionObserverTokens.append(nc.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            // Restart (bounded, so a persistent hardware fault can't loop forever).
            guard !self.pausedForExternalUse, self.runtimeRestartCount < 3 else {
                DispatchQueue.main.async { self.interruptionMessage = "Camera error — reopen the app" }
                return
            }
            self.runtimeRestartCount += 1
            DispatchQueue.main.async {
                self.interruptionMessage = err?.code == .mediaServicesWereReset
                    ? "Restarting camera…" : "Camera error — restarting…"
            }
            self.sessionQueue.asyncAfter(deadline: .now() + 0.5) {
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async {
                    if self.session.isRunning {
                        self.interruptionMessage = nil
                        self.runtimeRestartCount = 0
                    }
                }
            }
        })
        sessionObserverTokens.append(nc.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyThermalState(ProcessInfo.processInfo.thermalState) }
        })
        DispatchQueue.main.async { [weak self] in
            self?.applyThermalState(ProcessInfo.processInfo.thermalState)
        }
    }

    /// .serious/.critical: keep the base sim live but drop the expensive extras
    /// (halation, crosstalk, rolloff, Bent glitch) from preview + video.
    /// Captures still get the full look.
    @MainActor
    func applyThermalState(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .serious:
            cachedThermalThrottle = true
            cachedThermalCritical = false
            thermalWarning = "iPhone is warm — live effects reduced"
        case .critical:
            cachedThermalThrottle = true
            cachedThermalCritical = true
            thermalWarning = "iPhone is hot — let it cool"
        default:
            cachedThermalThrottle = false
            cachedThermalCritical = false
            thermalWarning = nil
        }
    }
    @ObservationIgnored nonisolated(unsafe) var sessionQueue = DispatchQueue(label: "cam.session", qos: .userInitiated)
    @ObservationIgnored nonisolated(unsafe) var frameOutputQueue = DispatchQueue(label: "cam.frame.output", qos: .userInteractive)
    // Single shared Metal-backed CIContext for all rendering (preview, capture, peaking)
    @ObservationIgnored nonisolated(unsafe) var ciContext: CIContext = {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let device = MTLCreateSystemDefaultDevice() else {
            return CIContext(options: [
                .useSoftwareRenderer: false,
                .workingColorSpace: p3,
                .outputColorSpace: p3
            ])
        }
        return CIContext(mtlDevice: device, options: [
            .workingColorSpace: p3,
            .outputColorSpace: p3,
            .cacheIntermediates: false
        ])
    }()

    /// Full-resolution photo renders get their own LOW-priority context. On
    /// the shared one, a 48MP film render (~3 s of GPU) queued ahead of the
    /// preview: the viewfinder froze for seconds after every shot.
    /// Photo renders: the GPU in the foreground; the CPU while the app is in
    /// the background, where iOS doesn't allow GPU work (shots taken just
    /// before leaving the app still develop — see DevelopActivity).
    nonisolated var photoContext: CIContext { Self.inBackground ? cpuPhotoContext : gpuPhotoContext }
    nonisolated(unsafe) static var inBackground = false
    /// Bumped each time the app goes to the background (a render that spans
    /// the switch is redone on the CPU).
    nonisolated(unsafe) static var backgroundEpoch = 0
    @ObservationIgnored nonisolated let cpuPhotoContext: CIContext = {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        return CIContext(options: [.workingColorSpace: p3, .outputColorSpace: p3,
                                   .cacheIntermediates: false, .useSoftwareRenderer: true])
    }()
    @ObservationIgnored nonisolated let gpuPhotoContext: CIContext = {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        var opts: [CIContextOption: Any] = [.workingColorSpace: p3, .outputColorSpace: p3,
                                            .cacheIntermediates: false, .priorityRequestLow: true]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: opts) }
        opts[.useSoftwareRenderer] = false
        return CIContext(options: opts)
    }()

    // Reusable CIFilter instances — avoid per-frame allocation
    @ObservationIgnored nonisolated(unsafe) var reusableColorControls = CIFilter.colorControls()
    @ObservationIgnored nonisolated(unsafe) var reusableTempTint = CIFilter.temperatureAndTint()
    @ObservationIgnored nonisolated(unsafe) var reusableColorMatrix = CIFilter.colorMatrix()
    @ObservationIgnored nonisolated(unsafe) var reusableToneCurve = CIFilter.toneCurve()
    @ObservationIgnored nonisolated(unsafe) var reusableVignette = CIFilter.vignette()
    @ObservationIgnored nonisolated(unsafe) var photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored nonisolated(unsafe) var videoDataOutput = AVCaptureVideoDataOutput()
    // Video recording
    @ObservationIgnored nonisolated(unsafe) var audioDataOutput = AVCaptureAudioDataOutput()
    @ObservationIgnored nonisolated(unsafe) var audioOutputAdded = false
    @ObservationIgnored nonisolated(unsafe) var cachedIsRecording: Bool = false
    /// Your exposure offset, readable off-main (smart AE adds its correction on top).
    @ObservationIgnored nonisolated(unsafe) var cachedUserBias: Float = 0
    @ObservationIgnored nonisolated(unsafe) var assetWriter: AVAssetWriter? = nil
    @ObservationIgnored nonisolated(unsafe) var videoWriterInput: AVAssetWriterInput? = nil
    @ObservationIgnored nonisolated(unsafe) var audioWriterInput: AVAssetWriterInput? = nil
    @ObservationIgnored nonisolated(unsafe) var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor? = nil
    @ObservationIgnored nonisolated(unsafe) var recordingSessionStarted = false
    @ObservationIgnored nonisolated(unsafe) var recordingOutputURL: URL? = nil
    /// Serializes the writer setup (sample-buffer queue) and teardown (main).
    /// Without this, stopRecording can read recordingSessionStarted=false while
    /// setupAssetWriter is mid-write, leaving an orphaned writer + lost video.
    @ObservationIgnored nonisolated let writerLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) var recordingTimer: Timer? = nil
    @ObservationIgnored nonisolated(unsafe) var lastRecordFrameTime: Double = 0
    @ObservationIgnored nonisolated(unsafe) var frameStack: [CIImage] = []
    @ObservationIgnored nonisolated(unsafe) var frameTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) var isCollectingFrames = false
    @ObservationIgnored nonisolated(unsafe) var pendingSim: FilmSimulation = .none
    @ObservationIgnored nonisolated(unsafe) var pendingGrain: Float = 0.0
    @ObservationIgnored nonisolated(unsafe) var pendingAspectRatio: AspectRatio = .full
    @ObservationIgnored nonisolated(unsafe) var pendingIsLandscape: Bool = false
    @ObservationIgnored nonisolated(unsafe) var pendingDeviceAngle: Double = 0
    @ObservationIgnored nonisolated(unsafe) var pendingGrainEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var pendingContextAwareGrain: Bool = false
    @ObservationIgnored nonisolated(unsafe) var pendingISO: Float = 100
    @ObservationIgnored nonisolated(unsafe) var pendingCrosstalk: Float = 0.1
    @ObservationIgnored nonisolated(unsafe) var pendingHalation: Float = 0.2
    @ObservationIgnored nonisolated(unsafe) var pendingRolloff: Float = 0.9
    @ObservationIgnored nonisolated(unsafe) var pendingCrosstalkEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var pendingHalationEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var pendingRolloffEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var pendingDoubleExposureOpacity: Double = 0.5
    @ObservationIgnored nonisolated(unsafe) var pendingMask: UIImage? = nil
    @ObservationIgnored nonisolated(unsafe) var pendingCustomSim: CustomSimulation?
    @ObservationIgnored nonisolated(unsafe) var pendingQuality: AVCapturePhotoOutput.QualityPrioritization = .quality
    @ObservationIgnored nonisolated(unsafe) var pendingLongExposureDuration: Double = 2.0
    @ObservationIgnored nonisolated(unsafe) var pendingPushPullEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var pendingPushPullAmount: Float = 0.0
    @ObservationIgnored nonisolated(unsafe) var pendingAnamorphicFlareEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var pendingLightArtifactsEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var pendingFilmScratchesEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var pendingRandomizationEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var pendingRandomSeed: UInt64 = 0
    /// Snapshot at capture time — used to manually crop photos captured on virtual cameras
    /// where iOS sometimes delivers the constituent's full FOV without applying
    /// videoZoomFactor (when maxPhotoDimensions is at the sensor max).
    @ObservationIgnored nonisolated(unsafe) var pendingZoomCropFactor: CGFloat = 1.0
    @ObservationIgnored nonisolated(unsafe) var pendingFull48 = true
    @ObservationIgnored nonisolated(unsafe) var cachedSim: FilmSimulation = .none
    @ObservationIgnored nonisolated(unsafe) var processQueue = DispatchQueue(label: "cam.process", qos: .userInitiated)
    /// In-flight burst processing count — bounded back-pressure to keep memory
    /// in check when capture rate exceeds save rate.
    @ObservationIgnored private let burstBacklogLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _burstBacklog: Int = 0
    /// Atomic add — `burstBacklog += 1` is a locked READ then a separate locked
    /// WRITE, so the capture thread's += and processQueue's -= could interleave
    /// and lose updates. If the count drifted upward, burst would eventually
    /// drop every frame (> 8 backlog). Do the read-modify-write in one lock.
    nonisolated func adjustBurstBacklog(by delta: Int) {
        burstBacklogLock.lock(); _burstBacklog += delta; burstBacklogLock.unlock()
    }
    nonisolated var burstBacklog: Int {
        get { burstBacklogLock.lock(); defer { burstBacklogLock.unlock() }; return _burstBacklog }
        set { burstBacklogLock.lock(); _burstBacklog = newValue; burstBacklogLock.unlock() }
    }
    @ObservationIgnored nonisolated(unsafe) var photoLibAuthorized = false
    @ObservationIgnored nonisolated(unsafe) var evObservation: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) var evTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) var focusObservation: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) var subjectAreaObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) var tapFocusSettleTimer: DispatchWorkItem?
    @ObservationIgnored nonisolated(unsafe) var metadataOutput = AVCaptureMetadataOutput()
    @ObservationIgnored nonisolated(unsafe) var lastFaceFocusTime: Date = .distantPast
    @ObservationIgnored nonisolated(unsafe) var tapFocusActive: Bool = false
    /// When the last tap-to-focus happened: the tapped point is kept while you
    /// reframe, instead of snapping back to the centre on the first scene change.
    @ObservationIgnored nonisolated(unsafe) var lastTapFocusTime: CFTimeInterval = 0
    @ObservationIgnored nonisolated(unsafe) var lastFaceSeenTime: CFTimeInterval = 0
    @ObservationIgnored nonisolated(unsafe) var lastFaceFocusPoint: CGPoint?
    @ObservationIgnored nonisolated(unsafe) var cachedManualFocusEnabled: Bool = false

    // Portrait / depth
    @ObservationIgnored nonisolated(unsafe) var depthDataOutput = AVCaptureDepthDataOutput()
    /// Lock-protected backing for `latestDepthPixelBuffer`. Cross-queue read/write
    /// without sync riste and use-after-release.
    @ObservationIgnored nonisolated(unsafe) private var _latestDepthPixelBuffer: CVPixelBuffer?
    @ObservationIgnored private let depthBufferLock = NSLock()
    nonisolated var latestDepthPixelBuffer: CVPixelBuffer? {
        get { depthBufferLock.lock(); defer { depthBufferLock.unlock() }; return _latestDepthPixelBuffer }
        set { depthBufferLock.lock(); _latestDepthPixelBuffer = newValue; depthBufferLock.unlock() }
    }
    @ObservationIgnored nonisolated(unsafe) var pendingPortraitEnabled: Bool = false
    @ObservationIgnored nonisolated(unsafe) var pendingPortraitFStop: Float = 2.8
    @ObservationIgnored nonisolated(unsafe) var firstExposureCIImage: CIImage?
    /// RAW halves of RAW + film captures, keyed by capture ID, waiting for
    /// their processed photo to finish rendering.
    @ObservationIgnored nonisolated(unsafe) private var rawStash: [Int64: Data] = [:]
    @ObservationIgnored private let rawStashLock = NSLock()

    /// Per-shot settings, applied when that shot's render starts.
    @ObservationIgnored nonisolated(unsafe) private var shotSettings: [Int64: (apply: @Sendable () -> Void, portrait: Bool)] = [:]
    @ObservationIgnored nonisolated(unsafe) private var shotsRendering = 0

    nonisolated var hasShotsInFlight: Bool {
        rawStashLock.lock(); defer { rawStashLock.unlock() }
        return !shotSettings.isEmpty || shotsRendering > 0
    }

    nonisolated func registerShot(id: Int64, apply: @escaping @Sendable () -> Void, portrait: Bool, burst: Bool = false) {
        rawStashLock.lock(); shotSettings[id] = (apply, portrait); rawStashLock.unlock()
        Task { @MainActor in DevelopActivity.shared.shotStarted(burst: burst) }
    }

    /// RAW multi-frame zoom: the normal photo taken as the burst's tone
    /// reference (reference capture ID → burst ID, then burst ID → photo).
    @ObservationIgnored nonisolated(unsafe) private var toneRefFor: [Int64: Int64] = [:]
    @ObservationIgnored nonisolated(unsafe) private var toneRefPhotos: [Int64: Data] = [:]
    @ObservationIgnored nonisolated(unsafe) private var burstToneRef: [Int64: Int64] = [:]
    nonisolated func storeToneReference(captureID: Int64, data: Data?) -> Bool {
        rawStashLock.lock(); defer { rawStashLock.unlock() }
        guard let burst = toneRefFor.removeValue(forKey: captureID) else { return false }
        if let data { toneRefPhotos[burst] = data }
        return true
    }
    /// Waits briefly for a burst's tone reference.
    nonisolated func takeToneReference(burst: Int64) -> Data? {
        rawStashLock.lock(); let refID = burstToneRef.removeValue(forKey: burst); rawStashLock.unlock()
        guard let refID else { return nil }
        for _ in 0..<40 {
            rawStashLock.lock()
            if let d = toneRefPhotos.removeValue(forKey: refID) { rawStashLock.unlock(); return d }
            rawStashLock.unlock()
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    /// Multi-frame zoom: the frames of a bracket, collected until all arrive.
    @ObservationIgnored nonisolated(unsafe) private var multiFrames: [Int64: (expected: Int, frames: [Data])] = [:]
    nonisolated func markMultiFrame(_ id: Int64, count: Int) {
        rawStashLock.lock(); multiFrames[id] = (count, []); rawStashLock.unlock()
    }
    /// nil: not a multi-frame shot. Otherwise the frames once complete
    /// (empty while still collecting).
    nonisolated func addMultiFrame(_ id: Int64, data: Data?) -> [Data]? {
        rawStashLock.lock(); defer { rawStashLock.unlock() }
        guard var m = multiFrames[id] else { return nil }
        if let data { m.frames.append(data) } else { m.expected -= 1 }
        if m.frames.count >= m.expected { multiFrames[id] = nil; return m.frames }
        multiFrames[id] = m
        return []
    }

    /// The capture failed: forget its settings (it would otherwise count as
    /// in flight forever, pausing Smart AE and the guides).
    nonisolated func dropShot(id: Int64) {
        rawStashLock.lock(); let had = shotSettings.removeValue(forKey: id) != nil; rawStashLock.unlock()
        if had { DevelopActivity.shared.shotFinished() }
    }

    /// Take a delivered shot's settings and count it as rendering.
    nonisolated func takeShot(id: Int64) -> (apply: @Sendable () -> Void, portrait: Bool)? {
        rawStashLock.lock(); defer { rawStashLock.unlock() }
        guard let s = shotSettings.removeValue(forKey: id) else { return nil }
        shotsRendering += 1
        return s
    }

    nonisolated func shotRendered() {
        rawStashLock.lock(); shotsRendering = max(0, shotsRendering - 1); rawStashLock.unlock()
        DevelopActivity.shared.shotFinished()
    }

    /// Render a small graded copy of a just-delivered shot for the thumbnail,
    /// so the shot is visible in well under a second instead of after the
    /// full-res render and the Photos save.
    nonisolated func publishQuickPreview(_ image: CIImage, recipe: ShotRecipe) {
        let s = 360 / max(image.extent.width, image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        var look = renderLook(small, recipe: recipe, flatten: false)
            .cropped(to: cropRect(for: small.extent))
        if pendingDeviceAngle == -90 { look = look.oriented(.right) }
        else if pendingDeviceAngle == 90 { look = look.oriented(.left) }
        else if pendingDeviceAngle == 180 { look = look.oriented(.down) }
        // Photo context, not the preview's: this decodes the full 48MP photo,
        // and on the preview's context the live view waited seconds behind it.
        guard let cg = photoContext.createCGImage(look, from: look.extent) else { return }
        let ui = UIImage(cgImage: cg)
        DispatchQueue.main.async { self.lastShotPreview = ui }
    }

    @ObservationIgnored nonisolated(unsafe) var wantsShutterThumb = false


    nonisolated func publishShutterThumb(_ frame: CIImage) {
        let s = 240 / max(frame.extent.width, frame.extent.height)
        let small = frame.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let look = applyLiveLook(small, grainTextures: false)
        guard let cg = photoContext.createCGImage(look, from: small.extent) else { return }
        let ui = UIImage(cgImage: cg)
        DispatchQueue.main.async { self.lastShotPreview = ui }
    }

    nonisolated func stashRAW(_ data: Data, id: Int64) {
        rawStashLock.lock()
        if rawStash.count > 6, let oldest = rawStash.keys.min() { rawStash[oldest] = nil }
        rawStash[id] = data
        rawStashLock.unlock()
    }

    /// The RAW for a capture, waiting briefly if it hasn't been delivered yet.
    nonisolated func takeRAW(id: Int64?) -> Data? {
        guard let id else { return nil }
        for _ in 0..<60 {
            rawStashLock.lock()
            let d = rawStash.removeValue(forKey: id)
            rawStashLock.unlock()
            if let d { return d }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }
    @ObservationIgnored nonisolated(unsafe) var capturingFirstExposure: Bool = false
    @ObservationIgnored nonisolated(unsafe) private var _burstActive: Bool = false
    @ObservationIgnored private let burstActiveLock = NSLock()
    nonisolated var burstActive: Bool {
        get { burstActiveLock.lock(); defer { burstActiveLock.unlock() }; return _burstActive }
        set { burstActiveLock.lock(); _burstActive = newValue; burstActiveLock.unlock() }
    }
    @ObservationIgnored nonisolated(unsafe) var currentDevice: AVCaptureDevice? {
        didSet {
            if currentDevice !== oldValue {
                restrictLensSwitching(currentDevice)
                SmartExposure.shared.deviceChanged()
                // A new lens starts unlocked.
                if cachedFocusLocked {
                    cachedFocusLocked = false
                    DispatchQueue.main.async { self.focusLocked = false; self.tapFocusActive = false }
                }
            }
        }
    }

    /// On the multi-lens (virtual) cameras iOS swaps lenses by itself when the
    /// focus distance changes, e.g. focusing close at 43mm hops tele → wide,
    /// and every hop is a visible stutter. Let it switch only when the zoom
    /// changes; focusing then stays on the lens you're on.
    nonisolated func restrictLensSwitching(_ device: AVCaptureDevice?) {
        guard let device, device.isVirtualDevice,
              device.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported,
              (try? device.lockForConfiguration()) != nil else { return }
        device.setPrimaryConstituentDeviceSwitchingBehavior(.restricted,
                                                            restrictedSwitchingBehaviorConditions: .videoZoomChanged)
        device.unlockForConfiguration()
    }
    @ObservationIgnored nonisolated(unsafe) private var isSwappingLens = false
    @ObservationIgnored nonisolated(unsafe) private var lastRequestedZoom: CGFloat = 1.0
    @ObservationIgnored nonisolated(unsafe) private var skipNextReconcile = false
    @ObservationIgnored nonisolated(unsafe) weak var editorPreviewRenderer: FilteredPreviewRenderer?
    @ObservationIgnored nonisolated(unsafe) weak var metalPreviewView: MetalFilteredPreviewView?
    @ObservationIgnored nonisolated(unsafe) private var lastFaceDetected = false
    @ObservationIgnored nonisolated(unsafe) weak var peakingView: PeakingUIView?
    @ObservationIgnored nonisolated(unsafe) weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored nonisolated(unsafe) weak var previewUIView: PreviewUIView?

    // MARK: Init

    override nonisolated init() {
        super.init()
        loadSettings()
        // Pre-authorize photo library so saves don't block on first capture.
        // Read/write (not add-only): saves are revertible Photos edits carrying
        // the ShotRecipe, and the re-grade screen reads the cam cam album.
        // PhotoSaver falls back to a flat add-only save if this is declined.
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            self.photoLibAuthorized = (status == .authorized || status == .limited)
        }
        installSessionObservers()
        requestPermissionAndStart()
    }

    deinit {
        evObservation?.invalidate()
        focusObservation?.invalidate()
        if let obs = subjectAreaObserver { NotificationCenter.default.removeObserver(obs) }
        evTimer?.invalidate()
        recordingTimer?.invalidate()
        tapFocusSettleTimer?.cancel()
    }

    nonisolated func loadSettings() {
        // Read all values synchronously on this thread (UserDefaults is thread-safe for reads)
        let ud = UserDefaults.standard
        let simRaw         = ud.string(forKey: "cc_selectedSim")
        let arRaw          = ud.string(forKey: "cc_aspectRatio")
        let grainEnabled   = ud.object(forKey: "cc_grainEnabled")   != nil ? ud.bool(forKey: "cc_grainEnabled")   : nil as Bool?
        let grainAmount    = ud.object(forKey: "cc_grainAmount")    != nil ? ud.float(forKey: "cc_grainAmount")   : nil as Float?
        let contextAwareGrain = ud.object(forKey: "cc_contextAwareGrain") != nil ? ud.bool(forKey: "cc_contextAwareGrain") : nil as Bool?
        let showGrid       = ud.object(forKey: "cc_showGrid")       != nil ? ud.bool(forKey: "cc_showGrid")       : nil as Bool?
        let showLevel      = ud.object(forKey: "cc_showLevel")      != nil ? ud.bool(forKey: "cc_showLevel")      : nil as Bool?
        let showPeaking    = ud.object(forKey: "cc_showPeaking")    != nil ? ud.bool(forKey: "cc_showPeaking")    : nil as Bool?
        let halationOn     = ud.object(forKey: "cc_halationEnabled") != nil ? ud.bool(forKey: "cc_halationEnabled") : nil as Bool?
        let halationAmt    = ud.object(forKey: "cc_halationAmount") != nil ? ud.float(forKey: "cc_halationAmount") : nil as Float?
        let digiCamQ       = ud.object(forKey: "cc_digiCamQuality") != nil ? ud.float(forKey: "cc_digiCamQuality") : nil as Float?
        let crosstalkOn    = ud.object(forKey: "cc_crosstalkEnabled") != nil ? ud.bool(forKey: "cc_crosstalkEnabled") : nil as Bool?
        let crosstalkAmt   = ud.object(forKey: "cc_crosstalkAmount") != nil ? ud.float(forKey: "cc_crosstalkAmount") : nil as Float?
        let rolloffOn      = ud.object(forKey: "cc_rolloffEnabled") != nil ? ud.bool(forKey: "cc_rolloffEnabled") : nil as Bool?
        let rolloffThresh  = ud.object(forKey: "cc_rolloffThreshold") != nil ? ud.float(forKey: "cc_rolloffThreshold") : nil as Float?
        let rawOn          = ud.object(forKey: "cc_rawEnabled")     != nil ? ud.bool(forKey: "cc_rawEnabled")     : nil as Bool?
        let burstOn        = ud.object(forKey: "cc_burstMode")      != nil ? ud.bool(forKey: "cc_burstMode")      : nil as Bool?
        let shutterLeft    = ud.object(forKey: "cc_shutterOnLeft")  != nil ? ud.bool(forKey: "cc_shutterOnLeft")  : nil as Bool?
        let unifiedZoom    = ud.object(forKey: "cc_unifiedZoom")    != nil ? ud.bool(forKey: "cc_unifiedZoom")    : nil as Bool?
        let volShutter     = ud.object(forKey: "cc_volumeShutter")  != nil ? ud.bool(forKey: "cc_volumeShutter")  : nil as Bool?
        let quality        = ud.object(forKey: "cc_photoQuality")   != nil ? ud.integer(forKey: "cc_photoQuality") : nil as Int?
        let focalIdx       = ud.object(forKey: "cc_focalIndex")     != nil ? ud.integer(forKey: "cc_focalIndex")  : nil as Int?
        let leRaw          = ud.string(forKey: "cc_longExposureMode")
        let leDur          = ud.object(forKey: "cc_longExposureDuration") != nil ? ud.double(forKey: "cc_longExposureDuration") : nil as Double?
        let brushSize      = ud.object(forKey: "cc_maskBrushSize")  != nil ? ud.double(forKey: "cc_maskBrushSize") : nil as Double?
        let flashStr       = ud.object(forKey: "cc_flashStrength")  != nil ? ud.float(forKey: "cc_flashStrength")  : nil as Float?
        let pushPullOn     = ud.object(forKey: "cc_pushPullEnabled") != nil ? ud.bool(forKey: "cc_pushPullEnabled")   : nil as Bool?
        let pushPullAmt    = ud.object(forKey: "cc_pushPullAmount")  != nil ? ud.float(forKey: "cc_pushPullAmount")   : nil as Float?
        let anamorphicOn   = ud.object(forKey: "cc_anamorphicFlare")   != nil ? ud.bool(forKey: "cc_anamorphicFlare")   : nil as Bool?
        let lightArtOn     = ud.object(forKey: "cc_lightArtifacts")   != nil ? ud.bool(forKey: "cc_lightArtifacts")   : nil as Bool?
        let filmScratchOn  = ud.object(forKey: "cc_filmScratches")    != nil ? ud.bool(forKey: "cc_filmScratches")    : nil as Bool?
        let randoOn        = ud.object(forKey: "cc_filmRando")         != nil ? ud.bool(forKey: "cc_filmRando")         : nil as Bool?

        DispatchQueue.main.async {
            if let raw = simRaw, let sim = FilmSimulation(rawValue: raw) { self.selectedSim = sim }
            if let raw = arRaw, let ar = AspectRatio(rawValue: raw) { self.selectedAspectRatio = ar }
            if let v = grainEnabled   { self.grainEnabled = v }
            if let v = grainAmount    { self.grainAmount = v }
            if let v = contextAwareGrain { self.contextAwareGrainEnabled = v }
            if let v = showGrid       { self.showGrid = v }
            if let v = showLevel      { self.showLevel = v }
            if let v = showPeaking    { self.showPeaking = v }
            if let v = halationOn     { self.halationEnabled = v }
            if let v = halationAmt    { self.halationAmount = v }
            if let v = digiCamQ       { self.digiCamQuality = v }
            if let v = crosstalkOn    { self.crosstalkEnabled = v }
            if let v = crosstalkAmt   { self.crosstalkAmount = v }
            if let v = rolloffOn      { self.rolloffEnabled = v }
            if let v = rolloffThresh  { self.rolloffThreshold = v }
            if let v = rawOn          { self.rawEnabled = v }
            if let v = burstOn        { self.burstMode = v }
            if let v = shutterLeft    { self.shutterOnLeft = v }
            if let v = unifiedZoom    { self.unifiedZoomMode = v }
            if let v = volShutter     { self.volumeShutterEnabled = v }
            if let v = quality        { self.photoQuality = v }
            if let idx = focalIdx, idx < focalPresets.count { self.selectedFocalIndex = idx }
            if let raw = leRaw, let mode = LongExposureMode(rawValue: raw) { self.longExposureMode = mode }
            if let v = leDur          { self.longExposureDuration = v }
            if let v = brushSize      { self.maskBrushSize = CGFloat(v) }
            if let v = flashStr       { self.flashStrength = v }
            if let v = pushPullOn   { self.pushPullEnabled = v }
            if let v = pushPullAmt  { self.pushPullAmount = v }
            if let v = anamorphicOn { self.anamorphicFlareEnabled = v }
            if let v = lightArtOn   { self.lightArtifactsEnabled = v }
            if let v = filmScratchOn { self.filmScratchesEnabled = v }
            if let v = randoOn      { self.filmRandomizationEnabled = v }
        }
    }

    // MARK: Permission and Session

    nonisolated func requestPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.isAuthorized = true }
            sessionQueue.async { self.configureSession() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.isAuthorized = granted
                    self.isDenied = !granted
                }
                if granted {
                    self.sessionQueue.async { self.configureSession() }
                }
            }
        default:
            DispatchQueue.main.async { self.isDenied = true }
        }
    }

    @ObservationIgnored nonisolated(unsafe) var videoOutputAdded = false

    /// Select the best device format: highest photo resolution while keeping video preview >= 1080p.
    /// Must be called while device is locked for configuration
    nonisolated func selectBestFormat(for device: AVCaptureDevice) {
        let candidates = device.formats.filter { f in
            guard CMFormatDescriptionGetMediaType(f.formatDescription) == kCMMediaType_Video else { return false }
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            // ≥1080p, 30fps, and the same shape as its photos, so the preview
            // frames exactly what's saved (a 16:9 feed would crop a 4:3 photo).
            guard dims.width >= 1920,
                  f.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 }),
                  let photo = f.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height })
            else { return false }
            let videoAspect = Double(dims.width) / Double(dims.height)
            let photoAspect = Double(photo.width) / Double(photo.height)
            return abs(videoAspect - photoAspect) < 0.02
        }
        var pool = candidates.isEmpty ? device.formats : candidates
        // Portrait needs a format that streams depth; the 48MP formats don't.
        if portraitSessionWanted {
            let depthPool = pool.filter { !$0.supportedDepthDataFormats.isEmpty }
            if !depthPool.isEmpty { pool = depthPool }
        }

        let best = pool.max { a, b in
            let aPhoto = a.supportedMaxPhotoDimensions
                .map { Int($0.width) * Int($0.height) }.max() ?? 0
            let bPhoto = b.supportedMaxPhotoDimensions
                .map { Int($0.width) * Int($0.height) }.max() ?? 0
            if aPhoto != bPhoto { return aPhoto < bPhoto }
            // Same photo size: the widest field of view first. Smaller feeds
            // are often a cropped sensor readout, so the preview showed less
            // than the photo (seen on the ultra-wide, where every format makes
            // a 12MP photo). Then the larger feed.
            if abs(a.videoFieldOfView - b.videoFieldOfView) > 0.5 { return a.videoFieldOfView < b.videoFieldOfView }
            let aVid = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let bVid = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(aVid.width) * Int(aVid.height) < Int(bVid.width) * Int(bVid.height)
        }
        guard let best else { return }
        device.activeFormat = best
        if portraitSessionWanted {
            // Largest float disparity/depth map the format offers.
            let floats: Set<FourCharCode> = [kCVPixelFormatType_DisparityFloat16, kCVPixelFormatType_DisparityFloat32,
                                             kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DepthFloat32]
            let depth = best.supportedDepthDataFormats
                .filter { floats.contains(CMFormatDescriptionGetMediaSubType($0.formatDescription)) }
                .max { a, b in
                    let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                    let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                    return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
                }
            if let depth { device.activeDepthDataFormat = depth }
        }
    }

    /// Portrait on: move to the multi-lens camera (the single main lens can't
    /// make depth) at the same framing, on a depth-capable format.
    /// Portrait off: back to the preset's normal lens and full-res format.
    func routeForPortrait() {
        let index = selectedFocalIndex
        guard focalPresets.indices.contains(index) else { return }
        let preset = focalPresets[index]
        guard preset.deviceType != .builtInUltraWideCamera else { return }   // no depth there
        let onVirtual = [.builtInTripleCamera, .builtInDualCamera, .builtInDualWideCamera]
            .contains(currentDevice?.deviceType)
        let wantsVirtual = portraitNeedsDepthCamera || preset.useVirtualDevice || oneLensActive
        let intentZoom = CGFloat(Double(currentMM) / 26.0)
        lastRequestedZoom = intentZoom
        if wantsVirtual && !onVirtual {
            swapToVirtualDevice(zoom: intentZoom * prospectiveVirtualCompensation, animate: true)
        } else if !wantsVirtual && onVirtual {
            swapInputDevice(to: preset, animate: true)
        } else if let device = currentDevice {
            // Same camera: just switch between the depth and full-res formats.
            sessionQueue.async { [self] in
                session.beginConfiguration()
                if (try? device.lockForConfiguration()) != nil {
                    selectBestFormat(for: device)
                    device.unlockForConfiguration()
                }
                session.commitConfiguration()
                if let maxDim = device.activeFormat.supportedMaxPhotoDimensions
                    .max(by: { $0.width * $0.height < $1.width * $1.height }) {
                    photoOutput.maxPhotoDimensions = maxDim
                }
                updateDepthAvailability(for: device)
                let z = lastRequestedZoom
                DispatchQueue.main.async { self.setZoom(z) }
            }
        }
    }

    nonisolated func configureSession() {
        // Record physical wide FOV reference before anything else — must not
        // depend on the chosen launch device (which may be virtual).
        recordPhysicalWideFOV()
        session.beginConfiguration()
        // Use inputPriority so we can manually select formats (needed for 48MP)
        session.sessionPreset = .inputPriority

        // Launch device depends on unified-zoom mode (read directly from UserDefaults
        // since the published property may not be loaded yet at this point in init).
        let savedQuality = UserDefaults.standard.object(forKey: "cc_photoQuality") as? Int ?? 2
        let unifiedZoom = (UserDefaults.standard.object(forKey: "cc_unifiedZoom") != nil
            ? UserDefaults.standard.bool(forKey: "cc_unifiedZoom")
            : false) && savedQuality < 2
        let device: AVCaptureDevice = {
            if unifiedZoom {
                if let d = AVCaptureDevice.default(.builtInTripleCamera,   for: .video, position: .back) { return d }
                if let d = AVCaptureDevice.default(.builtInDualCamera,     for: .video, position: .back) { return d }
                if let d = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) { return d }
            }
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)!
        }()
        currentDevice = device
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            return
        }
        if session.canAddInput(input) {
            session.addInput(input)
        }

        // Photo output only — get preview running ASAP
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        // Select best format and configure fast autofocus
        do {
            try device.lockForConfiguration()
            selectBestFormat(for: device)
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = false   // stills: snap, don't breathe (on only while recording)
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            // Subject-area change monitoring: fires a notification when the scene
            // shifts enough that a re-focus would improve sharpness
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        } catch {}

        // Face detection metadata output
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            if metadataOutput.availableMetadataObjectTypes.contains(.face) {
                metadataOutput.metadataObjectTypes = [.face]
                metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)
            }
        }

        // Depth data output for portrait mode (requires dual/triple/TrueDepth camera)
        if session.canAddOutput(depthDataOutput) {
            session.addOutput(depthDataOutput)
            depthDataOutput.setDelegate(self, callbackQueue: sessionQueue)
            depthDataOutput.isFilteringEnabled = true   // temporal smoothing
        }

        session.commitConfiguration()

        // Mark portrait mode available if depth data output was successfully added
        // (isDepthDataDeliverySupported on photoOutput returns false when a separate
        //  AVCaptureDepthDataOutput is already in the session, so we check the output itself)
        let depthAdded = session.outputs.contains(depthDataOutput)
        DispatchQueue.main.async {
            self.portraitModeAvailable = depthAdded
        }

        // Set max photo dimensions AFTER commit
        if let maxDim = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = maxDim
        }
        // Enable max quality and wide color
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = true
        }

        // Initialize depth-availability flag for the launch device
        updateDepthAvailability(for: device)

        // Start running immediately — don't wait for video data output
        session.startRunning()
        startEVObservation()
        startContextAwareFocusObservers(for: device)
            reapplyManualFocusIfNeeded(on: device)
            updateDepthAvailability(for: device)

        // Default to 28mm on launch
        let defaultZoom = CGFloat(28.0 / 26.0)
        do {
            try device.lockForConfiguration()
            let clamped = max(device.minAvailableVideoZoomFactor, min(defaultZoom, device.maxAvailableVideoZoomFactor))
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {}
        let deviceMax = Double(device.maxAvailableVideoZoomFactor)
        DispatchQueue.main.async {
            self.currentMM = 28
            self.zoom = Double(defaultZoom)
            self.selectedFocalIndex = 1
            self.maxManualZoom = min(deviceMax, 50.0)
        }

        // Defer video data output (only needed for long exposure) to avoid blocking startup
        sessionQueue.async { [self] in
            addVideoDataOutputIfNeeded()
        }
    }

    nonisolated func addVideoDataOutputIfNeeded() {
        guard !videoOutputAdded else { return }
        session.beginConfiguration()
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: frameOutputQueue)
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            videoOutputAdded = true
        }
        session.commitConfiguration()
        if let connection = videoDataOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        // Adding an output can cause AVFoundation to swap formats — re-pin max photo dimensions
        if let maxDim = currentDevice?.activeFormat
            .supportedMaxPhotoDimensions
            .max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = maxDim
        }
    }

    nonisolated func addAudioOutputIfNeeded() {
        guard !audioOutputAdded else { return }
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .videoRecording,
                                      options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? audioSession.setActive(true)
        session.beginConfiguration()
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }
        audioDataOutput.setSampleBufferDelegate(self, queue: frameOutputQueue)
        if session.canAddOutput(audioDataOutput) {
            session.addOutput(audioDataOutput)
            audioOutputAdded = true
        }
        session.commitConfiguration()
    }

    nonisolated func setupAssetWriter(width: Int, height: Int, startTime: CMTime) {
        writerLock.lock()
        defer { writerLock.unlock() }
        guard assetWriter == nil else { return }   // prevent double-init
        let maxLong = 1920
        let scale = min(1.0, Double(maxLong) / Double(max(width, height)))
        let outW = Int(Double(width)  * scale) & ~1
        let outH = Int(Double(height) * scale) & ~1
        let fname = "cc_\(Int(Date().timeIntervalSince1970)).mov"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fname)
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(url: url, fileType: .mov) else { return }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 16_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH
            ]
        )
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        if writer.canAdd(videoInput) { writer.add(videoInput) }
        if writer.canAdd(audioInput) { writer.add(audioInput) }
        writer.startWriting()
        writer.startSession(atSourceTime: startTime)
        self.recordingOutputURL = url
        self.assetWriter = writer
        self.videoWriterInput = videoInput
        self.audioWriterInput = audioInput
        self.pixelBufferAdaptor = adaptor
        self.recordingSessionStarted = true
    }

    nonisolated func bestDevice(for preset: FocalPreset) -> AVCaptureDevice? {
        AVCaptureDevice.default(preset.deviceType, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// Best virtual multi-lens back camera — used to return to zoom-controlled mode from physical ultrawide.
    nonisolated func bestVirtualBackDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInTripleCamera,      for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera,     for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    nonisolated func swapInputDevice(to preset: FocalPreset, animateFromZoom: CGFloat? = nil, animate: Bool = true, targetZoom: CGFloat? = nil) {
        #if DEBUG
        print(String(format: "[perf] %.2f SWAP physical %dmm", CACurrentMediaTime(), preset.mm))
        #endif
        // Stop any active recording before reconfiguring the session
        if cachedIsRecording {
            DispatchQueue.main.async { self.stopRecording() }
        }
        // Cancel any in-flight tap-focus state so the new device's continuous AF isn't paralyzed
        tapFocusSettleTimer?.cancel()
        tapFocusSettleTimer = nil
        tapFocusActive = false
        focusObservation?.invalidate()
        focusObservation = nil
        // Snapshot current preview on main thread BEFORE the session swap
        if animate {
            let preview = previewUIView
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    preview?.freezeAndCrossfade(duration: 0.35)
                }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        preview?.freezeAndCrossfade(duration: 0.35)
                    }
                }
            }
        }

        sessionQueue.async { [self] in
            defer {
                let reconcile = !skipNextReconcile
                isSwappingLens = false
                skipNextReconcile = false
                if reconcile {
                    let lrz = lastRequestedZoom
                    DispatchQueue.main.async { self.setZoom(lrz) }
                }
            }
            guard let device = bestDevice(for: preset) else { return }

            // Suspend video output delegate
            videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }

            guard let newInput = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(newInput) else {
                session.commitConfiguration()
                videoDataOutput.setSampleBufferDelegate(self, queue: frameOutputQueue)
                return
            }
            session.addInput(newInput)
            currentDevice = device

            // Select best format and configure fast AF
            do {
                try device.lockForConfiguration()
                selectBestFormat(for: device)
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isSmoothAutoFocusSupported {
                    device.isSmoothAutoFocusEnabled = false   // stills: snap, don't breathe (on only while recording)
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {}

            startContextAwareFocusObservers(for: device)
            reapplyManualFocusIfNeeded(on: device)
            updateDepthAvailability(for: device)

            // If animating, start at the bridge zoom so first frame matches previous FOV
            if let startZoom = animateFromZoom {
                applyZoom(factor: startZoom, on: device)
            }

            // Apply rotation INSIDE config block so it's atomic with the input swap
            for output in session.outputs {
                if let conn = output.connection(with: .video),
                   conn.isVideoRotationAngleSupported(90) {
                    conn.videoRotationAngle = 90
                }
            }

            session.commitConfiguration()
            // Re-enable video delegate after session settles
            videoDataOutput.setSampleBufferDelegate(self, queue: frameOutputQueue)

            // Set max photo dims after commit
            let dims = device.activeFormat.supportedMaxPhotoDimensions
            if let maxDim = dims.max(by: { $0.width * $0.height < $1.width * $1.height }), maxDim.width > 0 {
                photoOutput.maxPhotoDimensions = maxDim
            }
            if photoOutput.isAppleProRAWSupported {
                photoOutput.isAppleProRAWEnabled = true
            }

            // Re-apply exposure bias so the new device matches what the user had set
            let bias = exposureBias
            if bias != 0 {
                do {
                    try device.lockForConfiguration()
                    let clamped = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
                    device.setExposureTargetBias(clamped)
                    device.unlockForConfiguration()
                } catch {}
            }

            // Animate zoom to target smoothly
            let finalZoom = targetZoom ?? preset.zoomFactor
            if animateFromZoom != nil {
                animateZoom(to: finalZoom, on: device, duration: 0.6)
            } else {
                applyZoom(factor: finalZoom, on: device)
            }
            startEVObservation()
        }
    }

    /// Swap to the best virtual back camera (triple/dual) and set zoom — used when leaving physical ultrawide.
    nonisolated func swapToVirtualDevice(zoom: CGFloat, animate: Bool = true) {
        #if DEBUG
        print(String(format: "[perf] %.2f SWAP virtual z%.2f", CACurrentMediaTime(), zoom))
        #endif
        if cachedIsRecording {
            DispatchQueue.main.async { self.stopRecording() }
        }
        // Cancel any in-flight tap-focus state so the new device's continuous AF isn't paralyzed
        tapFocusSettleTimer?.cancel()
        tapFocusSettleTimer = nil
        tapFocusActive = false
        focusObservation?.invalidate()
        focusObservation = nil
        if animate {
            let preview = previewUIView
            if Thread.isMainThread {
                MainActor.assumeIsolated { preview?.freezeAndCrossfade(duration: 0.35) }
            } else {
                DispatchQueue.main.sync { MainActor.assumeIsolated { preview?.freezeAndCrossfade(duration: 0.35) } }
            }
        }
        sessionQueue.async { [self] in
            defer {
                let reconcile = !skipNextReconcile
                isSwappingLens = false
                skipNextReconcile = false
                if reconcile {
                    let lrz = lastRequestedZoom
                    DispatchQueue.main.async { self.setZoom(lrz) }
                }
            }
            guard let device = bestVirtualBackDevice() else { return }
            videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                session.commitConfiguration()
                videoDataOutput.setSampleBufferDelegate(self, queue: frameOutputQueue)
                return
            }
            session.addInput(input)
            currentDevice = device
            do {
                try device.lockForConfiguration()
                selectBestFormat(for: device)
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }   // stills: snap; smooth only while recording
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                device.isSubjectAreaChangeMonitoringEnabled = true
                let clamped = max(device.minAvailableVideoZoomFactor, min(zoom, device.maxAvailableVideoZoomFactor))
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {}
            for output in session.outputs {
                if let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
                    conn.videoRotationAngle = 90
                }
            }
            session.commitConfiguration()
            videoDataOutput.setSampleBufferDelegate(self, queue: frameOutputQueue)
            let dims = device.activeFormat.supportedMaxPhotoDimensions
            if let maxDim = dims.max(by: { $0.width * $0.height < $1.width * $1.height }), maxDim.width > 0 {
                photoOutput.maxPhotoDimensions = maxDim
            }
            if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = true }
            let bias = exposureBias
            if bias != 0 {
                do {
                    try device.lockForConfiguration()
                    let clampedBias = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
                    device.setExposureTargetBias(clampedBias)
                    device.unlockForConfiguration()
                } catch {}
            }
            startContextAwareFocusObservers(for: device)
            reapplyManualFocusIfNeeded(on: device)
            updateDepthAvailability(for: device)
            startEVObservation()
        }
    }

    /// Smoothly animate zoom using AVCaptureDevice's ramp API
    nonisolated func animateZoom(to factor: CGFloat, on device: AVCaptureDevice, duration: TimeInterval) {
        do {
            try device.lockForConfiguration()
            let clamped = max(device.minAvailableVideoZoomFactor,
                              min(factor, device.maxAvailableVideoZoomFactor))
            let rate = Float(abs(device.videoZoomFactor - clamped) / CGFloat(max(duration, 0.01)))
            device.ramp(toVideoZoomFactor: clamped, withRate: max(0.1, min(rate, 100.0)))
            device.unlockForConfiguration()
        } catch {}
    }

    nonisolated func applyZoom(factor: CGFloat, on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let clamped = max(device.minAvailableVideoZoomFactor,
                              min(factor, device.maxAvailableVideoZoomFactor))
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            // Ignore zoom errors
        }
    }

    nonisolated func applyRawZoom(factor: CGFloat) {
        guard let device = currentDevice else { return }
        applyZoom(factor: factor, on: device)
    }

    nonisolated var isRAWSupported: Bool {
        !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
    }

    // MARK: Flip Camera (front/back)

    func flipCamera() {
        let goingFront = !isFrontCamera
        isFrontCamera = goingFront
        previewUIView?.freezeAndCrossfade(duration: 0.4)
        sessionQueue.async { [self] in
            // Front: always physical wide-angle (TrueDepth / front wide)
            // Back: use same virtual-device priority as initial setup
            let device: AVCaptureDevice = {
                if goingFront {
                    return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                        ?? AVCaptureDevice.default(.builtInTrueDepthCamera,  for: .video, position: .front)!
                } else {
                    if let d = AVCaptureDevice.default(.builtInTripleCamera,      for: .video, position: .back) { return d }
                    if let d = AVCaptureDevice.default(.builtInDualCamera,        for: .video, position: .back) { return d }
                    if let d = AVCaptureDevice.default(.builtInDualWideCamera,    for: .video, position: .back) { return d }
                    return AVCaptureDevice.default(.builtInWideAngleCamera,       for: .video, position: .back)!
                }
            }()

            videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            guard let newInput = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(newInput) else {
                session.commitConfiguration()
                videoDataOutput.setSampleBufferDelegate(self, queue: frameOutputQueue)
                return
            }
            session.addInput(newInput)
            currentDevice = device

            do {
                try device.lockForConfiguration()
                selectBestFormat(for: device)
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isSmoothAutoFocusSupported {
                    device.isSmoothAutoFocusEnabled = false   // stills: snap, don't breathe (on only while recording)
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {}

            startContextAwareFocusObservers(for: device)
            reapplyManualFocusIfNeeded(on: device)
            updateDepthAvailability(for: device)

            // Rotation + mirror on every output connection.
            // videoDataOutput MUST also be mirrored so the Metal filtered
            // preview matches the preview layer on the front camera.
            for output in session.outputs {
                if let conn = output.connection(with: .video) {
                    if conn.isVideoRotationAngleSupported(90) {
                        conn.videoRotationAngle = 90
                    }
                    if conn.isVideoMirroringSupported {
                        conn.isVideoMirrored = goingFront
                    }
                }
            }

            session.commitConfiguration()
            videoDataOutput.setSampleBufferDelegate(self, queue: frameOutputQueue)

            let dims = device.activeFormat.supportedMaxPhotoDimensions
            if let maxDim = dims.max(by: { $0.width * $0.height < $1.width * $1.height }), maxDim.width > 0 {
                photoOutput.maxPhotoDimensions = maxDim
            }

            // Reset zoom state on the new device so a stale 50x from the back doesn't carry over.
            // Back: default to 28mm (matches initial launch); Front: 1.0x (no preset match).
            let resetZoom: CGFloat = goingFront ? 1.0 : CGFloat(28.0 / 26.0)
            do {
                try device.lockForConfiguration()
                let clamped = max(device.minAvailableVideoZoomFactor, min(resetZoom, device.maxAvailableVideoZoomFactor))
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {}
            // Refresh physical wide FOV reference when returning to back (in case
            // the device picked a different active format).
            if !goingFront { recordPhysicalWideFOV() }
            let newMax = min(Double(device.maxAvailableVideoZoomFactor), 50.0)
            DispatchQueue.main.async {
                self.maxManualZoom = newMax
                self.lastRequestedZoom = resetZoom
                self.zoom = Double(resetZoom)
                self.currentMM = goingFront ? 26 : 28
                self.selectedFocalIndex = goingFront ? -1 : 1
            }

            startEVObservation()
        }
    }

    nonisolated func startEVObservation() {
        guard currentDevice != nil else { return }
        evObservation?.invalidate()
        // Timer must be created and added to RunLoop.main on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.evTimer?.invalidate()
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                // Re-read the current device each tick so a lens swap doesn't keep the timer
                // bound to a stale device reference (and indirectly to a deallocated reading source).
                guard let self, let device = self.currentDevice else { return }
                let iso = device.iso
                let duration = device.exposureDuration.seconds
                guard duration > 0 else { return }
                // EV = log2(100/ISO) + log2(1/duration) — maps to roughly -3..+3 for typical scenes
                let ev = log2(100.0 / Float(iso)) + log2(Float(1.0 / duration))
                self.evReading = ev  // already on main
                MainActor.assumeIsolated { WatchConnector.shared.pushState() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.evTimer = timer
        }
    }

    // MARK: Focus and Exposure

    // MARK: AE/AF lock

    /// Long-press: focus and expose once at `point`, then hold both until the
    /// user taps or switches lens (like Apple's AE/AF LOCK).
    var focusLocked = false {
        didSet { cachedFocusLocked = focusLocked }
    }
    @ObservationIgnored nonisolated(unsafe) var cachedFocusLocked = false

    func lockFocusAndExposure(at point: CGPoint) {
        guard let device = currentDevice, !manualFocusEnabled else { return }
        tapFocusSettleTimer?.cancel(); tapFocusSettleTimer = nil
        focusObservation?.invalidate(); focusObservation = nil
        tapFocusActive = true
        focusLocked = true
        sessionQueue.async { [weak self] in
            guard let self, self.currentDevice === device,
                  (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
            if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
            if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
            device.unlockForConfiguration()
            // Let one focus + exposure pass finish, then freeze both.
            self.sessionQueue.asyncAfter(deadline: .now() + 0.7) {
                guard self.cachedFocusLocked, self.currentDevice === device,
                      (try? device.lockForConfiguration()) != nil else { return }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                device.unlockForConfiguration()
            }
        }
    }

    /// Release the lock and go back to continuous AF/AE at the centre.
    func unlockFocusAndExposure() {
        guard focusLocked else { return }
        focusLocked = false
        tapFocusActive = false
        guard let device = currentDevice else { return }
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            let centre = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = centre }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = centre }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        }
    }

    func tapToFocus(at point: CGPoint) {
        guard let device = currentDevice else { return }
        // A tap releases AE/AF lock and focuses normally.
        if focusLocked { focusLocked = false }
        tapFocusActive = true
        lastTapFocusTime = CACurrentMediaTime()
        lastFaceFocusPoint = nil
        // Cancel any pending settle timer
        tapFocusSettleTimer?.cancel()
        tapFocusSettleTimer = nil

        sessionQueue.async { [weak self] in
            guard let self, self.currentDevice === device else {
                // Tap targeted a stale device — clear the in-flight tap-focus state
                // so the new device's continuous AF isn't paralyzed.
                self?.tapFocusActive = false
                return
            }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }
                device.unlockForConfiguration()
            } catch {
                // Lock failed — bail out cleanly so tapFocusActive isn't stuck true.
                self.tapFocusActive = false
                return
            }

            // Watch isAdjustingFocus — return to continuous once the lens settles.
            // Safety cap: always return to continuous after 3 s even if KVO never fires settled.
            self.focusObservation?.invalidate()
            self.focusObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] dev, change in
                guard let self else { return }
                let adjusting = change.newValue ?? dev.isAdjustingFocus
                #if DEBUG
                print(String(format: "[perf] %.2f FOCUS %@", CACurrentMediaTime(), adjusting ? "start" : "end"))
                #endif
                DispatchQueue.main.async { self.isFocusing = adjusting }
                if !adjusting {
                    // Lens has settled — schedule return to continuous after a brief hold
                    let work = DispatchWorkItem { [weak self, dev] in
                        guard let self else { return }
                        self.tapFocusActive = false
                        self.sessionQueue.async {
                            do {
                                try dev.lockForConfiguration()
                                if dev.isFocusModeSupported(.continuousAutoFocus) {
                                    dev.focusMode = .continuousAutoFocus
                                }
                                if dev.isExposureModeSupported(.continuousAutoExposure) {
                                    dev.exposureMode = .continuousAutoExposure
                                }
                                dev.unlockForConfiguration()
                            } catch {}
                        }
                        self.focusObservation?.invalidate()
                        self.focusObservation = nil
                    }
                    self.tapFocusSettleTimer = work
                    // Hold for 1.5 s after settling before returning to continuous
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
                }
            }

            // Safety cap — return to continuous after 3 s regardless
            let safetyCap = DispatchWorkItem { [weak self, device] in
                guard let self else { return }
                self.tapFocusActive = false
                self.focusObservation?.invalidate()
                self.focusObservation = nil
                self.sessionQueue.async {
                    do {
                        try device.lockForConfiguration()
                        if device.isFocusModeSupported(.continuousAutoFocus) {
                            device.focusMode = .continuousAutoFocus
                        }
                        if device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                        }
                        device.unlockForConfiguration()
                    } catch {}
                }
                DispatchQueue.main.async { self.isFocusing = false }
            }
            self.tapFocusSettleTimer = safetyCap
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: safetyCap)
        }
    }

    func setExposureBias(_ bias: Float) {
        guard let device = currentDevice else { return }
        cachedUserBias = bias
        let smart = SmartExposure.shared
        let total = bias + (smart.enabled ? smart.correction : 0)
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let clamped = max(device.minExposureTargetBias,
                                  min(total, device.maxExposureTargetBias))
                device.setExposureTargetBias(clamped)
                device.unlockForConfiguration()
            } catch {}
        }
        exposureBias = bias
    }

    func setManualFocus(_ value: Float) {
        guard let device = currentDevice else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) {
                    if device.isLockingFocusWithCustomLensPositionSupported {
                        device.setFocusModeLocked(lensPosition: value, completionHandler: nil)
                    } else {
                        device.focusMode = .locked
                    }
                }
                device.unlockForConfiguration()
            } catch {}
        }
        manualFocusValue = value
    }

    /// Toggle manual focus on/off, properly applying the mode change to the
    /// camera device and cancelling any in-flight tap-focus sequences that
    /// would otherwise fight the new state.
    func setManualFocusEnabled(_ enabled: Bool) {
        // Cancel any pending tap-to-focus settle timers and the KVO observation
        // that would re-schedule them. Both can fire asynchronously and silently
        // return the device to continuous AF, breaking a freshly-enabled MF lock.
        tapFocusSettleTimer?.cancel()
        tapFocusSettleTimer = nil
        tapFocusActive = false
        if enabled {
            // Kill the tap-focus KVO so it can't create new settle timers after
            // we lock focus. Context-aware observers are re-attached on MF disable.
            focusObservation?.invalidate()
            focusObservation = nil
        }

        manualFocusEnabled = enabled
        cachedManualFocusEnabled = enabled

        guard let device = currentDevice else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try device.lockForConfiguration()
                if enabled {
                    if device.isFocusModeSupported(.locked) {
                        // setFocusModeLocked(lensPosition:completionHandler:) with a custom
                        // position requires isLockingFocusWithCustomLensPositionSupported —
                        // virtual/multi-camera devices report isFocusModeSupported(.locked)==true
                        // but throw an NSException if you pass a custom position.
                        if device.isLockingFocusWithCustomLensPositionSupported {
                            let pos = device.lensPosition
                            device.setFocusModeLocked(lensPosition: pos, completionHandler: nil)
                            DispatchQueue.main.async { self.manualFocusValue = pos }
                        } else {
                            // Lock at current position without specifying a lens position
                            device.focusMode = .locked
                        }
                    }
                } else {
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.unlockForConfiguration()
            } catch {}

            if !enabled {
                self.startContextAwareFocusObservers(for: device)
            }
        }
    }

    /// Re-apply manual focus state to a freshly-swapped device. Without this,
    /// swapping lenses while in MF silently drops the lock — the new device
    /// enters continuous AF instead of preserving the user's locked focus.
    /// Re-evaluate whether the currently active device produces depth data.
    /// Also clears the depth cache so we don't apply stale depth from a
    /// previous (depth-capable) device to a new (no-depth) device's photo.
    nonisolated func updateDepthAvailability(for device: AVCaptureDevice) {
        // With Depth Anything bundled, any lens can do Portrait (depth from the photo).
        let supportsDepth = !device.activeFormat.supportedDepthDataFormats.isEmpty || MonoDepth.available
        // Always clear the cache on swap — it was captured against the OLD device.
        latestDepthPixelBuffer = nil
        DispatchQueue.main.async {
            self.currentDeviceSupportsDepth = supportsDepth
            // If the new device doesn't support depth, force portrait mode off
            // so the toggle UI doesn't lie about what's about to happen.
            if !supportsDepth && self.portraitModeEnabled {
                self.portraitModeEnabled = false
            }
        }
    }

    nonisolated func reapplyManualFocusIfNeeded(on device: AVCaptureDevice) {
        guard cachedManualFocusEnabled, device.isFocusModeSupported(.locked) else { return }
        let value = cachedManualFocusValue
        do {
            try device.lockForConfiguration()
            if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: value, completionHandler: nil)
            } else {
                device.focusMode = .locked
            }
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: - Context-Aware Focus Observers

    /// Sets up three layers of context-aware AF for a given device:
    ///  1. `isAdjustingFocus` KVO → publishes `isFocusing` so the UI can show a live indicator
    ///  2. `subjectAreaDidChangeNotification` → recenters continuous AF when the scene shifts
    ///  3. Face-detection steering (handled in `metadataOutput(_:didOutput:from:)`)
    nonisolated func startContextAwareFocusObservers(for device: AVCaptureDevice) {
        // Clean up any previous observers
        focusObservation?.invalidate()
        focusObservation = nil
        if let prev = subjectAreaObserver {
            NotificationCenter.default.removeObserver(prev)
            subjectAreaObserver = nil
        }

        // 1. isAdjustingFocus KVO — keep isFocusing in sync
        focusObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            // Only publish when not in the middle of a tap-focus settle sequence
            if !self.tapFocusActive {
                let adjusting = change.newValue ?? false
                #if DEBUG
                print(String(format: "[perf] %.2f FOCUS %@", CACurrentMediaTime(), adjusting ? "start" : "end"))
                #endif
                DispatchQueue.main.async { self.isFocusing = adjusting }
            }
        }

        // 2. Subject-area change notification — reacquire AF when scene shifts
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: device,
            queue: nil
        ) { [weak self, weak device] _ in
            guard let self, let device else { return }
            // Ignore if user is doing manual focus or in the middle of a tap-focus
            guard !self.cachedManualFocusEnabled, !self.tapFocusActive, !self.cachedFocusLocked else { return }
            // Keep a tapped point for 8 s of reframing, and leave a face-steered
            // point alone while the face is still there (it used to snap to the
            // centre here, then the face steering pulled it back a second later:
            // focus ping-ponging between the face and the background).
            let now = CACurrentMediaTime()
            guard now - self.lastTapFocusTime > 8, now - self.lastFaceSeenTime > 1.5 else { return }
            self.sessionQueue.async {
                // This fires constantly while the phone moves. Continuous AF/AE
                // already follow the scene, so do NOTHING when they're running at
                // the centre. (It used to force a one-shot AF + AE lock and hand
                // back after 0.8 s every time — a visible hunt and exposure jump,
                // i.e. the "stutter / reset" while moving.)
                let center = CGPoint(x: 0.5, y: 0.5)
                func near(_ p: CGPoint) -> Bool { abs(p.x - 0.5) < 0.05 && abs(p.y - 0.5) < 0.05 }
                let focusFine = device.focusMode == .continuousAutoFocus
                    && (!device.isFocusPointOfInterestSupported || near(device.focusPointOfInterest))
                let exposureFine = device.exposureMode == .continuousAutoExposure
                    && (!device.isExposurePointOfInterestSupported || near(device.exposurePointOfInterest))
                guard !(focusFine && exposureFine) else { return }
                // A previous tap had locked a point: return smoothly to
                // continuous at the centre, no one-shot snap.
                do {
                    try device.lockForConfiguration()
                    if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                    if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                    device.unlockForConfiguration()
                } catch {}
            }
        }
    }

    /// AVCaptureMetadataOutputObjectsDelegate — steers AF toward the largest detected face.
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        // Don't interfere with manual focus or active tap-to-focus
        guard !cachedManualFocusEnabled, !tapFocusActive, !cachedFocusLocked else { return }
        guard let device = currentDevice else { return }

        let faces = metadataObjects.compactMap { $0 as? AVMetadataFaceObject }
        let detected = !faces.isEmpty

        // Only on change: this callback runs every frame, and each observed
        // write re-renders the views that read it.
        if detected != lastFaceDetected {
            lastFaceDetected = detected
            DispatchQueue.main.async { [weak self] in self?.faceDetected = detected }
        }

        guard detected else { return }
        lastFaceSeenTime = CACurrentMediaTime()
        // A tap wins over face steering for a while.
        guard CACurrentMediaTime() - lastTapFocusTime > 8 else { return }

        // Throttle face-steered focus updates to 1 Hz to avoid constant hunting
        let now = Date()
        guard now.timeIntervalSince(lastFaceFocusTime) > 1.0 else { return }
        lastFaceFocusTime = now

        // Pick the largest face by area
        let largest = faces.max(by: {
            ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height)
        })!
        // Face bounds are in normalized coordinates (0–1); centre is the focus point
        let cx = largest.bounds.midX
        let cy = largest.bounds.midY
        let focusPt = CGPoint(x: cx, y: cy)
        // Re-aiming a point that barely moved restarts the AF search for nothing.
        if let last = lastFaceFocusPoint, abs(last.x - cx) < 0.04, abs(last.y - cy) < 0.04 { return }
        lastFaceFocusPoint = focusPt

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = focusPt
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = focusPt
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Portrait Mode

    /// Enables / disables depth data delivery on photo output to match portrait mode state.
    func applyPortraitModeSession() {
        let enabled = portraitModeEnabled
        pendingPortraitEnabled = enabled
        sessionQueue.async { [self] in
            // Depth is streamed via AVCaptureDepthDataOutput — just toggle filtering
            depthDataOutput.isFilteringEnabled = enabled
            if !enabled {
                // Clear cached depth when portrait mode is off
                latestDepthPixelBuffer = nil
            }
        }
    }

    /// AVCaptureDepthDataOutputDelegate — caches the latest disparity map for live blur.
    nonisolated func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didOutput depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection
    ) {
        guard pendingPortraitEnabled else { return }
        // Convert to disparity (closer subjects = brighter pixels)
        let disparity: AVDepthData
        if depthData.depthDataType != kCVPixelFormatType_DisparityFloat32 {
            disparity = depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        } else {
            disparity = depthData
        }
        latestDepthPixelBuffer = disparity.depthDataMap
    }

    func toggleFlash() {
        switch flashMode {
        case .off:
            flashMode = .on; flashStrength = 0.1   // Min
        case .on:
            if flashStrength < 0.3 {
                flashStrength = 0.5                 // Min → Med
            } else if flashStrength < 0.8 {
                flashStrength = 1.0                 // Med → Max
            } else {
                flashMode = .auto                   // Max → Auto
            }
        case .auto: flashMode = .off
        @unknown default: flashMode = .off
        }
    }

    var flashLabel: String {
        switch flashMode {
        case .off:  return "OFF"
        case .on:
            if flashStrength < 0.3 { return "MIN" }
            if flashStrength < 0.8 { return "MED" }
            return "MAX"
        case .auto: return "AUTO"
        @unknown default: return "OFF"
        }
    }

    var effectiveQualityPrioritization: AVCapturePhotoOutput.QualityPrioritization {
        // Max / Natural are the user's 48MP choice: a saved camera's lower
        // quality (Speed = 12MP) must not override it.
        if let customSim = activeCustomSim, photoQuality < 2 {
            switch customSim.quality {
            case 0: return .speed
            case 1: return .balanced
            default: return .quality
            }
        }
        switch photoQuality {
        case 0: return .speed
        case 1: return .balanced
        default: return .quality          // Max, and Natural (48MP ProRAW)
        }
    }

    // MARK: Capture

    func capturePhoto() {
        if FilmRoll.shared.isFull {
            FilmRoll.shared.message = "Roll finished — develop it to keep shooting"
            return
        }
        isCapturing = true   // didSet pushes Watch state — no need to call pushState again
        FrameAdvisor.shared.noteShot(camera: self)   // framing example for the Mac-side training
        PoseGuide.shared.noteShot()
        wantsShutterThumb = true      // next live frame becomes the thumbnail, instantly
        // Each shot keeps its own copy of the settings: the shutter frees as soon
        // as the exposure is taken, so the next shot can start before this one
        // has rendered, and must not change its film, crop or rotation.
        // (computePhotoZoomCropFactor snapshots the on-device zoom: virtual
        // cameras sometimes deliver the full FOV, so we crop as a safety net.)
        let shotSim = selectedSim
        let shotGrain = grainAmount
        let shotAspectRatio = selectedAspectRatio
        let shotIsLandscape = isLandscape
        let shotDeviceAngle = deviceAngle
        let shotGrainEnabled = grainEnabled
        let shotContextAwareGrain = contextAwareGrainEnabled
        let shotISO = isoValue
        let shotCrosstalk = crosstalkAmount
        let shotHalation = halationAmount
        let shotRolloff = rolloffThreshold
        let shotCrosstalkEnabled = crosstalkEnabled
        let shotHalationEnabled = halationEnabled
        let shotRolloffEnabled = rolloffEnabled
        let shotDoubleExposureOpacity = doubleExposureOpacity
        let shotMask = doubleExposureMaskEnabled ? doubleExposureMask : nil
        let shotCustomSim = activeCustomSim
        let shotQuality = effectiveQualityPrioritization
        let shotLongExposureDuration = longExposureDuration
        let shotPushPullEnabled = pushPullEnabled
        let shotPushPullAmount = pushPullAmount
        let shotDevelopment = development
        let shotAnamorphicFlareEnabled = anamorphicFlareEnabled
        let shotLightArtifactsEnabled = lightArtifactsEnabled
        let shotFilmScratchesEnabled = filmScratchesEnabled
        let shotRandomizationEnabled = filmRandomizationEnabled
        let shotRandomSeed = UInt64.random(in: 0..<UInt64.max)
        let shotPortraitEnabled = portraitModeEnabled
        let shotPortraitFStop = portraitFStop
        let shotZoomCropFactor = computePhotoZoomCropFactor()
        let shotFull48 = full48
        let shotStrength = lookStrength
        let applySettings: @Sendable () -> Void = { [self] in
            pendingSim = shotSim
            pendingGrain = shotGrain
            pendingAspectRatio = shotAspectRatio
            pendingIsLandscape = shotIsLandscape
            pendingDeviceAngle = shotDeviceAngle
            pendingGrainEnabled = shotGrainEnabled
            pendingContextAwareGrain = shotContextAwareGrain
            pendingISO = shotISO
            pendingCrosstalk = shotCrosstalk
            pendingHalation = shotHalation
            pendingRolloff = shotRolloff
            pendingCrosstalkEnabled = shotCrosstalkEnabled
            pendingHalationEnabled = shotHalationEnabled
            pendingRolloffEnabled = shotRolloffEnabled
            pendingDoubleExposureOpacity = shotDoubleExposureOpacity
            pendingMask = shotMask
            pendingCustomSim = shotCustomSim
            pendingQuality = shotQuality
            pendingLongExposureDuration = shotLongExposureDuration
            pendingPushPullEnabled = shotPushPullEnabled
            pendingPushPullAmount = shotPushPullAmount
            pendingDevelopment = shotDevelopment
            pendingAnamorphicFlareEnabled = shotAnamorphicFlareEnabled
            pendingLightArtifactsEnabled = shotLightArtifactsEnabled
            pendingFilmScratchesEnabled = shotFilmScratchesEnabled
            pendingRandomizationEnabled = shotRandomizationEnabled
            pendingRandomSeed = shotRandomSeed
            pendingPortraitEnabled = shotPortraitEnabled
            pendingPortraitFStop = shotPortraitFStop
            pendingZoomCropFactor = shotZoomCropFactor
            pendingFull48 = shotFull48
            pendingLookStrength = shotStrength
        }

        if isLongExposure {
            switch longExposureMode {
            case .frameStack:
                sessionQueue.async { self.startFrameStackExposure() }
            case .nativeExposure:
                sessionQueue.async { self.startNativeExposure() }
            }
            applySettings()
            return
        }
        // While an earlier shot is still rendering, its settings must stay put;
        // this shot's are applied when its own render starts.
        if !hasShotsInFlight { applySettings() }

        let flash = flashMode
        let strength = flashStrength
        let useRAW = rawEnabled
        let quality = effectiveQualityPrioritization
        let portrait = portraitModeEnabled
        let natural = photoQuality == 3 && activeCustomSim == nil
        // Multi-frame zoom: Max, a digital zoom crop, nothing else in play.
        let multiFrameOK = photoQuality == 2 && !useRAW && !portrait && flash == .off
            && !doubleExposureEnabled && !burstMode && MultiFrameZoom.enabled
        sessionQueue.async { [self] in
            // Good light only: bracket frames get lighter noise reduction than
            // Apple's own multi-frame Max shot, and in dim light (measured in
            // a dark room) six of them merged were still noisier than it.
            if multiFrameOK, let d = currentDevice, !d.isVirtualDevice, d.videoZoomFactor >= 1.5, d.iso <= 400 || MultiFrameZoom.testing,
               photoOutput.maxBracketedCapturePhotoCount >= 2 {
                // A quick bracket of identical frames (~75 ms apart), merged
                // on the 48MP grid (MultiFrameZoom).
                let n = min(6, photoOutput.maxBracketedCapturePhotoCount)
                // Auto-exposure brackets don't expose like a normal shot
                // (measured: +0.4 EV processed, ~+1.3 EV with RAW; biased ones
                // overshoot the other way), so the burst uses exactly the
                // exposure the camera is metering now.
                let dur = d.exposureDuration, iso = d.iso
                let same = (0..<n).map { _ in
                    AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(exposureDuration: dur, iso: iso) }
                let bias: Float = 0
                let codec: AVVideoCodecType = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
                #if DEBUG
                print("[mf] bracket bias \(bias) iso \(d.iso)")
                #endif
                // RAW frames (Apple ProRAW) keep the sensor's detail that the
                // processed frames smooth away (measured on a test chart).
                let pro = MultiFrameZoom.useRAW
                    ? photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } : nil
                // RAW: iOS renders ProRAW brighter and flatter than its normal
                // processing (measured ~+0.8 EV median at the same exposure),
                // so a normal Max photo is taken first as the tone reference.
                var refID: Int64?
                if pro != nil {
                    let ref = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
                    ref.photoQualityPrioritization = .quality
                    ref.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                    refID = ref.uniqueID
                    rawStashLock.lock(); toneRefFor[ref.uniqueID] = ref.uniqueID; rawStashLock.unlock()
                    photoOutput.capturePhoto(with: ref, delegate: self)
                }
                let bs = pro.map { AVCapturePhotoBracketSettings(rawPixelFormatType: $0, processedFormat: nil, bracketedSettings: same) }
                    ?? AVCapturePhotoBracketSettings(rawPixelFormatType: 0, processedFormat: [AVVideoCodecKey: codec],
                                                     bracketedSettings: same)
                if let refID { rawStashLock.lock(); burstToneRef[bs.uniqueID] = refID; rawStashLock.unlock() }
                bs.photoQualityPrioritization = .quality
                bs.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                markMultiFrame(bs.uniqueID, count: n)

                registerShot(id: bs.uniqueID, apply: applySettings, portrait: false, burst: true)
                photoOutput.capturePhoto(with: bs, delegate: self)
                return
            }
            let settings: AVCapturePhotoSettings
            let codec: AVVideoCodecType = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            // Max quality must stay full resolution with RAW on: the plain
            // (Bayer) RAW is 12MP only and drags the processed photo down to
            // 12MP with it, so Max uses Apple ProRAW (48MP on Pro sensors).
            // Speed / Balanced keep the lighter 12MP Bayer RAW.
            let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
            let proRAW = rawTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
            let bayerRAW = rawTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
            let rawChoice = quality == .quality ? (proRAW ?? bayerRAW) : (bayerRAW ?? proRAW)
            if natural, !portrait, !capturingFirstExposure, let pro = proRAW {
                // Natural: ProRAW only, developed here without Apple's
                // photo processing (no local tone mapping, light noise
                // reduction) — see developNatural.
                settings = AVCapturePhotoSettings(rawPixelFormatType: pro)
                markNatural(settings.uniqueID, keepRAW: useRAW)
            } else if useRAW, let rawFormat = rawChoice {
                // RAW + film: the DNG and a processed photo from one exposure.
                // The processed one gets the film look; the DNG rides along as
                // the same Photos asset's RAW (like Halide / Project Indigo).
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat,
                                                  processedFormat: [AVVideoCodecKey: codec])
            } else {
                // Use HEIF for 10-bit wide color when available, fall back to JPEG
                if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                    settings = AVCapturePhotoSettings(format: [
                        AVVideoCodecKey: AVVideoCodecType.hevc
                    ])
                } else {
                    settings = AVCapturePhotoSettings(format: [
                        AVVideoCodecKey: AVVideoCodecType.jpeg
                    ])
                }
            }
            settings.photoQualityPrioritization = quality
            let dims = currentDevice?.activeFormat.supportedMaxPhotoDimensions
            switch quality {
            case .quality:
                if let d = dims?.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                    settings.maxPhotoDimensions = d
                }
            case .speed:
                if let d = dims?.min(by: { $0.width * $0.height < $1.width * $1.height }) {
                    settings.maxPhotoDimensions = d
                }
            default:
                break
            }
            // Flash: use torch-as-flash for adjustable strength, full strength uses native flash
            if flash == .on, let device = currentDevice, device.hasTorch {
                let level = Float(max(0.01, min(1.0, strength)))
                do {
                    try device.lockForConfiguration()
                    try? device.setTorchModeOn(level: level)
                    device.unlockForConfiguration()
                } catch {}
                settings.flashMode = .off  // torch provides the light
            } else if photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            registerShot(id: settings.uniqueID, apply: applySettings, portrait: portrait)
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    #if DEBUG
    /// -resProbe: which settings give a real 48MP photo here and now.
    nonisolated func debugBurstProbe() {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            PipelineAudit.log("burst maxBracket \(photoOutput.maxBracketedCapturePhotoCount) device \(device.localizedName)")
            if (try? device.lockForConfiguration()) != nil { device.videoZoomFactor = 2.7; device.unlockForConfiguration() }
            Thread.sleep(forTimeInterval: 0.8)
            let raws = photoOutput.availableRawPhotoPixelFormatTypes
            let bayer = raws.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) } ?? 0
            let pro = raws.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } ?? 0
            PipelineAudit.log("burst raw formats bayer \(bayer) proraw \(pro)")
            for (k, (q, rawFmt)) in [(AVCapturePhotoOutput.QualityPrioritization.balanced, bayer), (.quality, pro), (.speed, bayer)].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 6) { [self] in
                    sessionQueue.async { [self] in
                        let n = min(4, photoOutput.maxBracketedCapturePhotoCount)
                        let biases = (0..<n).map { _ in AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: 0) }
                        let bs = AVCapturePhotoBracketSettings(rawPixelFormatType: rawFmt,
                                                               processedFormat: rawFmt == pro ? [AVVideoCodecKey: AVVideoCodecType.hevc] : nil,
                                                               bracketedSettings: biases)
                        bs.photoQualityPrioritization = q
                        bs.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                        PipelineAudit.tag = "burst-\(q.rawValue)-raw\(rawFmt == pro ? "pro" : "bayer")"
                        PipelineAudit.log(String(format: "burst-%d request n=%d t=%.3f", q.rawValue, n, CACurrentMediaTime()))
                        photoOutput.capturePhoto(with: bs, delegate: self)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { PipelineAudit.tag = nil; PipelineAudit.log("done") }
        }
    }

    nonisolated func debugResolutionProbe() {
        func listFormats(_ d: AVCaptureDevice) {
            for f in d.formats {
                let v = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let ph = f.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" }.joined(separator: ",")
                let fps = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
                PipelineAudit.log("fmt \(d.localizedName) \(v.width)x\(v.height) @\(Int(fps)) photo [\(ph)] depth \(f.supportedDepthDataFormats.count) fov \(f.videoFieldOfView)")
            }
        }
        if let t = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) { listFormats(t) }
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            PipelineAudit.log("probe device \(device.localizedName) active max \(device.activeFormat.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" }) output max \(photoOutput.maxPhotoDimensions.width)x\(photoOutput.maxPhotoDimensions.height) iso \(device.iso)")
            let big = device.activeFormat.supportedMaxPhotoDimensions.max { $0.width * $0.height < $1.width * $1.height }!
            let tests: [(String, AVCapturePhotoOutput.QualityPrioritization, Bool, CGFloat)] =
                [("probe-q-z1", .quality, false, 1.0), ("probe-q-z1.3", .quality, false, 1.3), ("probe-q-z1.6", .quality, false, 1.6), ("probe-q-z2", .quality, false, 2),
                 ("probe-q-z2.7", .quality, false, 2.7), ("probe-raw-z1.6", .quality, true, 1.6)]
            for (k, t) in tests.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(k) * 4) { [self] in
                    sessionQueue.async { [self] in
                        if (try? device.lockForConfiguration()) != nil { device.videoZoomFactor = t.3; device.unlockForConfiguration() }
                        Thread.sleep(forTimeInterval: 0.5)
                        PipelineAudit.tag = t.0
                        let settings: AVCapturePhotoSettings
                        if t.2, let pro = photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                            settings = AVCapturePhotoSettings(rawPixelFormatType: pro)
                        } else {
                            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                        }
                        settings.photoQualityPrioritization = t.1
                        settings.maxPhotoDimensions = big
                        photoOutput.capturePhoto(with: settings, delegate: self)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { PipelineAudit.tag = nil; PipelineAudit.log("done") }
        }
    }
    #endif

    // MARK: Burst Capture

    func startBurst() {
        guard !isBursting, !isRecording, !capturingFirstExposure else { return }
        isBursting = true
        burstActive = true
        burstCount = 0
        WatchConnector.shared.pushState()
        // Snapshot zoom-crop factor so each burst frame gets the safety crop on
        // virtual cameras (otherwise burst frames have wider FOV than preview).
        pendingZoomCropFactor = computePhotoZoomCropFactor()
        // Snapshot pending values for burst processing
        pendingSim = selectedSim
        pendingCustomSim = activeCustomSim
        pendingGrain = grainAmount
        pendingGrainEnabled = grainEnabled
        pendingContextAwareGrain = contextAwareGrainEnabled
        pendingAspectRatio = selectedAspectRatio
        pendingIsLandscape = isLandscape
        pendingDeviceAngle = deviceAngle
        pendingCrosstalk = crosstalkAmount
        pendingCrosstalkEnabled = crosstalkEnabled
        pendingHalation = halationAmount
        pendingHalationEnabled = halationEnabled
        pendingRolloff = rolloffThreshold
        pendingRolloffEnabled = rolloffEnabled
        pendingPushPullEnabled = pushPullEnabled
        pendingPushPullAmount = pushPullAmount
        pendingDevelopment = development
        pendingAnamorphicFlareEnabled = anamorphicFlareEnabled
        pendingLightArtifactsEnabled = lightArtifactsEnabled
        pendingFilmScratchesEnabled = filmScratchesEnabled
        pendingRandomizationEnabled = filmRandomizationEnabled
        pendingRandomSeed = UInt64.random(in: 0..<UInt64.max)
        fireBurstShot()
    }

    func stopBurst() {
        isBursting = false
        burstActive = false
        burstBacklog = 0
        WatchConnector.shared.pushState()
    }

    // MARK: Video Recording

    /// Smooth AF (slow, no breathing) suits video; stills want the fast snap.
    func setSmoothAutoFocus(_ on: Bool) {
        sessionQueue.async { [weak self] in
            guard let device = self?.currentDevice, device.isSmoothAutoFocusSupported,
                  device.isSmoothAutoFocusEnabled != on else { return }
            do {
                try device.lockForConfiguration()
                device.isSmoothAutoFocusEnabled = on
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func startRecording() {
        guard !isRecording, !isBursting, !capturingFirstExposure else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()

        // Auto-swap to virtual triple camera before recording so the user can
        // zoom across wide↔tele constituents during the take without breaking
        // the AVAssetWriter (the triple handles internal lens switching via
        // videoZoomFactor — no session reconfig needed mid-recording).
        //
        // Note: this behavior is independent of the unifiedZoomMode toggle —
        // recording always uses the triple's full zoom range (when available).
        // Exception: if the user explicitly chose ultrawide (13mm preset / macro),
        // honor that — keep recording on ultrawide so they don't lose their FOV.
        let currentType = currentDevice?.deviceType
        let onVirtual = currentType == .builtInTripleCamera
                     || currentType == .builtInDualCamera
                     || currentType == .builtInDualWideCamera
        let onUltrawide = currentType == .builtInUltraWideCamera
        if !onVirtual && !onUltrawide {
            // Snapshot the current zoom in our 26mm-base scale; carry it across
            // the swap so the FOV doesn't jump. Apply the prospective virtual
            // compensation since the destination is the triple camera (whose
            // wide constituent is wider than physical wide — uncompensated zoom
            // would land at a wider FOV than intended).
            let carryIntent = max(1.0, lastRequestedZoom)
            let carryDeviceZoom = carryIntent * prospectiveVirtualCompensation
            swapToVirtualDevice(zoom: carryDeviceZoom, animate: false)
            // Wait for the swap to settle, then start the writer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.beginRecordingWriter()
            }
        } else {
            beginRecordingWriter()
        }
    }

    private func beginRecordingWriter() {
        guard !isRecording, !isBursting, !capturingFirstExposure else { return }
        isRecording = true
        setSmoothAutoFocus(true)
        WatchConnector.shared.pushState()
        recordingDuration = 0
        recordingSessionStarted = false
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.recordingDuration += 0.1
        }
        sessionQueue.async { [self] in
            self.addVideoDataOutputIfNeeded()
            self.addAudioOutputIfNeeded()
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        setSmoothAutoFocus(false)
        WatchConnector.shared.pushState()
        recordingTimer?.invalidate()
        recordingTimer = nil
        // Lock-protected snapshot — guarantees we see consistent writer state
        // even if a sample buffer is mid-setupAssetWriter on the frame queue.
        writerLock.lock()
        let writer = assetWriter
        let url = recordingOutputURL
        let sessionWasStarted = recordingSessionStarted
        if sessionWasStarted {
            videoWriterInput?.markAsFinished()
            audioWriterInput?.markAsFinished()
        }
        assetWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        pixelBufferAdaptor = nil
        recordingOutputURL = nil
        recordingSessionStarted = false
        writerLock.unlock()
        guard sessionWasStarted, let writer else { return }
        // AVAssetWriter isn't Sendable — use nonisolated(unsafe) so the compiler
        // doesn't warn when it's captured inside the @Sendable finishWriting closure.
        nonisolated(unsafe) let finishWriter = writer
        finishWriter.finishWriting {
            guard finishWriter.status == .completed, let url else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { success, error in
                if !success {
                    DispatchQueue.main.async {
                        self.saveErrorMessage = "Couldn't save video: \(error?.localizedDescription ?? "unknown error")"
                    }
                }
            })
            DispatchQueue.main.async {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    private nonisolated func fireBurstShot() {
        guard burstActive else { return }
        sessionQueue.async { [self] in
            let settings: AVCapturePhotoSettings
            if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            }
            settings.flashMode = .off
            settings.photoQualityPrioritization = .speed
            // Burst uses default binned resolution for max speed
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // Called from photoOutput delegate to chain the next burst shot
    nonisolated func burstDidCapture() {
        DispatchQueue.main.async { self.burstCount += 1 }
        // Fire next shot immediately — no main thread bounce
        fireBurstShot()
    }

    // MARK: Smooth Zoom

    func stepManualZoom(up: Bool) {
        let next = up ? min(zoom + 0.2, maxManualZoom) : max(zoom - 0.2, 0.5)
        zoom = next
        setZoom(CGFloat(next))
    }

    /// `factor` is INTENT zoom in our 26mm-based scale (so 1.0 = 28mm-ish, 5.0 = 130mm).
    /// Internally translates to the active device's `videoZoomFactor` based on the
    /// device type (ultrawide doubles, virtual cameras compensate for wider constituent).
    func setZoom(_ factor: CGFloat) {
        lastRequestedZoom = factor
        let currentType = currentDevice?.deviceType

        // While recording: never swap lenses (would tear down the AVAssetWriter).
        // The recording start auto-swaps us to virtual triple, so wide↔tele is
        // handled internally via videoZoomFactor changes — no session reconfig needed.
        if isRecording {
            guard let device = currentDevice else { return }
            let onUW = currentType == .builtInUltraWideCamera
            let onVirt = currentType == .builtInTripleCamera
                      || currentType == .builtInDualCamera
                      || currentType == .builtInDualWideCamera
            let deviceFactor: CGFloat
            if onUW {
                deviceFactor = max(1.0, factor * 2.0)
            } else if onVirt {
                deviceFactor = max(1.0, factor * virtualWideFOVCompensation)
            } else {
                deviceFactor = max(1.0, factor)
            }
            let clamped = max(device.minAvailableVideoZoomFactor, min(deviceFactor, device.maxAvailableVideoZoomFactor))
            // Display mm: convert clamped device factor back to intent mm
            let newMM: Int
            if onUW {
                newMM = Int(round(13.0 * Double(clamped)))
            } else if onVirt {
                newMM = Int(round(26.0 * Double(clamped) / Double(virtualWideFOVCompensation)))
            } else {
                newMM = Int(round(26.0 * Double(clamped)))
            }
            currentMM = newMM
            let matchingIdx = focalPresets.firstIndex { p in
                p.mm == newMM && (
                    (p.deviceType == .builtInUltraWideCamera && onUW) ||
                    (p.deviceType != .builtInUltraWideCamera && !onUW)
                )
            }
            selectedFocalIndex = matchingIdx ?? -1
            do {
                try device.lockForConfiguration()
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                device.ramp(toVideoZoomFactor: clamped, withRate: 60.0)
                device.unlockForConfiguration()
            } catch {}
            return
        }

        // Cross into ultrawide territory — swap to physical ultrawide (one-shot)
        if factor < 1.0 && currentType != .builtInUltraWideCamera {
            guard !isSwappingLens else { return }
            isSwappingLens = true
            selectedFocalIndex = 0
            let uwZoom = max(1.0, factor * 2.0)
            swapInputDevice(to: focalPresets[0], animate: false, targetZoom: uwZoom)
            currentMM = Int(round(13.0 * uwZoom))
            return
        }

        // Cross out of ultrawide — swap back to virtual device. The destination
        // is virtual so the zoom on the new device must be FOV-compensated.
        if factor >= 1.0 && currentType == .builtInUltraWideCamera {
            guard !isSwappingLens else { return }
            isSwappingLens = true
            selectedFocalIndex = -1
            swapToVirtualDevice(zoom: factor * prospectiveVirtualCompensation, animate: false)
            currentMM = Int(round(26.0 * Double(factor)))
            return
        }

        // On the physical telephoto: zooming further in stays on it (digital
        // zoom on the telephoto's own sensor); only going wider than the
        // telephoto swaps back to the multi-lens camera.
        if currentType == .builtInTelephotoCamera, let tele = Self.teleIntent, factor >= tele * 0.9,
           let device = currentDevice {
            let z = max(1, factor / tele)
            currentMM = Int(round(26.0 * Double(factor)))
            sessionQueue.async { [weak self] in self?.applyZoom(factor: z, on: device) }
            return
        }
        if currentType == .builtInTelephotoCamera {
            guard !isSwappingLens else { return }
            isSwappingLens = true
            selectedFocalIndex = -1
            swapToVirtualDevice(zoom: factor * prospectiveVirtualCompensation, animate: false)
            currentMM = Int(round(26.0 * Double(factor)))
            return
        }

        // Slider drag while on physical wide — only swap to virtual once the
        // user crosses where iOS can engage the telephoto. Compare INTENT zoom
        // to the 5.0x threshold (NOT compensated factor — 5.0 intent = 130mm).
        if currentType == .builtInWideAngleCamera, factor >= 5.0 {
            guard !isSwappingLens else { return }
            isSwappingLens = true
            selectedFocalIndex = -1
            swapToVirtualDevice(zoom: factor * prospectiveVirtualCompensation, animate: false)
            currentMM = Int(round(26.0 * Double(factor)))
            return
        }

        let onUltrawide = currentType == .builtInUltraWideCamera
        let onVirtual = currentType == .builtInTripleCamera
                     || currentType == .builtInDualCamera
                     || currentType == .builtInDualWideCamera
        // Translate intent zoom → device-specific videoZoomFactor.
        let deviceFactor: CGFloat
        if onUltrawide {
            deviceFactor = max(1.0, factor * 2.0)
        } else if onVirtual {
            deviceFactor = factor * virtualWideFOVCompensation
        } else {
            deviceFactor = factor
        }
        let newMM: Int
        if onUltrawide {
            newMM = Int(round(13.0 * Double(deviceFactor)))
        } else {
            // intent IS the mm-based scale; display directly
            newMM = Int(round(26.0 * Double(factor)))
        }
        currentMM = newMM
        // Sync focal preset highlight: only stay lit if the current mm matches that preset on the same lens
        let matchingIdx = focalPresets.firstIndex { p in
            p.mm == newMM && (
                (p.deviceType == .builtInUltraWideCamera && onUltrawide) ||
                (p.deviceType != .builtInUltraWideCamera && !onUltrawide && currentType != .builtInTelephotoCamera)
            )
        }
        selectedFocalIndex = matchingIdx ?? -1
        guard let device = currentDevice else { return }
        let clamped = max(device.minAvailableVideoZoomFactor, min(deviceFactor, device.maxAvailableVideoZoomFactor))
        do {
            try device.lockForConfiguration()
            // Use ramp() instead of direct videoZoomFactor write — produces a
            // hardware-accelerated smooth transition. Rate is high so small
            // slider deltas feel near-instant; large jumps glide instead of snap.
            // Cancel any prior ramp before issuing a new one.
            if device.isRampingVideoZoom {
                device.cancelVideoZoomRamp()
            }
            device.ramp(toVideoZoomFactor: clamped, withRate: 60.0)
            device.unlockForConfiguration()
        } catch {}
    }

    /// Would `setZoom(factor)` have to switch lenses (reconfigure the session —
    /// the preview freezes ~1 s)? Mirrors setZoom's swap rules.
    func zoomNeedsLensSwap(_ factor: CGFloat) -> Bool {
        guard !isRecording else { return false }
        let t = currentDevice?.deviceType
        if factor < 1.0 && t != .builtInUltraWideCamera { return true }
        if factor >= 1.0 && t == .builtInUltraWideCamera { return true }
        if t == .builtInTelephotoCamera { return true }
        if t == .builtInWideAngleCamera && factor >= 5.0 { return true }
        return false
    }

    func syncZoomState() {
        guard let device = currentDevice else { return }
        let deviceZoom = Double(device.videoZoomFactor)
        let baseMM: Double
        switch device.deviceType {
        case .builtInUltraWideCamera: baseMM = 13.0
        case .builtInTelephotoCamera: baseMM = 120.0
        case .builtInTripleCamera, .builtInDualCamera, .builtInDualWideCamera:
            // Virtual cameras have a wider wide-constituent than physical wide;
            // divide the on-device factor by the FOV compensation so the displayed
            // mm matches the labeled presets.
            baseMM = 26.0 / Double(virtualWideFOVCompensation)
        default: baseMM = 26.0
        }
        let mm = baseMM * deviceZoom
        currentMM = Int(round(mm))
        zoom = mm / 26.0
    }

    // MARK: Long Exposure - Frame Stack

    nonisolated func startFrameStackExposure() {
        frameStack.removeAll()
        isCollectingFrames = true
        let duration = pendingLongExposureDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.sessionQueue.async {
                self?.isCollectingFrames = false
                self?.finishFrameStack()
            }
        }
    }

    nonisolated func finishFrameStack() {
        // Take a local snapshot atomically before any guard so a concurrent
        // append on frameOutputQueue can't empty the array between the check and use.
        let stack = frameStack
        frameStack.removeAll()
        guard !stack.isEmpty else {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }
        let extent = stack[0].extent
        let count = Float(stack.count)

        // Average the frames
        var accumulated: CIImage = stack[0]
        for i in 1..<stack.count {
            let blend = CIFilter.additionCompositing()
            blend.inputImage = stack[i]
            blend.backgroundImage = accumulated
            accumulated = blend.outputImage ?? accumulated
        }

        // Divide by count using color matrix
        let scale = 1.0 / CGFloat(count)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = accumulated
        matrix.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let averaged = matrix.outputImage ?? accumulated

        DispatchQueue.main.async { self.isCapturing = false }
        processQueue.async { [self] in
            Self.lookAngle = pendingDeviceAngle         // which way is up for orientation-aware looks
            renderAndSave(ciImage: averaged.cropped(to: extent))
        }
    }

    // MARK: Long Exposure - Native

    nonisolated func startNativeExposure() {
        guard let device = currentDevice else {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }
        let duration = pendingLongExposureDuration

        // Clamp to what the current format supports
        let targetDuration = CMTimeMakeWithSeconds(duration, preferredTimescale: 1000000)
        let maxDuration = device.activeFormat.maxExposureDuration
        let minDuration = device.activeFormat.minExposureDuration
        let clampedDuration = CMTimeMinimum(CMTimeMaximum(targetDuration, minDuration), maxDuration)

        // Lock current ISO before switching to custom mode
        let currentISO = min(max(device.iso, device.activeFormat.minISO), device.activeFormat.maxISO)

        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: clampedDuration, iso: currentISO) { [weak self] _ in
                // Exposure is now applied — wait for the full duration then capture
                guard let self else { return }
                let waitTime = CMTimeGetSeconds(clampedDuration) + 0.3
                self.sessionQueue.asyncAfter(deadline: .now() + waitTime) {
                    self.captureAfterNativeExposure(device: device)
                }
            }
            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }
    }

    nonisolated func captureAfterNativeExposure(device: AVCaptureDevice) {
        // Bail if the user swapped lenses during the long-exposure wait. Otherwise
        // we'd capture from a device that's no longer the active session input
        // (which silently fails or yields a frame from the wrong lens).
        guard currentDevice === device else {
            DispatchQueue.main.async { self.isCapturing = false }
            // Best-effort: restore continuous auto on the stale device anyway.
            do {
                try device.lockForConfiguration()
                device.exposureMode = .continuousAutoExposure
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                device.unlockForConfiguration()
            } catch {}
            return
        }
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        }
        settings.photoQualityPrioritization = pendingQuality
        if pendingQuality == .quality,
           let maxDim = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            settings.maxPhotoDimensions = maxDim
        }
        photoOutput.capturePhoto(with: settings, delegate: self)

        // Reset exposure and focus back to continuous auto so preview recovers
        do {
            try device.lockForConfiguration()
            device.exposureMode = .continuousAutoExposure
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: Film Processing & Save

    // MARK: Natural (ProRAW developed without Apple's processing)

    @ObservationIgnored nonisolated(unsafe) private var naturalShots: [Int64: Bool] = [:]
    nonisolated func markNatural(_ id: Int64, keepRAW: Bool) {
        rawStashLock.lock(); naturalShots[id] = keepRAW; rawStashLock.unlock()
    }
    nonisolated func takeNatural(_ id: Int64) -> (keepRAW: Bool, Void)? {
        rawStashLock.lock(); defer { rawStashLock.unlock() }
        guard let k = naturalShots.removeValue(forKey: id) else { return nil }
        return (k, ())
    }

    /// Develop a ProRAW ourselves: Apple's processed photo applies local tone
    /// mapping (the "HDR look"), strong noise reduction and sharpening, which
    /// smear fine texture under a film look. Here: no local tone mapping,
    /// light noise reduction, default sharpening — then the film look.
    nonisolated func developNatural(_ dng: Data, keepRAW: Bool, shot: (@Sendable () -> Void)?) {
        DispatchQueue.main.async { self.isCapturing = false }
        processQueue.async { [self] in
            Self.lookAngle = pendingDeviceAngle         // which way is up for orientation-aware looks
            if let shot { shot() }
            defer { if shot != nil { shotRendered() } }
            // No local tone mapping, light noise reduction; highlights kept
            // via the extended range. Upright like an EXIF-oriented photo.
            guard var ciImage = Self.developWithHeadroom(dng, localToneMap: 0, noiseReduction: 0.15) else {
                DispatchQueue.main.async { self.saveErrorMessage = "Couldn't develop the RAW" }
                return
            }
            let metadata = CIImage(data: dng)?.properties ?? [:]
            ciImage = applyPhotoZoomCrop(ciImage)
            let base = ciImage
            pendingSceneISO = Self.captureISO(metadata)      // context-aware grain
            let recipe = pendingRecipe()
            publishQuickPreview(ciImage, recipe: recipe)
            let processed = applySimAndGrain(to: ciImage)
            var meta = metadata
            meta[kCGImagePropertyOrientation as String] = 1        // pixels are upright now
            renderAndSave(ciImage: processed, metadata: meta, base: base, recipe: recipe, raw: keepRAW ? dng : nil)
        }
    }

    /// Develop a DNG keeping what the processed photo clips: CIRAWFilter's
    /// extended dynamic range (highlights above 1.0) brought back into the
    /// photo with Apple's HDR tone mapper, so skies and lamps roll off instead
    /// of clipping before the film sees them. Upright, at the origin.
    nonisolated static func developWithHeadroom(_ dng: Data, localToneMap: Float? = nil,
                                                noiseReduction: Float? = nil, sharpness: Float? = nil) -> CIImage? {
        guard let raw = CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image") else { return nil }
        if let sh = sharpness, raw.isSharpnessSupported { raw.sharpnessAmount = sh }
        if let l = localToneMap, raw.isLocalToneMapSupported { raw.localToneMapAmount = l }
        if let n = noiseReduction, raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = n }
        raw.extendedDynamicRangeAmount = 1
        guard var img = raw.outputImage else { return nil }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let headroom = max(img.contentHeadroom, 1)
        if headroom > 1.01 {
            img = img.applyingFilter("CIToneMapHeadroom", parameters: ["inputSourceHeadroom": headroom,
                                                                       "inputTargetHeadroom": 1])
        }
        return img
    }

    nonisolated func processAndSaveJPEG(imageData: Data, rawID: Int64? = nil, frames: [Data]? = nil, shotID: Int64? = nil,
                                        shot: (@Sendable () -> Void)? = nil) {
        // Unblock shutter immediately — process and save in background
        DispatchQueue.main.async { self.isCapturing = false }

        processQueue.async { [self] in
            Self.lookAngle = pendingDeviceAngle         // which way is up for orientation-aware looks
            if let shot { shot() }
            defer { if shot != nil { shotRendered() } }
            guard var ciImage = CIImage(data: imageData) else { return }

            // Extract original metadata (focal length, lens, GPS, etc.) before processing
            let originalMetadata = ciImage.properties

            // Apply EXIF orientation so the image is upright before processing
            ciImage = ciImage.oriented(forExifOrientation: Int32(ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1))

            // Multi-frame zoom: merge the bracket on the 48MP grid.
            if let frames, frames.count >= 2 {
                func oriented(_ d: Data) -> CIImage? {
                    guard let f = CIImage(data: d) else { return nil }
                    return f.oriented(forExifOrientation: Int32(f.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1))
                }
                let dngs = frames.filter { MultiFrameZoom.isDNG($0) }
                var processedFrames = frames.filter { !MultiFrameZoom.isDNG($0) }.compactMap(oriented)
                if !dngs.isEmpty, let id = shotID, let ref = takeToneReference(burst: id).flatMap(oriented) {
                    processedFrames.insert(ref, at: 0)
                }
                let upright0 = processedFrames
                var upright = dngs.isEmpty ? upright0 : []
                #if DEBUG
                print("[mf] frames: \(dngs.count) DNG, \(processedFrames.count) processed")
                #endif
                if dngs.count >= 2, let refTone = processedFrames.first {
                    // RAW frames: Apple's RAW development (its sharpening kept:
                    // that's where the extra detail is), tone matched to the
                    // normal photo taken just before the burst.
                    let developed = dngs.compactMap { Self.developWithHeadroom($0) }
                    if let first = developed.first, let match = MultiFrameZoom.matchTone(first, to: refTone, context: photoContext) {
                        upright = developed.map(match)
                    } else { upright = developed }
                } else if dngs.count >= 2 {
                    upright = dngs.compactMap { Self.developWithHeadroom($0) }      // no reference: as developed
                }
                // The base image (metadata, fallback) is the processed photo.
                if let p = processedFrames.first { ciImage = p }
                #if DEBUG
                let t0 = CACurrentMediaTime()
                #endif
                if let merged = MultiFrameZoom.merge(upright, context: photoContext) { ciImage = merged }
                #if DEBUG
                print(String(format: "[perf] %.2f MULTIFRAME %d frames in %.0f ms", CACurrentMediaTime(), upright.count, (CACurrentMediaTime() - t0) * 1000))
                if PipelineAudit.tag != nil { PipelineAudit.log("multiframe \(upright.count) frames merged") }
                #endif
            }

            // Safety-net zoom crop for virtual cameras. iOS sometimes captures
            // the constituent's full FOV without applying videoZoomFactor on
            // max-quality photo paths — this brings the photo FOV in line with
            // the preview FOV. No-op on physical lenses.
            ciImage = applyPhotoZoomCrop(ciImage)

            // Red-eye correction on original colors before any film sim warmth is applied
            let redEyeStr: Float = {
                if pendingSim == .nightShot { return 0.55 }
                if pendingSim == .digiCam   { return 0.22 }
                return pendingCustomSim?.redEyeStrength ?? 0
            }()
            // RAW + film: the film is developed from the DNG (same exposure,
            // same framing) so the highlights Apple's processed photo clipped
            // are still there. Falls back to the processed photo.
            let raw = takeRAW(id: rawID)
            if let raw, firstExposureCIImage == nil, redEyeStr == 0,
               let dev = Self.developWithHeadroom(raw) {
                let e = ciImage.extent, d = dev.extent
                if abs(d.width / d.height - e.width / e.height) < 0.02, d.width > 0 {
                    let s = e.width / d.width
                    ciImage = dev.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
                        .cropped(to: CGRect(x: 0, y: 0, width: e.width, height: e.height))
                }
            }
            let base = ciImage                                  // framed, un-graded original
            let isDoubleExposure = firstExposureCIImage != nil  // composites can't be re-graded
            pendingSceneISO = Self.captureISO(originalMetadata)      // context-aware grain
            let recipe = pendingRecipe()
            if !isDoubleExposure { publishQuickPreview(ciImage, recipe: recipe) }
            if redEyeStr > 0 { ciImage = applyRedEyeCorrection(to: ciImage, strength: redEyeStr) }

            let processed = applySimAndGrain(to: ciImage)
            if rawID != nil, raw == nil {
                DispatchQueue.main.async { self.saveErrorMessage = "The RAW didn't arrive, saved the photo only" }
            }
            renderAndSave(ciImage: processed, metadata: originalMetadata,
                          base: isDoubleExposure ? nil : base, recipe: recipe, raw: raw)
        }
    }

    // MARK: - Portrait Depth Blur

    /// Portrait capture using depth embedded in the AVCapturePhoto (legacy path, kept for reference).
    nonisolated func processAndSavePortrait(imageData: Data, depthData: AVDepthData) {
        DispatchQueue.main.async { self.isCapturing = false }
        processQueue.async { [self] in
            Self.lookAngle = pendingDeviceAngle         // which way is up for orientation-aware looks
            guard var ciImage = CIImage(data: imageData) else { return }
            let originalMetadata = ciImage.properties
            ciImage = ciImage.oriented(forExifOrientation: Int32(ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1))
            let redEyeStr: Float = {
                if pendingSim == .nightShot { return 0.55 }
                if pendingSim == .digiCam   { return 0.22 }
                return pendingCustomSim?.redEyeStrength ?? 0
            }()
            if redEyeStr > 0 { ciImage = applyRedEyeCorrection(to: ciImage, strength: redEyeStr) }
            let disparity: AVDepthData = depthData.depthDataType == kCVPixelFormatType_DisparityFloat32
                ? depthData
                : depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
            let blurred = applyPortraitBlur(to: ciImage, disparityData: disparity, fStop: pendingPortraitFStop)
            pendingSceneISO = Self.captureISO(originalMetadata)      // context-aware grain
            let recipe = pendingRecipe()
            let withSim = applySimAndGrain(to: blurred)
            renderAndSave(ciImage: withSim, metadata: originalMetadata, base: blurred, recipe: recipe)
        }
    }

    /// Portrait capture using the live-streamed depth pixel buffer from AVCaptureDepthDataOutput.
    nonisolated func processAndSavePortraitFromBuffer(imageData: Data, depthBuffer: CVPixelBuffer?, rawID: Int64? = nil, shot: (@Sendable () -> Void)? = nil) {
        DispatchQueue.main.async { self.isCapturing = false }
        // CVPixelBuffer is not Sendable — rebind before the closure captures it
        nonisolated(unsafe) let sendableBuffer = depthBuffer
        processQueue.async { [self] in
            Self.lookAngle = pendingDeviceAngle         // which way is up for orientation-aware looks
            if let shot { shot() }
            defer { if shot != nil { shotRendered() } }
            guard var ciImage = CIImage(data: imageData) else { return };
            let originalMetadata = ciImage.properties
            ciImage = ciImage.oriented(forExifOrientation: Int32(ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1))
            ciImage = applyPhotoZoomCrop(ciImage)              // 48MP on Max (depth format is 12MP)
            let redEyeStr: Float = {
                if pendingSim == .nightShot { return 0.55 }
                if pendingSim == .digiCam   { return 0.22 }
                return pendingCustomSim?.redEyeStrength ?? 0
            }()
            if redEyeStr > 0 { ciImage = applyRedEyeCorrection(to: ciImage, strength: redEyeStr) }
            // Scale the depth map uniformly to full photo resolution. Using max()
            // ensures depth covers the image even on slight aspect mismatch and
            // prevents geometric warping that would mis-project subject depth.
            var cameraDepth: CIImage?
            if let buf = sendableBuffer {
                let depthCI = CIImage(cvPixelBuffer: buf)
                let sx = ciImage.extent.width  / depthCI.extent.width
                let sy = ciImage.extent.height / depthCI.extent.height
                let s  = max(sx, sy)
                cameraDepth = depthCI.transformed(by: CGAffineTransform(scaleX: s, y: s)).cropped(to: ciImage.extent)
            }
            // Depth Anything (if bundled): sharper, scene-wide depth from the
            // photo itself, fitted to the camera's depth when there is one.
            var scaledDepth: CIImage
            if let mono = MonoDepth.disparity(of: ciImage) {
                scaledDepth = MonoDepth.calibrated(mono, to: cameraDepth, context: photoContext)
            } else if let cameraDepth {
                scaledDepth = cameraDepth
            } else {
                renderAndSave(ciImage: applySimAndGrain(to: ciImage), metadata: originalMetadata, base: ciImage,
                              recipe: pendingRecipe(), raw: takeRAW(id: rawID))
                return
            }
            // Pixel-2-style: the subject's segmentation fixes the coarse depth
            // (edges, hair, an off-centre subject).
            var focus: CGRect?
            if let r = SubjectDepth.refine(disparity: scaledDepth, image: ciImage, context: photoContext) {
                scaledDepth = r.disparity; focus = r.focusRect
            }
            let blurred = applyPortraitBlurFromCIImage(to: ciImage, disparityCI: scaledDepth, fStop: pendingPortraitFStop, focusRect: focus)
            #if DEBUG
            if PipelineAudit.tag != nil {
                for (n, im) in [("in", ciImage), ("depth", scaledDepth), ("blurred", blurred)] {
                    PipelineAudit.log("portrait step \(n) " + PipelineAudit.describe(PipelineAudit.stats(im, ctx: photoContext)) + " extent \(im.extent)")
                }
                PipelineAudit.log("portrait fstop \(pendingPortraitFStop) focus \(String(describing: focus))")
            }
            #endif
            pendingSceneISO = Self.captureISO(originalMetadata)      // context-aware grain
            let recipe = pendingRecipe()
            publishQuickPreview(blurred, recipe: recipe)
            let withSim = applySimAndGrain(to: blurred)
            renderAndSave(ciImage: withSim, metadata: originalMetadata, base: blurred, recipe: recipe, raw: takeRAW(id: rawID))
        }
    }

    /// Removes red-eye from a flash photo using CIRedEyeCorrection, blended at `strength`
    /// (0 = no change, 1 = full correction). Applied before any warm film simulation.
    nonisolated func applyRedEyeCorrection(to image: CIImage, strength: Float) -> CIImage {
        guard strength > 0 else { return image }
        guard let filter = CIFilter(name: "CIRedEyeCorrection") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        guard let corrected = filter.outputImage?.cropped(to: image.extent) else { return image }
        guard strength < 1.0 else { return corrected }
        // Cross-dissolve: time=0 → original, time=1 → corrected
        if let blend = CIFilter(name: "CIDissolveTransition") {
            blend.setValue(image,     forKey: kCIInputImageKey)
            blend.setValue(corrected, forKey: kCIInputTargetImageKey)
            blend.setValue(strength,  forKey: kCIInputTimeKey)
            return blend.outputImage?.cropped(to: image.extent) ?? corrected
        }
        return corrected
    }

    /// Applies CIDepthBlurEffect to produce a high-quality portrait bokeh.
    /// Falls back to CIMaskedVariableBlur if the filter is unavailable.
    nonisolated func applyPortraitBlur(to image: CIImage, disparityData: AVDepthData, fStop: Float) -> CIImage {
        let disparityMap = CIImage(cvPixelBuffer: disparityData.depthDataMap)

        // Scale the disparity map to match the full photo dimensions
        let scaleX = image.extent.width  / disparityMap.extent.width
        let scaleY = image.extent.height / disparityMap.extent.height
        let scaledDisparity = disparityMap.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Try the high-quality Apple portrait filter first
        if let filter = CIFilter(name: "CIDepthBlurEffect") {
            filter.setValue(image,           forKey: kCIInputImageKey)
            filter.setValue(scaledDisparity, forKey: "inputDisparityImage")
            // inputAperture: higher = more blur (0–22 range).
            // Camera f-stop is inverted: f/1.4 = wide aperture = max blur → high inputAperture.
            // Map: f/1.4 → ~22, f/16 → ~2
            let aperture = Float((1.4 / Double(fStop)) * 22.0)
            filter.setValue(max(0.5, aperture), forKey: "inputAperture")
            // Focus on the center subject (normalized 0–1 coords)
            let cx = image.extent.midX
            let cy = image.extent.midY
            let focusSize: CGFloat = min(image.extent.width, image.extent.height) * 0.3
            let focusRect = CIVector(cgRect: CGRect(
                x: cx - focusSize / 2, y: cy - focusSize / 2,
                width: focusSize, height: focusSize
            ))
            filter.setValue(focusRect, forKey: "inputFocusRect")
            if let out = filter.outputImage {
                return out.cropped(to: image.extent)
            }
        }

        // Fallback: CIMaskedVariableBlur with the disparity as a luma mask
        // Build a normalized mask: bright disparity = far = more blur
        // Clamp near subject (bright foreground in disparity = near in some formats)
        // We'll invert the disparity so background is bright = blurred
        let invertedDisparity: CIImage = {
            guard let f = CIFilter(name: "CIColorInvert") else { return scaledDisparity }
            f.setValue(scaledDisparity, forKey: kCIInputImageKey)
            return f.outputImage ?? scaledDisparity
        }()

        // Luma-to-mask: use only the luminance channel as a grayscale mask
        let mask: CIImage = {
            guard let f = CIFilter(name: "CIMaximumComponent") else { return invertedDisparity }
            f.setValue(invertedDisparity, forKey: kCIInputImageKey)
            return f.outputImage ?? invertedDisparity
        }()

        // Blur radius = max at f/1.4 (40 px), min at f/16 (~3.5 px)
        let maxBlur: Float = 40.0
        let radius = Double(max(1.0, maxBlur * (1.4 / fStop)))

        if let blurFilter = CIFilter(name: "CIMaskedVariableBlur") {
            blurFilter.setValue(image,  forKey: kCIInputImageKey)
            blurFilter.setValue(mask,   forKey: "inputMask")
            blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
            if let out = blurFilter.outputImage {
                return out.cropped(to: image.extent)
            }
        }

        return image
    }

    /// Applies CIDepthBlurEffect (or CIMaskedVariableBlur fallback) directly from a pre-scaled CIImage disparity map.
    /// Which way is up in the image a look is rendering, per thread: the
    /// live preview and photos are still in sensor (portrait) orientation
    /// (landscape shots are rotated later), regrades are already upright (0).
    nonisolated static var lookAngle: Double {
        get { (Thread.current.threadDictionary["camcam.lookAngle"] as? Double) ?? 0 }
        set { Thread.current.threadDictionary["camcam.lookAngle"] = newValue }
    }

    /// Portrait bokeh style: 0 smooth, 1 soap bubble (Trioplan).
    @ObservationIgnored nonisolated(unsafe) static var bokehStyle = UserDefaults.standard.integer(forKey: "cc_bokehStyle")

    /// Trioplan soap-bubble bokeh: background highlights become discs with a
    /// bright rim and a dimmer (still filled) centre — over-corrected
    /// spherical aberration. `far` is white where the scene is far away.
    nonisolated func soapBubbles(_ blurred: CIImage, original: CIImage, far: CIImage, fStop: Float) -> CIImage {
        let e = blurred.extent
        let r = Double(max(e.width, e.height)) * 0.011 * Double(1.4 / max(fStop, 1))
        guard r > 2 else { return blurred }
        let luma = original.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)])
        guard let thr = CIFilter(name: "CIColorThreshold", parameters: [kCIInputImageKey: luma, "inputThreshold": 0.7])?.outputImage
        else { return blurred }
        // Bright points (in their own colour), only in the background.
        let points = original.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: thr])
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: far])
            .cropped(to: e)
        func disc(_ rr: Double) -> CIImage {
            points.clampedToExtent().applyingFilter("CIDiscBlur", parameters: [kCIInputRadiusKey: rr]).cropped(to: e)
        }
        // Rim = big disc − smaller disc (scaled so the centre stays a little lit).
        let outer = disc(r).applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 2.4, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 2.4, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 2.4, w: 0)])
        let inner = disc(r * 0.75).applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 1.9, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1.9, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 1.9, w: 0)])
        let rings = inner.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: outer])
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                         "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        return rings.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: blurred]).cropped(to: e)
    }

    nonisolated func applyPortraitBlurFromCIImage(to image: CIImage, disparityCI: CIImage, fStop: Float, focusRect: CGRect? = nil) -> CIImage {
        if Self.bokehStyle == 1 {
            let far = disparityCI.applyingFilter("CIColorInvert")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2.0])
            return soapBubbles(applySmoothPortraitBlur(image, disparityCI: disparityCI, fStop: fStop, focusRect: focusRect),
                               original: image, far: far, fStop: fStop)
        }
        return applySmoothPortraitBlur(image, disparityCI: disparityCI, fStop: fStop, focusRect: focusRect)
    }

    nonisolated private func applySmoothPortraitBlur(_ image: CIImage, disparityCI: CIImage, fStop: Float, focusRect: CGRect? = nil) -> CIImage {
        if let filter = CIFilter(name: "CIDepthBlurEffect") {
            filter.setValue(image,        forKey: kCIInputImageKey)
            filter.setValue(disparityCI,  forKey: "inputDisparityImage")
            let aperture = Float((1.4 / Double(fStop)) * 22.0)
            filter.setValue(max(0.5, aperture), forKey: "inputAperture")
            let cx = image.extent.midX
            let cy = image.extent.midY
            let focusSize = min(image.extent.width, image.extent.height) * 0.3
            filter.setValue(CIVector(cgRect: focusRect ?? CGRect(x: cx - focusSize/2, y: cy - focusSize/2,
                                                                  width: focusSize, height: focusSize)),
                            forKey: "inputFocusRect")
            if let out = filter.outputImage { return out.cropped(to: image.extent) }
        }
        // Fallback: invert disparity (far = bright = more blur) then CIMaskedVariableBlur
        let mask: CIImage = {
            guard let inv = CIFilter(name: "CIColorInvert") else { return disparityCI }
            inv.setValue(disparityCI, forKey: kCIInputImageKey)
            return inv.outputImage ?? disparityCI
        }()
        let radius = Double(max(1.0, 40.0 * (1.4 / fStop)))
        if let blurFilter = CIFilter(name: "CIMaskedVariableBlur") {
            blurFilter.setValue(image,  forKey: kCIInputImageKey)
            blurFilter.setValue(mask,   forKey: "inputMask")
            blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
            if let out = blurFilter.outputImage { return out.cropped(to: image.extent) }
        }
        return image
    }

    /// Applies a fast live-preview portrait blur to a video frame using the cached depth buffer.
    /// Live preview depth from Depth Anything when the camera streams none
    /// (48MP Portrait on the main lens), refreshed a few times a second.
    @ObservationIgnored nonisolated(unsafe) var latestMonoDisparity: CIImage?
    @ObservationIgnored nonisolated(unsafe) private var monoBusy = false
    @ObservationIgnored nonisolated(unsafe) private var monoAt: Double = 0
    nonisolated private static let monoQueue = DispatchQueue(label: "cam.monodepth", qos: .utility)
    nonisolated func updateLiveMonoDepth(_ frame: CIImage) {
        let t = CACurrentMediaTime()
        guard MonoDepth.available, !monoBusy, t - monoAt > 0.35, !hasShotsInFlight else { return }
        monoBusy = true; monoAt = t
        let s = 640 / max(frame.extent.width, frame.extent.height)
        let small = frame.transformed(by: CGAffineTransform(scaleX: s, y: s))
        Self.monoQueue.async { [self] in
            defer { monoBusy = false }
            guard let cg = gpuPhotoContext.createCGImage(small, from: small.extent),
                  let d = MonoDepth.disparity(of: CIImage(cgImage: cg)),
                  let dcg = gpuPhotoContext.createCGImage(MonoDepth.calibrated(d, to: nil, context: gpuPhotoContext),
                                                          from: d.extent, format: .RGBAh, colorSpace: nil)
            else { return }
            latestMonoDisparity = CIImage(cgImage: dcg)
        }
    }

    nonisolated func applyLivePortraitBlur(to image: CIImage, fStop: Float) -> CIImage {
        let disparityImage: CIImage
        if let depthBuffer = latestDepthPixelBuffer { disparityImage = CIImage(cvPixelBuffer: depthBuffer) }
        else if let mono = latestMonoDisparity { disparityImage = mono }
        else { return image }

        // Scale uniformly using the larger of the two ratios so the depth map
        // always covers the full image. Non-uniform scale would warp the depth
        // geometrically if the image and depth had even slightly different
        // aspect ratios, mis-projecting the subject's depth onto wrong pixels.
        let scaleX = image.extent.width  / disparityImage.extent.width
        let scaleY = image.extent.height / disparityImage.extent.height
        let scale  = max(scaleX, scaleY)
        // Centred: the live preview is a centre crop of the frame, and the
        // depth covers the whole frame.
        let sd = disparityImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledDisparity = sd.transformed(by: CGAffineTransform(translationX: image.extent.midX - sd.extent.midX,
                                                                   y: image.extent.midY - sd.extent.midY))

        // Invert disparity so far = bright = more blur
        let mask: CIImage = {
            guard let f = CIFilter(name: "CIColorInvert") else { return scaledDisparity }
            f.setValue(scaledDisparity, forKey: kCIInputImageKey)
            return f.outputImage ?? scaledDisparity
        }()

        // Blur radius (reduced for real-time performance, but still clearly visible)
        let maxBlur: Float = 20.0
        let radius = Double(max(0.5, maxBlur * (1.4 / fStop)))

        if let blurFilter = CIFilter(name: "CIMaskedVariableBlur") {
            blurFilter.setValue(image,  forKey: kCIInputImageKey)
            blurFilter.setValue(mask,   forKey: "inputMask")
            blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
            if let out = blurFilter.outputImage {
                let blurred = out.cropped(to: image.extent)
                if Self.bokehStyle == 1 {
                    let far = mask.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2.0])
                    return soapBubbles(blurred, original: image, far: far, fStop: fStop)
                }
                return blurred
            }
        }
        return image
    }

    nonisolated func saveRAW(data: Data) {
        DispatchQueue.main.async { self.isCapturing = false }
        processQueue.async { [self] in
            Self.lookAngle = pendingDeviceAngle         // which way is up for orientation-aware looks
            guard photoLibAuthorized else { return }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("dng")
            do {
                try data.write(to: tempURL)
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCreationRequest.forAsset()
                        .addResource(with: .photo, fileURL: tempURL, options: nil)
                }) { [weak self] success, error in
                    try? FileManager.default.removeItem(at: tempURL)
                    if !success {
                        DispatchQueue.main.async {
                            self?.saveErrorMessage = "Couldn't save RAW: \(error?.localizedDescription ?? "unknown error")"
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.saveErrorMessage = "Couldn't write RAW to temp: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Computes how much to additionally crop the captured photo to compensate for
    /// virtual-camera quirks where iOS delivers the constituent's full FOV without
    /// AVCapturePhotoOutput already delivers a JPEG whose field of view matches the
    /// live preview exactly — the zoom is baked in by iOS regardless of quality
    /// setting or maxPhotoDimensions. No manual crop is needed or correct.
    nonisolated func computePhotoZoomCropFactor() -> CGFloat { return 1.0 }

    /// Apply the manual safety-net zoom crop, if needed.
    nonisolated func applyPhotoZoomCrop(_ image: CIImage, upscale: Bool = true) -> CIImage {
        let cropped = zoomCropOnly(image)
        return upscale && pendingFull48 ? Self.upscaleTo48(cropped) : cropped
    }

    /// Max / Natural: a photo smaller than 48MP (a zoom crop, the 12MP
    /// telephoto / ultra-wide, Portrait's depth format) is resampled to 48MP
    /// so every shot comes out the same size, and the film grain is laid down
    /// at the same scale. Lanczos, upright pixels at the origin.
    nonisolated static func upscaleTo48(_ image: CIImage) -> CIImage {
        let e = image.extent
        let px = e.width * e.height
        guard px > 1, px < 47_000_000 else { return image }
        let s = (48_771_072 / px).squareRoot()        // 8064 × 6048
        let up = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
        return up.transformed(by: CGAffineTransform(translationX: -up.extent.minX, y: -up.extent.minY))
            .cropped(to: CGRect(x: 0, y: 0, width: (e.width * s).rounded(.down), height: (e.height * s).rounded(.down)))
    }

    nonisolated private func zoomCropOnly(_ image: CIImage) -> CIImage {
        let factor = pendingZoomCropFactor
        guard factor > 1.05 else { return image }
        let extent = image.extent
        let newW = extent.width / factor
        let newH = extent.height / factor
        let cx = extent.origin.x + (extent.width - newW) / 2.0
        let cy = extent.origin.y + (extent.height - newH) / 2.0
        let cropRect = CGRect(x: cx, y: cy, width: newW, height: newH)
        return image.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cx, y: -cy))
    }

    nonisolated func cropRect(for extent: CGRect) -> CGRect {
        guard let baseRatio = pendingAspectRatio.ratio else { return extent }
        // Mirror the AspectRatioOverlay formula exactly so the saved crop matches
        // what the user sees on screen:
        //   Portrait  → ratio = baseRatio          (e.g. 16:9 wide band across middle)
        //   Landscape → ratio = 1/baseRatio         (narrow in screen coords; after
        //                                            rotation appears wide 16:9)
        // The ciImage here is already EXIF-oriented to display orientation, so its
        // extent aspect directly corresponds to what is visible on screen.
        let ratio = pendingIsLandscape ? (1.0 / baseRatio) : baseRatio
        let w = extent.width
        let h = extent.height
        let sensorRatio = w / h

        if ratio > sensorRatio {
            // Crop top/bottom
            let newH = w / ratio
            let y = (h - newH) / 2.0
            return CGRect(x: extent.origin.x, y: extent.origin.y + y, width: w, height: newH)
        } else {
            // Crop left/right
            let newW = h * ratio
            let x = (w - newW) / 2.0
            return CGRect(x: extent.origin.x + x, y: extent.origin.y, width: newW, height: h)
        }
    }

    /// Crop to the chosen aspect, rotate to the capture-time device angle,
    /// render in Display P3 and encode with the original EXIF (+ GPS).
    nonisolated private func encodeFramed(_ image: CIImage, metadata: [String: Any],
                                          utType: CFString, location: CLLocation?) -> Data? {
        var cropped = image.cropped(to: cropRect(for: image.extent))
        // Rotate image to match device orientation at capture time
        if pendingDeviceAngle == -90 { cropped = cropped.oriented(.right) }       // landscape right → 90° CW
        else if pendingDeviceAngle == 90 { cropped = cropped.oriented(.left) }    // landscape left → 90° CCW
        else if pendingDeviceAngle == 180 { cropped = cropped.oriented(.down) }   // upside down

        let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        // Render straight into an opaque (noneSkipLast) bitmap so the encoder
        // knows there's no alpha: one full-res buffer and no CPU redraw
        // (at 48MP the old render-then-redraw held two ~190MB bitmaps).
        let bounds = cropped.extent.integral
        let w = Int(bounds.width), h = Int(bounds.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: p3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let pixels = ctx.data else { return nil }
        // In horizontal strips: one 48MP render is a single long GPU job that
        // the live preview had to wait behind (a visible hitch ~2 s after
        // each shot); separate strips let preview frames in between.
        #if DEBUG
        let t0 = CACurrentMediaTime()
        #endif
        let strips = h > 3000 ? 8 : 1
        let rowsPer = (h + strips - 1) / strips
        let epoch = Self.backgroundEpoch
        let startedOnGPU = !Self.inBackground
        for pass in 0..<2 {
        // GPU work is cut off when the app leaves the foreground: a render
        // that spanned the switch is redone on the CPU.
        if pass == 1 && !(startedOnGPU && epoch != Self.backgroundEpoch) { break }
        for i in 0..<strips {
            let y0 = i * rowsPer, y1 = min(h, y0 + rowsPer)
            guard y1 > y0 else { break }
            // Bitmap row 0 is the top; Core Image's y runs up from the bottom.
            let stripBounds = CGRect(x: bounds.minX, y: bounds.maxY - CGFloat(y1), width: bounds.width, height: CGFloat(y1 - y0))
            (pass == 1 ? cpuPhotoContext : photoContext).render(cropped, toBitmap: pixels.advanced(by: y0 * w * 4), rowBytes: w * 4, bounds: stripBounds,
                                format: .RGBA8, colorSpace: p3)
        }
        }
        #if DEBUG
        print(String(format: "[perf] %.2f RENDER %dx%d in %.0f ms (%d strips)", CACurrentMediaTime(), w, h, (CACurrentMediaTime() - t0) * 1000, strips))
        #endif
        guard let opaque = ctx.makeImage() else { return nil }

        // Original EXIF, orientation reset (already rotated), real pixel dims.
        var meta = metadata
        meta.removeValue(forKey: kCGImagePropertyOrientation as String)
        if var exif = meta[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = w
            exif[kCGImagePropertyExifPixelYDimension as String] = h
            meta[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = meta[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            meta[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if let location {
            meta[kCGImagePropertyGPSDictionary as String] =
                Dictionary(uniqueKeysWithValues: MetadataTools.gpsDictionary(for: location).map { ($0.key as String, $0.value) })
        }
        if utType == ("public.jpeg" as CFString) { meta[kCGImageDestinationLossyCompressionQuality as String] = 1.0 }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, utType, 1, nil)
                ?? CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, opaque, meta as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Save a processed shot.
    /// - base: the framed but UN-graded image (after depth blur, before the
    ///   look). When given with a non-identity recipe, the shot is saved
    ///   non-destructively: base = original resource, look = Photos edit with
    ///   the recipe attached → revertible and re-gradable in cam cam.
    nonisolated func renderAndSave(ciImage: CIImage, metadata: [String: Any] = [:],
                                   base: CIImage? = nil, recipe: ShotRecipe? = nil, raw: Data? = nil) {
        #if DEBUG
        if PipelineAudit.tag != nil {
            PipelineAudit.log("\(PipelineAudit.tag!) recipe \(recipe?.displayName ?? "none") raw \(raw.map { "\($0.count / 1_000_000)MB" } ?? "no")")
            PipelineAudit.dump(base: base, rendered: ciImage, ctx: photoContext)
            return
        }
        #endif
        let location = LocationTagger.photoLocation()
        let heic = AVFileType.heic.rawValue as CFString
        let original: Data
        var rendered: Data? = nil
        var savedRecipe: ShotRecipe? = nil

        if let base, let recipe, !recipe.isIdentity {
            // Encode one at a time so only one full-res bitmap is alive at once.
            guard let b = encodeFramed(base, metadata: metadata, utType: heic, location: location) else { return }
            original = b
            rendered = encodeFramed(ciImage, metadata: metadata, utType: "public.jpeg" as CFString, location: location)
            savedRecipe = rendered == nil ? nil : recipe
        } else {
            guard let d = encodeFramed(ciImage, metadata: metadata, utType: heic, location: location) else { return }
            original = d
        }

        if FilmRoll.shared.absorb(original: original, rendered: rendered,
                                  recipe: savedRecipe, location: location) { return }

        Task {
            do {
                let result = try await PhotoSaver.save(original: original, rendered: rendered,
                                                       recipe: savedRecipe, location: location, raw: raw)
                if let issue = result.rawIssue {
                    await MainActor.run { [weak self] in self?.saveErrorMessage = issue }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.saveErrorMessage = "Couldn't save photo: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Lens selection, FOV compensation, double exposure

    /// Query the back physical wide directly and record its FOV reference.
    /// Doesn't activate the device — just reads its default active format's FOV.
    /// The physical telephoto's field of view as an intent zoom (1 = the main
    /// lens), e.g. 5 on a 5× telephoto; nil without one.
    nonisolated static let teleIntent: CGFloat? = {
        guard let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back),
              let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return nil }
        let t = tele.activeFormat.videoFieldOfView, w = wide.activeFormat.videoFieldOfView
        guard t > 0, w > 0 else { return nil }
        return CGFloat(tan(Double(w) * .pi / 360) / tan(Double(t) * .pi / 360))
    }()

    nonisolated func recordPhysicalWideFOV() {
        guard let physical = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        let fov = physical.activeFormat.videoFieldOfView
        if fov > 0 {
            self.physicalWideFOV = fov
        }
    }

    /// Compensation factor that scales `targetZoom` on virtual cameras so the
    /// preview + photo FOV matches the equivalent zoom on the physical wide.
    ///
    /// Computed dynamically: the virtual triple's wide constituent typically has
    /// a slightly wider FOV than the standalone physical wide (Apple adds padding
    /// for fusion). compensation = tan(virtual_FOV/2) / tan(physical_FOV/2).
    /// Returns 1.0 when on physical wide (no compensation needed).
    nonisolated var virtualWideFOVCompensation: CGFloat {
        guard let device = currentDevice else { return 1.0 }
        return compensationForVirtualDevice(device)
    }

    /// Compensation factor for a SPECIFIC device (not necessarily currently active).
    /// Lets us pre-compute the right targetZoom for a swap before the swap happens
    /// — critical for the 120mm preset to land high enough on the triple's scale
    /// to actually engage the telephoto constituent (above the 5x switchover).
    nonisolated func compensationForVirtualDevice(_ device: AVCaptureDevice) -> CGFloat {
        let isVirtual = device.deviceType == .builtInTripleCamera
                     || device.deviceType == .builtInDualCamera
                     || device.deviceType == .builtInDualWideCamera
        guard isVirtual else { return 1.0 }
        let virtualFOV = device.activeFormat.videoFieldOfView
        guard virtualFOV > 0, physicalWideFOV > 0 else { return 1.0 }
        let halfV = Double(virtualFOV) * .pi / 360.0
        let halfP = Double(physicalWideFOV) * .pi / 360.0
        let comp = tan(halfV) / tan(halfP)
        return CGFloat(max(1.0, min(1.5, comp)))
    }

    /// Pre-computed compensation for the back triple camera (or fallback virtual).
    /// Used when computing targetZoom for a swap that hasn't happened yet.
    nonisolated var prospectiveVirtualCompensation: CGFloat {
        if let d = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) {
            return compensationForVirtualDevice(d)
        }
        if let d = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
            return compensationForVirtualDevice(d)
        }
        if let d = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) {
            return compensationForVirtualDevice(d)
        }
        return 1.0
    }

    func selectFocalPreset(_ index: Int) {
        guard index >= 0, index < focalPresets.count else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        let preset = focalPresets[index]
        let currentType = currentDevice?.deviceType

        // While recording: don't tear down the session. Just pass intent to setZoom
        // (which compensates internally for the virtual device we're on).
        if isRecording {
            let intentZoom = CGFloat(Double(preset.mm) / 26.0)
            selectedFocalIndex = index
            lastRequestedZoom = intentZoom
            setZoom(intentZoom)
            return
        }

        selectedFocalIndex = index
        // Macro mode requires the ultrawide lens — clear the toggle if user picks anything else
        if macroModeEnabled && preset.deviceType != .builtInUltraWideCamera {
            macroModeEnabled = false
        }

        // Route to virtual triple if either:
        //   • The preset is explicitly virtual (e.g. 120mm telephoto auto-switch), OR
        //   • Unified-zoom mode is on AND the preset isn't ultrawide (which can only
        //     be reached via the physical builtInUltraWideCamera).
        let useVirtual = preset.useVirtualDevice
            || ((oneLensActive || portraitNeedsDepthCamera) && preset.deviceType != .builtInUltraWideCamera)

        // intentZoom = preset's mm in our 26mm-based scale. setZoom takes intent.
        // For swap calls that take a device-specific zoom we apply the prospective
        // virtual compensation (queries the triple device directly) so the 120mm
        // preset lands above the 5x switchover and actually engages the telephoto.
        let intentZoom = CGFloat(Double(preset.mm) / 26.0)
        lastRequestedZoom = intentZoom

        // 120mm: the real telephoto, always. Through the multi-lens camera iOS
        // kept the main lens and cropped 6.9× in dim light (soft 12MP, wrong
        // exposure) — "switching on me". Portrait / One lens still use it.
        if preset.useVirtualDevice, !portraitNeedsDepthCamera, !oneLensActive, Self.teleIntent != nil {
            if currentType == .builtInTelephotoCamera, let device = currentDevice {
                sessionQueue.async { [weak self] in self?.applyZoom(factor: 1, on: device) }
            } else {
                skipNextReconcile = true
                swapInputDevice(to: FocalPreset(mm: preset.mm, deviceType: .builtInTelephotoCamera, zoomFactor: 1), animate: false)
            }
            DispatchQueue.main.async {
                self.currentMM = preset.mm
                self.zoom = Double(preset.mm) / 26.0
            }
            return
        }

        if useVirtual {
            let onVirtual = currentType == .builtInTripleCamera
                         || currentType == .builtInDualCamera
                         || currentType == .builtInDualWideCamera
            if onVirtual {
                setZoom(intentZoom)
            } else {
                // Skip the post-swap reconcile — we already set lastRequestedZoom
                // and the swap itself applies targetZoom. Reconcile would just
                // redundantly call setZoom on the freshly swapped virtual device.
                // The swap takes a DEVICE zoom factor — convert intent → device.
                skipNextReconcile = true
                swapToVirtualDevice(zoom: intentZoom * prospectiveVirtualCompensation, animate: false)
            }
        } else {
            // Physical lens preset — swap to that lens (or just reset zoom if already on it).
            if currentType != preset.deviceType {
                skipNextReconcile = true
                swapInputDevice(to: preset, animate: false)
            } else if let device = currentDevice {
                sessionQueue.async { [weak self] in self?.applyZoom(factor: preset.zoomFactor, on: device) }
            }
        }

        DispatchQueue.main.async {
            self.currentMM = preset.mm
            self.zoom = Double(preset.mm) / 26.0
        }
    }

    func captureDoubleExposureFirst() {
        isCapturing = true
        capturingFirstExposure = true
        pendingQuality = effectiveQualityPrioritization
        // Snapshot zoom-crop factor so the first-exposure frame gets the safety
        // crop (otherwise the first frame has wider FOV than the second on virtual cameras).
        pendingZoomCropFactor = computePhotoZoomCropFactor()
        // Snapshot sim settings for first exposure
        pendingSim = selectedSim
        pendingCustomSim = activeCustomSim
        pendingGrain = grainAmount
        pendingGrainEnabled = grainEnabled
        pendingContextAwareGrain = contextAwareGrainEnabled
        pendingCrosstalk = crosstalkAmount
        pendingCrosstalkEnabled = crosstalkEnabled
        pendingHalation = halationAmount
        pendingHalationEnabled = halationEnabled
        pendingRolloff = rolloffThreshold
        pendingRolloffEnabled = rolloffEnabled
        let flash = flashMode
        sessionQueue.async { [self] in
            let settings: AVCapturePhotoSettings
            if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [
                    AVVideoCodecKey: AVVideoCodecType.hevc
                ])
            } else {
                settings = AVCapturePhotoSettings(format: [
                    AVVideoCodecKey: AVVideoCodecType.jpeg
                ])
            }
            settings.photoQualityPrioritization = pendingQuality
            if pendingQuality == .quality,
               let maxDim = currentDevice?.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                settings.maxPhotoDimensions = maxDim
            }
            if photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    #if DEBUG
    nonisolated func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output !== audioDataOutput else { return }
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String ?? "?"
        print(String(format: "[perf] %.2f DROP %@", CACurrentMediaTime(), reason))
    }
    #endif

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Route audio to writer when recording
        if output === audioDataOutput {
            guard cachedIsRecording,
                  recordingSessionStarted,
                  let audioIn = audioWriterInput,
                  audioIn.isReadyForMoreMediaData
            else { return }
            audioIn.append(sampleBuffer)
            return
        }
        #if DEBUG
        PerfProbe.frame()
        #endif

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Shutter pressed: show this frame (with the look) as the thumbnail
        // right away. iOS takes ~1.5s to deliver a Max-quality 48MP photo; the
        // real one replaces this when it lands.
        if wantsShutterThumb {
            wantsShutterThumb = false
            // Off the camera queue: its GPU readback lands right as the photo
            // capture starts and used to stall the viewfinder ~0.3 s per shot.
            let frame = CIImage(cvPixelBuffer: pixelBuffer)
            DispatchQueue.global(qos: .userInitiated).async { [self] in publishShutterThumb(frame) }
        }

        // Styles: keep a live person mask fresh (~6 Hz, off this queue)
        if cachedSim.styleKind != nil {
            SkinMask.shared.update(pixelBuffer, time: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        }

        // Framing box / suggestions (rear camera)
        FrameAdvisor.shared.process(pixelBuffer,
                                    time: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                                    camera: self)

        // Pose guide: suggests a pose and coaches the subject into it (rear camera)
        PoseGuide.shared.process(pixelBuffer,
                                 time: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                                 camera: self)

        // Smart Take: fires the shutter when everyone in frame is posed
        SmartTake.shared.process(pixelBuffer,
                                 time: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                                 camera: self)

        // Smart auto exposure (throttled internally to ~5 Hz)
        SmartExposure.shared.process(pixelBuffer,
                                     time: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                                     camera: self)

        // Long exposure frame stacking. Cap = ~30fps × duration so long durations
        // (e.g. 30s) don't get silently truncated at 300 frames. Hard ceiling at 1500
        // frames to bound memory.
        // CRITICAL: render each frame to a CGImage so it owns its pixel data.
        // CIImage(cvPixelBuffer:) only references the buffer; if the AVCapture pool
        // reuses the buffer (likely under sustained 30fps), all stored frames mutate.
        if isCollectingFrames {
            let cap = min(1500, max(300, Int(pendingLongExposureDuration * 30) + 30))
            if frameStack.count < cap {
                let raw = CIImage(cvPixelBuffer: pixelBuffer)
                if let cg = ciContext.createCGImage(raw, from: raw.extent) {
                    frameStack.append(CIImage(cgImage: cg))
                }
            }
        }

        // Forward frames to editor preview renderer if active
        if let renderer = editorPreviewRenderer {
            renderer.processFrame(pixelBuffer: pixelBuffer)
        }

        // Forward frames to focus peaking overlay
        if let peaking = peakingView {
            peaking.processFrame(pixelBuffer: pixelBuffer)
        }

        // Live filtered preview — render to Metal view (no CGImage round-trip)
        let sim = cachedSim
        let customSim = cachedActiveCustomSim
        let metal = metalPreviewView

        let zebras = cachedZebras
        guard sim != .none || customSim != nil || zebras else {
            metal?.currentImage = nil
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Video recording — bake film sim into frames, capped at 1080p, throttled to 30fps
        if cachedIsRecording {
            if !recordingSessionStarted {
                let w = Int(ciImage.extent.width)
                let h = Int(ciImage.extent.height)
                setupAssetWriter(width: w, height: h, startTime: pts)
                lastRecordFrameTime = 0
            }
            let ptsSeconds = CMTimeGetSeconds(pts)
            if ptsSeconds - lastRecordFrameTime >= (1.0 / 30.0),
               recordingSessionStarted,
               let adaptor = pixelBufferAdaptor,
               let videoIn = videoWriterInput,
               videoIn.isReadyForMoreMediaData {
                lastRecordFrameTime = ptsSeconds
                let maxLong = 1920.0
                let srcMax = max(ciImage.extent.width, ciImage.extent.height)
                let recScale = min(1.0, maxLong / srcMax)
                var rec = recScale < 1.0
                    ? ciImage.transformed(by: CGAffineTransform(scaleX: recScale, y: recScale))
                    : ciImage
                // Same look as the preview (incl. grain, DigiCam scanlines and
                // Bent glitches — previously video got only the base sim + 4 effects).
                rec = applyLiveLook(rec, grainTextures: false)
                var pb: CVPixelBuffer?
                if let pool = adaptor.pixelBufferPool {
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
                }
                if let pb {
                    ciContext.render(rec, to: pb)
                    adaptor.append(pb, withPresentationTime: pts)
                }
            }
        }

        // Preview: only the part of the frame the screen shows (it's taller
        // than 4:3, so aspect-fill hides the sides), at ~75% of screen
        // resolution. Rendering the look on the whole frame at a fixed half
        // size spent GPU on hidden pixels and, with smaller feeds, upscaled.
        var scaled: CIImage
        if let size = metal?.drawSize, size.width > 0, ciImage.extent.width > 0 {
            let e = ciImage.extent
            let fill = max(size.width / e.width, size.height / e.height)
            let vw = size.width / fill, vh = size.height / fill            // visible part, buffer pixels
            let visible = ciImage.cropped(to: CGRect(x: e.midX - vw / 2, y: e.midY - vh / 2, width: vw, height: vh).integral)
            let k = min(1, fill * 0.75)
            scaled = visible.transformed(by: CGAffineTransform(translationX: -visible.extent.minX, y: -visible.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: k, y: k))
        } else {
            scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        }

        // Same look as the saved photo (same order, same sims skip film grain),
        // shared with video recording so all three match.
        Self.lookAngle = FrameAdvisor.shared.cachedAngle     // live orientation
        var filtered = applyLiveLook(scaled, grainTextures: true)

        // Live portrait depth blur in preview (uses cached depth from AVCaptureDepthDataOutput)
        if pendingPortraitEnabled && latestDepthPixelBuffer == nil { updateLiveMonoDepth(ciImage) }
        if pendingPortraitEnabled && (latestDepthPixelBuffer != nil || latestMonoDisparity != nil) {
            filtered = applyLivePortraitBlur(to: filtered, fStop: pendingPortraitFStop)
        }

        // Filters like blur, bloom, halation, motion-blur expand the CIImage's
        // extent beyond the input. Crop back to the downscaled-input extent so
        // Metal's aspect-fill math (which uses image.extent) renders correctly.
        filtered = filtered.cropped(to: scaled.extent)

        // Zebras measure the sensor image (what will clip), drawn over the look.
        if zebras {
            filtered = ExposureAids.zebras(over: filtered, measuring: scaled)
        }

        if let metal {
            metal.currentImage = filtered
            metal.render(filtered)        // drawn here, off the main thread
            SceneMotion.displayedFrameTime = CMTimeGetSeconds(pts)   // box overlay matches this frame
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    /// The exposure is done: free the shutter now instead of waiting for the
    /// full-res photo to be processed (seconds at 48MP / RAW). The double
    /// exposure's first frame still waits — its preview is needed first.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        guard !capturingFirstExposure, !burstActive else { return }
        DispatchQueue.main.async { self.isCapturing = false }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        // Turn off torch if it was used as flash
        if let device = currentDevice, device.torchMode == .on {
            sessionQueue.async {
                do {
                    try device.lockForConfiguration()
                    device.torchMode = .off
                    device.unlockForConfiguration()
                } catch {}
            }
        }
        if error != nil, let frames = addMultiFrame(photo.resolvedSettings.uniqueID, data: nil) {
            // One frame of a bracket failed: merge what arrived.
            if !frames.isEmpty, let first = frames.first {
                processAndSaveJPEG(imageData: first, frames: frames, shotID: photo.resolvedSettings.uniqueID,
                                   shot: takeShot(id: photo.resolvedSettings.uniqueID)?.apply)
            }
            return
        }
        guard error == nil else {
            dropShot(id: photo.resolvedSettings.uniqueID)
            DispatchQueue.main.async {
                self.isCapturing = false
                self.isBursting = false
            }
            return
        }

        // RAW multi-frame zoom's tone reference photo.
        if storeToneReference(captureID: photo.resolvedSettings.uniqueID, data: error == nil ? photo.fileDataRepresentation() : nil) {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }
        // Multi-frame zoom: collect the burst (processed or RAW frames) first —
        // a RAW frame must not fall through to the plain DNG save below.
        if let frames = addMultiFrame(photo.resolvedSettings.uniqueID, data: photo.fileDataRepresentation()) {
            guard !frames.isEmpty, let first = frames.first else { return }      // still collecting
            processAndSaveJPEG(imageData: first, frames: frames, shotID: photo.resolvedSettings.uniqueID,
                                   shot: takeShot(id: photo.resolvedSettings.uniqueID)?.apply)
            return
        }

        // RAW: with a processed photo coming too (RAW + film), stash it to be
        // saved alongside the graded photo; RAW-only falls back to a bare DNG.
        let pairedRAWID: Int64? = photo.resolvedSettings.rawPhotoDimensions.width > 0
            && photo.resolvedSettings.photoDimensions.width > 0 ? photo.resolvedSettings.uniqueID : nil
        #if DEBUG
        if let tag = PipelineAudit.tag, photo.isRawPhoto {
            let r = photo.resolvedSettings
            PipelineAudit.log("\(tag) delivered RAW \(r.rawPhotoDimensions.width)x\(r.rawPhotoDimensions.height) processed \(r.photoDimensions.width)x\(r.photoDimensions.height)")
            if tag.hasPrefix("probe") { return }
        }
        if let tag = PipelineAudit.tag, tag.hasPrefix("burst") {
            let r = photo.resolvedSettings
            PipelineAudit.log(String(format: "%@ frame %d/%d photo %dx%d raw %dx%d isRaw %d t=%.3f err=%@", tag, photo.sequenceCount, r.expectedPhotoCount,
                                     r.photoDimensions.width, r.photoDimensions.height, r.rawPhotoDimensions.width, r.rawPhotoDimensions.height,
                                     photo.isRawPhoto ? 1 : 0, CACurrentMediaTime(), String(describing: error)))
            if let d = photo.fileDataRepresentation() {
                try? d.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("\(tag)-\(photo.sequenceCount).\(photo.isRawPhoto ? "dng" : "heic")"))
            }
            return
        }
        if let tag = PipelineAudit.tag, tag.hasPrefix("probe") {
            let r = photo.resolvedSettings
            PipelineAudit.log("\(tag) delivered \(r.photoDimensions.width)x\(r.photoDimensions.height)")
            if tag == "probe-q-z1", let d = photo.fileDataRepresentation() {
                try? d.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("test48.heic"))
            }
            return
        }
        #endif
        if photo.isRawPhoto, let natural = takeNatural(photo.resolvedSettings.uniqueID),
           let data = photo.fileDataRepresentation() {
            let shot = takeShot(id: photo.resolvedSettings.uniqueID)
            developNatural(data, keepRAW: natural.keepRAW, shot: shot?.apply)
            return
        }
        if photo.isRawPhoto, let data = photo.fileDataRepresentation() {
            if let id = pairedRAWID, !capturingFirstExposure {
                stashRAW(data, id: id)
            } else if pairedRAWID == nil {
                saveRAW(data: data)
                if burstActive { burstDidCapture() }
            }
            return
        }

        // Guard against the 12MP regression (it has happened twice): a Max
        // shot from the main lens should be ~48MP.
        let dims = photo.resolvedSettings.photoDimensions
        if output.maxPhotoQualityPrioritization == .quality, dims.width > 0,
           ((currentDevice?.videoZoomFactor ?? 1) / virtualWideFOVCompensation) <= 1.4,   // longer zooms crop: smaller is normal
           Int(dims.width) * Int(dims.height) < 20_000_000,
           (currentDevice?.activeFormat.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0) > 40_000_000 {
            print("⚠️ cam cam: photo delivered at \(dims.width)×\(dims.height) although the lens supports 48MP")
        }
        #if DEBUG
        if let tag = PipelineAudit.tag {
            let r = photo.resolvedSettings
            PipelineAudit.log("\(tag) delivered photo \(r.photoDimensions.width)x\(r.photoDimensions.height) raw \(r.rawPhotoDimensions.width)x\(r.rawPhotoDimensions.height) device \(currentDevice?.localizedName ?? "?") zoom \(String(format: "%.2f", currentDevice?.videoZoomFactor ?? 0)) constituent \((currentDevice?.activePrimaryConstituent?.localizedName) ?? "-") format max \(currentDevice?.activeFormat.supportedMaxPhotoDimensions.last.map { "\($0.width)x\($0.height)" } ?? "?") output max \(output.maxPhotoDimensions.width)x\(output.maxPhotoDimensions.height)")
        }
        #endif
        let shot = takeShot(id: photo.resolvedSettings.uniqueID)
        guard let data = photo.fileDataRepresentation() else {
            if shot != nil { shotRendered() }
            DispatchQueue.main.async {
                self.isCapturing = false
                self.isBursting = false
            }
            return
        }

        // Double exposure first shot — apply sim, store CIImage, don't save
        if capturingFirstExposure {
            capturingFirstExposure = false
            if let shot { processQueue.sync { shot.apply() }; shotRendered() }
            if let ciImage = CIImage(data: data) {
                let oriented = ciImage.oriented(forExifOrientation: Int32(ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1))
                // Safety crop for virtual cameras (no-op on physical) so first
                // and second exposures share the same FOV before composite.
                let cropped = applyPhotoZoomCrop(oriented)
                // Apply film sim to first exposure so both shots match
                let processed = applySimAndGrain(to: cropped)
                firstExposureCIImage = processed
                // Generate preview CGImage for overlay
                let preview = photoContext.createCGImage(processed, from: processed.extent)
                DispatchQueue.main.async {
                    self.firstExposurePreview = preview
                    self.isCapturing = false
                }
            } else {
                DispatchQueue.main.async { self.isCapturing = false }
            }
            return
        }

        // For burst mode, process in background and chain next shot immediately.
        // Bounded back-pressure: if processQueue is more than 8 frames behind
        // (memory pressure risk), drop the captured data instead of queueing.
        // The next shot is still chained so the burst keeps firing.
        if burstActive {
            let capturedData = data
            if burstBacklog > 8 {
                // Skip processing this frame — too many in-flight already
                burstDidCapture()
                return
            }
            adjustBurstBacklog(by: 1)
            processQueue.async { [self] in
                Self.lookAngle = pendingDeviceAngle
            Self.lookAngle = pendingDeviceAngle         // which way is up for orientation-aware looks
                defer { self.adjustBurstBacklog(by: -1) }
                guard var ciImage = CIImage(data: capturedData) else { return }
                let metadata = ciImage.properties
                ciImage = ciImage.oriented(forExifOrientation: Int32(ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1))
                ciImage = applyPhotoZoomCrop(ciImage, upscale: false)
                pendingSceneISO = Self.captureISO(metadata)      // context-aware grain
                let recipe = pendingRecipe()
                let processed = applySimAndGrain(to: ciImage)
                renderAndSave(ciImage: processed, metadata: metadata, base: ciImage, recipe: recipe)
            }
            burstDidCapture()
            return
        }

        // Portrait mode: apply high-quality depth blur using the most recent live depth frame.
        // (Depth is delivered via AVCaptureDepthDataOutput, not embedded in AVCapturePhoto
        //  when a separate depth output is in the session.)
        if shot?.portrait ?? pendingPortraitEnabled, latestDepthPixelBuffer != nil || MonoDepth.available {
            processAndSavePortraitFromBuffer(imageData: data, depthBuffer: latestDepthPixelBuffer, rawID: pairedRAWID, shot: shot?.apply)
        } else {
            processAndSaveJPEG(imageData: data, rawID: pairedRAWID, shot: shot?.apply)
        }
    }
}

#if DEBUG
/// Debug-only main-thread hitch probe (UI: dial, box, chrome).
final class MainHitchProbe: NSObject {
    static let shared = MainHitchProbe()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    func start() {
        link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }
    @objc private func tick(_ l: CADisplayLink) {
        if last > 0, l.timestamp - last > 0.05 {
            print(String(format: "[perf] %.2f MAIN %.0f ms", CACurrentMediaTime(), (l.timestamp - last) * 1000))
        }
        last = l.timestamp
    }
}

/// Debug-only preview timing: logs late video frames (camera queue blocked).
nonisolated enum PerfProbe {
    nonisolated(unsafe) static var last: Double = 0
    static func frame() {
        let t = CACurrentMediaTime()
        if last > 0, t - last > 0.05 { print(String(format: "[perf] %.2f GAP %.0f ms", t, (t - last) * 1000)) }
        last = t
    }
}
#endif
