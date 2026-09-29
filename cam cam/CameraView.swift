//
//  CameraView.swift
//  cam cam
//
//  Complete camera implementation: types, CameraManager, and all UI views.

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

// MARK: - Orientation-Aware Icon/Text Rotation BZHNNY
private struct IconRotation: ViewModifier {
    let angle: Double
    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(angle))
    }
}

extension View {
    func iconRotation(_ angle: Double) -> some View {
        modifier(IconRotation(angle: angle))
    }

    @ViewBuilder
    func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Custom Film Simulation Model

struct CustomSimulation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "My Film"

    // Exposure
    var brightness: Float = 0.0       // -0.1 ... 0.1
    var contrast: Float = 1.0         // 0.7 ... 1.5
    var saturation: Float = 1.0       // 0.0 ... 2.0

    // Temperature
    var temperature: Float = 6500     // 3000 ... 10000
    var tint: Float = 0               // -50 ... 50

    // Tone curve
    var shadowLift: Float = 0.0       // 0 ... 0.15
    var midShift: Float = 0.0         // -0.1 ... 0.1
    var highlightRolloff: Float = 0.0 // -0.1 ... 0.0

    // Color channels
    var redMult: Float = 1.0          // 0.7 ... 1.3
    var greenMult: Float = 1.0        // 0.7 ... 1.3
    var blueMult: Float = 1.0         // 0.7 ... 1.3

    // Red bias (adds warmth to shadows)
    var redBias: Float = 0.0          // -0.05 ... 0.05
    var greenBias: Float = 0.0
    var blueBias: Float = 0.0

    /// Optional .cube LUT filename (in Documents/LUTs/). When non-nil, the
    /// pipeline applies the LUT and SKIPS the parameter-based color grading
    /// — the LUT is the entire look. Other effects (grain, vignette, bloom,
    /// halation, etc.) still apply after the LUT.
    /// Backward-compatible: existing simulations decode with nil here.
    var lutFilename: String? = nil

    // Quality: 0 = speed, 1 = balanced, 2 = quality (Deep Fusion)
    var quality: Int = 2

    // Effects
    var vignetteIntensity: Float = 0.0 // 0 ... 2.0
    var fadeAmount: Float = 0.0        // 0 ... 0.15 (lifts black point)
    var bloomIntensity: Float = 0.0    // 0 ... 0.5
    var bloomRadius: Float = 8.0       // 2 ... 20
    var hazeAmount: Float = 0.0        // 0 = clear, 1 = heavy atmospheric haze
    var redEyeStrength: Float = 0.0    // 0 = off, 1 = full correction; blended at capture time
}

// MARK: - Custom Sim Store

@Observable final class CustomSimStore {
    var simulations: [CustomSimulation] = []
    var activeCustomSimID: UUID?

    private let key = "cam_cam_custom_sims"

    init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CustomSimulation].self, from: data) else { return }
        simulations = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(simulations) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func addNew() -> CustomSimulation {
        var sim = CustomSimulation()
        sim.name = "Custom \(simulations.count + 1)"
        simulations.append(sim)
        save()
        return sim
    }

    func update(_ sim: CustomSimulation) {
        if let idx = simulations.firstIndex(where: { $0.id == sim.id }) {
            simulations[idx] = sim
            save()
        }
    }

    func delete(_ sim: CustomSimulation) {
        simulations.removeAll { $0.id == sim.id }
        if activeCustomSimID == sim.id { activeCustomSimID = nil }
        save()
    }

    var activeSim: CustomSimulation? {
        guard let id = activeCustomSimID else { return nil }
        return simulations.first { $0.id == id }
    }
}

// MARK: - Film Simulation Enum

nonisolated enum FilmSimulation: String, CaseIterable, Identifiable, Sendable {
    case none

    // Leicas — modern bodies + B&W + vintage glass + cinematic
    case leica, leicaQ3, leicaMonochrom, leicaClassic, leicaEternal

    // Fujifilm — pro chromes first, then negatives, then consumer
    case fujiProvia, fujiAstia, fujiVelvia, fujiClassicChrome, fujiEterna
    case fujiPro400H, fujiSuperia, fujiColor200
    case fujiReala100, fuji160NS, fujiSensia

    // Kodak color negatives — pro to consumer
    case kodakPortra, kodakEktar, kodakGold, kodakUltramax, kodakColorplus
    case kodakPortra160, kodakProImage100, kodakAdvantix

    // Cinema / Cinestill — daylight then tungsten
    case cinestill50D, cinestill400D, cinestill800T, kodakVision3
    case kodak2383, fujiEternaVivid

    // Slide film
    case kodachrome64, ektachrome100
    case fujiProvia400X, agfaRSX

    // Instant
    case polaroid600, polaroidSX70, polaroidSpectra, polaroidiType
    case fujiInstax

    // Black & white
    case fujiAcros, kodakTriX, kodakTmax400, ilfordHP5
    case ilfordDelta3200, ilfordDelta100, ilfordXP2
    case kodakDoubleX, kodakP3200

    // Stylized / effects looks
    case agfaVista, lomography, lomochromePurple
    case kodakAerochrome
    case lomochromeMetropolis, lomochromeTurquoise
    case nightShot, urbanJade, goldenHaze, digiCam

    // Experimental / darkroom / alternative process
    case crossProcess, bleachBypass, expiredFilm
    case cyanotype, daguerreotype, duotone
    case retroChrome, neonNoir, circuitBent, circuitBentHeavy

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:           return "None"
        case .leica:          return "Leica M"
        case .fujiProvia:     return "Provia"
        case .fujiVelvia:     return "Velvia"
        case .fujiColor200:   return "Fuji 200"
        case .fujiPro400H:    return "Pro 400H"
        case .fujiSuperia:    return "Superia"
        case .kodakPortra:    return "Portra"
        case .kodakGold:      return "Gold"
        case .kodakUltramax:  return "Ultramax"
        case .kodakColorplus: return "ColorPlus"
        case .kodakEktar:     return "Ektar"
        case .cinestill800T:  return "800T"
        case .kodakVision3:   return "Vision3"
        case .cinestill50D:   return "50D"
        case .agfaVista:      return "Vista"
        case .ilfordHP5:      return "HP5"
        case .kodakTriX:      return "Tri-X"
        case .fujiAcros:      return "Acros"
        case .lomography:     return "Lomo"
        case .digiCam:        return "DigiCam"
        case .nightShot:      return "Night"
        case .urbanJade:      return "Urban Jade"
        case .kodachrome64:   return "Kodachrome"
        case .ektachrome100:  return "Ektachrome"
        case .polaroid600:    return "Polaroid"
        case .goldenHaze:     return "Golden Haze"
        case .fujiEterna:           return "Eterna"
        case .fujiClassicChrome:    return "Classic Chrome"
        case .fujiAstia:            return "Astia"
        case .fujiReala100:         return "Reala 100"
        case .fuji160NS:            return "160NS"
        case .fujiSensia:           return "Sensia"
        case .cinestill400D:        return "400D"
        case .kodakAerochrome:      return "Aerochrome"
        case .kodakPortra160:       return "Portra 160"
        case .kodakProImage100:     return "Pro Image"
        case .kodakAdvantix:        return "Advantix"
        case .kodak2383:            return "Kodak 2383"
        case .fujiEternaVivid:      return "Eterna Vivid"
        case .fujiProvia400X:       return "Provia 400X"
        case .agfaRSX:              return "Agfa RSX"
        case .fujiInstax:           return "Instax"
        case .ilfordDelta3200:      return "Delta 3200"
        case .ilfordDelta100:       return "Delta 100"
        case .ilfordXP2:            return "XP2 Super"
        case .kodakDoubleX:         return "Double-X"
        case .kodakP3200:           return "P3200"
        case .lomochromeMetropolis: return "Metropolis"
        case .lomochromeTurquoise:  return "Turquoise"
        case .polaroidSX70:         return "SX-70"
        case .polaroidSpectra:      return "Spectra"
        case .polaroidiType:        return "i-Type"
        case .lomochromePurple:     return "Lomo Purple"
        case .crossProcess:         return "X-Process"
        case .bleachBypass:         return "Silver Ret."
        case .expiredFilm:          return "Expired"
        case .cyanotype:            return "Cyanotype"
        case .daguerreotype:        return "Daguerreotype"
        case .duotone:              return "Duotone"
        case .retroChrome:          return "RetroChrm"
        case .neonNoir:             return "Neon Noir"
        case .circuitBent:          return "Bent"
        case .circuitBentHeavy:     return "Bent++"
        case .kodakTmax400:         return "T-Max 400"
        case .leicaMonochrom:       return "Leica Mono"
        case .leicaQ3:              return "Leica Q3"
        case .leicaClassic:         return "Leica Classic"
        case .leicaEternal:         return "Leica Eternal"
        }
    }
}

// MARK: - Focal Preset

nonisolated struct FocalPreset: Sendable {
    let mm: Int
    let deviceType: AVCaptureDevice.DeviceType
    let zoomFactor: CGFloat
    /// If true, route through the virtual triple camera so iOS handles
    /// lens switching (used for the 120mm tele where close-subject fallback matters).
    var useVirtualDevice: Bool = false
}

nonisolated let focalPresets: [FocalPreset] = [
    FocalPreset(mm: 13,  deviceType: .builtInUltraWideCamera, zoomFactor: 1.0),
    FocalPreset(mm: 28,  deviceType: .builtInWideAngleCamera, zoomFactor: 1.0),
    FocalPreset(mm: 35,  deviceType: .builtInWideAngleCamera, zoomFactor: 1.3),
    FocalPreset(mm: 50,  deviceType: .builtInWideAngleCamera, zoomFactor: 1.92),
    FocalPreset(mm: 70,  deviceType: .builtInWideAngleCamera, zoomFactor: 2.7),
    FocalPreset(mm: 120, deviceType: .builtInWideAngleCamera, zoomFactor: 4.615, useVirtualDevice: true),
]

// MARK: - Aspect Ratio

nonisolated enum AspectRatio: String, CaseIterable, Identifiable, Sendable {
    case full, square, widescreen, cinematic, portrait
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full:       return "4:3"
        case .square:     return "1:1"
        case .widescreen: return "16:9"
        case .cinematic:  return "2.39:1"
        case .portrait:   return "3:4"
        }
    }
    var ratio: CGFloat? {
        switch self {
        case .full:       return nil
        case .square:     return 1.0
        case .widescreen: return 16.0 / 9.0
        case .cinematic:  return 2.39
        case .portrait:   return 3.0 / 4.0
        }
    }
}

// MARK: - Long Exposure Mode

nonisolated enum LongExposureMode: String, CaseIterable, Identifiable, Sendable {
    case frameStack, nativeExposure
    var id: String { rawValue }
    var label: String {
        switch self {
        case .frameStack:     return "Frame Stack"
        case .nativeExposure: return "Native"
        }
    }
}

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
    var flashMode: AVCaptureDevice.FlashMode = .off
    var flashStrength: Float = 1.0 {
        didSet { UserDefaults.standard.set(flashStrength, forKey: "cc_flashStrength") }
    }
    var focusLocked: Bool = false
    var isFocusing: Bool = false          // true while camera is hunting for focus
    var faceDetected: Bool = false        // true when ≥1 face is in frame
    var manualFocusEnabled: Bool = false
    var manualFocusValue: Float = 0.5 {
        didSet { cachedManualFocusValue = manualFocusValue }
    }
    /// Nonisolated mirror of manualFocusValue, safe for sample-buffer/swap callbacks.
    @ObservationIgnored nonisolated(unsafe) var cachedManualFocusValue: Float = 0.5

    // Portrait mode
    var portraitModeEnabled: Bool = false {
        didSet { applyPortraitModeSession() }
    }
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
        didSet { UserDefaults.standard.set(anamorphicFlareEnabled, forKey: "cc_anamorphicFlare") }
    }
    var lightArtifactsEnabled: Bool = false {
        didSet { UserDefaults.standard.set(lightArtifactsEnabled, forKey: "cc_lightArtifacts") }
    }
    var filmScratchesEnabled: Bool = false {
        didSet { UserDefaults.standard.set(filmScratchesEnabled, forKey: "cc_filmScratches") }
    }
    var filmRandomizationEnabled: Bool = false {
        didSet { UserDefaults.standard.set(filmRandomizationEnabled, forKey: "cc_filmRando") }
    }
    var maskBrushOpacity: Double = 1.0 // 1 = expose more, 0 = erase mask
    var showGrid: Bool = false {
        didSet { UserDefaults.standard.set(showGrid, forKey: "cc_showGrid") }
    }
    var showLevel: Bool = false {
        didSet { UserDefaults.standard.set(showLevel, forKey: "cc_showLevel") }
    }
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
        didSet { UserDefaults.standard.set(unifiedZoomMode, forKey: "cc_unifiedZoom") }
    }
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
    var photoQuality: Int = 2 { // 0 speed, 1 balanced, 2 quality
        didSet { UserDefaults.standard.set(photoQuality, forKey: "cc_photoQuality") }
    }
    @ObservationIgnored nonisolated(unsafe) var activeCustomSim: CustomSimulation?
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
    @ObservationIgnored nonisolated(unsafe) var grainPreviewExtent: CGRect = .zero
    @ObservationIgnored nonisolated(unsafe) var grainPreviewBuilding: Bool = false
    @ObservationIgnored nonisolated(unsafe) var grainPreviewLuma: Float = 0.5
    @ObservationIgnored nonisolated(unsafe) var grainPreviewLumaCounter: Int = 0

    // MARK: nonisolated(unsafe) stored properties
    nonisolated(unsafe) let session = AVCaptureSession()

    /// Stop the AVCaptureSession when the iPhone camera isn't being used —
    /// e.g. while SonyView is presented and the user is shooting via the
    /// Sony body's WiFi. The capture pipeline drains a real amount of
    /// battery (multiple watts), so stopping it during Sony mode is a big
    /// win. AVFoundation requires startRunning/stopRunning off the main
    /// thread to avoid blocking the UI.
    @MainActor
    func pauseForExternalUse() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Resume the AVCaptureSession after SonyView dismisses. Takes ~1 s for
    /// the camera to come back up, which is acceptable since the user is
    /// transitioning back into the phone-camera UI anyway.
    @MainActor
    func resumeFromExternalUse() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning { self.session.startRunning() }
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
    @ObservationIgnored nonisolated(unsafe) var cachedSim: FilmSimulation = .none
    @ObservationIgnored nonisolated(unsafe) var processQueue = DispatchQueue(label: "cam.process", qos: .userInitiated)
    /// In-flight burst processing count — bounded back-pressure to keep memory
    /// in check when capture rate exceeds save rate.
    @ObservationIgnored private let burstBacklogLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _burstBacklog: Int = 0
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
    @ObservationIgnored nonisolated(unsafe) var capturingFirstExposure: Bool = false
    @ObservationIgnored nonisolated(unsafe) private var _burstActive: Bool = false
    @ObservationIgnored private let burstActiveLock = NSLock()
    nonisolated var burstActive: Bool {
        get { burstActiveLock.lock(); defer { burstActiveLock.unlock() }; return _burstActive }
        set { burstActiveLock.lock(); _burstActive = newValue; burstActiveLock.unlock() }
    }
    @ObservationIgnored nonisolated(unsafe) var currentDevice: AVCaptureDevice?
    @ObservationIgnored nonisolated(unsafe) private var isSwappingLens = false
    @ObservationIgnored nonisolated(unsafe) private var lastRequestedZoom: CGFloat = 1.0
    @ObservationIgnored nonisolated(unsafe) private var skipNextReconcile = false
    @ObservationIgnored nonisolated(unsafe) weak var editorPreviewRenderer: FilteredPreviewRenderer?
    @ObservationIgnored nonisolated(unsafe) weak var metalPreviewView: MetalFilteredPreviewView?
    @ObservationIgnored nonisolated(unsafe) weak var peakingView: PeakingUIView?
    @ObservationIgnored nonisolated(unsafe) weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored nonisolated(unsafe) weak var previewUIView: PreviewUIView?

    // MARK: Init

    override nonisolated init() {
        super.init()
        loadSettings()
        // Pre-authorize photo library so saves don't block on first capture
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            self.photoLibAuthorized = (status == .authorized || status == .limited)
        }
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
            return dims.width >= 1920
        }
        let pool = candidates.isEmpty ? device.formats : candidates

        let best = pool.max { a, b in
            let aPhoto = a.supportedMaxPhotoDimensions
                .map { Int($0.width) * Int($0.height) }.max() ?? 0
            let bPhoto = b.supportedMaxPhotoDimensions
                .map { Int($0.width) * Int($0.height) }.max() ?? 0
            if aPhoto != bPhoto { return aPhoto < bPhoto }
            let aVid = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let bVid = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(aVid.width) * Int(aVid.height) < Int(bVid.width) * Int(bVid.height)
        }
        guard let best else { return }
        device.activeFormat = best
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
        let unifiedZoom = UserDefaults.standard.object(forKey: "cc_unifiedZoom") != nil
            ? UserDefaults.standard.bool(forKey: "cc_unifiedZoom")
            : false
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
                device.isSmoothAutoFocusEnabled = true
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
                    device.isSmoothAutoFocusEnabled = true
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
                if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
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
                    device.isSmoothAutoFocusEnabled = true
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

    func tapToFocus(at point: CGPoint) {
        guard let device = currentDevice else { return }
        tapFocusActive = true
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
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let clamped = max(device.minExposureTargetBias,
                                  min(bias, device.maxExposureTargetBias))
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
        let supportsDepth = !device.activeFormat.supportedDepthDataFormats.isEmpty
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
            guard !self.cachedManualFocusEnabled, !self.tapFocusActive else { return }
            self.sessionQueue.async {
                do {
                    try device.lockForConfiguration()
                    // Snap focus at center then hand back to continuous
                    if device.isFocusPointOfInterestSupported {
                        device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                        device.focusMode = .autoFocus
                    }
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                        device.exposureMode = .autoExpose
                    }
                    device.unlockForConfiguration()

                    // Return to continuous after a short snap
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
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
                } catch {}
            }
        }
    }

    /// AVCaptureMetadataOutputObjectsDelegate — steers AF toward the largest detected face.
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        // Don't interfere with manual focus or active tap-to-focus
        guard !cachedManualFocusEnabled, !tapFocusActive else { return }
        guard let device = currentDevice else { return }

        let faces = metadataObjects.compactMap { $0 as? AVMetadataFaceObject }
        let detected = !faces.isEmpty

        DispatchQueue.main.async { [weak self] in self?.faceDetected = detected }

        guard detected else { return }

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
        // If a custom sim is active and has its own quality, use that
        if let customSim = activeCustomSim {
            switch customSim.quality {
            case 0: return .speed
            case 1: return .balanced
            default: return .quality
            }
        }
        switch photoQuality {
        case 0: return .speed
        case 1: return .balanced
        default: return .quality
        }
    }

    // MARK: Capture

    func capturePhoto() {
        isCapturing = true   // didSet pushes Watch state — no need to call pushState again
        pendingSim = selectedSim
        pendingGrain = grainAmount
        pendingAspectRatio = selectedAspectRatio
        pendingIsLandscape = isLandscape
        pendingDeviceAngle = deviceAngle
        pendingGrainEnabled = grainEnabled
        pendingContextAwareGrain = contextAwareGrainEnabled
        pendingISO = isoValue
        pendingCrosstalk = crosstalkAmount
        pendingHalation = halationAmount
        pendingRolloff = rolloffThreshold
        pendingCrosstalkEnabled = crosstalkEnabled
        pendingHalationEnabled = halationEnabled
        pendingRolloffEnabled = rolloffEnabled
        pendingDoubleExposureOpacity = doubleExposureOpacity
        pendingMask = doubleExposureMaskEnabled ? doubleExposureMask : nil
        pendingCustomSim = activeCustomSim
        pendingQuality = effectiveQualityPrioritization
        pendingLongExposureDuration = longExposureDuration
        pendingPushPullEnabled = pushPullEnabled
        pendingPushPullAmount = pushPullAmount
        pendingAnamorphicFlareEnabled = anamorphicFlareEnabled
        pendingLightArtifactsEnabled = lightArtifactsEnabled
        pendingFilmScratchesEnabled = filmScratchesEnabled
        pendingRandomizationEnabled = filmRandomizationEnabled
        pendingRandomSeed = UInt64.random(in: 0..<UInt64.max)
        pendingPortraitEnabled = portraitModeEnabled
        pendingPortraitFStop = portraitFStop
        // Snapshot the on-device zoom factor for the photo pipeline. On virtual
        // cameras (triple/dual) iOS occasionally delivers the constituent's
        // full FOV without applying the zoom — we crop ourselves as a safety net.
        pendingZoomCropFactor = computePhotoZoomCropFactor()

        if isLongExposure {
            switch longExposureMode {
            case .frameStack:
                sessionQueue.async { self.startFrameStackExposure() }
            case .nativeExposure:
                sessionQueue.async { self.startNativeExposure() }
            }
            return
        }

        let flash = flashMode
        let strength = flashStrength
        let useRAW = rawEnabled
        sessionQueue.async { [self] in
            let settings: AVCapturePhotoSettings
            if useRAW, let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
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
            settings.photoQualityPrioritization = pendingQuality
            let dims = currentDevice?.activeFormat.supportedMaxPhotoDimensions
            switch pendingQuality {
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
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

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
            }, completionHandler: { [weak self] success, error in
                if !success {
                    DispatchQueue.main.async {
                        self?.saveErrorMessage = "Couldn't save video: \(error?.localizedDescription ?? "unknown error")"
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

        // Slider drag while on physical telephoto — swap back to virtual.
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

    nonisolated func processAndSaveJPEG(imageData: Data) {
        // Unblock shutter immediately — process and save in background
        DispatchQueue.main.async { self.isCapturing = false }

        processQueue.async { [self] in
            guard var ciImage = CIImage(data: imageData) else { return }

            // Extract original metadata (focal length, lens, GPS, etc.) before processing
            let originalMetadata = ciImage.properties

            // Apply EXIF orientation so the image is upright before processing
            ciImage = ciImage.oriented(forExifOrientation: Int32(ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1))

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
            if redEyeStr > 0 { ciImage = applyRedEyeCorrection(to: ciImage, strength: redEyeStr) }

            let processed = applySimAndGrain(to: ciImage)
            renderAndSave(ciImage: processed, metadata: originalMetadata)
        }
    }

    // MARK: - Portrait Depth Blur

    /// Portrait capture using depth embedded in the AVCapturePhoto (legacy path, kept for reference).
    nonisolated func processAndSavePortrait(imageData: Data, depthData: AVDepthData) {
        DispatchQueue.main.async { self.isCapturing = false }
        processQueue.async { [self] in
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
            let withSim = applySimAndGrain(to: blurred)
            renderAndSave(ciImage: withSim, metadata: originalMetadata)
        }
    }

    /// Portrait capture using the live-streamed depth pixel buffer from AVCaptureDepthDataOutput.
    nonisolated func processAndSavePortraitFromBuffer(imageData: Data, depthBuffer: CVPixelBuffer) {
        DispatchQueue.main.async { self.isCapturing = false }
        // CVPixelBuffer is not Sendable — rebind before the closure captures it
        nonisolated(unsafe) let sendableBuffer = depthBuffer
        processQueue.async { [self] in
            guard var ciImage = CIImage(data: imageData) else { return };
            let originalMetadata = ciImage.properties
            ciImage = ciImage.oriented(forExifOrientation: Int32(ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1))
            let redEyeStr: Float = {
                if pendingSim == .nightShot { return 0.55 }
                if pendingSim == .digiCam   { return 0.22 }
                return pendingCustomSim?.redEyeStrength ?? 0
            }()
            if redEyeStr > 0 { ciImage = applyRedEyeCorrection(to: ciImage, strength: redEyeStr) }
            // Scale the depth map uniformly to full photo resolution. Using max()
            // ensures depth covers the image even on slight aspect mismatch and
            // prevents geometric warping that would mis-project subject depth.
            let depthCI = CIImage(cvPixelBuffer: sendableBuffer)
            let sx = ciImage.extent.width  / depthCI.extent.width
            let sy = ciImage.extent.height / depthCI.extent.height
            let s  = max(sx, sy)
            let scaledDepth = depthCI.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let blurred = applyPortraitBlurFromCIImage(to: ciImage, disparityCI: scaledDepth, fStop: pendingPortraitFStop)
            let withSim = applySimAndGrain(to: blurred)
            renderAndSave(ciImage: withSim, metadata: originalMetadata)
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
    nonisolated func applyPortraitBlurFromCIImage(to image: CIImage, disparityCI: CIImage, fStop: Float) -> CIImage {
        if let filter = CIFilter(name: "CIDepthBlurEffect") {
            filter.setValue(image,        forKey: kCIInputImageKey)
            filter.setValue(disparityCI,  forKey: "inputDisparityImage")
            let aperture = Float((1.4 / Double(fStop)) * 22.0)
            filter.setValue(max(0.5, aperture), forKey: "inputAperture")
            let cx = image.extent.midX
            let cy = image.extent.midY
            let focusSize = min(image.extent.width, image.extent.height) * 0.3
            filter.setValue(CIVector(cgRect: CGRect(x: cx - focusSize/2, y: cy - focusSize/2,
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
    nonisolated func applyLivePortraitBlur(to image: CIImage, fStop: Float) -> CIImage {
        guard let depthBuffer = latestDepthPixelBuffer else { return image }
        let disparityImage = CIImage(cvPixelBuffer: depthBuffer)

        // Scale uniformly using the larger of the two ratios so the depth map
        // always covers the full image. Non-uniform scale would warp the depth
        // geometrically if the image and depth had even slightly different
        // aspect ratios, mis-projecting the subject's depth onto wrong pixels.
        let scaleX = image.extent.width  / disparityImage.extent.width
        let scaleY = image.extent.height / disparityImage.extent.height
        let scale  = max(scaleX, scaleY)
        let scaledDisparity = disparityImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

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
                return out.cropped(to: image.extent)
            }
        }
        return image
    }

    nonisolated func saveRAW(data: Data) {
        DispatchQueue.main.async { self.isCapturing = false }
        processQueue.async { [self] in
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
    nonisolated func applyPhotoZoomCrop(_ image: CIImage) -> CIImage {
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

    nonisolated func renderAndSave(ciImage: CIImage, metadata: [String: Any] = [:]) {
        var cropped = ciImage.cropped(to: cropRect(for: ciImage.extent))

        // Rotate image to match device orientation at capture time
        if pendingDeviceAngle == -90 {
            // Landscape right (home button on right) — rotate 90° CW
            cropped = cropped.oriented(.right)
        } else if pendingDeviceAngle == 90 {
            // Landscape left (home button on left) — rotate 90° CCW
            cropped = cropped.oriented(.left)
        } else if pendingDeviceAngle == 180 {
            // Upside down
            cropped = cropped.oriented(.down)
        }

        let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

        // Render in Display P3 — use RGBx (no alpha) to halve memory and avoid alpha warning
        guard let cgImage = ciContext.createCGImage(cropped, from: cropped.extent, format: .RGBA8, colorSpace: p3) else {
            return
        }

        // Force noneSkipLast alpha info so encoder knows image is opaque
        let w = cgImage.width, h = cgImage.height
        let opaqueImage: CGImage
        if let ctx = CGContext(data: nil, width: w, height: h,
                               bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: p3,
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            opaqueImage = ctx.makeImage() ?? cgImage
        } else {
            opaqueImage = cgImage
        }

        // Write HEIF/JPEG with original EXIF metadata (focal length, lens, GPS, etc.)
        let mutableData = NSMutableData()
        // Prefer HEIF, fall back to JPEG
        let uti = AVFileType.heic.rawValue as CFString
        guard let dest = CGImageDestinationCreateWithData(mutableData, uti, 1, nil)
                ?? CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else {
            return
        }

        // Build metadata: preserve original EXIF but fix orientation to Up (already rotated)
        var meta = metadata
        // Remove orientation since we already applied it
        meta.removeValue(forKey: kCGImagePropertyOrientation as String)
        if var exif = meta[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            // Update pixel dimensions to match cropped output
            exif[kCGImagePropertyExifPixelXDimension as String] = w
            exif[kCGImagePropertyExifPixelYDimension as String] = h
            meta[kCGImagePropertyExifDictionary as String] = exif
        }
        // Set TIFF orientation to normal
        if var tiff = meta[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            meta[kCGImagePropertyTIFFDictionary as String] = tiff
        }

        CGImageDestinationAddImage(dest, opaqueImage, meta as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        let finalData = mutableData as Data

        guard photoLibAuthorized else {
            DispatchQueue.main.async { [weak self] in
                self?.saveErrorMessage = "Photo library access denied"
            }
            return
        }
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: finalData, options: nil)
        }, completionHandler: { [weak self] success, error in
            if !success {
                DispatchQueue.main.async {
                    self?.saveErrorMessage = "Couldn't save photo: \(error?.localizedDescription ?? "unknown error")"
                }
            }
        })
    }

    // MARK: Film Simulation Pipeline

    nonisolated func applySimAndGrain(to input: CIImage) -> CIImage {
        var image: CIImage
        if let customSim = pendingCustomSim {
            image = applyCustomSim(to: input, sim: customSim)
        } else {
            image = applyFilmSim(to: input)
        }

        // Live portrait depth blur — applied BEFORE film sim effects so bokeh looks natural
        if pendingPortraitEnabled {
            image = applyLivePortraitBlur(to: image, fStop: pendingPortraitFStop)
        }

        // Crosstalk
        if pendingCrosstalkEnabled {
            image = applyColorCrosstalk(input: image, amount: pendingCrosstalk)
        }

        // Halation
        if pendingHalationEnabled {
            image = applyHalation(input: image, amount: pendingHalation)
        }

        // Rolloff
        if pendingRolloffEnabled {
            image = applyHighlightRolloff(input: image, threshold: pendingRolloff)
        }

        // Push/Pull processing
        if pendingPushPullEnabled {
            image = applyPushPull(input: image, stops: pendingPushPullAmount)
        }

        // Grain (push adds extra grain)
        // DigiCam routes through addDigitalNoise to keep its CCD character separate from film grain
        // Use switch (not ==) to avoid triggering CustomSimulation's @MainActor Equatable conformance
        let isDigiCam: Bool
        switch pendingCustomSim {
        case .none:  isDigiCam = pendingSim == .digiCam
        case .some:  isDigiCam = false
        }
        // Circuit-bent sims repurpose the grain toggle to mean "glitches" —
        // no film/CCD grain is laid down for them. Detect here so the grain
        // block skips them; the glitch pass below handles the toggle instead.
        let isCircuitBentSim: Bool
        switch pendingCustomSim {
        case .none:  isCircuitBentSim = pendingSim == .circuitBent || pendingSim == .circuitBentHeavy
        case .some:  isCircuitBentSim = false
        }
        // DigiCam and circuit-bent sims handle their own noise/glitches
        // elsewhere (DigiCam noise is baked into its sim case scaled by the
        // grain slider; circuit-bent uses the glitch pass). Skip them here so
        // grain isn't applied on top.
        if pendingGrainEnabled && pendingGrain > 0 && !isCircuitBentSim && !isDigiCam {
            let pushExtra: Float = pendingPushPullEnabled ? max(0, pendingPushPullAmount * 0.08) : 0
            var grainAmt = pendingGrain + pushExtra

            // Context-aware grain: scale amount by inverse of scene luminance
            // Dark scenes → more grain (like underexposed film), bright scenes → less
            if pendingContextAwareGrain {
                let avgFilter = CIFilter.areaAverage()
                avgFilter.inputImage = image
                avgFilter.extent = image.extent
                if let avgImg = avgFilter.outputImage {
                    var bitmap = [UInt8](repeating: 0, count: 4)
                    ciContext.render(avgImg,
                                    toBitmap: &bitmap,
                                    rowBytes: 4,
                                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    format: .RGBA8,
                                    colorSpace: CGColorSpaceCreateDeviceRGB())
                    let luma = (Float(bitmap[0]) * 0.299 + Float(bitmap[1]) * 0.587 + Float(bitmap[2]) * 0.114) / 255.0
                    // Dark (luma≈0) → 1.7x, mid (luma≈0.5) → 1.0x, bright (luma≈1.0) → 0.4x
                    let scale = 1.7 - luma * 1.3
                    grainAmt = min(0.5, grainAmt * scale)
                }
            }

            image = addGrain(input: image, amount: grainAmt)
        } else if pendingPushPullEnabled && pendingPushPullAmount > 0 && !isDigiCam {
            // Even with grain off, push adds a small amount of grain
            image = addGrain(input: image, amount: pendingPushPullAmount * 0.06)
        }

        // DigiCam scanlines. The context-aware button doubles as a "lines"
        // toggle for DigiCam — overlays subtle horizontal interlacing lines
        // like an old camcorder/CCD readout. Only when DigiCam is active and
        // its quality isn't Off.
        if isDigiCam && pendingContextAwareGrain && cachedDigiCamQuality >= 1 {
            image = applyScanlines(input: image)
        }

        // Circuit-bent random glitches. The grain toggle drives these instead
        // of laying down film grain (skipped above). Per-frame random band
        // displacement, channel jumps, scanline dropouts. Context-aware grain
        // additionally randomizes light + color each frame — the "broken
        // sensor that drifts" feel.
        if isCircuitBentSim && pendingGrainEnabled && pendingGrain > 0 {
            let isCircuitHeavy = (pendingSim == .circuitBentHeavy)
            // Grain slider doubles as a "weirdness" dial for bent sims:
            // 0…0.5 → 0…1 intensity scaling the glitch magnitude/frequency.
            let weirdness = min(1.0, pendingGrain / 0.5)
            image = circuitBentGlitch(image,
                                      heavy: isCircuitHeavy,
                                      wild: pendingContextAwareGrain,
                                      intensity: CGFloat(weirdness))
        }

        // Anamorphic flares
        if pendingAnamorphicFlareEnabled {
            image = applyAnamorphicFlare(input: image)
        }

        // Derive per-shot random booleans from seed for the Randomize toggle
        // Using distinct bit-mixed offsets so leak/scratch decisions are independent.
        let randLeakChance  = Double(pendingRandomSeed &* 0x517CC1B727220A95 >> 33) / Double(1 << 31)
        let randScratchChance = Double(pendingRandomSeed &* 0xBF58476D1CE4E5B9 >> 33) / Double(1 << 31)

        // Light artifacts (leaks + edge burns)
        if pendingLightArtifactsEnabled || (pendingRandomizationEnabled && randLeakChance < 0.40) {
            image = applyLightArtifacts(input: image, seed: pendingRandomSeed)
        }

        // Film scratches
        if pendingFilmScratchesEnabled || (pendingRandomizationEnabled && randScratchChance < 0.40) {
            image = applyFilmScratches(input: image, seed: pendingRandomSeed &+ 0x1234567890ABCDEF)
        }

        // Film randomization (color/tone)
        if pendingRandomizationEnabled {
            image = applyFilmRandomization(input: image, seed: pendingRandomSeed)
        }

        // Double exposure compositing
        if let first = firstExposureCIImage {
            image = compositeDoubleExposure(base: first, overlay: image, opacity: Float(pendingDoubleExposureOpacity), mask: pendingMask)
            firstExposureCIImage = nil
            // Clear the mask + preview so the next double-exposure starts fresh.
            // (UI mask binding is cleared on main thread.)
            pendingMask = nil
            DispatchQueue.main.async {
                self.firstExposurePreview = nil
                self.doubleExposureMask = nil
            }
        }

        return image
    }

    /// Stateless version of the film sim pipeline used by the Sony connector.
    /// Applies a sim and grain without touching any of the `pending*` capture state,
    /// so it's safe to call from outside the capture flow (e.g. imported photos).
    @MainActor
    func applySimAndGrainDirect(to input: CIImage,
                                 sim: FilmSimulation,
                                 custom: CustomSimulation?) -> CIImage {
        // LUT short-circuit: if the active custom sim references a .cube
        // file, apply the LUT and skip the parameter-based grading
        // pipeline. The LUT IS the entire look.
        if let custom, let lutFilename = custom.lutFilename {
            return LUTManager.shared.apply(filename: lutFilename, to: input)
        }
        // Snapshot only the properties we need; use defaults for everything else.
        let savedSim          = pendingSim;          pendingSim          = sim
        let savedCustom       = pendingCustomSim;    pendingCustomSim     = custom
        let savedGrain        = pendingGrain;              pendingGrain              = grainAmount
        let savedGrainEnabled = pendingGrainEnabled;       pendingGrainEnabled       = grainEnabled
        let savedContextGrain = pendingContextAwareGrain;  pendingContextAwareGrain  = contextAwareGrainEnabled
        // Disable live-capture-only effects that don't make sense for imported photos
        let savedPortrait     = pendingPortraitEnabled; pendingPortraitEnabled = false
        let savedDouble       = firstExposureCIImage
        firstExposureCIImage  = nil  // prevent double-exposure compositing

        let result = applySimAndGrain(to: input)

        // Restore
        pendingSim            = savedSim
        pendingCustomSim      = savedCustom
        pendingGrain              = savedGrain
        pendingGrainEnabled       = savedGrainEnabled
        pendingContextAwareGrain  = savedContextGrain
        pendingPortraitEnabled    = savedPortrait
        firstExposureCIImage  = savedDouble
        return result
    }

    nonisolated func applyFilmSim(to image: CIImage) -> CIImage {
        switch pendingSim {
        case .none:
            return image

        case .leica:
            // Leica M: microcontrast 3D pop, cool-neutral cast, shadow-cool/highlight-warm split,
            // compressed highlights with deep luminous shadows — rangefinder character
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.90
            cc.contrast = 1.05
            cc.brightness = 0.0
            // Neutral-cool — Leica glass doesn't warm like a smartphone
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6300, y: 0)
            // Shadow-cool / highlight-warm split: pull blue slightly, suppress globally
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.96, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            // Leica tone curve: deep shadows, smooth midtone lift, compressed highlights
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: -0.01, mid: 0.02, highlights: -0.06)
            // Clarity pass for the microcontrast/3D pop Leica glass is known for
            return claritySharpen(input: curved)

        case .fujiProvia:
            // Provia/Standard: Fuji's most neutral stock — accurate color, no exaggeration.
            // It's the reference point; Velvia is "Provia but pushed hard". Should feel clinical.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.0   // neutral — Provia does NOT boost saturation
            cc.contrast = 1.04
            cc.brightness = 0.0
            // Barely neutral-cool: Provia is slightly cooler than daylight, not warm
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6700, y: 0)
            return toneCurve(input: temp.outputImage ?? image, shadows: 0.01, mid: 0.0, highlights: -0.02)

        case .fujiVelvia:
            // Velvia: ultra-vivid saturation, deep contrast, cool cast, electric greens & blues
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.65    // Velvia's signature extreme pop
            cc.contrast = 1.25     // punchy contrast
            cc.brightness = -0.01
            // Slightly cool — Velvia pops blues and greens, not warm
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 6900, y: 0)  // pull toward cool
            // Strong green channel push: foliage pops electric; slight blue lift for sky
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cool.outputImage
            matrix.rVector = CIVector(x: 1.0,  y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.12, z: 0.0,  w: 0)   // electric foliage
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.06, w: 0)   // sky pop
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.0, mid: -0.01, highlights: -0.04)
            return claritySharpen(input: curved)

        case .fujiColor200:
            // Fuji C200: affordable daylight film, distinctly cool-green vs Provia's neutral.
            // Lower contrast than Provia, noticeable green shift in daylight — cheap but characterful.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.04
            cc.contrast = 1.0
            cc.brightness = 0.01
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 7100, y: -6)  // cool + green tint
            // Green channel push to separate from Provia
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cool.outputImage
            matrix.rVector = CIVector(x: 1.0,  y: 0.0,  z: 0.0, w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.05, z: 0.0, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.96, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.03, mid: 0.0, highlights: -0.02)

        case .fujiPro400H:
            // Pro 400H: pastel tones, low contrast, slight green in shadows
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.85
            cc.contrast = 0.95
            cc.brightness = 0.02
            let tint = CIFilter.temperatureAndTint()
            tint.inputImage = cc.outputImage
            tint.neutral = CIVector(x: 6500, y: 0)
            tint.targetNeutral = CIVector(x: 6800, y: -10)
            return toneCurve(input: tint.outputImage ?? image, shadows: 0.05, mid: 0.01, highlights: -0.03)

        case .kodakPortra:
            // Portra 400: wide exposure latitude, natural skin rendering, subdued saturation.
            // The magic is in the orange-red midtone push that makes skin glow — not a blanket warm shift.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.90  // Portra is never punchy — colors stay natural
            cc.contrast = 1.02    // gentle — latitude is the point, not contrast
            cc.brightness = 0.01
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5700, y: 8)  // warm + slight magenta = skin rendering
            // Skin-tone matrix: red-orange push in midtones, suppress blue (removes digital coolness)
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.07, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.02, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.88, w: 0)  // pull blue hard
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.005, z: 0.0, w: 0)  // lifted warm blacks
            // Smooth highlight rolloff: Portra's latitude = no blowout
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.03, mid: 0.01, highlights: -0.05)

        case .kodakGold:
            // Kodak Gold 200: warm, saturated, yellow-shifted
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.2
            cc.contrast = 1.08
            cc.brightness = 0.02
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5500, y: 10)
            return toneCurve(input: warm.outputImage ?? image, shadows: 0.03, mid: 0.01, highlights: -0.01)

        case .kodakUltramax:
            // Ultramax 400: warm highlights, distinctly blue (not green) shadows, punchy
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.25
            cc.contrast = 1.1
            cc.brightness = 0.0
            // Warm shift — highlights lean golden/amber
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5900, y: 0)   // warm highlights
            // Blue push into shadows via bias — the signature Ultramax shadow color
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.0,  y: 0.0, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0, z: 1.06, w: 0)   // blue lift
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.0, y: 0.0, z: 0.03, w: 0)  // blue in the blacks
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.03, mid: 0.0, highlights: -0.03)

        case .kodakColorplus:
            // ColorPlus 200: budget consumer film — flat, slightly warm, nothing special.
            // Deliberately less punchy than Gold: lower contrast, muted sat, slight highlight lift
            // from cheap optics/processing. Should feel like a cheap disposable camera.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.0   // flat — budget film, no pop
            cc.contrast = 0.97    // slightly below neutral
            cc.brightness = 0.01
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5950, y: 3)  // subtle warm, nothing like Gold
            // Slight highlight lift from cheap film stock — whites feel slightly blown
            return toneCurve(input: warm.outputImage ?? image, shadows: 0.03, mid: 0.01, highlights: 0.02)

        case .kodakEktar:
            // Ektar 100: extreme reds, very fine grain, highly saturated, daylight balanced
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.5    // extremely saturated
            cc.contrast = 1.15
            cc.brightness = -0.01
            // Daylight balanced — neutral to slightly cool, not warm
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6400, y: 0)  // basically neutral
            // RED BOOST: Ektar's defining trait — reds are almost aggressive
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.2,  y: 0.0,  z: 0.0,  w: 0)   // extreme red push
            matrix.gVector = CIVector(x: 0.0,  y: 1.04, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.93, w: 0)   // slightly suppress blue
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let sharpened = claritySharpen(input: matrix.outputImage ?? image)
            return toneCurve(input: sharpened, shadows: 0.01, mid: 0.0, highlights: -0.04)

        case .digiCam:
            // DigiCam: early 2000s digital look — crushed shadows, slightly magenta white
            // balance, baked-in CCD noise, and a touch of edge softness (NOT haze).
            // Sharpened via clarity to keep crisp pixel-level detail like an old CCD sensor.
            //
            // Quality slider 0..20 maps to:
            //   q=0  → OFF: pass image through untouched. Lets the user keep
            //          DigiCam "selected" in the strip but bypass it on the fly.
            //   q=5  → heavy noise (~0.32), 4 posterize levels, crushed shadows (cheapest disposable)
            //   q=12 → moderate noise (~0.16), 8 posterize levels (early-2000s point-and-shoot, default)
            //   q=20 → minimal noise (~0.04), 16 posterize levels (mid-2000s prosumer compact)
            if cachedDigiCamQuality < 1 { return image }
            let q = max(5, min(20, cachedDigiCamQuality))
            let qNorm = (q - 5) / 15.0                                // 0 = worst, 1 = best
            let noiseAmt: Float    = 0.32 - 0.28 * qNorm              // 0.32 → 0.04
            let posterLevels: Int  = Int(4 + round(12 * Double(qNorm))) // 4 → 16
            let shadowCrush: Float = 0.06 + 0.04 * (1 - qNorm)        // crush more on low quality

            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.82
            cc.contrast = 1.22
            cc.brightness = 0.0
            let tint = CIFilter.temperatureAndTint()
            tint.inputImage = cc.outputImage
            tint.neutral = CIVector(x: 6500, y: 0)
            tint.targetNeutral = CIVector(x: 7000, y: 12)
            var staged: CIImage = tint.outputImage ?? image
            // Quality-driven posterize — fewer levels = more visible color banding,
            // mimicking older sensors' lower bit depth.
            if let poster = CIFilter(name: "CIColorPosterize") {
                poster.setValue(staged, forKey: kCIInputImageKey)
                poster.setValue(posterLevels, forKey: "inputLevels")
                staged = poster.outputImage ?? staged
            }
            let crushed = toneCurve(input: staged, shadows: shadowCrush, mid: 0.0, highlights: -0.05)
            // Tiny edge softness — old digital sensor lowpass, NOT a hazy blur
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = crushed
            blur.radius = 0.6
            let blurred = blur.outputImage?.cropped(to: image.extent) ?? crushed
            // Re-add micro-contrast so the result still feels crisp, not soft
            let crisped = claritySharpen(input: blurred)
            // CCD noise — quality sets the *character* (noiseAmt), the grain
            // slider acts as the master amount. At grain-min (or grain off)
            // the DigiCam look is clean: posterize + crush + tint, zero CCD
            // speckle. As the grain slider climbs, the quality-shaped noise
            // fades in. This is the SOLE source of DigiCam noise — the grain
            // block below skips DigiCam so it's never applied twice.
            if pendingGrainEnabled && pendingGrain > 0 {
                let mult = min(1.0, pendingGrain / 0.5)   // grain 0…0.5 → 0…1
                return addDigitalNoise(input: crisped, amount: noiseAmt * mult)
            }
            return crisped

        case .nightShot:
            // Night shot: warm point-and-shoot flash look — punchy contrast, warm skin,
            // deep dark background. Think candid party / street flash photography.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.12
            cc.contrast = 1.28
            cc.brightness = -0.03
            // Warm the image to match flash color temp (~5400K)
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5400, y: 7)   // warm amber + tiny magenta
            // Slight shadow crush to separate flash-lit subject from dark ambient background
            return toneCurve(input: warm.outputImage ?? image, shadows: -0.06, mid: 0.01, highlights: 0.04)

        case .urbanJade:
            // Urban Jade: lush saturated greens, warm golden sunlight, teal shadows,
            // punchy reds, rich contrast — subtropical city courtyard look
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.25        // rich color without oversaturating
            cc.contrast = 1.15          // good punch
            cc.brightness = 0.01

            // Slight warm shift — golden sunlight tone
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5800, y: 8)  // warm with slight green tint

            // Color matrix: boost greens, push teal into shadows, keep reds vivid
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.05, y: 0.0,  z: 0.0,  w: 0)  // reds stay punchy
            matrix.gVector = CIVector(x: 0.0,  y: 1.12, z: 0.03, w: 0)  // boost green, teal hint
            matrix.bVector = CIVector(x: 0.0,  y: 0.06, z: 0.92, w: 0)  // blue pulled toward teal
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.0, y: 0.008, z: 0.012, w: 0) // teal shadow bias

            // Tone curve: deep shadows, lifted midtones, smooth highlight rolloff
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.02, mid: 0.03, highlights: -0.04)

            // Subtle vignette to frame the scene
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.4
            vignette.radius = 1.5
            return vignette.outputImage ?? curved

        case .fujiSuperia:
            // Superia 400: ~5900K with green bias — not as warm as before, green-leaning daylight
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.95
            cc.contrast = 1.08
            cc.brightness = 0.01
            // 5900K + green tint: slightly warm but distinctly green-biased
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5900, y: -8)  // mild warm + green
            // Boost green channel, light amber in shadows, pull down blue slightly
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.01, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.06, z: 0.0,  w: 0)  // green push
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.93, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.008, y: 0.006, z: 0.0, w: 0)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.05, mid: 0.01, highlights: -0.02)
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.5
            vignette.radius = 1.3
            return vignette.outputImage ?? curved

        case .cinestill800T:
            // CineStill 800T: strong teal-orange split, orange-red halation around lights (not global warm)
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.2
            cc.contrast = 1.25
            cc.brightness = -0.02
            // Heavy teal shadows / warm orange highlights via color matrix
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.15, y: 0.0,  z: 0.0, w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 0.88, z: 0.08, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.12, z: 1.2,  w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: -0.01, z: 0.03, w: 0)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.04, mid: -0.01, highlights: -0.06)
            // Orange halation: tint source orange-red, bloom it, screen-blend so only bright areas halo
            let orangeSrc = CIFilter.colorMatrix()
            orangeSrc.inputImage = curved
            orangeSrc.rVector = CIVector(x: 1.35, y: 0.05, z: 0.0,  w: 0)
            orangeSrc.gVector = CIVector(x: 0.0,  y: 0.85, z: 0.0,  w: 0)
            orangeSrc.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.35, w: 0)
            orangeSrc.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let orangeTinted = orangeSrc.outputImage?.cropped(to: image.extent) ?? curved
            let bloom = CIFilter.bloom()
            bloom.inputImage = orangeTinted
            bloom.intensity = 0.55
            bloom.radius = 18
            let orangeBloom = bloom.outputImage?.cropped(to: image.extent) ?? orangeTinted
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = orangeBloom
            screen.backgroundImage = curved
            return screen.outputImage?.cropped(to: image.extent) ?? curved

        case .kodakVision3:
            // Vision3 500T: cinema negative tungsten stock — shot in daylight it reads cool-teal.
            // Defining traits: flat/wide latitude, teal-orange grade, NO vignette (cinema, not still film).
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.04
            cc.contrast = 0.88    // intentionally flat — cinema negative latitude
            cc.brightness = 0.02  // lifted slightly, negative stock has no true black
            // Tungsten stock in daylight = blue-cool cast
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 7400, y: 0)
            // Teal-orange split: the classic cinema grade
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cool.outputImage
            matrix.rVector = CIVector(x: 1.04, y: 0.0,  z: 0.0,  w: 0)  // warm highlight reds
            matrix.gVector = CIVector(x: 0.0,  y: 0.92, z: 0.06, w: 0)  // green pulled to teal
            matrix.bVector = CIVector(x: 0.0,  y: 0.08, z: 1.18, w: 0)  // strong teal in shadows
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.005, y: 0.0, z: 0.025, w: 0)  // teal lifted blacks
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.05, mid: -0.01, highlights: -0.04)

        case .agfaVista:
            // Agfa Vista 200: warm-punchy consumer film, known for rich reds/yellows and high saturation.
            // NOT sunset-orange — the previous 4800K was too extreme. Vista reads warm-amber, ~5200-5300K.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.28
            cc.contrast = 1.16
            cc.brightness = 0.01
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5250, y: 10)  // warm-amber, not extreme orange
            // Boost reds, suppress blue — Vista's saturated warm rendering
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.08, y: 0.02, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.02, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.84, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.04, mid: 0.02, highlights: -0.04)
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.5
            vignette.radius = 1.0
            return vignette.outputImage ?? curved

        case .ilfordHP5:
            // Ilford HP5: high contrast B&W, deep crushed blacks, bright silver highlights
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = image
            let cc = CIFilter.colorControls()
            cc.inputImage = mono.outputImage
            cc.contrast = 1.3
            cc.brightness = -0.01
            let curved = toneCurve(input: cc.outputImage ?? image, shadows: 0.02, mid: -0.02, highlights: -0.06)
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.8
            vignette.radius = 1.3
            return vignette.outputImage ?? curved

        case .lomography:
            // Lomography: heavy cross-process, oversaturated, strong green/yellow shift, dark vignette
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.6
            cc.contrast = 1.3
            cc.brightness = 0.0
            // Strong cross-process: greens go electric, blues turn teal, reds go amber
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.15, y: 0.08, z: 0.0, w: 0)
            matrix.gVector = CIVector(x: 0.0, y: 1.2, z: 0.05, w: 0)
            matrix.bVector = CIVector(x: 0.0, y: 0.05, z: 0.75, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.02, y: 0.01, z: -0.02, w: 0)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.06, mid: 0.0, highlights: -0.08)
            // Heavy dark vignette
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 1.8
            vignette.radius = 1.8
            return vignette.outputImage ?? curved

        case .cinestill50D:
            // CineStill 50D: daylight cinema stock — clean, crisp, neutral-cool, low ISO character.
            // Teal-green shadows are the cinema stock signature; more readable than the previous imperceptible biases.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.06
            cc.contrast = 1.06
            cc.brightness = 0.01
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 6900, y: 0)
            // Teal-green in shadows — cinema stock signature, bumped to actually show
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cool.outputImage
            matrix.rVector = CIVector(x: 0.98, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.05, z: 0.03, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.04, z: 1.10, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.0, y: 0.006, z: 0.018, w: 0)  // visible teal in blacks
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.02, mid: 0.0, highlights: -0.03)

        case .kodakTriX:
            // Kodak Tri-X 400: the definitive photojournalism B&W — gritty, high contrast, chunky grain
            let mono = CIFilter.photoEffectNoir()
            mono.inputImage = image
            let cc = CIFilter.colorControls()
            cc.inputImage = mono.outputImage
            cc.contrast = 1.35   // punchy, street-photography contrast
            cc.brightness = -0.02
            cc.saturation = 0.0
            // Slightly warm/sepia tone (Tri-X has a warm silver tone)
            let toned = CIFilter.colorMatrix()
            toned.inputImage = cc.outputImage
            toned.rVector = CIVector(x: 1.0,  y: 0.0, z: 0.0, w: 0)
            toned.gVector = CIVector(x: 0.0,  y: 0.96, z: 0.0, w: 0)
            toned.bVector = CIVector(x: 0.0,  y: 0.0, z: 0.90, w: 0)
            toned.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: toned.outputImage ?? image, shadows: 0.0, mid: -0.02, highlights: -0.05)
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.9
            vignette.radius = 1.4
            return vignette.outputImage ?? curved

        case .fujiAcros:
            // Fuji Acros 100: ultra-fine grain B&W, smooth gradations, deep blacks, luminous highlights
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = image
            let cc = CIFilter.colorControls()
            cc.inputImage = mono.outputImage
            cc.contrast = 1.15   // refined contrast — not as crushed as Tri-X
            cc.brightness = 0.0
            cc.saturation = 0.0
            // Acros has a distinctly cooler/bluer tone than HP5 or Tri-X
            let cooled = CIFilter.colorMatrix()
            cooled.inputImage = cc.outputImage
            cooled.rVector = CIVector(x: 0.96, y: 0.0,  z: 0.0,  w: 0)
            cooled.gVector = CIVector(x: 0.0,  y: 0.97, z: 0.0,  w: 0)
            cooled.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.0,  w: 0)
            cooled.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: cooled.outputImage ?? image, shadows: 0.02, mid: 0.0, highlights: -0.03)
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.5
            vignette.radius = 1.6
            return vignette.outputImage ?? curved

        case .kodachrome64:
            // Kodachrome 64: the most iconic slide film — warm reds, saturated blues, deep greens
            // Distinct look: punchy primaries, slightly elevated blacks, unique color rendering
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.3
            cc.contrast = 1.2
            cc.brightness = 0.0
            // Slightly warm — Kodachrome's famous warm cast
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5800, y: 5)
            // The Kodachrome color matrix: reds push orange, blues go deep, greens stay rich
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.15, y: 0.05, z: 0.0,  w: 0)  // warm red push
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.12, w: 0)  // deep blue
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.0, z: 0.0, w: 0)  // lifted blacks
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.04, mid: 0.0, highlights: -0.04)
            return claritySharpen(input: curved)

        case .ektachrome100:
            // Ektachrome E100: cool, clinical slide film — fine detail, punchy blues, accurate colors
            // Popular for landscapes, aviation, underwater — very different from warm Kodachrome
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.2
            cc.contrast = 1.15
            cc.brightness = 0.0
            // Cool balanced — Ektachrome runs cool, blues and cyans are dominant
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 7200, y: -5)  // notably cool
            // Blue/cyan emphasis — the Ektachrome signature
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cool.outputImage
            matrix.rVector = CIVector(x: 0.97, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.05, z: 0.03, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.03, z: 1.15, w: 0)  // electric blue
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.02, mid: 0.0, highlights: -0.05)
            return claritySharpen(input: curved)

        case .goldenHaze:
            // Golden Haze: dreamy backlit look — lifted blacks, lush greens, warm glow,
            // heavy diffusion bloom and Pro-Mist softness. No true shadows, pure luminance.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.88   // slightly muted — dreaminess, not pop
            cc.contrast = 0.82     // low contrast, nothing is crushed
            cc.brightness = 0.05   // airy, slightly overexposed feel
            // Warm golden-hour cast
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5300, y: 6)
            // Lush green boost + suppress blue for that sunlit foliage look
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.02, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.12, z: 0.0,  w: 0)   // electric foliage
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.82, w: 0)   // suppress blue
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.03, y: 0.025, z: 0.01, w: 0) // milky lifted blacks
            // Lift shadows hard — no true blacks, everything is luminous
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.12, mid: 0.02, highlights: -0.01)
            // Heavy bloom — the backlit glow that defines this look
            let bloom = CIFilter.bloom()
            bloom.inputImage = curved
            bloom.intensity = 0.85
            bloom.radius = 28
            let bloomed = bloom.outputImage?.cropped(to: image.extent) ?? curved
            // Pro-Mist style diffusion — very slight gaussian to soften edges
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = bloomed
            blur.radius = 1.5
            let softened = blur.outputImage?.cropped(to: image.extent) ?? bloomed
            // Wide soft vignette — just enough to frame without darkening
            let vignette = CIFilter.vignette()
            vignette.inputImage = softened
            vignette.intensity = 0.25
            vignette.radius = 2.5
            return vignette.outputImage ?? softened

        case .polaroid600:
            // Polaroid 600: lo-fi instant film — faded, shifted colors, heavy vignette, soft
            // Colors shift toward blue-green, contrast is low, whites are milky
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.75   // muted — Polaroid colors are never punchy
            cc.contrast = 0.85    // low contrast, milky
            cc.brightness = 0.04  // lifted — Polaroid overexposes slightly
            // Cool-green shift characteristic of 600 film
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 7500, y: -12)  // cool + green
            // Fade and shift: push blue-green into everything, lift shadows
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cool.outputImage
            matrix.rVector = CIVector(x: 0.88, y: 0.0,  z: 0.0,  w: 0)   // suppress red
            matrix.gVector = CIVector(x: 0.0,  y: 1.02, z: 0.04, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.05, z: 1.05, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.02, y: 0.02, z: 0.04, w: 0)  // milky lifted blacks
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.08, mid: 0.02, highlights: -0.01)
            // Soft blur — Polaroid optics are never sharp
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = curved
            blur.radius = 0.8
            let softened = blur.outputImage?.cropped(to: image.extent) ?? curved
            // Heavy vignette — characteristic Polaroid frame darkening
            let vignette = CIFilter.vignette()
            vignette.inputImage = softened
            vignette.intensity = 1.4
            vignette.radius = 0.9
            return vignette.outputImage ?? softened

        // MARK: - Pro additions

        case .fujiEterna:
            // Fuji Eterna 250D — cinematic motion-picture stock. Low contrast, muted/desat
            // palette with subtle green-cyan in shadows, soft warm highlights. Grade-friendly.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.78
            cc.contrast = 0.88
            cc.brightness = 0.01
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5800, y: -6)   // cool with slight green
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 0.98, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.02, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.97, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.015, z: 0.005, w: 0)  // shadow lift
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.04, mid: 0.0, highlights: -0.03)

        case .fujiClassicChrome:
            // Fujifilm Classic Chrome — desaturated reds, slight cyan, retro magazine look
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.82
            cc.contrast = 1.05
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6400, y: -8)   // touch of cyan
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 0.92, y: 0.04, z: 0.0,  w: 0)   // pull reds toward orange/desat
            matrix.gVector = CIVector(x: 0.0,  y: 0.96, z: 0.04, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.02, z: 1.0,  w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.02, mid: 0.0, highlights: -0.02)

        case .fujiAstia:
            // Fuji Astia — soft pro portrait. Smooth mids, gentle skin tones, low contrast.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.95
            cc.contrast = 0.95
            cc.brightness = 0.01
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6400, y: 4)   // very slightly warm
            // Skin-friendly matrix: lift R/G slightly, keep B natural
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.04, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.01, y: 1.01, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.99, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.02, mid: 0.01, highlights: -0.02)

        case .cinestill400D:
            // Cinestill 400D — daylight color neg, modern, mild halation, balanced color.
            // Closer to neutral than 800T, less warm than 50D.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.04
            cc.contrast = 1.04
            cc.brightness = 0.005
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5500, y: 4)   // daylight WB
            // Subtle halation — a tiny red-channel bloom around highlights
            let bloom = CIFilter.bloom()
            bloom.inputImage = temp.outputImage
            bloom.intensity = 0.20
            bloom.radius = 8
            let bloomed = bloom.outputImage?.cropped(to: image.extent) ?? (temp.outputImage ?? image)
            return toneCurve(input: bloomed, shadows: 0.01, mid: 0.0, highlights: -0.02)

        case .kodakAerochrome:
            // Kodak Aerochrome — false-color IR slide film. Foliage goes red/pink,
            // skies stay cyan, skin shifts magenta. Very distinctive.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.35
            cc.contrast = 1.10
            cc.brightness = 0.0
            // Channel swap: green → red, red stays, blue stays
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 0.20, y: 1.10, z: 0.0,  w: 0)   // greens become reds
            matrix.gVector = CIVector(x: 0.10, y: 0.30, z: 0.05, w: 0)   // suppress green
            matrix.bVector = CIVector(x: 0.0,  y: 0.05, z: 0.95, w: 0)   // blues mostly preserved
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.02, mid: 0.0, highlights: -0.02)

        case .kodakTmax400:
            // Kodak T-Max 400 — pro B&W, fine grain, clean shadows, moderate contrast.
            // Cooler than Tri-X, smoother than HP5.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.10
            mono.brightness = 0.0
            return toneCurve(input: mono.outputImage ?? image, shadows: -0.02, mid: 0.01, highlights: -0.04)

        case .polaroidSX70:
            // Polaroid SX-70 — earlier instant film. Cooler than 600, more washed,
            // muted yellows/greens, wider tonal compression.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.70
            cc.contrast = 0.78           // very flat
            cc.brightness = 0.04         // milky
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6900, y: -4)   // cool, slight green
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 0.95, y: 0.04, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 0.92, z: 0.06, w: 0)
            matrix.bVector = CIVector(x: 0.04, y: 0.0,  z: 0.98, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.04, y: 0.04, z: 0.04, w: 0)   // milky lifted blacks
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.06, mid: 0.0, highlights: -0.03)
            // Light vignette — softer than 600
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.6
            vignette.radius = 1.4
            return vignette.outputImage ?? curved

        case .lomochromePurple:
            // Lomochrome Purple — purple/teal color shift, greens → purple, blues → teal.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.20
            cc.contrast = 1.05
            cc.brightness = 0.0
            // Hue rotation by ~120° via channel swap; greens become magenta/purple
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 0.85, y: 0.40, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.20, y: 0.50, z: 0.30, w: 0)
            matrix.bVector = CIVector(x: 0.30, y: 0.20, z: 1.05, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.02, mid: 0.0, highlights: -0.03)

        case .leicaMonochrom:
            // Leica M Monochrom — dedicated B&W sensor. Clean, slightly warm-toned blacks,
            // smooth gradient, micro-contrast pop.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.05
            mono.brightness = 0.0
            // Warm-toned B&W: very slight sepia bias
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = mono.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.97, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: -0.01, mid: 0.01, highlights: -0.04)
            return claritySharpen(input: curved)

        case .leicaQ3:
            // Leica Q3 / SL3 modern color profile. Balanced warm midtones, rich greens,
            // natural skin, slightly higher contrast than M.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.02
            cc.contrast = 1.08
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6200, y: 2)   // very slightly warm
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.03, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.04, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.0,  w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: -0.02, mid: 0.01, highlights: -0.03)
            return claritySharpen(input: curved)

        case .leicaClassic:
            // Leica Classic — pre-digital Leitz lens character. Warm cast, golden highlights,
            // softer contrast, slight glow in highlights.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.92
            cc.contrast = 0.95
            cc.brightness = 0.02
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5400, y: 4)   // warm
            let bloom = CIFilter.bloom()
            bloom.inputImage = temp.outputImage
            bloom.intensity = 0.30
            bloom.radius = 12
            let bloomed = bloom.outputImage?.cropped(to: image.extent) ?? (temp.outputImage ?? image)
            return toneCurve(input: bloomed, shadows: 0.04, mid: 0.0, highlights: -0.02)

        case .leicaEternal:
            // Leica Eternal — built-in cinematic profile in newer M11/Q3. Very low contrast,
            // smooth gradient, muted saturation, neutral WB. Designed for grading.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.80
            cc.contrast = 0.82
            cc.brightness = 0.01
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6500, y: 0)   // truly neutral
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 0.99, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.01, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.02, y: 0.02, z: 0.02, w: 0)  // shadow lift for grading
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.05, mid: 0.0, highlights: -0.04)

        // MARK: - Instant (additional)

        case .polaroidSpectra:
            // Polaroid Spectra (1986) — warmer and earthier than 600. Slight yellow-amber
            // cast, creamy lifted blacks, soft optics, strong vignette.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.82
            cc.contrast = 0.88
            cc.brightness = 0.03
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5700, y: 8)   // warm amber
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.05, y: 0.02, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.02, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.88, w: 0)  // blue suppressed → amber
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.03, y: 0.025, z: 0.01, w: 0)  // creamy black lift
            let spectraCurved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.06, mid: 0.01, highlights: -0.02)
            let spectraBlur = CIFilter.gaussianBlur()
            spectraBlur.inputImage = spectraCurved
            spectraBlur.radius = 0.7
            let spectraSoft = spectraBlur.outputImage?.cropped(to: image.extent) ?? spectraCurved
            let spectraVig = CIFilter.vignette()
            spectraVig.inputImage = spectraSoft
            spectraVig.intensity = 1.1
            spectraVig.radius = 1.0
            return spectraVig.outputImage ?? spectraSoft

        case .polaroidiType:
            // Polaroid i-Type / Originals Color — modern instant film. Green-tinted shadows,
            // faded mids, milky blacks, cool-neutral whites.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.78
            cc.contrast = 0.88
            cc.brightness = 0.02
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6800, y: -14)  // cool with green cast
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 0.93, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.07, z: 0.04, w: 0)  // green push
            matrix.bVector = CIVector(x: 0.0,  y: 0.04, z: 0.98, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.02, y: 0.035, z: 0.025, w: 0)  // green-milky lift
            let iTypeCurved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.06, mid: 0.01, highlights: -0.02)
            let iTypeVig = CIFilter.vignette()
            iTypeVig.inputImage = iTypeCurved
            iTypeVig.intensity = 0.8
            iTypeVig.radius = 1.3
            return iTypeVig.outputImage ?? iTypeCurved

        // MARK: - Experimental / Alternative Process

        case .crossProcess:
            // E-6 slide film cross-processed in C-41 chemicals. High contrast, extreme
            // color shifts: shadows cyan, reds punch hard, blues go electric teal.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.50
            cc.contrast = 1.18
            cc.brightness = -0.02
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.20, y: 0.10, z: -0.10, w: 0)
            matrix.gVector = CIVector(x: 0.04, y: 1.05, z: -0.04, w: 0)
            matrix.bVector = CIVector(x: -0.14, y: 0.06, z: 1.12, w: 0)  // blues → electric cyan
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: -0.02, y: -0.01, z: 0.03, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.07, mid: 0.0, highlights: 0.02)

        case .bleachBypass:
            // Silver retention / bleach bypass — skip the bleach step so silver stays in
            // the emulsion alongside the dye. Result: crushed contrast, heavy desaturation,
            // metallic silver sheen in mids. Used in Se7en, Saving Private Ryan.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.30   // almost mono but traces of color survive
            cc.contrast = 1.35
            cc.brightness = -0.02
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.96, w: 0)  // very slightly warm/silver
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.07, mid: 0.0, highlights: -0.03)

        case .expiredFilm:
            // Expired color negative — dye layers degrade unevenly, magenta/cyan fog builds
            // in shadows, contrast collapses, colors go unpredictable. Green channel fades most.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.88
            cc.contrast = 0.80
            cc.brightness = 0.04
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.04, y: 0.0,  z: 0.06, w: 0)  // warm+magenta push
            matrix.gVector = CIVector(x: 0.0,  y: 0.84, z: 0.0,  w: 0)  // green layer degraded
            matrix.bVector = CIVector(x: 0.06, y: 0.0,  z: 1.10, w: 0)  // blue/cyan fog
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.05, y: 0.03, z: 0.07, w: 0)  // heavy shadow fog
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.09, mid: 0.02, highlights: -0.01)

        case .cyanotype:
            // Cyanotype photographic print — prussian blue sensitizer process invented 1842.
            // Deep blue shadows, pale icy highlights, no warm tones at all.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.08
            mono.brightness = 0.0
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = mono.outputImage
            // Map luminance to prussian-blue range: shadows deep cobalt, highlights pale cyan
            matrix.rVector = CIVector(x: 0.78, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 0.88, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.08, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.0, y: 0.02, z: 0.14, w: 0)  // blue base fog
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.02, mid: 0.0, highlights: -0.03)

        case .daguerreotype:
            // Daguerreotype / ambrotype — silver-mercury plate, 1840s. Cold metallic B&W,
            // dense blacks, slightly specular highlights, heavy corner falloff.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.25
            mono.brightness = -0.03
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = mono.outputImage
            matrix.rVector = CIVector(x: 0.96, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 0.97, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.03, y: 0.03, z: 1.05, w: 0)  // cold silver sheen
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let dagCurved = toneCurve(input: matrix.outputImage ?? image, shadows: -0.06, mid: 0.0, highlights: -0.02)
            let dagVig = CIFilter.vignette()
            dagVig.inputImage = dagCurved
            dagVig.intensity = 2.2
            dagVig.radius = 0.65
            return dagVig.outputImage ?? dagCurved

        case .duotone:
            // Duotone — indigo-purple shadows, warm amber/cream highlights.
            // Classic editorial duotone like magazine covers and art prints.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.08
            mono.brightness = 0.0
            // Map: L=0 → indigo (0.14, 0.10, 0.36), L=1 → cream (1.0, 0.92, 0.72)
            // output = matrix * [L, L, L] + bias
            // R = 0.86*L + 0.14  →  rVector.x = 0.86, bias.x = 0.14
            // G = 0.82*L + 0.10  →  gVector.y = 0.82, bias.y = 0.10
            // B = 0.36*L + 0.36  →  bVector.z = 0.36, bias.z = 0.36
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = mono.outputImage
            matrix.rVector = CIVector(x: 0.86, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 0.82, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.36, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.14, y: 0.10, z: 0.36, w: 0)
            return matrix.outputImage ?? image

        case .retroChrome:
            // Retro Chrome — oversaturated slide film a la early 1970s Ektachrome.
            // Punchy primaries, high contrast, vivid reds and teals.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.48
            cc.contrast = 1.14
            cc.brightness = -0.01
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5500, y: 6)  // warm-neutral
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.08, y: 0.0,  z: -0.04, w: 0)  // reds pop
            matrix.gVector = CIVector(x: 0.0,  y: 0.98, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: -0.04, y: 0.0, z: 1.06, w: 0)  // teals push
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.04, mid: 0.01, highlights: -0.03)

        case .neonNoir:
            // Neon Noir — dark cyberpunk city look. Deep shadows, electric magentas and
            // cyan-teals, high contrast, slightly blown artificial light sources.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.42
            cc.contrast = 1.16
            cc.brightness = -0.04
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.12, y: -0.05, z: 0.12, w: 0)
            matrix.gVector = CIVector(x: -0.04, y: 0.88, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.12, y: 0.0,  z: 1.16, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.0, y: 0.0, z: 0.02, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.08, mid: 0.0, highlights: -0.01)

        case .circuitBent:
            // Circuit-Bent — infrared/thermal false-color look. The grain
            // slider drives the speckle amount (0 when grain off → clean
            // gradient; up to full as the slider climbs).
            return circuitBend(image, heavy: false, speckleScale: bentSpeckleScale)

        case .circuitBentHeavy:
            // Circuit-Bent Heavy — same recipe, cranked. Grain slider drives
            // the speckle the same way.
            return circuitBend(image, heavy: true, speckleScale: bentSpeckleScale)

        // MARK: - Fujifilm additions

        case .fujiReala100:
            // Fuji Reala 100 — widely regarded as the most color-accurate neg film ever made.
            // Natural skin tones, cool-neutral WB, low saturation boost, very clean shadow detail.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.95
            cc.contrast = 1.0
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6600, y: 2)  // barely cool, nearly neutral
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.01, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.0,  w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.005, y: 0.005, z: 0.005, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.01, mid: 0.0, highlights: -0.01)

        case .fuji160NS:
            // Fuji 160NS (Natura S) — natural-light professional neg. Extremely soft contrast,
            // gently warm, shadow detail preserved, designed for indoor available light.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.90
            cc.contrast = 0.92
            cc.brightness = 0.02
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5900, y: 4)  // gently warm
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.01, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.98, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.01, z: 0.005, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.03, mid: 0.0, highlights: -0.02)

        case .fujiSensia:
            // Fuji Sensia 100 — consumer slide film. Vivid but smoother than Velvia,
            // accurate WB, slightly warm, punchy reds and greens without the harshness.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.15
            cc.contrast = 1.08
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6000, y: 4)
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.04, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.02, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.0,  w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.01, mid: 0.01, highlights: -0.02)

        // MARK: - Kodak additions

        case .kodakPortra160:
            // Kodak Portra 160 — finer grain and cooler/cleaner than 400. The go-to for
            // bright daylight portrait work. Very neutral WB, exceptional skin latitude.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.94
            cc.contrast = 0.97
            cc.brightness = 0.005
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6700, y: 2)  // slightly cooler than Portra 400
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.0,  y: 0.0,  z: 0.0, w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.01, z: 0.0, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.0, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.008, y: 0.008, z: 0.006, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.015, mid: 0.0, highlights: -0.01)

        case .kodakProImage100:
            // Kodak Pro Image 100 — affordable professional neg, hugely popular in Asia
            // and Latin America. Warm, slightly pushed reds, good greens, slight tropical feel.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.04
            cc.contrast = 1.04
            cc.brightness = 0.01
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5800, y: 6)  // warm with slight green
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.04, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.03, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.96, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.01, z: 0.0, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.01, mid: 0.01, highlights: -0.02)

        case .kodakAdvantix:
            // Kodak Advantix / Nexia — consumer APS compact film. Lo-fi warm look,
            // slightly over-saturated in reds, soft shadow detail, budget point-and-shoot feel.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.08
            cc.contrast = 0.95
            cc.brightness = 0.03
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5500, y: 8)  // warm compact-camera WB
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.08, y: 0.02, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.92, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.015, y: 0.01, z: 0.0, w: 0)
            let advBlur = CIFilter.gaussianBlur()
            advBlur.inputImage = matrix.outputImage
            advBlur.radius = 0.5
            let advSoft = advBlur.outputImage?.cropped(to: image.extent) ?? (matrix.outputImage ?? image)
            return toneCurve(input: advSoft, shadows: 0.02, mid: 0.01, highlights: -0.01)

        // MARK: - Cinema additions

        case .kodak2383:
            // Kodak 2383 print film — the standard theatrical print stock used for projection.
            // Warm golden grade, lifted shadows, smooth S-curve, orange-amber tint in mids.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.06
            cc.contrast = 1.08
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5600, y: 6)  // warm theatrical WB
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.06, y: 0.02, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.90, w: 0)  // blue pulled → amber
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.02, y: 0.015, z: 0.0, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.03, mid: 0.01, highlights: -0.03)

        case .fujiEternaVivid:
            // Fuji Eterna Vivid 250D — the punchier cinema daylight stock. More saturation
            // and contrast than Eterna 250D, still grade-friendly, cool-neutral base.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.98
            cc.contrast = 0.96
            cc.brightness = 0.01
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5700, y: -3)
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.0,  y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.04, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.98, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.012, z: 0.005, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.03, mid: 0.0, highlights: -0.03)

        // MARK: - Slide additions

        case .fujiProvia400X:
            // Fuji Provia 400X — faster slide film, slightly cooler and less saturated
            // than 100F. Fine grain for the speed. Good for mixed-light situations.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.10
            cc.contrast = 1.08
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6700, y: -2)  // slightly cool
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.0,  y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.02, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.01, mid: 0.0, highlights: -0.02)

        case .agfaRSX:
            // Agfa RSX 100 / CT Precisa — European slide film. Warm-neutral, slight magenta
            // bias in shadows, excellent skin, different character from Fuji or Kodak slides.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.06
            cc.contrast = 1.06
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5900, y: 10)  // warm + slight magenta
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.04, y: 0.0,  z: 0.02, w: 0)  // slight magenta
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.0,  w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.01, mid: 0.01, highlights: -0.02)

        // MARK: - Instant additions

        case .fujiInstax:
            // Fuji Instax Mini — the world's most popular instant film. Slightly overexposed
            // feel, warm and cheerful, lifted shadows, soft pastel quality.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.05
            cc.contrast = 0.90
            cc.brightness = 0.06  // characteristic slight overexposure
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5800, y: 4)  // warm
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.03, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.02, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.97, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.02, y: 0.02, z: 0.015, w: 0)  // pastel lift
            let instaxBlur = CIFilter.gaussianBlur()
            instaxBlur.inputImage = matrix.outputImage
            instaxBlur.radius = 0.4
            let instaxSoft = instaxBlur.outputImage?.cropped(to: image.extent) ?? (matrix.outputImage ?? image)
            return toneCurve(input: instaxSoft, shadows: 0.04, mid: 0.01, highlights: -0.01)

        // MARK: - B&W additions

        case .ilfordDelta3200:
            // Ilford Delta 3200 — very high speed, massively grainy, pushed look.
            // High contrast but with lifted shadows from the push processing.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.22
            mono.brightness = -0.01
            return toneCurve(input: mono.outputImage ?? image, shadows: -0.04, mid: 0.02, highlights: -0.06)

        case .ilfordDelta100:
            // Ilford Delta 100 — ultra fine grain, clinical precision. Textbook-clean B&W.
            // Smooth gradients, accurate mid tones, the "correct" B&W film.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.05
            mono.brightness = 0.0
            return toneCurve(input: mono.outputImage ?? image, shadows: -0.01, mid: 0.0, highlights: -0.02)

        case .ilfordXP2:
            // Ilford XP2 Super — C-41 (chromogenic) B&W. The silver grain is replaced
            // with dye clouds → very smooth, slightly warm tone, more like B&W portrait print.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.03
            mono.brightness = 0.0
            // Slight warm tone from the chromogenic dye clouds
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = mono.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.97, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.01, mid: 0.0, highlights: -0.02)

        case .kodakDoubleX:
            // Kodak Double-X 5222 — classic cinema B&W negative. Schindler's List, Raging
            // Bull, Manhattan. High contrast, rich deep blacks, slightly cool silver tone.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.28
            mono.brightness = -0.02
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = mono.outputImage
            matrix.rVector = CIVector(x: 0.97, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 0.98, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.02, y: 0.02, z: 1.02, w: 0)  // cool cinema silver
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.06, mid: 0.0, highlights: -0.03)

        case .kodakP3200:
            // Kodak T-MAX P3200 — pushed high-speed B&W. Very contrasty, gritty,
            // visible grain structure, street/night photography workhorse.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.32
            mono.brightness = -0.02
            return toneCurve(input: mono.outputImage ?? image, shadows: -0.07, mid: 0.01, highlights: -0.05)

        // MARK: - Lomography additions

        case .lomochromeMetropolis:
            // Lomochrome Metropolis — desaturated urban palette. Greens shift toward brown/olive,
            // blues flatten, shadows go grey-green. Gritty city feel.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.62
            cc.contrast = 1.06
            cc.brightness = -0.01
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 0.95, y: 0.08, z: 0.0,  w: 0)   // slight brown pull
            matrix.gVector = CIVector(x: 0.04, y: 0.88, z: 0.04, w: 0)   // greens muted/olive
            matrix.bVector = CIVector(x: 0.0,  y: 0.06, z: 0.92, w: 0)   // blues flatten
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.015, z: 0.01, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.02, mid: 0.0, highlights: -0.02)

        case .lomochromeTurquoise:
            // Lomochrome Turquoise — extreme teal/turquoise color shift. Warm tones become
            // teal, sky goes green, skin turns aqua. Very distinctive and otherworldly.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.25
            cc.contrast = 1.05
            cc.brightness = 0.0
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            // Pull red into teal: reduce R, boost G+B
            matrix.rVector = CIVector(x: 0.25, y: 0.35, z: 0.40, w: 0)   // reds → teal
            matrix.gVector = CIVector(x: 0.10, y: 0.75, z: 0.20, w: 0)   // greens stay with teal shift
            matrix.bVector = CIVector(x: 0.05, y: 0.20, z: 1.05, w: 0)   // blues/teals amplified
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.01, mid: 0.0, highlights: -0.02)
        }
    }

    // MARK: Custom Sim Processing

    nonisolated func applyCustomSim(to image: CIImage, sim: CustomSimulation) -> CIImage {
        // LUT short-circuit: if this sim is backed by a .cube file, apply
        // the LUT and skip parameter-based grading. The LUT IS the look.
        // This branch runs from the live preview's nonisolated callback,
        // which is why LUTManager is non-isolated and thread-safe.
        if let lutFilename = sim.lutFilename {
            return LUTManager.shared.apply(filename: lutFilename, to: image)
        }

        var result = image

        // 1. Brightness / Contrast / Saturation
        let cc = CIFilter.colorControls()
        cc.inputImage = result
        cc.brightness = sim.brightness
        cc.contrast = sim.contrast
        cc.saturation = sim.saturation
        result = cc.outputImage ?? result

        // 2. Temperature & Tint
        let temp = CIFilter.temperatureAndTint()
        temp.inputImage = result
        temp.neutral = CIVector(x: 6500, y: 0)
        temp.targetNeutral = CIVector(x: CGFloat(sim.temperature), y: CGFloat(sim.tint))
        result = temp.outputImage ?? result

        // 3. Color matrix (channel multipliers + bias)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = result
        matrix.rVector = CIVector(x: CGFloat(sim.redMult), y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: CGFloat(sim.greenMult), z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(sim.blueMult), w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: CGFloat(sim.redBias), y: CGFloat(sim.greenBias), z: CGFloat(sim.blueBias), w: 0)
        result = matrix.outputImage ?? result

        // 4. Tone curve (shadow lift, mid shift, highlight rolloff)
        result = toneCurve(input: result, shadows: sim.shadowLift + sim.fadeAmount, mid: sim.midShift, highlights: sim.highlightRolloff)

        // 5. Fade (lift the black point)
        if sim.fadeAmount > 0 {
            let fade = CIFilter.colorMatrix()
            fade.inputImage = result
            fade.rVector = CIVector(x: CGFloat(1.0 - sim.fadeAmount), y: 0, z: 0, w: 0)
            fade.gVector = CIVector(x: 0, y: CGFloat(1.0 - sim.fadeAmount), z: 0, w: 0)
            fade.bVector = CIVector(x: 0, y: 0, z: CGFloat(1.0 - sim.fadeAmount), w: 0)
            fade.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            fade.biasVector = CIVector(x: CGFloat(sim.fadeAmount), y: CGFloat(sim.fadeAmount), z: CGFloat(sim.fadeAmount), w: 0)
            result = fade.outputImage ?? result
        }

        // 6. Bloom / halation
        if sim.bloomIntensity > 0 {
            let bloom = CIFilter.bloom()
            bloom.inputImage = result
            bloom.intensity = sim.bloomIntensity
            bloom.radius = sim.bloomRadius
            result = bloom.outputImage?.cropped(to: image.extent) ?? result
        }

        // 7. Haze — cool-white atmospheric veil cross-dissolved over the image
        if sim.hazeAmount > 0 {
            let mist = CIImage(color: CIColor(red: 0.96, green: 0.97, blue: 1.0))
                .cropped(to: image.extent)
            if let blend = CIFilter(name: "CIDissolveTransition") {
                blend.setValue(result, forKey: kCIInputImageKey)
                blend.setValue(mist,   forKey: kCIInputTargetImageKey)
                blend.setValue(NSNumber(value: sim.hazeAmount * 0.65), forKey: kCIInputTimeKey)
                result = blend.outputImage?.cropped(to: image.extent) ?? result
            }
        }

        // 8. Vignette
        if sim.vignetteIntensity > 0 {
            let vignette = CIFilter.vignette()
            vignette.inputImage = result
            vignette.intensity = sim.vignetteIntensity
            vignette.radius = 1.5
            result = vignette.outputImage ?? result
        }

        return result
    }

    // MARK: Push/Pull Processing

    nonisolated func applyPushPull(input: CIImage, stops: Float) -> CIImage {
        // Clamp to valid range
        let s = max(-2.0, min(3.0, stops))
        guard abs(s) > 0.05 else { return input }

        // Push: crush shadows, blow highlights, increase contrast
        // Pull: open shadows, protect highlights, lower contrast
        let shadowShift  = -s * 0.035   // push darkens shadows, pull lifts them
        let highlightShift = s * 0.04   // push clips highlights, pull brings them down
        let midShift     = s * 0.015

        let curve = CIFilter.toneCurve()
        curve.inputImage = input
        let s0 = CGFloat(max(0, min(1, 0.0 + shadowShift)))
        let s1 = CGFloat(max(0, min(1, 0.25 + shadowShift * 0.5)))
        let s2 = CGFloat(max(0, min(1, 0.5 + midShift)))
        let s3 = CGFloat(max(0, min(1, 0.75 + highlightShift * 0.5)))
        let s4 = CGFloat(max(0, min(1, 1.0 + highlightShift)))
        curve.point0 = CGPoint(x: 0,    y: s0)
        curve.point1 = CGPoint(x: 0.25, y: s1)
        curve.point2 = CGPoint(x: 0.5,  y: s2)
        curve.point3 = CGPoint(x: 0.75, y: s3)
        curve.point4 = CGPoint(x: 1,    y: s4)
        return curve.outputImage ?? input
    }

    // MARK: Anamorphic Flares

    nonisolated func applyAnamorphicFlare(input: CIImage) -> CIImage {
        let extent = input.extent

        // 1. Extract bright highlights via a luminance threshold
        let highlight = CIFilter.colorMatrix()
        highlight.inputImage = input
        // Keep only pixels above ~0.82 luminance by biasing heavily negative then clamping
        highlight.rVector = CIVector(x: 3, y: 0, z: 0, w: 0)
        highlight.gVector = CIVector(x: 0, y: 3, z: 0, w: 0)
        highlight.bVector = CIVector(x: 0, y: 0, z: 3, w: 0)
        highlight.biasVector = CIVector(x: -2.2, y: -2.2, z: -2.2, w: 0)
        let bright = highlight.outputImage?.clamped(to: extent) ?? input

        // 2. Horizontal motion blur — wide streak
        let blur = CIFilter.motionBlur()
        blur.inputImage = bright
        blur.radius = 220
        blur.angle = 0  // horizontal
        let streaked = blur.outputImage?.clamped(to: extent) ?? bright

        // 3. Tint the streak blue/cyan
        let tint = CIFilter.colorMatrix()
        tint.inputImage = streaked
        tint.rVector = CIVector(x: 0.3, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: 0.6, z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: 1.4, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let tinted = tint.outputImage?.clamped(to: extent) ?? streaked

        // 4. Screen blend over original
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = tinted
        screen.backgroundImage = input
        return screen.outputImage?.cropped(to: extent) ?? input
    }

    // MARK: Film Randomization

    nonisolated func applyFilmRandomization(input: CIImage, seed: UInt64) -> CIImage {
        var rng = seed
        func nextFloat(min: Float, max: Float) -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let t = Float(rng >> 33) / Float(UInt32.max)
            return min + t * (max - min)
        }

        var image = input

        // Random temperature shift ±150K
        let tempShift = nextFloat(min: -150, max: 150)
        let temp = CIFilter.temperatureAndTint()
        temp.inputImage = image
        temp.neutral = CIVector(x: 6500, y: 0)
        temp.targetNeutral = CIVector(x: CGFloat(6500 + tempShift), y: CGFloat(nextFloat(min: -4, max: 4)))
        image = temp.outputImage ?? image

        // Random micro-vignette
        let vigStrength = nextFloat(min: 0, max: 0.25)
        let vignette = CIFilter.vignette()
        vignette.inputImage = image
        vignette.intensity = vigStrength
        vignette.radius = nextFloat(min: 1.2, max: 2.0)
        image = vignette.outputImage ?? image

        // Random subtle color bias (film batch variation)
        let rb = nextFloat(min: -0.012, max: 0.012)
        let gb = nextFloat(min: -0.008, max: 0.008)
        let bb = nextFloat(min: -0.012, max: 0.012)
        let bias = CIFilter.colorMatrix()
        bias.inputImage = image
        bias.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        bias.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        bias.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        bias.biasVector = CIVector(x: CGFloat(rb), y: CGFloat(gb), z: CGFloat(bb), w: 0)
        image = bias.outputImage ?? image

        return image
    }

    // MARK: Filter Building Blocks

    nonisolated func toneCurve(input: CIImage, shadows: Float, mid: Float, highlights: Float) -> CIImage {
        let curve = CIFilter.toneCurve()
        curve.inputImage = input
        curve.point0 = CGPoint(x: 0.0, y: max(0.0, min(1.0, 0.0 + CGFloat(shadows))))
        curve.point1 = CGPoint(x: 0.25, y: max(0.0, min(1.0, 0.25 + CGFloat(shadows * 0.5))))
        curve.point2 = CGPoint(x: 0.5, y: max(0.0, min(1.0, 0.5 + CGFloat(mid))))
        curve.point3 = CGPoint(x: 0.75, y: max(0.0, min(1.0, 0.75 + CGFloat(highlights * 0.5))))
        curve.point4 = CGPoint(x: 1.0, y: max(0.0, min(1.0, 1.0 + CGFloat(highlights))))
        return curve.outputImage ?? input
    }

    nonisolated func claritySharpen(input: CIImage) -> CIImage {
        let filter = CIFilter.unsharpMask()
        filter.inputImage = input
        filter.intensity = 0.6
        filter.radius = 1.5
        return filter.outputImage ?? input
    }

    /// Isolate one of R/G/B as its own grayscale-in-channel image. Used by
    /// circuitBend to separate planes before shifting them spatially.
    nonisolated private func isolateChannel(_ image: CIImage, channel: Int) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
        let rOn  = CIVector(x: 1, y: 0, z: 0, w: 0)
        let gOn  = CIVector(x: 0, y: 1, z: 0, w: 0)
        let bOn  = CIVector(x: 0, y: 0, z: 1, w: 0)
        m.rVector = channel == 0 ? rOn : zero
        m.gVector = channel == 1 ? gOn : zero
        m.bVector = channel == 2 ? bOn : zero
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage ?? image
    }

    /// Circuit-bent digicam look. Built from stock CIFilters so it works at
    /// live-preview rate. The signature elements:
    ///   • RGB plane separation (red shifts right, blue shifts left) — gives
    ///     the chromatic-fringe glitch reads as "wrong sensor readout"
    ///   • Posterize to a few levels per channel — fakes a broken DAC's stepped
    ///     output, the source of the banded color smears on real bent cams
    ///   • Saturation/contrast crank + magenta hue shift — pushes the palette
    ///     into the impossible-color zone these mods produce
    ///   • Crushed shadows + highlight clip — matches the under-bias that
    ///     bent sensors usually drift to
    ///   • `heavy: true` cranks all knobs and overlays hard scan lines for
    ///     a more outright-broken read.
    /// Single-pass Metal warp kernel for the ripple glitch. Loaded lazily
    /// from the app's default.metallib (Ripple.ci.metal compiles into it with
    /// the CIKernel flags applied automatically by the `.ci.metal` suffix).
    /// Double-optional: nil = not yet attempted, .some(nil) = attempted &
    /// unavailable (→ caller falls back to the composite ripple, so the effect
    /// still works even if the metallib is somehow missing).
    @ObservationIgnored nonisolated(unsafe) static var _rippleKernel: CIWarpKernel?? = nil
    nonisolated static func rippleKernel() -> CIWarpKernel? {
        if let attempted = _rippleKernel { return attempted }
        var loaded: CIWarpKernel? = nil
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let data = try? Data(contentsOf: url) {
            loaded = try? CIWarpKernel(functionName: "rippleWarp", fromMetalLibraryData: data)
        }
        _rippleKernel = .some(loaded)
        return loaded
    }

    /// Speckle amount for the circuit-bent base look, driven by the grain
    /// slider. 0 when grain is off (clean gradient); ramps to 1 at the top of
    /// the slider. Same dial that drives the glitch "weirdness", so one grain
    /// control governs all the bent chaos.
    nonisolated var bentSpeckleScale: CGFloat {
        guard pendingGrainEnabled else { return 0 }
        return min(1.0, CGFloat(pendingGrain) / 0.5)
    }

    /// Build (and cache) the rainbow gradient LUT used by the circuit-bent
    /// thermal map. A 256×1 horizontal gradient sweeping the full spectrum;
    /// CIColorMap indexes pixel luminance into it. Cached because the
    /// CGContext draw is too expensive to repeat every frame.
    nonisolated func thermalGradient() -> CIImage {
        if let g = cachedThermalGradient { return g }
        let width = 256, height = 1
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CIImage.empty() }

        // INTERLEAVED circuit-bend palette — warm and cool colours alternate
        // so that even if the index concentrates in one region, it spans
        // contrasting hues instead of a single family. No colour dominates.
        // (A monotonic rainbow made whatever sat at mid-luminance take over —
        // magenta, then green; interleaving breaks that.)
        let stops: [(CGFloat, UIColor)] = [
            (0.00, UIColor(red: 0.03, green: 0.0,  blue: 0.08, alpha: 1)), // near-black
            (0.10, UIColor(red: 0.0,  green: 0.35, blue: 1.0,  alpha: 1)), // blue
            (0.20, UIColor(red: 1.0,  green: 0.55, blue: 0.0,  alpha: 1)), // orange
            (0.30, UIColor(red: 0.0,  green: 1.0,  blue: 0.55, alpha: 1)), // green
            (0.40, UIColor(red: 1.0,  green: 0.0,  blue: 0.7,  alpha: 1)), // magenta
            (0.50, UIColor(red: 0.0,  green: 0.85, blue: 1.0,  alpha: 1)), // cyan
            (0.60, UIColor(red: 1.0,  green: 0.85, blue: 0.0,  alpha: 1)), // yellow
            (0.70, UIColor(red: 0.45, green: 0.0,  blue: 1.0,  alpha: 1)), // violet
            (0.80, UIColor(red: 1.0,  green: 0.15, blue: 0.15, alpha: 1)), // red
            (0.90, UIColor(red: 0.1,  green: 0.7,  blue: 1.0,  alpha: 1)), // sky blue
            (1.00, UIColor(red: 1.0,  green: 1.0,  blue: 1.0,  alpha: 1)), // white hot
        ]
        let cgColors = stops.map { $0.1.cgColor } as CFArray
        let locations = stops.map { $0.0 }
        guard let grad = CGGradient(colorsSpace: cs, colors: cgColors, locations: locations) else {
            return CIImage.empty()
        }
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: width, y: 0),
                               options: [])
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        let ci = CIImage(cgImage: cg)
        cachedThermalGradient = ci
        return ci
    }

    /// - Parameter speckleScale: 0…1 grain amount from the slider. 0 = no
    ///   speckle (clean thermal gradient); 1 = full thermal-photo grain.
    nonisolated func circuitBend(_ image: CIImage, heavy: Bool = false, speckleScale: CGFloat = 1.0) -> CIImage {
        let extent = image.extent

        // Circuit-bend look: a CONTROLLED rainbow palette (so no single colour
        // dominates) driven by brightness, but scrambled by a low-frequency
        // CHAOS field so the colour mapping is non-uniform and broken across
        // the frame — not a clean linear sweep. Original luminance is blended
        // back so detail/structure always survives.
        let posterLevels: Int    = heavy ? 8 : 12       // colour bands
        let preContrast: Float   = heavy ? 1.35 : 1.20
        // Two chaos octaves so the frame is ALWAYS richly multi-coloured —
        // big blobs set broad colour regions, fine blobs break them up. This
        // is what stops a uniform scene from bathing in a single flat colour.
        // Higher chaos amplitude spreads the colour INDEX across the whole
        // gradient (instead of piling up at mid-luminance, which made one
        // colour family — magenta — dominate). The index is mostly chaos-
        // driven now, so colour varies by region rather than tracking the
        // scene's (usually mid) brightness.
        let chaosCoarse: CGFloat = heavy ? 1.30 : 1.10  // broad colour regions
        let chaosFine: CGFloat   = heavy ? 0.60 : 0.50  // finer break-up
        let sigmaCoarse: Double  = heavy ? 18 : 26
        let sigmaFine: Double    = heavy ? 5  : 8
        let postSat: Float       = heavy ? 1.45 : 1.25
        let speckleAmp: CGFloat  = (heavy ? 0.10 : 0.06) * max(0, speckleScale)
        let fringeShift: CGFloat = heavy ? 6 : 3

        // ── 1. Grayscale luminance (keep a clean copy for detail) ───────
        let gray = CIFilter.colorControls()
        gray.inputImage = image
        gray.saturation = 0.0
        gray.contrast = preContrast
        gray.brightness = -0.02
        let origLuma = (gray.outputImage ?? image).cropped(to: extent)
        var index = origLuma

        // ── 2. CHAOS: two octaves of blurred-noise offset to the INDEX ──
        // Each octave pushes regions to different gradient positions, so the
        // brightness→colour mapping is non-uniform across the frame and the
        // result is always full of varied colour — never one flat hue. THIS
        // is the look; it does NOT need the context-aware wild animator.
        func addChaosOctave(_ amp: CGFloat, _ sigma: Double, _ seedShift: CGFloat) {
            guard amp > 0, let rnd = CIFilter(name: "CIRandomGenerator"),
                  let raw = rnd.outputImage else { return }
            // seedShift samples a different region of the (infinite) noise so
            // the two octaves don't correlate.
            let blobs = raw.transformed(by: CGAffineTransform(translationX: seedShift, y: seedShift))
                .cropped(to: extent)
                .applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            let mono = CIFilter.colorControls()
            mono.inputImage = blobs
            mono.saturation = 0.0
            let scale = CIFilter.colorMatrix()
            scale.inputImage = mono.outputImage
            scale.rVector = CIVector(x: amp, y: 0, z: 0, w: 0)
            scale.gVector = CIVector(x: 0, y: amp, z: 0, w: 0)
            scale.bVector = CIVector(x: 0, y: 0, z: amp, w: 0)
            scale.biasVector = CIVector(x: -amp / 2, y: -amp / 2, z: -amp / 2, w: 0)
            let add = CIFilter.additionCompositing()
            add.inputImage = scale.outputImage
            add.backgroundImage = index
            index = (add.outputImage ?? index).cropped(to: extent)
        }
        addChaosOctave(chaosCoarse, sigmaCoarse, 0)
        addChaosOctave(chaosFine, sigmaFine, 1024)

        // ── 3. Speckle: fine noise into the index (grain slider) ────────
        if speckleAmp > 0, let rnd = CIFilter(name: "CIRandomGenerator"),
           let raw = rnd.outputImage {
            let mono = CIFilter.colorControls()
            mono.inputImage = raw.cropped(to: extent)
            mono.saturation = 0.0
            let scale = CIFilter.colorMatrix()
            scale.inputImage = mono.outputImage
            scale.rVector = CIVector(x: speckleAmp, y: 0, z: 0, w: 0)
            scale.gVector = CIVector(x: 0, y: speckleAmp, z: 0, w: 0)
            scale.bVector = CIVector(x: 0, y: 0, z: speckleAmp, w: 0)
            scale.biasVector = CIVector(x: -speckleAmp / 2, y: -speckleAmp / 2, z: -speckleAmp / 2, w: 0)
            let add = CIFilter.additionCompositing()
            add.inputImage = scale.outputImage
            add.backgroundImage = index
            index = (add.outputImage ?? index).cropped(to: extent)
        }

        // ── 4. Posterize the index into discrete bands ──────────────────
        if let poster = CIFilter(name: "CIColorPosterize") {
            poster.setValue(index, forKey: kCIInputImageKey)
            poster.setValue(posterLevels, forKey: "inputLevels")
            index = poster.outputImage ?? index
        }

        // ── 5. Index → colour via the balanced rainbow gradient LUT ─────
        var colorRGB = index
        if let map = CIFilter(name: "CIColorMap") {
            map.setValue(index, forKey: kCIInputImageKey)
            map.setValue(thermalGradient(), forKey: "inputGradientImage")
            colorRGB = map.outputImage ?? index
        }

        // ── 6. Restore ORIGINAL luminance for detail (colour blend) ─────
        // CIColorBlendMode = luminosity of backdrop + hue/sat of source.
        let cblend = CIFilter.colorBlendMode()
        cblend.inputImage = colorRGB           // wild colour
        cblend.backgroundImage = origLuma      // real detail/structure
        var result = (cblend.outputImage ?? colorRGB).cropped(to: extent)

        // ── 7. Polish: saturation ───────────────────────────────────────
        let polish = CIFilter.colorControls()
        polish.inputImage = result
        polish.saturation = postSat
        result = (polish.outputImage ?? result).cropped(to: extent)

        // ── D. Subtle channel offset for the glitchy chromatic fringe. ──
        // clampedToExtent() so the shifted channels smear their edge pixels
        // instead of leaving a transparent gap (which flattens to a black
        // line in the saved photo).
        let red  = isolateChannel(result, channel: 0).clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: fringeShift, y: 0))
        let grn  = isolateChannel(result, channel: 1)
        let blue = isolateChannel(result, channel: 2).clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -fringeShift, y: 0))
        let a = CIFilter.additionCompositing(); a.inputImage = red; a.backgroundImage = grn
        let b = CIFilter.additionCompositing(); b.inputImage = a.outputImage ?? grn; b.backgroundImage = blue
        result = (b.outputImage ?? result).cropped(to: extent)

        // ── E. Heavy mode only: hard horizontal scan lines on top ───────
        if heavy {
            let stripes = CIFilter.checkerboardGenerator()
            stripes.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            stripes.color1 = CIColor(red: 0.35, green: 0.35, blue: 0.4, alpha: 1)
            stripes.width = 3
            stripes.center = CGPoint(x: 0, y: 0)
            let stripPattern = (stripes.outputImage ?? CIImage.empty())
                .transformed(by: CGAffineTransform(scaleX: 9999, y: 1))
                .cropped(to: extent)
            let mult = CIFilter.multiplyCompositing()
            mult.inputImage = stripPattern
            mult.backgroundImage = result
            result = (mult.outputImage ?? result).cropped(to: extent)
        }

        return result.cropped(to: extent)
    }

    /// Horizontal interlacing scanlines — the old-camcorder / CCD-readout
    /// look. Static (not random): a fixed-period dark stripe pattern
    /// multiplied over the image. Used by DigiCam when its context-aware
    /// "lines" toggle is on. Deliberately subtle so it reads as a CRT/LCD
    /// artifact, not a glitch.
    nonisolated func applyScanlines(input: CIImage) -> CIImage {
        let extent = input.extent
        guard extent.height > 1 else { return input }
        // 2px-on / 2px-off dark lines — clearly visible interlacing.
        let stripes = CIFilter.checkerboardGenerator()
        stripes.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        stripes.color1 = CIColor(red: 0.6, green: 0.6, blue: 0.66, alpha: 1)
        stripes.width = 2
        stripes.center = CGPoint(x: 0, y: 0)
        let pattern = (stripes.outputImage ?? CIImage.empty())
            .transformed(by: CGAffineTransform(scaleX: 9999, y: 1))   // horizontal-only
            .cropped(to: extent)
        let mult = CIFilter.multiplyCompositing()
        mult.inputImage = pattern
        mult.backgroundImage = input
        return (mult.outputImage ?? input).cropped(to: extent)
    }

    /// Per-frame random glitch overlay for the circuit-bent sims. Called only
    /// when grain is enabled. Each invocation rolls fresh randomness so the
    /// glitches flicker and jump frame-to-frame like a genuinely faulty board.
    ///   • `heavy`: bigger ceilings on displacement, harder dropouts
    ///   • `wild` (context-aware grain on): also randomize hue, exposure and
    ///     color cast each frame — the sensor "drifts" unpredictably
    ///   • `intensity` 0…1: the "weirdness" dial driven by the grain slider.
    ///     Scales band count, shift magnitude, glitch probability and the
    ///     wild-mode swing ranges. Near 0 = barely-there occasional twitch;
    ///     1 = full chaos.
    /// All built from stock CIFilters so it survives at live-preview rate.
    nonisolated func circuitBentGlitch(_ image: CIImage, heavy: Bool, wild: Bool, intensity: CGFloat = 1.0) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let t = max(0.0, min(1.0, intensity))            // clamp the dial
        let tF = Float(t)

        // FLATTEN the incoming image to pixels first. The base circuit-bend
        // sim is already a deep filter graph (two blurs, colour-map, blend);
        // stacking the glitch's many composite passes on top at full capture
        // resolution (48MP) overflowed Core Image and rendered BLACK. Baking
        // the base to a CGImage here gives the glitch a shallow, bounded graph
        // so it renders reliably at any resolution.
        var img: CIImage
        if let cg = ciContext.createCGImage(image, from: extent) {
            img = CIImage(cgImage: cg)
        } else {
            img = image
        }

        // ── 1. Signal RIPPLE: rows shifted by a smooth wave ─────────────
        // Real bent-camera/databending tearing = each row displaced by a
        // value that varies CONTINUOUSLY down the frame, so the image ripples
        // and tears organically. Two sine octaves + a little per-strip noise
        // give a wobble that reads as genuine signal corruption — not random
        // hard bands and never fake black lines. Strip count kept modest so
        // the composite graph stays shallow (no Metal kernel dependency).
        // Bent++ ripples much harder than Bent — bigger amplitude and more
        // wave cycles so the whole frame churns instead of gently wobbling.
        let rippleAmp: CGFloat = (heavy ? 130 : 28) * t
        if rippleAmp > 0.5 {
            let freq1 = heavy ? Float.random(in: 3...6)  : Float.random(in: 1.5...3.5)
            let freq2 = heavy ? Float.random(in: 9...18) : Float.random(in: 5...11)
            let phase = Float.random(in: 0...(2 * .pi))
            if let kernel = CameraManager.rippleKernel() {
                // Fast path: single-pass Metal warp — per-pixel smooth ripple.
                let maxShift = rippleAmp * 1.2 + 5
                if let warped = kernel.apply(
                    extent: extent,
                    roiCallback: { _, rect in rect.insetBy(dx: -maxShift, dy: 0) },
                    image: img.clampedToExtent(),
                    arguments: [Float(rippleAmp), freq1, freq2, phase, Float(extent.height)]
                ) {
                    img = warped.cropped(to: extent)
                }
            } else {
                // Fallback: composite strip ripple (no Metal kernel available).
                let cf1 = CGFloat(freq1), cf2 = CGFloat(freq2), cph = CGFloat(phase)
                let stripCount = heavy ? 22 : 16
                let stripH = max(1, extent.height / CGFloat(stripCount))
                for i in 0..<stripCount {
                    let y0 = extent.minY + CGFloat(i) * stripH
                    let f = CGFloat(i) / CGFloat(stripCount)
                    let wave = sin(f * cf1 * 2 * .pi + cph) * 0.7
                             + sin(f * cf2 * 2 * .pi + cph * 1.7) * 0.3
                    let shift = wave * rippleAmp + CGFloat.random(in: -rippleAmp * 0.1...rippleAmp * 0.1)
                    let rect = CGRect(x: extent.minX, y: y0 - 0.5, width: extent.width, height: stripH + 1)
                    let strip = img.clampedToExtent()
                        .transformed(by: CGAffineTransform(translationX: shift, y: 0))
                        .cropped(to: rect)
                    let over = CIFilter.sourceOverCompositing()
                    over.inputImage = strip
                    over.backgroundImage = img
                    img = (over.outputImage ?? img).cropped(to: extent)
                }
            }
        }

        // ── 2. Occasional big "data jump" tears on top of the ripple ────
        // A few rows yanked far sideways = the moment the signal glitches
        // hard. Sparse; scales with weirdness.
        let jumpBands = Int((CGFloat(heavy ? 5 : 3) * t).rounded())
        for _ in 0..<max(0, jumpBands) {
            let bandH = CGFloat.random(in: 4...(heavy ? 36 : 20))
            let bandY = CGFloat.random(in: extent.minY...max(extent.minY, extent.maxY - bandH))
            let shift = CGFloat.random(in: -1...1) * (heavy ? 150 : 80) * t
            let rect = CGRect(x: extent.minX, y: bandY, width: extent.width, height: bandH)
            let band = img.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: shift, y: 0))
                .cropped(to: rect)
            let over = CIFilter.sourceOverCompositing()
            over.inputImage = band
            over.backgroundImage = img
            img = (over.outputImage ?? img).cropped(to: extent)
        }

        // ── 3. Chromatic channel desync (looks like real signal bleed) ──
        if CGFloat.random(in: 0...1) < t * 0.9 {
            let jumpMax: CGFloat = (heavy ? 70 : 36) * t
            let jump = CGFloat.random(in: (jumpMax * 0.3)...max(jumpMax * 0.3 + 0.1, jumpMax))
            let red  = isolateChannel(img, channel: 0).clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: jump, y: 0))
            let gb   = isolateChannel(img, channel: 1)
            let blue = isolateChannel(img, channel: 2).clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -jump, y: 0))
            let a = CIFilter.additionCompositing(); a.inputImage = red; a.backgroundImage = gb
            let b = CIFilter.additionCompositing(); b.inputImage = a.outputImage ?? gb; b.backgroundImage = blue
            img = (b.outputImage ?? img).cropped(to: extent)
        }

        // ── 4. Wild mode: randomize light + color each frame ────────────
        // Swing ranges scale with weirdness so low t drifts gently.
        if wild {
            // Exposure swing — kept moderate so the frame doesn't blow out to
            // a flat color. Centered with a tighter range; the base sim is
            // already very bright/saturated so a little goes a long way.
            let exp = CIFilter.exposureAdjust()
            exp.inputImage = img
            exp.ev = Float.random(in: -0.9...0.9) * tF
            img = exp.outputImage ?? img

            // Hue can spin a full half-turn each frame at max — this is the
            // big chaos lever and it's safe (rotation never collapses values).
            let hue = CIFilter.hueAdjust()
            hue.inputImage = img
            hue.angle = Float.random(in: -3.14...3.14) * tF
            img = hue.outputImage ?? img

            // Color cast — moderate so it tints rather than floods.
            let castRange = 0.18 * t
            let m = CIFilter.colorMatrix()
            m.inputImage = img
            m.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
            m.biasVector = CIVector(x: CGFloat.random(in: -castRange...castRange),
                                    y: CGFloat.random(in: -castRange...castRange),
                                    z: CGFloat.random(in: -castRange...castRange),
                                    w: 0)
            img = m.outputImage ?? img

            // Saturation kick — never below 0.6 (so it doesn't gray out) and
            // capped so it doesn't push an already-saturated frame to a flat
            // primary.
            let cc = CIFilter.colorControls()
            cc.inputImage = img
            cc.saturation = 1.0 + (Float.random(in: -0.4...0.7)) * tF
            img = cc.outputImage ?? img
        }

        return img.cropped(to: extent)
    }

    /// Builds 8 fully-rasterised grain textures at `extent` on a background queue.
    /// Each texture is a CGImage-backed CIImage — zero filter graph evaluation when
    /// blended at preview time. Called lazily from the video-frame queue; skipped
    /// silently if a build is already in flight.
    nonisolated func buildGrainPreviewTextures(for extent: CGRect) {
        guard !grainPreviewBuilding, cachedGrainAmount > 0 else { return }
        grainPreviewBuilding = true
        DispatchQueue.global(qos: .utility).async { [self] in
            let a = CGFloat(max(0, min(0.35, cachedGrainAmount)))
            var textures: [CIImage] = []
            textures.reserveCapacity(8)
            for _ in 0..<8 {
                let ox = CGFloat.random(in: 0...4096)
                let oy = CGFloat.random(in: 0...4096)
                guard let rawNoise = CIFilter.randomGenerator().outputImage else { continue }
                let noise = rawNoise
                    .transformed(by: CGAffineTransform(translationX: ox, y: oy))
                    .cropped(to: extent)
                let mono = CIFilter.colorControls()
                mono.inputImage = noise
                mono.saturation = 0.0
                mono.brightness = -0.5
                mono.contrast = Float(1.0 + a * 1.8)
                guard let monoNoise = mono.outputImage?.cropped(to: extent) else { continue }
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = monoNoise
                blur.radius = Float(0.4 + a * 0.6)
                guard let blurred = blur.outputImage?.cropped(to: extent) else { continue }
                // Force eager rasterisation — pixel data baked into CGImage,
                // so the blend at preview time is a plain Metal texture composite.
                if let cg = ciContext.createCGImage(blurred, from: extent) {
                    textures.append(CIImage(cgImage: cg))
                }
            }
            grainPreviewTextures = textures
            grainPreviewExtent   = extent
            grainPreviewBuilding = false
        }
    }

    nonisolated func addGrain(input: CIImage, amount: Float) -> CIImage {
        guard amount > 0 else { return input }
        let a = CGFloat(max(0, min(0.35, amount)))
        let extent = input.extent

        // Random offset per call — CIRandomGenerator produces a fixed texture,
        // so we translate into a different region each time for true per-frame randomness
        let ox = CGFloat.random(in: 0...4096)
        let oy = CGFloat.random(in: 0...4096)
        guard let rawNoise = CIFilter.randomGenerator().outputImage else { return input }
        let noise = rawNoise
            .transformed(by: CGAffineTransform(translationX: ox, y: oy))
            .cropped(to: extent)

        // Monochrome, centred at 0.5 so it both lightens and darkens
        let mono = CIFilter.colorControls()
        mono.inputImage = noise
        mono.saturation = 0.0
        mono.brightness = -0.5
        mono.contrast = Float(1.0 + a * 1.8)
        guard let monoNoise = mono.outputImage?.cropped(to: extent) else { return input }

        // Minimal blur — just enough to round pixel edges, not enough to cause blotchiness
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = monoNoise
        blur.radius = Float(0.4 + a * 0.6)
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return input }

        // Soft light blend — more natural distribution than overlay, avoids clumping artifacts
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = blurred
        blend.backgroundImage = input
        guard let blended = blend.outputImage?.cropped(to: extent) else { return input }

        // Mix to control overall strength
        let strength = max(0.0, 1.0 - Double(a) * 1.5)
        let mix = CIFilter(name: "CIDissolveTransition", parameters: [
            kCIInputImageKey: blended,
            kCIInputTargetImageKey: input,
            "inputTime": NSNumber(value: strength)
        ])
        return mix?.outputImage?.cropped(to: extent) ?? blended
    }

    /// Sharp CCD-style digital noise — no blur, slight chroma component.
    /// Used by DigiCam instead of the film-grain pipeline.
    nonisolated func addDigitalNoise(input: CIImage, amount: Float) -> CIImage {
        guard amount > 0 else { return input }
        let a = max(0, min(0.5, amount))

        // 1. Raw random noise — keep it sharp (no blur = digital pixel noise)
        guard let noise = CIFilter.randomGenerator().outputImage?.cropped(to: input.extent) else { return input }

        // 2. Slight colour cast so it reads as CCD chroma noise (faint red/blue channels)
        let colorMatrix = CIFilter.colorMatrix()
        colorMatrix.inputImage = noise
        colorMatrix.rVector = CIVector(x: CGFloat(0.5 + a * 0.3), y: 0, z: 0, w: 0)
        colorMatrix.gVector = CIVector(x: 0, y: CGFloat(0.45), z: 0, w: 0)
        colorMatrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(0.5 + a * 0.3), w: 0)
        colorMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        colorMatrix.biasVector = CIVector(x: -0.25, y: -0.225, z: -0.25, w: 0)
        guard let colorNoise = colorMatrix.outputImage?.cropped(to: input.extent) else { return input }

        // 3. Screen blend (brightens selectively — looks like sensor hot pixels / amp noise)
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = colorNoise
        screen.backgroundImage = input
        guard let screened = screen.outputImage?.cropped(to: input.extent) else { return input }

        // 4. Mix: low amounts stay subtle, high amounts get gritty
        let mix = CIFilter(name: "CIDissolveTransition", parameters: [
            kCIInputImageKey: screened,
            kCIInputTargetImageKey: input,
            "inputTime": NSNumber(value: 1.0 - Double(a) * 1.8)
        ])
        return mix?.outputImage?.cropped(to: input.extent) ?? screened
    }

    /// Film light artifacts: light leaks, edge burns, and faint film scratches.
    /// Seeded so each capture gets a consistent but unique artifact pattern.
    nonisolated func applyLightArtifacts(input: CIImage, seed: UInt64) -> CIImage {
        let extent = input.extent
        var result = input

        // Simple LCG for repeatable per-shot randomness
        var s = seed &+ 0x9e3779b97f4a7c15
        func next() -> CGFloat {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(s >> 33) / 0x7fffffff
        }

        // ── Light leak ─────────────────────────────────────────────────────────
        // Warm/amber/pinkish gradient bleeding in from a random edge or corner
        let leakEdge = Int(next() * 4)   // 0=top 1=bottom 2=left 3=right
        let leakPos  = next()            // position along the edge
        let leakSpread = 0.25 + next() * 0.35
        let leakOpacity = 0.18 + next() * 0.28

        // Pick a leak color: amber, orange-red, or pink
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (1.0, 0.45, 0.05),   // amber-orange
            (1.0, 0.25, 0.10),   // orange-red
            (0.95, 0.15, 0.30),  // pink-red
            (1.0, 0.55, 0.0),    // golden yellow
        ]
        let col = palette[Int(next() * CGFloat(palette.count)) % palette.count]

        let w = extent.width, h = extent.height
        var p0: CIVector
        var p1: CIVector
        switch leakEdge {
        case 0:  // top
            p0 = CIVector(x: leakPos * w, y: h)
            p1 = CIVector(x: leakPos * w, y: h * (1 - leakSpread))
        case 1:  // bottom
            p0 = CIVector(x: leakPos * w, y: 0)
            p1 = CIVector(x: leakPos * w, y: h * leakSpread)
        case 2:  // left
            p0 = CIVector(x: 0, y: leakPos * h)
            p1 = CIVector(x: w * leakSpread, y: leakPos * h)
        default: // right
            p0 = CIVector(x: w, y: leakPos * h)
            p1 = CIVector(x: w * (1 - leakSpread), y: leakPos * h)
        }

        let leak = CIFilter.smoothLinearGradient()
        leak.point0 = CGPoint(x: p0.x, y: p0.y)
        leak.point1 = CGPoint(x: p1.x, y: p1.y)
        leak.color0 = CIColor(red: col.0, green: col.1, blue: col.2, alpha: leakOpacity)
        leak.color1 = CIColor(red: col.0, green: col.1, blue: col.2, alpha: 0)
        if let leakImg = leak.outputImage?.cropped(to: extent) {
            // Screen blend — light leak only brightens, never darkens
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = leakImg
            screen.backgroundImage = result
            result = screen.outputImage?.cropped(to: extent) ?? result
        }

        // ── Edge burn / secondary leak (50% chance) ────────────────────────────
        if next() > 0.5 {
            let burnEdge = (leakEdge + 1 + Int(next() * 3)) % 4
            let burnOpacity = 0.08 + next() * 0.14
            let burnSpread = 0.12 + next() * 0.15
            var b0, b1: CGPoint
            switch burnEdge {
            case 0:  b0 = CGPoint(x: w * 0.5, y: h);            b1 = CGPoint(x: w * 0.5, y: h * (1 - burnSpread))
            case 1:  b0 = CGPoint(x: w * 0.5, y: 0);            b1 = CGPoint(x: w * 0.5, y: h * burnSpread)
            case 2:  b0 = CGPoint(x: 0, y: h * 0.5);            b1 = CGPoint(x: w * burnSpread, y: h * 0.5)
            default: b0 = CGPoint(x: w, y: h * 0.5);            b1 = CGPoint(x: w * (1 - burnSpread), y: h * 0.5)
            }
            let burn = CIFilter.smoothLinearGradient()
            burn.point0 = b0; burn.point1 = b1
            // Burn is darker — multiply blend to darken edges slightly
            burn.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: burnOpacity)
            burn.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let burnImg = burn.outputImage?.cropped(to: extent) {
                let multiply = CIFilter.multiplyBlendMode()
                multiply.inputImage = burnImg
                multiply.backgroundImage = result
                // Use dissolve to mix burn in subtly
                if let darkened = multiply.outputImage?.cropped(to: extent) {
                    let mix = CIFilter(name: "CIDissolveTransition", parameters: [
                        kCIInputImageKey: darkened,
                        kCIInputTargetImageKey: result,
                        "inputTime": NSNumber(value: 0.6)
                    ])
                    result = mix?.outputImage?.cropped(to: extent) ?? result
                }
            }
        }

        return result
    }

    /// Applies faint vertical film scratches to the image.
    nonisolated func applyFilmScratches(input: CIImage, seed: UInt64) -> CIImage {
        let extent = input.extent
        let w = extent.width
        var result = input

        var rng = seed &+ 0xDEADBEEF_CAFEBABE
        func next() -> CGFloat {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(rng >> 33) / CGFloat(1 << 31)
        }

        // 1–3 scratches per frame
        let count = 1 + Int(next() * 2.99)
        for _ in 0..<count {
            let scratchX = next() * w + extent.origin.x
            let scratchWidth = 0.4 + next() * 1.2  // thin — 0.4 to 1.6pt
            let scratchOpacity = 0.06 + next() * 0.14
            let scratchRect = CGRect(x: scratchX, y: extent.origin.y, width: scratchWidth, height: extent.height)
            let scratchColor = CIColor(red: 1, green: 0.95, blue: 0.85, alpha: scratchOpacity)
            let scratchImg = CIImage(color: scratchColor).cropped(to: scratchRect)
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = scratchImg
            screen.backgroundImage = result
            result = screen.outputImage?.cropped(to: extent) ?? result
        }

        return result
    }

    nonisolated func applyColorCrosstalk(input: CIImage, amount: Float) -> CIImage {
        let a = CGFloat(max(0, min(0.2, amount)))
        let r = CIVector(x: 1 - a, y: a * 0.5, z: a * 0.5, w: 0)
        let g = CIVector(x: a * 0.5, y: 1 - a, z: a * 0.5, w: 0)
        let b = CIVector(x: a * 0.5, y: a * 0.5, z: 1 - a, w: 0)
        let m = CIFilter.colorMatrix()
        m.inputImage = input
        m.rVector = r
        m.gVector = g
        m.bVector = b
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage ?? input
    }

    nonisolated func applyHalation(input: CIImage, amount: Float) -> CIImage {
        let redExtract = CIFilter.colorMatrix()
        redExtract.inputImage = input
        redExtract.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        redExtract.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        redExtract.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        redExtract.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let redOnly = redExtract.outputImage ?? input
        let highlight = CIFilter.highlightShadowAdjust()
        highlight.inputImage = redOnly
        highlight.highlightAmount = 1.0
        highlight.shadowAmount = 0.0
        let bright = highlight.outputImage ?? redOnly
        let gaussian = CIFilter.gaussianBlur()
        gaussian.inputImage = bright
        gaussian.radius = Float(max(2, Double(amount) * 20.0))
        let blurred = gaussian.outputImage?.cropped(to: input.extent) ?? input
        let tint = CIFilter.colorMatrix()
        tint.inputImage = blurred
        tint.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0.2, y: 0, z: 0, w: 0)
        tint.bVector = CIVector(x: 0.0, y: 0, z: 0, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(0.15 + amount))
        let colored = tint.outputImage ?? blurred
        let composite = CIFilter.screenBlendMode()
        composite.inputImage = colored
        composite.backgroundImage = input
        return composite.outputImage ?? input
    }

    nonisolated func applyHighlightRolloff(input: CIImage, threshold: Float) -> CIImage {
        let t = CGFloat(max(0.5, min(0.98, threshold)))
        let curve = CIFilter.toneCurve()
        curve.inputImage = input
        curve.point0 = CGPoint(x: 0.0, y: 0.0)
        curve.point1 = CGPoint(x: 0.5, y: 0.5)
        curve.point2 = CGPoint(x: t, y: t - 0.05)
        curve.point3 = CGPoint(x: (t + 1.0) * 0.5, y: (t + 1.0) * 0.5 - 0.02)
        curve.point4 = CGPoint(x: 1.0, y: 0.98)
        return curve.outputImage ?? input
    }

    nonisolated func compositeDoubleExposure(base: CIImage, overlay: CIImage, opacity: Float, mask: UIImage? = nil) -> CIImage {
        // Scale base to match overlay extent if they differ
        var scaledBase = base
        let targetExtent = overlay.extent
        if base.extent.size != targetExtent.size {
            let sx = targetExtent.width / base.extent.width
            let sy = targetExtent.height / base.extent.height
            scaledBase = base.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        if let mask = mask, let cgMask = mask.cgImage {
            // Mask mode: use painted mask to control blend per-pixel.
            // The mask was painted in UIKit coordinates over the PREVIEW which uses
            // .resizeAspectFill (cropped to fit the screen). We aspect-fill scale
            // and center-crop the mask to match the preview's framing on the photo.
            // (No Y-flip needed — CIImage(cgImage:) maps CGImage row 0 to CIImage
            // top, so the mask is already in the right orientation for compositing.)
            var maskCI = CIImage(cgImage: cgMask)

            // Aspect-fill scale: pick the larger scale factor so the mask covers
            // the entire target, then center-crop the overflow.
            let maskW = maskCI.extent.width
            let maskH = maskCI.extent.height
            let sx = targetExtent.width  / maskW
            let sy = targetExtent.height / maskH
            let scale = max(sx, sy)
            maskCI = maskCI.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            // Center the scaled mask on the target extent
            let scaledW = maskCI.extent.width
            let scaledH = maskCI.extent.height
            let dx = (targetExtent.width  - scaledW) / 2.0 + targetExtent.origin.x
            let dy = (targetExtent.height - scaledH) / 2.0 + targetExtent.origin.y
            maskCI = maskCI.transformed(by: CGAffineTransform(translationX: dx, y: dy))
            maskCI = maskCI.cropped(to: targetExtent)

            // Apply global opacity on top of per-pixel mask: brush alpha × blend slider
            let opacityFilter = CIFilter.colorMatrix()
            opacityFilter.inputImage = maskCI
            opacityFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
            let scaledMask = opacityFilter.outputImage ?? maskCI

            // BlendWithMask: overlay shows through where mask is white, base shows where black
            let blendWithMask = CIFilter.blendWithMask()
            blendWithMask.inputImage = overlay         // foreground (second shot)
            blendWithMask.backgroundImage = scaledBase  // background (first shot)
            blendWithMask.maskImage = scaledMask
            return blendWithMask.outputImage?.cropped(to: targetExtent) ?? overlay
        }

        // No mask: uniform opacity screen blend
        let opacityFilter = CIFilter.colorMatrix()
        opacityFilter.inputImage = overlay
        opacityFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        let adjusted = opacityFilter.outputImage ?? overlay
        let blend = CIFilter.screenBlendMode()
        blend.inputImage = adjusted
        blend.backgroundImage = scaledBase
        return blend.outputImage?.cropped(to: targetExtent) ?? overlay
    }

    /// Reference field-of-view (degrees) of the physical wide-angle lens.
    /// Used to compute per-device FOV compensation for virtual cameras.
    /// Refreshed any time we have a clean opportunity to query the physical wide.
    @ObservationIgnored nonisolated(unsafe) var physicalWideFOV: Float = 73.0

    /// Query the back physical wide directly and record its FOV reference.
    /// Doesn't activate the device — just reads its default active format's FOV.
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
            || (unifiedZoomMode && preset.deviceType != .builtInUltraWideCamera)

        // intentZoom = preset's mm in our 26mm-based scale. setZoom takes intent.
        // For swap calls that take a device-specific zoom we apply the prospective
        // virtual compensation (queries the triple device directly) so the 120mm
        // preset lands above the 5x switchover and actually engages the telephoto.
        let intentZoom = CGFloat(Double(preset.mm) / 26.0)
        lastRequestedZoom = intentZoom

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

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

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
        let customSim = activeCustomSim
        let metal = metalPreviewView

        guard sim != .none || customSim != nil else {
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
                if let cs = activeCustomSim {
                    rec = applyCustomSim(to: rec, sim: cs)
                } else {
                    let saved = pendingSim; pendingSim = cachedSim
                    rec = applyFilmSim(to: rec)
                    pendingSim = saved
                }
                if cachedCrosstalkEnabled { rec = applyColorCrosstalk(input: rec, amount: cachedCrosstalkAmount) }
                if cachedHalationEnabled  { rec = applyHalation(input: rec, amount: cachedHalationAmount) }
                if cachedRolloffEnabled   { rec = applyHighlightRolloff(input: rec, threshold: cachedRolloffThreshold) }
                if cachedPushPullEnabled  { rec = applyPushPull(input: rec, stops: cachedPushPullAmount) }
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

        // Downscale for preview — half resolution is plenty for screen display
        let previewScale: CGFloat = 0.5
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: previewScale, y: previewScale))

        // Apply full sim + effects pipeline to preview
        var filtered: CIImage
        if let customSim {
            filtered = applyCustomSim(to: scaled, sim: customSim)
        } else {
            let prevPending = pendingSim
            pendingSim = cachedSim
            filtered = applyFilmSim(to: scaled)
            pendingSim = prevPending

            // DigiCam scanlines — the context-aware "lines" toggle. Mirrors
            // the capture pipeline so the live preview actually shows them.
            if cachedSim == .digiCam && cachedContextAwareGrain && cachedDigiCamQuality >= 1 {
                filtered = applyScanlines(input: filtered)
            }
            // Circuit-bent per-frame glitches — only when grain is on; the
            // grain slider scales the weirdness, context-aware = wild drift.
            if (cachedSim == .circuitBent || cachedSim == .circuitBentHeavy)
                && cachedGrainEnabled && cachedGrainAmount > 0 {
                let heavy = (cachedSim == .circuitBentHeavy)
                let weirdness = min(1.0, CGFloat(cachedGrainAmount) / 0.5)
                filtered = circuitBentGlitch(filtered, heavy: heavy,
                                             wild: cachedContextAwareGrain,
                                             intensity: weirdness)
            }
        }
        // Apply live effects so preview matches saved output
        if cachedCrosstalkEnabled {
            filtered = applyColorCrosstalk(input: filtered, amount: cachedCrosstalkAmount)
        }
        if cachedHalationEnabled {
            filtered = applyHalation(input: filtered, amount: cachedHalationAmount)
        }
        if cachedRolloffEnabled {
            filtered = applyHighlightRolloff(input: filtered, threshold: cachedRolloffThreshold)
        }
        if cachedPushPullEnabled {
            filtered = applyPushPull(input: filtered, stops: cachedPushPullAmount)
        }

        // Grain preview — cycles through 8 pre-baked textures; cost = one softLight blend per frame.
        // Textures are built once on a background queue and reused until settings change.
        if cachedGrainEnabled && cachedGrainAmount > 0 {
            let previewExtent = scaled.extent
            // Trigger a (re)build if textures are missing or the frame size changed
            if grainPreviewTextures.isEmpty || grainPreviewExtent != previewExtent {
                buildGrainPreviewTextures(for: previewExtent)
            }
            if !grainPreviewTextures.isEmpty {
                let idx = grainPreviewFrameIdx % grainPreviewTextures.count
                grainPreviewFrameIdx &+= 1
                let grainTex = grainPreviewTextures[idx]

                // Context-aware: re-sample scene luma every 30 frames (~1 s at 30 fps).
                // A 1×1 pixel render is near-zero GPU cost; throttling prevents any stall cadence.
                var grainAmt = cachedGrainAmount
                if cachedContextAwareGrain {
                    grainPreviewLumaCounter &+= 1
                    if grainPreviewLumaCounter % 30 == 1 {
                        let avg = CIFilter.areaAverage()
                        avg.inputImage = filtered
                        avg.extent = filtered.extent
                        if let avgImg = avg.outputImage {
                            var bmp = [UInt8](repeating: 0, count: 4)
                            ciContext.render(avgImg, toBitmap: &bmp, rowBytes: 4,
                                            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                            format: .RGBA8,
                                            colorSpace: CGColorSpaceCreateDeviceRGB())
                            grainPreviewLuma = (Float(bmp[0]) * 0.299 +
                                               Float(bmp[1]) * 0.587 +
                                               Float(bmp[2]) * 0.114) / 255.0
                        }
                    }
                    let scale = 1.7 - grainPreviewLuma * 1.3
                    grainAmt = min(0.5, grainAmt * scale)
                }

                let a = Double(max(0, min(0.35, grainAmt)))
                let blend = CIFilter.softLightBlendMode()
                blend.inputImage = grainTex
                blend.backgroundImage = filtered
                if let blended = blend.outputImage?.cropped(to: previewExtent) {
                    let strength = max(0.0, 1.0 - a * 1.5)
                    if let mixed = CIFilter(name: "CIDissolveTransition", parameters: [
                        kCIInputImageKey: blended,
                        kCIInputTargetImageKey: filtered,
                        "inputTime": NSNumber(value: strength)
                    ])?.outputImage?.cropped(to: previewExtent) {
                        filtered = mixed
                    }
                }
            }
        }

        // Live portrait depth blur in preview (uses cached depth from AVCaptureDepthDataOutput)
        if pendingPortraitEnabled && latestDepthPixelBuffer != nil {
            filtered = applyLivePortraitBlur(to: filtered, fStop: pendingPortraitFStop)
        }

        // Filters like blur, bloom, halation, motion-blur expand the CIImage's
        // extent beyond the input. Crop back to the downscaled-input extent so
        // Metal's aspect-fill math (which uses image.extent) renders correctly.
        filtered = filtered.cropped(to: scaled.extent)

        if let metal {
            metal.currentImage = filtered
            DispatchQueue.main.async { metal.setNeedsDisplay() }
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
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
        guard error == nil else {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.isBursting = false
            }
            return
        }

        // Check if RAW
        if photo.isRawPhoto, let data = photo.fileDataRepresentation() {
            saveRAW(data: data)
            if burstActive { burstDidCapture() }
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.isBursting = false
            }
            return
        }

        // Double exposure first shot — apply sim, store CIImage, don't save
        if capturingFirstExposure {
            capturingFirstExposure = false
            if let ciImage = CIImage(data: data) {
                let oriented = ciImage.oriented(forExifOrientation: Int32(ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1))
                // Safety crop for virtual cameras (no-op on physical) so first
                // and second exposures share the same FOV before composite.
                let cropped = applyPhotoZoomCrop(oriented)
                // Apply film sim to first exposure so both shots match
                let processed = applySimAndGrain(to: cropped)
                firstExposureCIImage = processed
                // Generate preview CGImage for overlay
                let preview = ciContext.createCGImage(processed, from: processed.extent)
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
            burstBacklog += 1
            processQueue.async { [self] in
                defer { self.burstBacklog -= 1 }
                guard var ciImage = CIImage(data: capturedData) else { return }
                let metadata = ciImage.properties
                ciImage = ciImage.oriented(forExifOrientation: Int32(ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1))
                ciImage = applyPhotoZoomCrop(ciImage)
                let processed = applySimAndGrain(to: ciImage)
                renderAndSave(ciImage: processed, metadata: metadata)
            }
            burstDidCapture()
            return
        }

        // Portrait mode: apply high-quality depth blur using the most recent live depth frame.
        // (Depth is delivered via AVCaptureDepthDataOutput, not embedded in AVCapturePhoto
        //  when a separate depth output is in the session.)
        if pendingPortraitEnabled, let depthBuffer = latestDepthPixelBuffer {
            processAndSavePortraitFromBuffer(imageData: data, depthBuffer: depthBuffer)
        } else {
            processAndSaveJPEG(imageData: data)
        }
    }
}

// MARK: - PreviewUIView

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }

    private var observation: NSKeyValueObservation?
    private var sessionStartObserver: Any?
    private var snapshotView: UIView?

    func configure(session: AVCaptureSession) {
        guard let previewLayer else { return }
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        applyRotation()

        // Re-apply rotation whenever inputs change (lens swap) or session starts running
        observation = session.observe(\.inputs, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyRotation() }
        }
        // Store observer token so deinit can unregister it (otherwise leaks)
        sessionStartObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification,
            object: session, queue: .main
        ) { [weak self] _ in
            self?.applyRotation()
        }
    }

    func applyRotation() {
        guard let conn = previewLayer?.connection,
              conn.isVideoRotationAngleSupported(90) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        conn.videoRotationAngle = 90
        CATransaction.commit()
    }

    /// Capture a snapshot of the current preview and overlay it, then crossfade out
    func freezeAndCrossfade(duration: TimeInterval = 0.4) {
        // Snapshot the current preview layer into an image view
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let snapshot = renderer.image { ctx in
            layer.render(in: ctx.cgContext)
        }
        let imageView = UIImageView(image: snapshot)
        imageView.frame = bounds
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        snapshotView = imageView

        // Fade out after the new lens starts producing frames
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            UIView.animate(withDuration: duration, delay: 0, options: .curveEaseInOut) {
                imageView.alpha = 0
            } completion: { _ in
                imageView.removeFromSuperview()
                self.snapshotView = nil
            }
        }
    }

    deinit {
        observation?.invalidate()
        if let obs = sessionStartObserver { NotificationCenter.default.removeObserver(obs) }
    }
}

// MARK: - CameraPreviewView

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var camera: CameraManager? = nil

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.configure(session: session)
        camera?.previewLayer = view.previewLayer
        camera?.previewUIView = view
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.applyRotation()
    }
}

// MARK: - Metal Filtered Preview

/// Renders filtered CIImages directly on the GPU via Metal — no CGImage round-trip
final class MetalFilteredPreviewView: MTKView, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue?
    nonisolated(unsafe) var sharedCIContext: CIContext?
    private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    nonisolated(unsafe) var currentImage: CIImage?

    func setup(sharedContext: CIContext? = nil) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.device = device
        commandQueue = device.makeCommandQueue()
        sharedCIContext = sharedContext
        delegate = self
        framebufferOnly = false
        // On-demand rendering: only draw when setNeedsDisplay() is called
        isPaused = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 60
        backgroundColor = .clear
        isOpaque = false
    }

    func draw(in view: MTKView) {
        guard let image = currentImage,
              let context = sharedCIContext,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }

        let dSize = drawableSize
        // Aspect-fill so the preview fills the whole screen.
        let scaleX = dSize.width / image.extent.width
        let scaleY = dSize.height / image.extent.height
        let scale = max(scaleX, scaleY)
        // Combine scale + translation into a single transform
        let scaledW = image.extent.width * scale
        let scaledH = image.extent.height * scale
        let offsetX = (dSize.width - scaledW) / 2 - image.extent.origin.x * scale
        let offsetY = (dSize.height - scaledH) / 2 - image.extent.origin.y * scale
        let centered = image.transformed(by: CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offsetX, ty: offsetY))

        let destination = CIRenderDestination(
            width: Int(dSize.width),
            height: Int(dSize.height),
            pixelFormat: colorPixelFormat,
            commandBuffer: commandBuffer,
            mtlTextureProvider: { drawable.texture }
        )
        _ = try? context.startTask(toRender: centered, to: destination)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

struct MetalFilteredPreview: UIViewRepresentable {
    let camera: CameraManager

    func makeUIView(context: Context) -> MetalFilteredPreviewView {
        let view = MetalFilteredPreviewView()
        view.setup(sharedContext: camera.ciContext)
        camera.metalPreviewView = view
        return view
    }

    func updateUIView(_ uiView: MetalFilteredPreviewView, context: Context) {}
}

// MARK: - ExposureMeterBar

struct ExposureMeterBar: View {
    let evValue: Float
    let bias: Float

    private let range: Float = 3.0
    private let dialSize: CGFloat = 64

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.5))
                .frame(width: dialSize, height: dialSize)

            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 1.5)
                .frame(width: dialSize, height: dialSize)

            // Coloured arc
            Circle()
                .trim(from: 0.5 - arcFraction(for: evValue) / 2,
                      to:   0.5 + arcFraction(for: evValue) / 2)
                .stroke(meterColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: dialSize - 8, height: dialSize - 8)
                .rotationEffect(.degrees(90))
                .animation(.easeOut(duration: 0.12), value: evValue)

            // Bias marker dot
            Circle()
                .fill(Color.yellow)
                .frame(width: 5, height: 5)
                .offset(y: -(dialSize / 2 - 4))
                .rotationEffect(.degrees(Double(bias / range) * 90))

            // Centre label
            VStack(spacing: 0) {
                Image(systemName: "sun.max")
                    .font(.system(size: 8))
                    .foregroundStyle(meterColor)
                Text(evLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }

            // Scale ticks
            ForEach([-3, -1, 0, 1, 3], id: \.self) { stop in
                Rectangle()
                    .fill(Color.white.opacity(stop == 0 ? 0.8 : 0.3))
                    .frame(width: 1, height: stop == 0 ? 6 : 4)
                    .offset(y: -(dialSize / 2 - 2))
                    .rotationEffect(.degrees(Double(stop) / Double(range) * 90))
            }
        }
        .frame(width: dialSize, height: dialSize)
    }

    private func arcFraction(for value: Float) -> CGFloat {
        let clamped = Swift.max(-range, Swift.min(value, range))
        return CGFloat(abs(clamped) / range) * 0.5
    }

    private var evLabel: String {
        String(format: "%+.1f", evValue + bias)
    }

    private var meterColor: Color {
        let total = abs(evValue)
        if total < 0.5 { return .green }
        if total < 1.5 { return .yellow }
        return .red
    }
}

// MARK: - Triangle Shape

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - GridOverlay

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { path in
                // Vertical thirds
                path.move(to: CGPoint(x: w / 3, y: 0))
                path.addLine(to: CGPoint(x: w / 3, y: h))
                path.move(to: CGPoint(x: 2 * w / 3, y: 0))
                path.addLine(to: CGPoint(x: 2 * w / 3, y: h))
                // Horizontal thirds
                path.move(to: CGPoint(x: 0, y: h / 3))
                path.addLine(to: CGPoint(x: w, y: h / 3))
                path.move(to: CGPoint(x: 0, y: 2 * h / 3))
                path.addLine(to: CGPoint(x: w, y: 2 * h / 3))
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - LevelOverlay

struct LevelOverlay: View {
    let roll: Double // degrees

    var body: some View {
        GeometryReader { geo in
            let centerX = geo.size.width / 2
            let centerY = geo.size.height / 2
            let lineLength: CGFloat = 80
            let isLevel = abs(roll) < 1.0

            ZStack {
                // Center dot
                Circle()
                    .fill(isLevel ? Color.green : Color.white)
                    .frame(width: 6, height: 6)
                    .position(x: centerX, y: centerY)

                // Horizon line
                Path { path in
                    path.move(to: CGPoint(x: centerX - lineLength, y: centerY))
                    path.addLine(to: CGPoint(x: centerX + lineLength, y: centerY))
                }
                .stroke(isLevel ? Color.green : Color.white.opacity(0.5), lineWidth: 1)
                .rotationEffect(.degrees(-roll), anchor: UnitPoint(x: 0.5, y: centerY / geo.size.height))

                // Reference line (always horizontal)
                Path { path in
                    path.move(to: CGPoint(x: centerX - lineLength * 0.4, y: centerY))
                    path.addLine(to: CGPoint(x: centerX + lineLength * 0.4, y: centerY))
                }
                .stroke(Color.yellow.opacity(0.5), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - MotionManager

@Observable final class MotionManager {
    var roll: Double = 0.0
    var pitch: Double = 0.0
    /// Snapped rotation angle for UI elements: 0, 90, -90, or 180
    var iconAngle: Double = 0.0
    var isLandscape: Bool = false
    /// Degrees the camera's horizon is tilted from level, accounting for the
    /// current device orientation. 0 = level. Use this for the LevelOverlay
    /// instead of raw `roll` (which only makes sense in portrait).
    var levelTilt: Double = 0.0
    @ObservationIgnored nonisolated(unsafe) var motionManager = CMMotionManager()

    func startUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 15.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion = motion else { return }
            self.roll = motion.attitude.roll * 180.0 / .pi
            self.pitch = motion.attitude.pitch * 180.0 / .pi

            // Determine device orientation from gravity
            let g = motion.gravity
            let newAngle: Double
            if abs(g.x) > abs(g.y) {
                // Landscape — negate to counter the tilt so text stays upright
                newAngle = g.x > 0 ? -90 : 90
            } else if g.y > 0.8 {
                // Upside down
                newAngle = 180
            } else {
                // Portrait (normal)
                newAngle = 0
            }
            let landscape = abs(g.x) > abs(g.y)

            // Compute orientation-aware level tilt from gravity. The screen's "down"
            // direction in device coords depends on current rotation:
            //   portrait → (0,-1)   landscape-left → (-1,0)
            //   upsideDown → (0,1)  landscape-right → (1,0)
            // Tilt = signed angle between screen-down and gravity (projected to XY).
            // Computed via the 2D cross/dot trick: angle = atan2(cross, dot).
            let tiltRad: Double
            switch newAngle {
            case 90:   tiltRad = atan2(-g.y, -g.x)       // landscape left
            case -90:  tiltRad = atan2(g.y, g.x)         // landscape right
            case 180:  tiltRad = atan2(-g.x, g.y)        // upside down
            default:   tiltRad = atan2(g.x, -g.y)        // portrait
            }
            let tiltDeg = tiltRad * 180.0 / .pi
            self.levelTilt = tiltDeg

            if newAngle != self.iconAngle {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.iconAngle = newAngle
                    self.isLandscape = landscape
                }
            } else if landscape != self.isLandscape {
                self.isLandscape = landscape
            }
        }
    }

    func stopUpdates() {
        motionManager.stopDeviceMotionUpdates()
    }
}

// MARK: - AspectRatioOverlay

struct AspectRatioOverlay: View {
    let aspectRatio: AspectRatio
    let geoSize: CGSize
    var isLandscape: Bool = false

    var body: some View {
        if let baseRatio = aspectRatio.ratio {
            // Orientation-aware: rotate the frame with the device so it always
            // looks like the labeled ratio from the USER's viewpoint.
            //   Portrait viewing: on-screen ratio = baseRatio (e.g. 16:9 wide slit)
            //   Landscape viewing: on-screen ratio = 1/baseRatio (tall narrow on
            //     portrait-locked screen, which when rotated 90° in user's view
            //     appears as 16:9 wide.)
            let ratio: CGFloat = isLandscape ? (1.0 / baseRatio) : baseRatio
            let fullW = geoSize.width
            let fullH = geoSize.height
            let fullRatio = fullW / fullH

            if ratio > fullRatio {
                // Wider than viewport: crop top and bottom
                let visibleH = fullW / ratio
                let barH = (fullH - visibleH) / 2
                VStack(spacing: 0) {
                    Rectangle().fill(Color.black.opacity(0.6)).frame(height: barH)
                    Spacer()
                    Rectangle().fill(Color.black.opacity(0.6)).frame(height: barH)
                }
            } else {
                // Taller: crop left and right
                let visibleW = fullH * ratio
                let barW = (fullW - visibleW) / 2
                HStack(spacing: 0) {
                    Rectangle().fill(Color.black.opacity(0.6)).frame(width: barW)
                    Spacer()
                    Rectangle().fill(Color.black.opacity(0.6)).frame(width: barW)
                }
            }
        }
    }
}

// MARK: - Double Exposure Mask Painter

struct MaskPainterView: UIViewRepresentable {
    @Binding var mask: UIImage?
    @Binding var brushTipPosition: CGPoint?     // live position for the on-screen brush ring
    var brushSize: CGFloat
    var brushOpacity: Double  // 1 = paint (expose), 0 = erase
    var viewSize: CGSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: CGRect(origin: .zero, size: viewSize))
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    class Coordinator: NSObject {
        var parent: MaskPainterView
        var lastPoint: CGPoint?

        init(_ parent: MaskPainterView) { self.parent = parent }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let pt = gesture.location(in: gesture.view)
            DispatchQueue.main.async { self.parent.brushTipPosition = pt }
            draw(from: pt, to: pt)
            // Hide the indicator shortly after a tap
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.parent.brushTipPosition = nil
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let pt = gesture.location(in: gesture.view)
            switch gesture.state {
            case .began:
                lastPoint = pt
                DispatchQueue.main.async { self.parent.brushTipPosition = pt }
                draw(from: pt, to: pt)
            case .changed:
                DispatchQueue.main.async { self.parent.brushTipPosition = pt }
                draw(from: lastPoint ?? pt, to: pt)
                lastPoint = pt
            default:
                lastPoint = nil
                DispatchQueue.main.async { self.parent.brushTipPosition = nil }
            }
        }

        func draw(from: CGPoint, to: CGPoint) {
            let size = parent.viewSize
            guard size.width > 0, size.height > 0 else { return }

            // Create or reuse mask canvas
            let current = parent.mask ?? UIImage.solidColor(.black, size: size)
            UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
            defer { UIGraphicsEndImageContext() }
            current.draw(at: .zero)

            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(parent.brushSize)

            if parent.brushOpacity > 0.5 {
                // Paint white = expose second image in this area
                ctx.setStrokeColor(UIColor.white.withAlphaComponent(CGFloat(parent.brushOpacity)).cgColor)
                ctx.setBlendMode(.normal)
            } else {
                // Erase = reveal first image (paint black)
                ctx.setStrokeColor(UIColor.black.cgColor)
                ctx.setBlendMode(.normal)
            }

            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()

            parent.mask = UIGraphicsGetImageFromCurrentImageContext()
        }
    }
}

struct MaskOverlayView: View {
    @Bindable var camera: CameraManager
    let geoSize: CGSize
    @State private var brushTip: CGPoint? = nil

    var body: some View {
        ZStack {
            // Show current mask as semi-transparent overlay
            if let mask = camera.doubleExposureMask, let cgImage = mask.cgImage {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .blendMode(.screen)
                    .opacity(0.35)
                    .allowsHitTesting(false)
            }

            // Painting canvas
            MaskPainterView(
                mask: $camera.doubleExposureMask,
                brushTipPosition: $brushTip,
                brushSize: camera.maskBrushSize,
                brushOpacity: camera.maskBrushOpacity,
                viewSize: geoSize
            )

            // Live brush-tip indicator — shows the user where they're painting and the
            // size of the brush. Filled tint reflects paint vs erase mode.
            if let pt = brushTip {
                let isErase = camera.maskBrushOpacity < 0.5
                Circle()
                    .stroke(isErase ? Color.red : Color.yellow, lineWidth: 1.5)
                    .background(
                        Circle().fill((isErase ? Color.red : Color.yellow).opacity(0.18))
                    )
                    .frame(width: camera.maskBrushSize, height: camera.maskBrushSize)
                    .position(pt)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.08), value: pt)
            }
        }
    }
}

extension UIImage {
    static func solidColor(_ color: UIColor, size: CGSize) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        color.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }
}

// MARK: - FocusIndicator

struct FocusIndicator: View {
    let position: CGPoint
    @State private var scale: CGFloat = 1.5
    @State private var opacity: Double = 1.0

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 70, height: 70)
            .scaleEffect(scale)
            .opacity(opacity)
            .position(position)
            .onAppear {
                withAnimation(.easeOut(duration: 0.3)) {
                    scale = 1.0
                }
                withAnimation(.easeOut(duration: 1.5).delay(0.5)) {
                    opacity = 0.0
                }
            }
    }
}

// MARK: - Focus Hunting Indicator

/// Small pulsing ring shown while the camera is actively searching for focus.
struct FocusHuntingIndicator: View {
    @State private var pulse: Bool = false

    var body: some View {
        Circle()
            .stroke(Color.yellow.opacity(pulse ? 0.9 : 0.35), lineWidth: 1.5)
            .frame(width: 18, height: 18)
            .scaleEffect(pulse ? 1.15 : 0.9)
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 12)
            .padding(.top, 56)
    }
}

// MARK: - Face Detected Badge

/// Tiny face icon that appears when the camera's face detection has a lock.
struct FaceDetectedBadge: View {
    @State private var visible: Bool = false

    var body: some View {
        Image(systemName: "face.dashed")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.yellow.opacity(0.85))
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeIn(duration: 0.2)) { visible = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 36)
            .padding(.top, 59)
    }
}

// MARK: - ExposureDial

struct ExposureDial: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    // Capture the value at the moment the drag begins so we can apply the
    // TOTAL translation rather than accumulating incremental deltas, which
    // would cause the dial to drift/over-respond across frames.
    @State private var valueAtDragStart: Float = 0
    @State private var isDragging: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.55))
                .frame(width: 72, height: 72)

            // Tick marks
            ForEach(0..<24, id: \.self) { i in
                Circle()
                    .fill(Color.gray.opacity(0.35))
                    .frame(width: 2, height: 2)
                    .offset(y: -31)
                    .rotationEffect(.degrees(Double(i) * 15))
            }

            VStack(spacing: 1) {
                Image(systemName: "sun.min.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text(String(format: "%+.1f", value))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 8)   // raised from 1 so taps aren't swallowed
                .onChanged { gesture in
                    if !isDragging {
                        isDragging = true
                        valueAtDragStart = value
                    }
                    let delta = Float(-gesture.translation.height / 200.0)
                    value = max(range.lowerBound, min(range.upperBound, valueAtDragStart + delta))
                }
                .onEnded { _ in isDragging = false }
        )
    }
}

// MARK: - OpacityDial

struct OpacityDial: View {
    @Binding var value: Double
    let label: String

    @State private var valueAtDragStart: Double = 0
    @State private var isDragging: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.55))
                .frame(width: 60, height: 60)

            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.gray)
                Text("\(Int(value * 100))%")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { gesture in
                    if !isDragging {
                        isDragging = true
                        valueAtDragStart = value
                    }
                    let delta = -gesture.translation.height / 200.0
                    value = max(0, min(1, valueAtDragStart + delta))
                }
                .onEnded { _ in isDragging = false }
        )
    }
}

// MARK: - Focus Peaking

struct FocusPeakingView: UIViewRepresentable {
    let camera: CameraManager

    func makeUIView(context: Context) -> PeakingUIView {
        let view = PeakingUIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.sharedContext = camera.ciContext
        camera.peakingView = view
        return view
    }

    func updateUIView(_ uiView: PeakingUIView, context: Context) {}

    static func dismantleUIView(_ uiView: PeakingUIView, coordinator: ()) {
        // Will be cleared when camera.showPeaking toggled off
    }
}

class PeakingUIView: UIView {
    nonisolated(unsafe) var sharedContext: CIContext?
    private var overlayLayer = CALayer()
    nonisolated(unsafe) var lastPeakingTime: CFTimeInterval = 0
    // Reuse filter instances
    nonisolated(unsafe) var edgesFilter = CIFilter.edges()
    nonisolated(unsafe) var colorMatrixFilter = CIFilter.colorMatrix()

    override init(frame: CGRect) {
        super.init(frame: frame)
        overlayLayer.contentsGravity = .resizeAspectFill
        layer.addSublayer(overlayLayer)
        // Pre-configure static filter params
        edgesFilter.intensity = 5.0
        colorMatrixFilter.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        colorMatrixFilter.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        colorMatrixFilter.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        colorMatrixFilter.aVector = CIVector(x: 1, y: 0, z: 0, w: 0)
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlayLayer.frame = bounds
    }

    nonisolated func processFrame(pixelBuffer: CVPixelBuffer) {
        // Throttle to ~15fps
        let now = CACurrentMediaTime()
        guard now - lastPeakingTime > 0.066 else { return }
        lastPeakingTime = now

        guard let context = sharedContext else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // Downscale for peaking — edges are visible at quarter res
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))

        edgesFilter.inputImage = scaled
        guard let edgeImage = edgesFilter.outputImage else { return }

        colorMatrixFilter.inputImage = edgeImage

        guard let colored = colorMatrixFilter.outputImage,
              let cgImage = context.createCGImage(colored, from: scaled.extent) else { return }

        DispatchQueue.main.async {
            self.overlayLayer.contents = cgImage
        }
    }
}

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



// MARK: - CameraContentView

struct CameraContentView: View {
    @State private var camera = CameraManager()
    @State private var motion = MotionManager()
    @State private var volumeObserver = VolumeButtonObserver()
    @State private var customSimStore = CustomSimStore()
    @State private var focusPoint: CGPoint?
    @State private var showFocusIndicator = false
    @State private var showViewMenu = false
    // showZoomSlider lives on camera so volume callbacks can check it
    @State private var zoomDebounceWork: DispatchWorkItem? = nil
    @State private var isDraggingZoom = false
    @State private var localZoom: Double = 1.0
    @State private var showCustomSimEditor = false
    @State private var showSonyView = false
    @State private var showLUTImporter = false

    /// Film-sim strip category filter. With many custom sims + LUTs the
    /// single horizontal scroll becomes a mess; these chips let you focus
    /// on one source at a time. "All" preserves the original behavior.
    /// Persisted across launches so you stay in whichever view you used last.
    @AppStorage("cc_simCategory") private var simCategoryRaw: String = SimCategory.all.rawValue
    private var simCategory: SimCategory {
        get { SimCategory(rawValue: simCategoryRaw) ?? .all }
    }
    private enum SimCategory: String, CaseIterable, Identifiable {
        case all, builtIn, custom, luts
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:     return "All"
            case .builtIn: return "Built-in"
            case .custom:  return "Custom"
            case .luts:    return "LUTs"
            }
        }
        var icon: String {
            switch self {
            case .all:     return "square.grid.2x2.fill"
            case .builtIn: return "film.fill"      // film reel
            case .custom:  return "wrench.fill"    // wrench for hand-tuned
            case .luts:    return "cube.fill"      // cube for 3D LUT
            }
        }
        var accent: Color {
            switch self {
            case .all:     return .white
            case .builtIn: return .yellow
            case .custom:  return .cyan
            case .luts:    return .orange
            }
        }
    }
    @State private var editingSim: CustomSimulation?
    @State private var sectionOverlaysExpanded = true
    @State private var sectionFilmEffectsExpanded = true
    @State private var sectionShootingExpanded = true
    @State private var sectionDoubleExpExpanded = true
    @State private var sectionQualityExpanded = true
    @State private var shutterPressTimer: Timer? = nil
    @State private var shutterIsHolding = false
    @State private var cleanMode = false
    @State private var recordingLocked = false
    @State private var recordingPendingLock = false
    @State private var startupBlackOpacity: Double = 1.0
    @State private var lockDragOffset: CGFloat = 0

    var body: some View {
        @Bindable var camera = camera
        GeometryReader { geo in
            ZStack {
                // Camera layer
                cameraLayer
                    .ignoresSafeArea()
                    .onTapGesture { location in
                        guard !camera.manualFocusEnabled else { return }
                        focusPoint = location
                        showFocusIndicator = true
                        // Convert to camera coordinates (0...1)
                        let camPoint = CGPoint(
                            x: location.y / geo.size.height,
                            y: 1.0 - location.x / geo.size.width
                        )
                        camera.tapToFocus(at: camPoint)
                        // Auto-hide after 1.8s
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            showFocusIndicator = false
                        }
                    }

                // Aspect ratio overlay
                AspectRatioOverlay(aspectRatio: camera.selectedAspectRatio, geoSize: geo.size, isLandscape: motion.isLandscape)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // Grid
                if camera.showGrid {
                    GridOverlay()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // Level
                if camera.showLevel {
                    LevelOverlay(roll: motion.levelTilt)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // Focus peaking
                if camera.showPeaking {
                    FocusPeakingView(camera: camera)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // Exposure meter — floating top left, fixed size
                ExposureMeterBar(evValue: camera.evReading, bias: camera.exposureBias)
                    .iconRotation(motion.iconAngle)
                    .frame(width: 80, height: 80)
                    .position(x: 56, y: 100)
                    .allowsHitTesting(false)

                // Focus indicator (tap-to-focus square)
                if showFocusIndicator, let pt = focusPoint {
                    FocusIndicator(position: pt)
                        .allowsHitTesting(false)
                }

                // Live AF hunting indicator — pulsing ring at top-left while camera seeks focus
                if camera.isFocusing {
                    FocusHuntingIndicator()
                        .allowsHitTesting(false)
                }

                // Face-detected indicator — small icon when AF is steering toward a face
                if camera.faceDetected && !camera.manualFocusEnabled {
                    FaceDetectedBadge()
                        .allowsHitTesting(false)
                }

                // Save error toast — auto-dismisses
                if let msg = camera.saveErrorMessage {
                    VStack {
                        Spacer()
                        Text(msg)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.85), in: Capsule())
                            .padding(.bottom, 180)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    .allowsHitTesting(false)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            if camera.saveErrorMessage == msg {
                                withAnimation { camera.saveErrorMessage = nil }
                            }
                        }
                    }
                }

                // Controls overlay — full width
                VStack(spacing: 0) {
                    // Top bar — right-aligned content
                    topBar
                        .padding(.top, 60)

                    Spacer()

                    // Bottom controls — full width
                    bottomSection
                }
                .frame(maxWidth: .infinity)

                // Startup fade — hides orientation settle on first frame
                if startupBlackOpacity > 0 {
                    Color.black
                        .ignoresSafeArea()
                        .opacity(startupBlackOpacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .onChange(of: motion.isLandscape) { _, newValue in
            camera.isLandscape = newValue
        }
        .onChange(of: motion.iconAngle) { _, newValue in
            camera.deviceAngle = newValue
        }
        .onChange(of: cleanMode) { _, isClean in
            if isClean && !camera.showZoomSlider {
                camera.showZoomSlider = true
                camera.syncZoomState()
            }
        }
        .onChange(of: camera.zoom) { _, newValue in
            // Volume buttons and presets write camera.zoom — sync to local slider
            if abs(newValue - localZoom) > 0.01 { localZoom = newValue }
        }
        .onChange(of: camera.showZoomSlider) { _, isShown in
            if isShown { localZoom = camera.zoom }
        }
        .onAppear {
            // Fade out startup black so orientation is correct before anything is visible
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.easeOut(duration: 0.3)) { startupBlackOpacity = 0 }
            }
            // Wire WatchConnector to this manager so Watch shutter messages route correctly
            WatchConnector.shared.camera = camera
            WatchConnector.shared.pushState()
            motion.startUpdates()
            let evStep: Float = 0.33
            let opacityStep: Double = 0.1
            let triggerShutter = {
                guard !camera.isCapturing else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if camera.doubleExposureEnabled && camera.firstExposurePreview == nil {
                    camera.captureDoubleExposureFirst()
                } else {
                    camera.capturePhoto()
                }
            }
            volumeObserver.onVolumeUp = {
                // Volume-shutter mode short-circuits everything else
                if camera.volumeShutterEnabled {
                    triggerShutter()
                    return
                }
                let bothActive = camera.showZoomSlider && camera.doubleExposureEnabled
                if camera.showZoomSlider && camera.volumeControlsEV {
                    // EV dial tapped — volume controls exposure
                    let newBias = min(camera.exposureBias + evStep, 3.0)
                    camera.setExposureBias(newBias)
                } else if bothActive && camera.volumeControlsBlend {
                    camera.doubleExposureOpacity = min(camera.doubleExposureOpacity + opacityStep, 1.0)
                } else if camera.showZoomSlider {
                    camera.stepManualZoom(up: true)
                } else if camera.doubleExposureEnabled {
                    camera.doubleExposureOpacity = min(camera.doubleExposureOpacity + opacityStep, 1.0)
                } else {
                    let newBias = min(camera.exposureBias + evStep, 3.0)
                    camera.setExposureBias(newBias)
                }
            }
            volumeObserver.onVolumeDown = {
                if camera.volumeShutterEnabled {
                    triggerShutter()
                    return
                }
                let bothActive = camera.showZoomSlider && camera.doubleExposureEnabled
                if camera.showZoomSlider && camera.volumeControlsEV {
                    let newBias = max(camera.exposureBias - evStep, -3.0)
                    camera.setExposureBias(newBias)
                } else if bothActive && camera.volumeControlsBlend {
                    camera.doubleExposureOpacity = max(camera.doubleExposureOpacity - opacityStep, 0.0)
                } else if camera.showZoomSlider {
                    camera.stepManualZoom(up: false)
                } else if camera.doubleExposureEnabled {
                    camera.doubleExposureOpacity = max(camera.doubleExposureOpacity - opacityStep, 0.0)
                } else {
                    let newBias = max(camera.exposureBias - evStep, -3.0)
                    camera.setExposureBias(newBias)
                }
            }
        }
        .onDisappear {
            motion.stopUpdates()
            shutterPressTimer?.invalidate()
            shutterPressTimer = nil
        }
    }

    // MARK: - Camera Layer

    @ViewBuilder
    private var cameraLayer: some View {
        if camera.isDenied {
            Color.black.overlay {
                VStack(spacing: 10) {
                    Image(systemName: "camera.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Camera access denied")
                        .foregroundStyle(.secondary)
                    Text("Enable in Settings > cam cam")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            CameraPreviewView(session: camera.session, camera: camera)
                .overlay {
                    // Live filtered preview — Metal-rendered, full GPU pipeline
                    // Always present when a sim is selected; Metal view shows nothing if no image
                    if camera.selectedSim != .none || camera.activeCustomSim != nil {
                        MetalFilteredPreview(camera: camera)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    // Overlay first exposure while framing second shot
                    if camera.doubleExposureEnabled, let preview = camera.firstExposurePreview {
                        GeometryReader { geo in
                            Image(decorative: preview, scale: 1.0)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .opacity(camera.doubleExposureOpacity)
                                .allowsHitTesting(false)

                            // Mask painter — only active when mask mode is on
                            if camera.doubleExposureMaskEnabled {
                                MaskOverlayView(camera: camera, geoSize: geo.size)
                            }
                        }
                    }
                }
        }
    }

    // MARK: - Top Bar

    @ViewBuilder private var topBar: some View {
        @Bindable var camera = camera
        ZStack(alignment: .topTrailing) {
            // Tap-outside overlay — dismisses dropdown when visible
            if showViewMenu {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.25)) { showViewMenu = false }
                    }
                    .ignoresSafeArea()
            }
        VStack(alignment: .trailing, spacing: 8) {
            // Top pill row — right-aligned (hidden in clean mode)
            if !cleanMode {
            HStack(spacing: 8) {
                Spacer()

                TopPill(
                    icon: "square.stack",
                    text: camera.doubleExposureEnabled ? "2X" : "1X",
                    isActive: camera.doubleExposureEnabled
                )
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    camera.doubleExposureEnabled.toggle()
                    if !camera.doubleExposureEnabled {
                        camera.firstExposureCIImage = nil
                        camera.firstExposurePreview = nil
                        camera.capturingFirstExposure = false
                        camera.pendingMask = nil
                        camera.doubleExposureMask = nil
                        camera.doubleExposureMaskEnabled = false
                        camera.volumeControlsBlend = false
                    }
                }

                TopPill(
                    text: camera.rawEnabled ? "RAW" : "JPEG",
                    isActive: camera.rawEnabled
                )
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    camera.rawEnabled.toggle()
                }

                TopPill(
                    icon: "timer",
                    text: camera.isLongExposure ? Self.durationLabel(camera.longExposureDuration) : "BULB",
                    isActive: camera.isLongExposure
                )
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    camera.isLongExposure.toggle()
                }

                TopPill(
                    icon: "viewfinder",
                    text: camera.manualFocusEnabled ? "MF" : "AF",
                    isActive: camera.manualFocusEnabled
                )
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    camera.setManualFocusEnabled(!camera.manualFocusEnabled)
                }

            }
            } // end if !cleanMode (top pill row)

            // View options button + dropdown
            HStack(spacing: 6) {
                Spacer()

                // Flash state pill — visible when flash is not off (hidden in clean mode)
                if camera.flashMode != .off && !cleanMode {
                    HStack(spacing: 3) {
                        Image(systemName: camera.flashMode == .auto ? "bolt.badge.automatic" : "bolt.fill")
                            .font(.system(size: 8))
                        Text(camera.flashLabel)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.yellow)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Blend % pill — visible when double exposure is active (hidden in clean mode)
                if camera.doubleExposureEnabled && !cleanMode {
                    let blendIsVolumeTarget = camera.volumeControlsBlend && camera.showZoomSlider && camera.doubleExposureEnabled
                    Button {
                        if camera.showZoomSlider && camera.doubleExposureEnabled {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                camera.volumeControlsBlend.toggle()
                                if camera.volumeControlsBlend { camera.volumeControlsEV = false }
                            }
                        }
                    } label: {
                        Text("BLEND \(Int(camera.doubleExposureOpacity * 100))%")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(blendIsVolumeTarget ? .black : .white)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(blendIsVolumeTarget ? Color.yellow : Color.black.opacity(0.4))
                                    .overlay(Capsule().stroke(blendIsVolumeTarget ? Color.clear : Color.white.opacity(0.3), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Portrait mode pill (hidden in clean mode)
                if camera.portraitModeEnabled && !cleanMode {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill").font(.system(size: 10))
                        Text(String(format: "f/%.1f", camera.portraitFStop))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Capsule().fill(Color.yellow))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Clean mode pill — always visible
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { cleanMode.toggle() }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: cleanMode ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(cleanMode ? .black : .white)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(cleanMode ? Color.white : Color.black.opacity(0.4))
                                .overlay(Capsule().stroke(cleanMode ? Color.clear : Color.white.opacity(0.3), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)

                if !cleanMode {
                // Volume-button shutter toggle — pill next to the dropdown
                Button {
                    camera.volumeShutterEnabled.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: camera.volumeShutterEnabled ? "speaker.wave.2.circle.fill" : "speaker.wave.2.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(camera.volumeShutterEnabled ? .black : .white)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(camera.volumeShutterEnabled ? Color.yellow : Color.black.opacity(0.4))
                                .overlay(Capsule().stroke(camera.volumeShutterEnabled ? Color.clear : Color.white.opacity(0.3), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(duration: 0.25)) { showViewMenu.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                        Text(camera.selectedAspectRatio.label).font(.system(size: 12, weight: .semibold))
                        Image(systemName: showViewMenu ? "chevron.up" : "chevron.down").font(.system(size: 9))
                    }
                    .foregroundStyle(showViewMenu ? .yellow : .white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(showViewMenu ? Color.yellow.opacity(0.2) : Color.black.opacity(0.4))
                            .overlay(Capsule().stroke(showViewMenu ? .yellow : Color.white.opacity(0.3), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                } // end if !cleanMode (dropdown)
            }

            // Dropdown menu
            if showViewMenu {
                ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Aspect ratios
                    HStack(spacing: 6) {
                        ForEach(AspectRatio.allCases) { ratio in
                            let sel = camera.selectedAspectRatio == ratio
                            Button {
                                camera.selectedAspectRatio = ratio
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                Text(ratio.label)
                                    .font(.system(size: 12, weight: sel ? .bold : .regular))
                                    .foregroundStyle(sel ? .black : .white)
                                    .padding(.horizontal, 9).padding(.vertical, 6)
                                    .background(Capsule().fill(sel ? Color.white : Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 10)

                    Divider().background(Color.white.opacity(0.2))

                    // OVERLAYS section
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("OVERLAYS", isExpanded: $sectionOverlaysExpanded, accent: .cyan)
                        if sectionOverlaysExpanded {
                            HStack(spacing: 10) {
                                viewMenuToggle(icon: "grid", title: "Grid", isOn: $camera.showGrid)
                                viewMenuToggle(icon: "level", title: "Level", isOn: $camera.showLevel)
                                viewMenuToggle(icon: "eye", title: "Peaking", isOn: $camera.showPeaking)
                            }
                            .padding(.bottom, 6)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    Divider().background(Color.white.opacity(0.2))

                    // FILM EFFECTS section
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("FILM EFFECTS", isExpanded: $sectionFilmEffectsExpanded, accent: .purple)
                        if sectionFilmEffectsExpanded {
                            HStack(spacing: 8) {
                                // Halation = red bloom around highlights on film stock
                                viewMenuToggle(icon: "drop.fill", title: "Halation",
                                               isOn: $camera.halationEnabled, accent: .red)
                                // Crosstalk = channels bleeding into each other → purple
                                viewMenuToggle(icon: "paintpalette", title: "Crosstalk",
                                               isOn: $camera.crosstalkEnabled, accent: .purple)
                                // Rolloff = highlight shoulder → cool blue
                                viewMenuToggle(icon: "waveform", title: "Rolloff",
                                               isOn: $camera.rolloffEnabled, accent: .blue)
                            }
                            HStack(spacing: 8) {
                                // Anamorphic flares are classic cyan streaks
                                viewMenuToggle(icon: "aqi.medium", title: "Flares",
                                               isOn: $camera.anamorphicFlareEnabled, accent: .cyan)
                                // Light leaks = warm orange exposure
                                viewMenuToggle(icon: "light.beacon.max", title: "Light Leaks",
                                               isOn: $camera.lightArtifactsEnabled, accent: .orange)
                                // Scratches = chemical decay green tint
                                viewMenuToggle(icon: "line.diagonal", title: "Scratches",
                                               isOn: $camera.filmScratchesEnabled, accent: .green)
                            }
                            HStack(spacing: 8) {
                                // Randomize = chaos → pink
                                viewMenuToggle(icon: "dice", title: "Randomize",
                                               isOn: $camera.filmRandomizationEnabled, accent: .pink)
                            }
                            // DigiCam quality — only visible when DigiCam is the
                            // active sim. 5 = crustiest disposable, 20 = clean
                            // mid-2000s compact. Linear interpolation between.
                            if camera.selectedSim == .digiCam {
                                // Magenta accent — distinct from the rest of FILM EFFECTS
                                // (which use red/purple/blue/cyan/green/pink toggles)
                                // and signals "this is a digital glitch control, not film."
                                let digiAccent = Color(red: 1.0, green: 0.32, blue: 0.78)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "camera.aperture")
                                            .font(.system(size: 12))
                                        Text(camera.digiCamQuality < 1
                                             ? "DigiCam Quality: Off"
                                             : "DigiCam Quality: \(Int(camera.digiCamQuality))")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundStyle(camera.digiCamQuality < 1 ? .white.opacity(0.5) : digiAccent)
                                    HStack(spacing: 8) {
                                        Text("Off")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.5))
                                        Slider(
                                            value: Binding(
                                                get: { Double(camera.digiCamQuality) },
                                                set: { camera.digiCamQuality = Float($0) }
                                            ),
                                            in: 0...20,
                                            step: 1
                                        )
                                        .tint(digiAccent)
                                        Text("20")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                }
                                .padding(.vertical, 4)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            // Push / Pull
                            VStack(alignment: .leading, spacing: 6) {
                                let pushPullLabel: String = {
                                    if camera.pushPullAmount == 0 { return "Push / Pull" }
                                    if camera.pushPullAmount > 0 { return "Push +\(String(format: "%.0f", camera.pushPullAmount))" }
                                    return "Pull \(String(format: "%.0f", camera.pushPullAmount))"
                                }()
                                Button {
                                    camera.pushPullEnabled.toggle()
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.up.arrow.down.circle")
                                            .font(.system(size: 12))
                                        Text(pushPullLabel)
                                            .font(.system(size: 12, weight: camera.pushPullEnabled ? .bold : .regular))
                                    }
                                    .foregroundStyle(camera.pushPullEnabled ? .yellow : .white)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(camera.pushPullEnabled ? Color.yellow.opacity(0.2) : Color.white.opacity(0.1)))
                                }
                                .buttonStyle(.plain)
                                if camera.pushPullEnabled {
                                    HStack(spacing: 8) {
                                        Text("Pull")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.5))
                                        Slider(value: $camera.pushPullAmount, in: -2...3, step: 1)
                                            .tint(.yellow)
                                        Text("Push")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            .padding(.bottom, 6)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    Divider().background(Color.white.opacity(0.2))

                    // SHOOTING section
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("SHOOTING", isExpanded: $sectionShootingExpanded, accent: .orange)
                        if sectionShootingExpanded {
                            HStack(spacing: 10) {
                                viewMenuToggle(icon: "bolt.circle", title: "Burst", isOn: $camera.burstMode)

                                // Portrait mode — shown whenever the session supports depth output.
                                // Dimmed (not hidden) when the current lens doesn't produce depth
                                // so the user can see it exists and knows to switch back to the
                                // main camera to use it.
                                if camera.portraitModeAvailable {
                                    viewMenuToggle(icon: "person.fill", title: "Portrait", isOn: $camera.portraitModeEnabled)
                                        .opacity(camera.currentDeviceSupportsDepth ? 1.0 : 0.4)
                                        .allowsHitTesting(camera.currentDeviceSupportsDepth)
                                }

                                // Macro mode — swaps to physical ultrawide for ~2cm focus distance
                                viewMenuToggle(icon: "leaf.fill", title: "Macro", isOn: $camera.macroModeEnabled)
                            }
                            HStack(spacing: 10) {
                                // Lefty mode — moves shutter cluster over to where the EV dial sits
                                viewMenuToggle(icon: "hand.point.left.fill", title: "Lefty", isOn: $camera.shutterOnLeft)
                                // Unified zoom — single virtual triple camera, no preset swaps
                                viewMenuToggle(icon: "rectangle.stack", title: "1-Lens", isOn: $camera.unifiedZoomMode)
                            }

                            Spacer().frame(height: 6)
                        }
                    }

                    // DOUBLE EXPOSURE section (only when active)
                    if camera.doubleExposureEnabled {
                        Divider().background(Color.white.opacity(0.2))
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader("DOUBLE EXPOSURE MASK", isExpanded: $sectionDoubleExpExpanded, accent: .pink)
                            if sectionDoubleExpExpanded {
                                HStack(spacing: 10) {
                                    viewMenuToggle(icon: "paintbrush.fill", title: "Mask Mode", isOn: $camera.doubleExposureMaskEnabled)
                                }
                                if camera.doubleExposureMaskEnabled {
                                    maskBrushControls
                                        .padding(.bottom, 6)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                        }
                    }

                    Divider().background(Color.white.opacity(0.2))

                    // PHOTO QUALITY section
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("PHOTO QUALITY", isExpanded: $sectionQualityExpanded, accent: .mint)
                        if sectionQualityExpanded {
                            HStack(spacing: 6) {
                                ForEach(Array(["Speed", "Balanced", "Max"].enumerated()), id: \.offset) { idx, label in
                                    let sel = camera.photoQuality == idx
                                    Button {
                                        camera.photoQuality = idx
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    } label: {
                                        Text(label)
                                            .font(.system(size: 12, weight: sel ? .bold : .regular))
                                            .foregroundStyle(sel ? .black : .white)
                                            .padding(.horizontal, 9).padding(.vertical, 6)
                                            .background(Capsule().fill(sel ? Color.white : Color.white.opacity(0.12)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    Divider().background(Color.white.opacity(0.2))

                    // Sony camera connector
                    Button {
                        showSonyView = true
                        withAnimation(.spring(duration: 0.25)) { showViewMenu = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "camera.on.rectangle.fill")
                                .font(.system(size: 13))
                            Text("Sony Camera")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Image(systemName: "wifi")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.3))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .foregroundStyle(.yellow)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)

                    Divider().background(Color.white.opacity(0.2))

                    // Custom film editor
                    Button {
                        showCustomSimEditor = true
                        withAnimation(.spring(duration: 0.25)) { showViewMenu = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paintbrush.pointed.fill")
                                .font(.system(size: 13))
                            Text("Custom Films")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(customSimStore.simulations.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .foregroundStyle(.cyan)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                } // end ScrollView content (VStack)
                .frame(maxHeight: 500)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.trailing, 20)
        } // end ZStack
    }

    /// Format a long-exposure duration: whole seconds as "Xs", half-seconds as "X.5s".
    private static func durationLabel(_ s: Double) -> String {
        s.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fs", s)
            : String(format: "%.1fs", s)
    }

    @ViewBuilder
    private var maskBrushControls: some View {
        @Bindable var camera = camera
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Brush Size")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("\(Int(camera.maskBrushSize))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: $camera.maskBrushSize, in: 10...120, step: 5)
                .tint(.white)
            HStack(spacing: 8) {
                Button { camera.maskBrushOpacity = 1.0 } label: {
                    Label("Expose", systemImage: "plus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(camera.maskBrushOpacity > 0.5 ? Color.black : Color.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(camera.maskBrushOpacity > 0.5 ? Color.white : Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                Button { camera.maskBrushOpacity = 0.0 } label: {
                    Label("Erase", systemImage: "minus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(camera.maskBrushOpacity <= 0.5 ? Color.black : Color.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(camera.maskBrushOpacity <= 0.5 ? Color.white : Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    camera.doubleExposureMask = nil
                    camera.pendingMask = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red.opacity(0.9))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Handle a .cube LUT file selected via the fileImporter. Copies it to
    /// the app's LUT directory, validates it parses, creates a CustomSimulation
    /// entry referencing the file, and auto-selects it as the active sim.
    private func handleLUTImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let filename = try LUTManager.shared.importLUT(from: url)
                var sim = CustomSimulation()
                sim.name = filename
                    .replacingOccurrences(of: ".cube", with: "",
                                          options: String.CompareOptions.caseInsensitive)
                    .replacingOccurrences(of: "_", with: " ")
                sim.lutFilename = filename
                customSimStore.simulations.append(sim)
                customSimStore.save()
                customSimStore.activeCustomSimID = sim.id
                camera.activeCustomSim = sim
                camera.selectedSim = .none
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                // Show a brief save-error message if available; otherwise silent fail
                camera.saveErrorMessage = "LUT import failed: \(error.localizedDescription)"
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        case .failure:
            break   // user cancelled the picker
        }
    }

    /// Section-header pill. `accent` colors the title text + chevron so each
    /// section in the View menu reads as visually distinct at a glance —
    /// Display=cyan, Film Effects=purple, Shooting=orange, etc.
    private func sectionHeader(_ title: String, isExpanded: Binding<Bool>, accent: Color = .white) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 6) {
                // Small accent dot before the title — strong visual anchor
                // that survives even with the dim text below.
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.85))
                    .tracking(0.6)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.5))
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 180 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded.wrappedValue)
            }
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
    }

    /// Toggle pill. The `accent` param lets each toggle pick its own active
    /// color — e.g. halation=red (its on-film color), crosstalk=purple,
    /// scratches=green. Inactive state stays neutral white so the active
    /// ones really pop.
    @ViewBuilder
    private func viewMenuToggle(icon: String, title: String, isOn: Binding<Bool>, accent: Color = .yellow) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 12, weight: isOn.wrappedValue ? .bold : .regular))
            }
            .foregroundStyle(isOn.wrappedValue ? accent : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                Capsule().fill(isOn.wrappedValue ? accent.opacity(0.22) : Color.white.opacity(0.1))
            )
            .overlay(
                Capsule().stroke(isOn.wrappedValue ? accent.opacity(0.4) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(spacing: 16) {
            // MF focus slider — hidden in clean mode
            if camera.manualFocusEnabled && !cleanMode {
                HStack(spacing: 6) {
                    Text("Near")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                    Slider(
                        value: Binding(
                            get: { camera.manualFocusValue },
                            set: { camera.setManualFocus($0) }
                        ),
                        in: 0...1
                    )
                    .tint(.yellow)
                    Text("Far")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Zoom slider — hidden in clean mode
            if camera.showZoomSlider && !cleanMode {
                VStack(spacing: 6) {
                    // Show live localZoom during drag (no camera round-trip lag); fall back
                    // to camera.currentMM when idle so it matches the preset readouts exactly.
                    Text("\(isDraggingZoom ? Int(round(26.0 * localZoom)) : camera.currentMM)mm")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.yellow)

                    HStack(spacing: 8) {
                        Text("0.5x")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                        Slider(value: $localZoom, in: 0.5...camera.maxManualZoom) { editing in
                            isDraggingZoom = editing
                            if !editing { camera.zoom = localZoom }
                        }
                        .tint(.yellow)
                        .onChange(of: localZoom) { _, v in
                            if isDraggingZoom { camera.setZoom(CGFloat(v)) }
                        }
                        Text("\(Int(camera.maxManualZoom))x")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Portrait f-stop slider — hidden in clean mode
            if camera.portraitModeEnabled && !cleanMode {
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: "person.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.yellow)
                        Text("APERTURE")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.5))
                        Spacer()
                        Text(String(format: "f/%.1f", camera.portraitFStop))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.yellow)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(camera.portraitFStop) },
                            set: { v in
                                camera.portraitFStop = Float(v)
                                camera.pendingPortraitFStop = Float(v)
                            }
                        ),
                        in: 1.4...16.0,
                        step: 0.1
                    )
                    .tint(.yellow)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.5))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.25), lineWidth: 1))
                )
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Focal length presets
            HStack(spacing: 18) {
                ForEach(Array(focalPresets.enumerated()), id: \.offset) { index, preset in
                    VStack(spacing: 2) {
                        Text("\(preset.mm == 50 && camera.currentMM == 55 ? 55 : preset.mm)")
                            .font(.system(size: 15, weight: camera.selectedFocalIndex == index ? .bold : .semibold, design: .rounded))
                        Text("mm")
                            .font(.system(size: 9))
                    }
                    .iconRotation(motion.iconAngle)
                    .foregroundStyle(camera.selectedFocalIndex == index ? .yellow : .white)
                    .frame(width: 54, height: 54)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.5))
                            .overlay(
                                Circle().stroke(
                                    camera.selectedFocalIndex == index ? Color.yellow : Color.white.opacity(0.3),
                                    lineWidth: camera.selectedFocalIndex == index ? 1.5 : 0.5
                                )
                            )
                    )
                    .onTapGesture(count: 2) {
                        if preset.mm == 50 {
                            let alreadyOnThisLens = camera.selectedFocalIndex == index
                            if alreadyOnThisLens {
                                // Toggle between 50mm and 55mm
                                let target = camera.currentMM == 55 ? 50.0 / 26.0 : 55.0 / 26.0
                                camera.sessionQueue.async {
                                    guard let device = camera.currentDevice else { return }
                                    camera.applyZoom(factor: CGFloat(target), on: device)
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    camera.syncZoomState()
                                }
                            } else {
                                // Switch to this lens first, then go to 55mm
                                camera.selectFocalPreset(index)
                                // Wait for lens swap to complete, then apply 55mm
                                camera.sessionQueue.async {
                                    guard let device = camera.currentDevice else { return }
                                    let factor55 = 55.0 / 26.0
                                    camera.applyZoom(factor: CGFloat(factor55), on: device)
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    camera.syncZoomState()
                                }
                            }
                        } else {
                            camera.selectFocalPreset(index)
                        }
                    }
                    .onTapGesture(count: 1) {
                        camera.selectFocalPreset(index)
                    }
                }

            }

            // Sim category chips + sim strip — hidden in clean mode.
            // The category row is only shown when there are customs/LUTs
            // (otherwise it's just clutter for the built-in-only case).
            if !cleanMode {
                let hasCustomsOrLUTs = !customSimStore.simulations.isEmpty
                let cat = simCategory
                // Partition the custom sims once so the strip doesn't re-walk twice.
                let customSims = customSimStore.simulations.filter { $0.lutFilename == nil }
                let lutSims    = customSimStore.simulations.filter { $0.lutFilename != nil }
                // What goes in the strip for the current category.
                let showBuiltIns = cat == .all || cat == .builtIn
                let showCustoms  = cat == .all || cat == .custom
                let showLUTs     = cat == .all || cat == .luts

                ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // ── Category tabs inline, same pill style as sims below.
                    // Icon + label, accent-colored when active. Followed by a
                    // thin divider so the sims feel like a separate visual
                    // group while still scrolling as one row.
                    if hasCustomsOrLUTs {
                        ForEach(SimCategory.allCases) { c in
                            let isActive = c == cat
                            let count: Int = {
                                switch c {
                                case .all:     return FilmSimulation.allCases.count + customSimStore.simulations.count
                                case .builtIn: return FilmSimulation.allCases.count
                                case .custom:  return customSims.count
                                case .luts:    return lutSims.count
                                }
                            }()
                            if c == .all || count > 0 {
                                Button {
                                    simCategoryRaw = c.rawValue
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: c.icon)
                                            .font(.system(size: 10))
                                        Text(c.label)
                                            .font(.system(size: 13, weight: isActive ? .bold : .regular))
                                    }
                                    .foregroundStyle(isActive ? .black : c.accent)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule().fill(isActive ? c.accent : c.accent.opacity(0.15))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        // Thin divider between tabs and the sims that follow
                        Rectangle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 1, height: 24)
                            .padding(.horizontal, 2)
                    }
                    // Built-in sims
                    if showBuiltIns {
                        ForEach(FilmSimulation.allCases) { sim in
                            let isSelected = camera.selectedSim == sim && customSimStore.activeCustomSimID == nil
                            Button {
                                camera.selectedSim = sim
                                customSimStore.activeCustomSimID = nil
                                camera.activeCustomSim = nil
                            } label: {
                                Text(sim.label)
                                    .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                                    .foregroundStyle(isSelected ? .black : .white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(isSelected ? Color.yellow : Color.white.opacity(0.18)))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Divider — only show in "All" view between built-ins and customs.
                    if cat == .all && hasCustomsOrLUTs {
                        Rectangle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 1, height: 24)
                    }

                    // Custom (param-based) sims
                    if showCustoms {
                        ForEach(customSims) { sim in
                            let isSelected = customSimStore.activeCustomSimID == sim.id
                            Button {
                                customSimStore.activeCustomSimID = sim.id
                                camera.activeCustomSim = sim
                                camera.selectedSim = .none
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "paintbrush.fill")
                                        .font(.system(size: 9))
                                    Text(sim.name)
                                        .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                                }
                                .foregroundStyle(isSelected ? .black : .cyan)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(isSelected ? Color.cyan : Color.cyan.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // LUT-based sims
                    if showLUTs {
                        ForEach(lutSims) { sim in
                            let isSelected = customSimStore.activeCustomSimID == sim.id
                            Button {
                                customSimStore.activeCustomSimID = sim.id
                                camera.activeCustomSim = sim
                                camera.selectedSim = .none
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "cube.fill")
                                        .font(.system(size: 9))
                                    Text(sim.name)
                                        .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                                }
                                .foregroundStyle(isSelected ? .black : .orange)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(isSelected ? Color.orange : Color.orange.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    if let name = sim.lutFilename {
                                        LUTManager.shared.deleteLUT(filename: name)
                                    }
                                    customSimStore.delete(sim)
                                    if customSimStore.activeCustomSimID == sim.id {
                                        camera.activeCustomSim = nil
                                    }
                                } label: {
                                    Label("Delete LUT", systemImage: "trash")
                                }
                            }
                        }
                    }

                    // Create custom sim button — only in All or Custom
                    if cat == .all || cat == .custom {
                        Button {
                            showCustomSimEditor = true
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 18))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }

                    // Import LUT button — only in All or LUTs
                    if cat == .all || cat == .luts {
                        Button {
                            showLUTImporter = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus.square.dashed")
                                    .font(.system(size: 11))
                                Text("LUT")
                                    .font(.system(size: 13))
                            }
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().stroke(Color.orange.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 32)
            }
            .padding(.horizontal, -32)
            .fullScreenCover(isPresented: $showCustomSimEditor) {
                CustomSimEditorView(store: customSimStore, camera: camera)
            }
            .fullScreenCover(isPresented: $showSonyView) {
                SonyView(camera: camera)
                    .preferredColorScheme(.dark)
            }
            .fileImporter(
                isPresented: $showLUTImporter,
                allowedContentTypes: [
                    UTType(filenameExtension: "cube") ?? .data,
                    .data
                ],
                allowsMultipleSelection: false
            ) { result in
                handleLUTImport(result: result)
            }
            } // end if !cleanMode (film sim strip)

            // Grain toggle + slider — hidden in clean mode
            if (camera.selectedSim != .none || customSimStore.activeCustomSimID != nil) && !cleanMode {
                HStack(spacing: 10) {
                    Button {
                        camera.grainEnabled.toggle()
                        // Context-aware requires grain to be on
                        if !camera.grainEnabled { camera.contextAwareGrainEnabled = false }
                    } label: {
                        Image(systemName: camera.grainEnabled ? "circle.grid.3x3.fill" : "circle.grid.3x3")
                            .font(.system(size: 16))
                            .iconRotation(motion.iconAngle)
                            .foregroundStyle(camera.grainEnabled ? .yellow : .white.opacity(0.6))
                    }
                    .buttonStyle(.plain)

                    if camera.grainEnabled {
                        Slider(value: $camera.grainAmount, in: 0...0.5)
                            .tint(.white)
                        Image(systemName: "circle.grid.3x3.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.6))

                        // Context-aware grain button — only active when grain is on.
                        // Repurposed per active sim:
                        //   • DigiCam → "lines" (CCD scanline overlay)
                        //   • Circuit-bent → "wild" (random light/color drift)
                        //   • everything else → context-aware grain (luma-scaled)
                        let isDigiCamActive = camera.selectedSim == .digiCam
                            && customSimStore.activeCustomSimID == nil
                        let ctxIcon: String = {
                            if isDigiCamActive {
                                return camera.contextAwareGrainEnabled ? "lines.measurement.horizontal" : "line.3.horizontal"
                            }
                            return camera.contextAwareGrainEnabled ? "waveform.badge.magnifyingglass" : "waveform"
                        }()
                        Button {
                            camera.contextAwareGrainEnabled.toggle()
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Image(systemName: ctxIcon)
                                .font(.system(size: 14))
                                .iconRotation(motion.iconAngle)
                                .foregroundStyle(camera.contextAwareGrainEnabled ? .yellow : .white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }

            // Long exposure controls — hidden in clean mode
            if camera.isLongExposure && !cleanMode {
                VStack(spacing: 10) {
                    // Mode toggle + duration label
                    HStack(spacing: 8) {
                        ForEach(LongExposureMode.allCases) { mode in
                            let selected = camera.longExposureMode == mode
                            Button {
                                camera.longExposureMode = mode
                            } label: {
                                Text(mode.label)
                                    .font(.system(size: 12, weight: selected ? .bold : .regular))
                                    .foregroundStyle(selected ? .black : .white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(selected ? Color.cyan : Color.white.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Text(String(format: "%.1fs", camera.longExposureDuration))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.cyan)
                    }

                    // Duration slider
                    HStack(spacing: 8) {
                        Text("1s")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                        Slider(value: $camera.longExposureDuration, in: 1...30, step: 0.5)
                            .tint(.cyan)
                        Text("30s")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Shutter row: [EV dial] [flash] | shutter | [opacity dial or spacer]
            shutterRow
                .padding(.bottom, 30)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - Shutter Row

    private var shutterRow: some View {
        ZStack {
            // Shutter button — center by default, leading edge in lefty mode
            shutterButton
                .frame(maxWidth: .infinity, alignment: camera.shutterOnLeft ? .leading : .center)
                .animation(.easeInOut(duration: 0.25), value: camera.shutterOnLeft)

            // Zoom toggle button — sits 72pt right of center in both modes
            // (in lefty mode it ends up to the right of the EV dial which is at center).
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    camera.showZoomSlider.toggle()
                    if camera.showZoomSlider {
                        camera.syncZoomState()
                    } else {
                        camera.volumeControlsBlend = false
                        camera.volumeControlsEV = false
                    }
                }
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 13))
                    .iconRotation(motion.iconAngle)
                    .foregroundStyle(camera.showZoomSlider ? .black : .white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(camera.showZoomSlider ? Color.yellow : Color.white.opacity(0.18))
                            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .offset(x: 72)

            // EV dial — leading edge by default; slides to center in lefty mode
            // (where the shutter used to be).
            let evIsVolumeTarget = camera.volumeControlsEV && camera.showZoomSlider
            ExposureDial(
                value: Binding(
                    get: { camera.exposureBias },
                    set: { camera.setExposureBias($0) }
                ),
                range: -3.0...3.0
            )
            .frame(width: 72, height: 72)
            .overlay(
                Circle()
                    .stroke(Color.yellow, lineWidth: evIsVolumeTarget ? 2 : 0)
                    .frame(width: 74, height: 74)
                    .animation(.easeInOut(duration: 0.15), value: evIsVolumeTarget)
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard camera.showZoomSlider else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        camera.volumeControlsEV.toggle()
                        if camera.volumeControlsEV { camera.volumeControlsBlend = false }
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: camera.shutterOnLeft ? .center : .leading)
            .animation(.easeInOut(duration: 0.25), value: camera.shutterOnLeft)

            // Flash button — sits 72pt left of center in both modes
            // (in lefty mode it ends up to the left of the EV dial which is at center).
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                camera.toggleFlash()
            } label: {
                Image(systemName: camera.flashMode == .off ? "bolt.slash.fill" : (camera.flashMode == .on ? "bolt.fill" : "bolt.badge.automatic"))
                    .font(.system(size: 13))
                    .iconRotation(motion.iconAngle)
                    .foregroundStyle(camera.flashMode == .on ? .black : (camera.flashMode == .auto ? .black : .white))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(camera.flashMode != .off ? Color.yellow : Color.white.opacity(0.18))
                            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .offset(x: -72)

            // Right side: recording lock / timer / flip
            HStack {
                Spacer()
                if camera.isRecording {
                    if shutterIsHolding && !recordingLocked {
                        // Slide-to-lock track
                        HStack(spacing: 6) {
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                                    .frame(width: 52, height: 26)
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 20, height: 20)
                                    .offset(x: 3 + min(lockDragOffset / 65.0 * 29, 29))
                                    .animation(.interactiveSpring(), value: lockDragOffset)
                            }
                            Image(systemName: "lock.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(lockDragOffset > 25 ? 1.0 : 0.4))
                                .animation(.easeOut(duration: 0.1), value: lockDragOffset)
                        }
                        .iconRotation(motion.iconAngle)
                        .frame(width: 72, height: 72)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    } else if recordingLocked {
                        // Locked — show lock icon + tap hint
                        VStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                            Text("tap to stop")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .iconRotation(motion.iconAngle)
                        .frame(width: 72, height: 72)
                        .transition(.opacity)
                    } else {
                        // Timer
                        let totalSecs = Int(camera.recordingDuration)
                        let mins = totalSecs / 60
                        let secs = totalSecs % 60
                        VStack(spacing: 2) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                            Text(String(format: "%d:%02d", mins, secs))
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                        .iconRotation(motion.iconAngle)
                        .frame(width: 72, height: 72)
                    }
                } else if camera.isBursting {
                    VStack(spacing: 2) {
                        Text("\(camera.burstCount)")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(.yellow)
                        Text("shots")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .iconRotation(motion.iconAngle)
                    .frame(width: 72, height: 72)
                } else if !cleanMode {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            camera.flipCamera()
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                            .font(.system(size: 26))
                            .iconRotation(motion.iconAngle)
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.45))
                                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var shutterButton: some View {
        ZStack {
            Circle()
                .stroke(
                    camera.isRecording ? Color.red.opacity(0.8) :
                    camera.burstMode   ? Color.yellow.opacity(0.5) :
                                         Color.white.opacity(0.5),
                    lineWidth: 3
                )
                .frame(width: 84, height: 84)
            RoundedRectangle(cornerRadius: camera.isRecording ? 8 : 35)
                .fill(
                    camera.isRecording  ? Color.red :
                    camera.isBursting   ? Color.yellow :
                    camera.isCapturing  ? Color.gray :
                                          Color.white
                )
                .frame(
                    width:  camera.isRecording ? 28 : 70,
                    height: camera.isRecording ? 28 : 70
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: camera.isRecording)
                .animation(.easeInOut(duration: 0.12), value: camera.isCapturing)
            if camera.isCapturing && !camera.isBursting && !camera.isRecording {
                ProgressView().tint(.white)
            }
            if camera.doubleExposureEnabled && camera.firstExposurePreview != nil && !camera.isRecording {
                Text("2nd")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
            }
            if camera.burstMode && !camera.isBursting && !camera.isRecording {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.black.opacity(0.4))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Track rightward drag during recording to arm lock
                    if camera.isRecording && !recordingLocked {
                        lockDragOffset = max(0, value.translation.width)
                        if lockDragOffset >= 65 && !recordingPendingLock {
                            recordingPendingLock = true
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        }
                        return
                    }
                    if recordingLocked { return }
                    guard shutterPressTimer == nil, !shutterIsHolding else { return }
                    shutterPressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                        shutterIsHolding = true
                        shutterPressTimer = nil
                        if camera.burstMode {
                            camera.startBurst()
                        } else {
                            camera.startRecording()
                        }
                    }
                }
                .onEnded { _ in
                    lockDragOffset = 0
                    // Finger lifted after dragging to lock threshold — commit lock, keep recording
                    if recordingPendingLock {
                        recordingLocked = true
                        recordingPendingLock = false
                        shutterIsHolding = false
                        return
                    }
                    // Tap while locked → stop recording
                    if recordingLocked {
                        camera.stopRecording()
                        recordingLocked = false
                        shutterIsHolding = false
                        shutterPressTimer?.invalidate()
                        shutterPressTimer = nil
                        return
                    }
                    if let t = shutterPressTimer {
                        t.invalidate()
                        shutterPressTimer = nil
                        shutterIsHolding = false
                        guard !camera.isCapturing else { return }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        if camera.doubleExposureEnabled && camera.firstExposurePreview == nil {
                            camera.captureDoubleExposureFirst()
                        } else {
                            camera.capturePhoto()
                        }
                    } else {
                        shutterIsHolding = false
                        if camera.burstMode {
                            camera.stopBurst()
                        } else if camera.isRecording {
                            camera.stopRecording()
                        }
                    }
                }
        )
        .disabled(camera.isCapturing && !camera.burstMode && !camera.isRecording)
    }

}

// MARK: - Top Pill

private struct TopPill: View {
    var icon: String? = nil
    var text: String
    var showChevron: Bool = false
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
            }
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(isActive ? .black : .white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(isActive ? Color.yellow : Color.black.opacity(0.5))
                .overlay(Capsule().stroke(isActive ? Color.yellow : Color.white.opacity(0.25), lineWidth: 1))
        )
        .animation(.easeInOut(duration: 0.18), value: isActive)
    }
}

// MARK: - Custom Sim Editor

// MARK: - Live Filtered Preview for Editor

@Observable final class FilteredPreviewRenderer: NSObject {
    var previewImage: CGImage?
    @ObservationIgnored nonisolated(unsafe) var currentSim: CustomSimulation = CustomSimulation()
    @ObservationIgnored nonisolated(unsafe) var applyCustomSim: ((CIImage, CustomSimulation) -> CIImage)?
    @ObservationIgnored nonisolated(unsafe) var lastFrameTime: CFAbsoluteTime = 0
    @ObservationIgnored nonisolated(unsafe) var sharedContext: CIContext?
    private weak var camera: CameraManager?

    func start(session: AVCaptureSession, camera: CameraManager) {
        self.camera = camera
        self.sharedContext = camera.ciContext
        self.applyCustomSim = { [weak camera] image, sim in
            camera?.applyCustomSim(to: image, sim: sim) ?? image
        }
        // Ensure video data output is available, then register as receiver
        camera.addVideoDataOutputIfNeeded()
        camera.editorPreviewRenderer = self
    }

    func stop() {
        camera?.editorPreviewRenderer = nil
        camera = nil
    }

    /// Called from CameraManager.captureOutput on the video frame queue
    nonisolated func processFrame(pixelBuffer: CVPixelBuffer) {
        // Throttle to ~15fps for editor preview
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFrameTime > 0.066 else { return }
        lastFrameTime = now

        guard let context = sharedContext else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // Downsample for performance — quarter res for editor
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let sim = currentSim
        let filtered = applyCustomSim?(scaled, sim) ?? scaled
        guard let cgImage = context.createCGImage(filtered, from: filtered.extent) else { return }
        DispatchQueue.main.async { self.previewImage = cgImage }
    }
}

struct CustomSimEditorView: View {
    var store: CustomSimStore
    var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var editing: CustomSimulation?
    @State private var showDeleteConfirm = false
    @State private var previewRenderer = FilteredPreviewRenderer()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if store.simulations.isEmpty && editing == nil {
                    emptyState
                } else if let sim = editing {
                    VStack(spacing: 0) {
                        // Live filtered preview
                        livePreview
                            .frame(height: 220)
                            .clipped()

                        SimParameterEditor(sim: Binding(
                            get: { sim },
                            set: {
                                editing = $0
                                previewRenderer.currentSim = $0
                            }
                        ))
                    }
                } else {
                    simList
                }
            }
            .navigationTitle(editing != nil ? "Edit Film" : "Custom Films")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if editing != nil {
                        Button("Back") {
                            if let e = editing {
                                store.update(e)
                            }
                            previewRenderer.stop()
                            editing = nil
                        }
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if editing != nil {
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                    } else {
                        Button {
                            let newSim = store.addNew()
                            editing = newSim
                            startPreview(for: newSim)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20))
                        }
                    }
                }
            }
            .alert("Delete this film?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let e = editing {
                        previewRenderer.stop()
                        store.delete(e)
                        editing = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onDisappear {
                previewRenderer.stop()
            }
        }
    }

    private var livePreview: some View {
        Group {
            if let image = previewRenderer.previewImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black.overlay {
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func startPreview(for sim: CustomSimulation) {
        previewRenderer.currentSim = sim
        previewRenderer.start(session: camera.session, camera: camera)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "paintpalette")
                .font(.system(size: 48))
                .foregroundStyle(.gray)
            Text("No custom films yet")
                .font(.title3)
                .foregroundStyle(.gray)
            Button {
                let newSim = store.addNew()
                editing = newSim
            } label: {
                Label("Create Film", systemImage: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(.yellow))
            }
        }
    }

    private var simList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.simulations) { sim in
                    Button {
                        editing = sim
                        startPreview(for: sim)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sim.name)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(simSummary(sim))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer()
                            if store.activeCustomSimID == sim.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.yellow)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }

    private func simSummary(_ sim: CustomSimulation) -> String {
        var parts: [String] = []
        if sim.temperature < 5500 { parts.append("warm") }
        else if sim.temperature > 7500 { parts.append("cool") }
        if sim.contrast > 1.15 { parts.append("high contrast") }
        if sim.saturation < 0.8 { parts.append("desaturated") }
        else if sim.saturation > 1.3 { parts.append("vivid") }
        if sim.vignetteIntensity > 0.5 { parts.append("vignette") }
        if sim.fadeAmount > 0.03 { parts.append("faded") }
        if sim.bloomIntensity > 0.1 { parts.append("bloom") }
        return parts.isEmpty ? "Neutral" : parts.joined(separator: " \u{00b7} ")
    }
}

// MARK: - Parameter Editor

private struct SimParameterEditor: View {
    @Binding var sim: CustomSimulation

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Name field
                HStack {
                    Text("NAME")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                TextField("Film name", text: $sim.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)

                // Sections
                paramSection("EXPOSURE") {
                    paramSlider("Brightness", value: $sim.brightness, range: -0.1...0.1)
                    paramSlider("Contrast", value: $sim.contrast, range: 0.7...1.5, neutral: 1.0)
                    paramSlider("Saturation", value: $sim.saturation, range: 0.0...2.0, neutral: 1.0)
                }

                paramSection("WHITE BALANCE") {
                    paramSlider("Temperature", value: $sim.temperature, range: 3000...10000, neutral: 6500)
                    paramSlider("Tint", value: $sim.tint, range: -50...50)
                }

                paramSection("TONE CURVE") {
                    paramSlider("Shadow Lift", value: $sim.shadowLift, range: 0...0.15)
                    paramSlider("Midtone", value: $sim.midShift, range: -0.1...0.1)
                    paramSlider("Highlight Roll", value: $sim.highlightRolloff, range: -0.1...0.0)
                    paramSlider("Fade", value: $sim.fadeAmount, range: 0...0.15)
                }

                paramSection("COLOR CHANNELS") {
                    paramSlider("Red", value: $sim.redMult, range: 0.7...1.3, neutral: 1.0, tint: .red)
                    paramSlider("Green", value: $sim.greenMult, range: 0.7...1.3, neutral: 1.0, tint: .green)
                    paramSlider("Blue", value: $sim.blueMult, range: 0.7...1.3, neutral: 1.0, tint: .blue)
                }

                paramSection("COLOR BIAS") {
                    paramSlider("Red Bias", value: $sim.redBias, range: -0.05...0.05, tint: .red)
                    paramSlider("Green Bias", value: $sim.greenBias, range: -0.05...0.05, tint: .green)
                    paramSlider("Blue Bias", value: $sim.blueBias, range: -0.05...0.05, tint: .blue)
                }

                paramSection("EFFECTS") {
                    paramSlider("Vignette", value: $sim.vignetteIntensity, range: 0...2.0)
                    paramSlider("Bloom", value: $sim.bloomIntensity, range: 0...0.5)
                    if sim.bloomIntensity > 0 {
                        paramSlider("Bloom Size", value: $sim.bloomRadius, range: 2...20)
                    }
                    paramSlider("Haze", value: $sim.hazeAmount, range: 0...1.0, tint: .cyan)
                    Divider().background(Color.white.opacity(0.1))
                    paramSlider("Red-Eye", value: $sim.redEyeStrength, range: 0...1.0, tint: .red)
                }

                // Quality picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("CAPTURE QUALITY")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                    HStack(spacing: 6) {
                        ForEach(Array(["Speed", "Balanced", "Max"].enumerated()), id: \.offset) { idx, label in
                            let sel = sim.quality == idx
                            Button {
                                sim.quality = idx
                            } label: {
                                Text(label)
                                    .font(.system(size: 13, weight: sel ? .bold : .regular))
                                    .foregroundStyle(sel ? .black : .white)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(Capsule().fill(sel ? Color.cyan : Color.white.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)

                    Text("Speed is fastest, Max uses Deep Fusion for best detail")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 4)
                }

                // Reset button
                Button {
                    let name = sim.name
                    let id = sim.id
                    sim = CustomSimulation()
                    sim.name = name
                    sim.id = id
                } label: {
                    Text("Reset to Default")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .padding(20)

                Spacer(minLength: 60)
            }
        }
    }

    @ViewBuilder
    private func paramSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.horizontal, 20)
                .padding(.top, 20)

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
            .padding(.horizontal, 16)
        }
    }

    private func paramSlider(
        _ label: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        neutral: Float = 0,
        tint: Color = .yellow
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(formatValue(value.wrappedValue, range: range))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint.opacity(0.8))
            }
            Slider(value: value, in: range)
                .tint(tint)
        }
        .padding(.vertical, 6)
    }

    private func formatValue(_ val: Float, range: ClosedRange<Float>) -> String {
        if range.upperBound > 100 {
            return String(format: "%.0f", val)
        } else if range.upperBound - range.lowerBound < 1 {
            return String(format: "%.3f", val)
        } else {
            return String(format: "%.2f", val)
        }
    }
}
