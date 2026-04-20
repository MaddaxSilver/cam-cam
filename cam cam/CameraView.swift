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
import Combine
import CoreMotion
import MediaPlayer
import MetalKit

// MARK: - Orientation-Aware Icon/Text Rotation

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

    // Quality: 0 = speed, 1 = balanced, 2 = quality (Deep Fusion)
    var quality: Int = 2

    // Effects
    var vignetteIntensity: Float = 0.0 // 0 ... 2.0
    var fadeAmount: Float = 0.0        // 0 ... 0.15 (lifts black point)
    var bloomIntensity: Float = 0.0    // 0 ... 0.5
    var bloomRadius: Float = 8.0       // 2 ... 20
}

// MARK: - Custom Sim Store

final class CustomSimStore: ObservableObject {
    @Published var simulations: [CustomSimulation] = []
    @Published var activeCustomSimID: UUID?

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
    case leica
    case fujiProvia, fujiVelvia, fujiColor200, fujiPro400H, fujiSuperia
    case kodakPortra, kodakGold, kodakUltramax, kodakColorplus, kodakEktar
    case cinestill800T, kodakVision3
    case agfaVista
    case ilfordHP5
    case lomography
    case digiCam
    case nightShot
    case urbanJade

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
        case .agfaVista:      return "Vista"
        case .ilfordHP5:      return "HP5"
        case .lomography:     return "Lomo"
        case .digiCam:        return "DigiCam"
        case .nightShot:      return "Night"
        case .urbanJade:      return "Urban Jade"
        }
    }
}

// MARK: - Focal Preset

nonisolated struct FocalPreset: Sendable {
    let mm: Int
    let deviceType: AVCaptureDevice.DeviceType
    let zoomFactor: CGFloat
}

nonisolated let focalPresets: [FocalPreset] = [
    FocalPreset(mm: 24,  deviceType: .builtInUltraWideCamera, zoomFactor: 1.0),
    FocalPreset(mm: 28,  deviceType: .builtInWideAngleCamera,  zoomFactor: 1.0),
    FocalPreset(mm: 35,  deviceType: .builtInWideAngleCamera,  zoomFactor: 1.3),
    FocalPreset(mm: 50,  deviceType: .builtInWideAngleCamera,  zoomFactor: 1.92),
    FocalPreset(mm: 70,  deviceType: .builtInWideAngleCamera,  zoomFactor: 2.7),
    FocalPreset(mm: 120, deviceType: .builtInTelephotoCamera,  zoomFactor: 1.0),
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

final class CameraManager: NSObject, ObservableObject {

    // MARK: Published properties (MainActor)
    @Published var filteredFrame: CGImage?
    @Published var isAuthorized = false
    @Published var isDenied = false
    @Published var selectedSim: FilmSimulation = .none {
        didSet {
            cachedSim = selectedSim
            UserDefaults.standard.set(selectedSim.rawValue, forKey: "cc_selectedSim")
        }
    }
    @Published var selectedAspectRatio: AspectRatio = .full {
        didSet { UserDefaults.standard.set(selectedAspectRatio.rawValue, forKey: "cc_aspectRatio") }
    }
    @Published var isLandscape: Bool = false
    @Published var deviceAngle: Double = 0
    @Published var grainAmount: Float = 0.0 {
        didSet { UserDefaults.standard.set(grainAmount, forKey: "cc_grainAmount") }
    }
    @Published var grainEnabled: Bool = false {
        didSet { UserDefaults.standard.set(grainEnabled, forKey: "cc_grainEnabled") }
    }
    @Published var exposureBias: Float = 0.0
    @Published var isoValue: Float = 100.0
    @Published var shutterSpeed: Double = 1.0 / 60.0
    @Published var isCapturing = false
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published var focusLocked: Bool = false
    @Published var manualFocusEnabled: Bool = false
    @Published var manualFocusValue: Float = 0.5
    @Published var selectedFocalIndex: Int = 1 {
        didSet { UserDefaults.standard.set(selectedFocalIndex, forKey: "cc_focalIndex") }
    }
    @Published var isLongExposure: Bool = false
    @Published var longExposureMode: LongExposureMode = .frameStack {
        didSet { UserDefaults.standard.set(longExposureMode.rawValue, forKey: "cc_longExposureMode") }
    }
    @Published var longExposureDuration: Double = 2.0 {
        didSet { UserDefaults.standard.set(longExposureDuration, forKey: "cc_longExposureDuration") }
    }
    @Published var doubleExposureEnabled: Bool = false
    @Published var doubleExposureMaskEnabled: Bool = false
    @Published var doubleExposureMask: UIImage? = nil
    @Published var maskBrushSize: CGFloat = 40 {
        didSet { UserDefaults.standard.set(Double(maskBrushSize), forKey: "cc_maskBrushSize") }
    }
    @Published var maskBrushOpacity: Double = 1.0 // 1 = expose more, 0 = erase mask
    @Published var showGrid: Bool = false {
        didSet { UserDefaults.standard.set(showGrid, forKey: "cc_showGrid") }
    }
    @Published var showLevel: Bool = false {
        didSet { UserDefaults.standard.set(showLevel, forKey: "cc_showLevel") }
    }
    @Published var showPeaking: Bool = false {
        didSet { UserDefaults.standard.set(showPeaking, forKey: "cc_showPeaking") }
    }
    @Published var evReading: Float = 0.0
    @Published var crosstalkAmount: Float = 0.1 {
        didSet { UserDefaults.standard.set(crosstalkAmount, forKey: "cc_crosstalkAmount") }
    }
    @Published var crosstalkEnabled: Bool = false {
        didSet { UserDefaults.standard.set(crosstalkEnabled, forKey: "cc_crosstalkEnabled") }
    }
    @Published var halationAmount: Float = 0.2 {
        didSet { UserDefaults.standard.set(halationAmount, forKey: "cc_halationAmount") }
    }
    @Published var halationEnabled: Bool = false {
        didSet { UserDefaults.standard.set(halationEnabled, forKey: "cc_halationEnabled") }
    }
    @Published var rolloffEnabled: Bool = false {
        didSet { UserDefaults.standard.set(rolloffEnabled, forKey: "cc_rolloffEnabled") }
    }
    @Published var rolloffThreshold: Float = 0.9 {
        didSet { UserDefaults.standard.set(rolloffThreshold, forKey: "cc_rolloffThreshold") }
    }
    @Published var rawEnabled: Bool = false {
        didSet { UserDefaults.standard.set(rawEnabled, forKey: "cc_rawEnabled") }
    }
    @Published var doubleExposureOpacity: Double = 0.5
    @Published var firstExposurePreview: CGImage?
    @Published var burstMode: Bool = false {
        didSet { UserDefaults.standard.set(burstMode, forKey: "cc_burstMode") }
    }
    @Published var isBursting: Bool = false
    @Published var burstCount: Int = 0
    @Published var currentZoomFactor: CGFloat = 1.0
    @Published var currentMM: Int = 28
    @Published var isFrontCamera: Bool = false
    @Published var photoQuality: Int = 2 { // 0 speed, 1 balanced, 2 quality
        didSet { UserDefaults.standard.set(photoQuality, forKey: "cc_photoQuality") }
    }
    nonisolated(unsafe) var liveFilteredFrame: CGImage?
    nonisolated(unsafe) var liveFilterActive: Bool = false
    nonisolated(unsafe) var activeCustomSim: CustomSimulation?
    nonisolated(unsafe) var lastFilterFrameTime: CFAbsoluteTime = 0

    // MARK: nonisolated(unsafe) stored properties
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) var sessionQueue = DispatchQueue(label: "cam.session", qos: .userInitiated)
    nonisolated(unsafe) var frameOutputQueue = DispatchQueue(label: "cam.frame.output", qos: .userInteractive)
    // Single shared Metal-backed CIContext for all rendering (preview, capture, peaking)
    nonisolated(unsafe) var ciContext: CIContext = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return CIContext(options: [
                .useSoftwareRenderer: false,
                .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                .outputColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!
            ])
        }
        return CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            .cacheIntermediates: false
        ])
    }()

    // Reusable CIFilter instances — avoid per-frame allocation
    nonisolated(unsafe) var reusableColorControls = CIFilter.colorControls()
    nonisolated(unsafe) var reusableTempTint = CIFilter.temperatureAndTint()
    nonisolated(unsafe) var reusableColorMatrix = CIFilter.colorMatrix()
    nonisolated(unsafe) var reusableToneCurve = CIFilter.toneCurve()
    nonisolated(unsafe) var reusableVignette = CIFilter.vignette()
    nonisolated(unsafe) var photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) var videoDataOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) var frameStack: [CIImage] = []
    nonisolated(unsafe) var frameTimer: Timer?
    nonisolated(unsafe) var isCollectingFrames = false
    nonisolated(unsafe) var pendingSim: FilmSimulation = .none
    nonisolated(unsafe) var pendingGrain: Float = 0.0
    nonisolated(unsafe) var pendingAspectRatio: AspectRatio = .full
    nonisolated(unsafe) var pendingIsLandscape: Bool = false
    nonisolated(unsafe) var pendingDeviceAngle: Double = 0
    nonisolated(unsafe) var pendingGrainEnabled: Bool = false
    nonisolated(unsafe) var pendingISO: Float = 100
    nonisolated(unsafe) var pendingCrosstalk: Float = 0.1
    nonisolated(unsafe) var pendingHalation: Float = 0.2
    nonisolated(unsafe) var pendingRolloff: Float = 0.9
    nonisolated(unsafe) var pendingCrosstalkEnabled: Bool = false
    nonisolated(unsafe) var pendingHalationEnabled: Bool = false
    nonisolated(unsafe) var pendingRolloffEnabled: Bool = false
    nonisolated(unsafe) var pendingDoubleExposureOpacity: Double = 0.5
    nonisolated(unsafe) var pendingMask: UIImage? = nil
    nonisolated(unsafe) var pendingCustomSim: CustomSimulation?
    nonisolated(unsafe) var pendingQuality: AVCapturePhotoOutput.QualityPrioritization = .quality
    nonisolated(unsafe) var pendingLongExposureDuration: Double = 2.0
    nonisolated(unsafe) var cachedSim: FilmSimulation = .none
    nonisolated(unsafe) var processQueue = DispatchQueue(label: "cam.process", qos: .userInitiated)
    nonisolated(unsafe) var photoLibAuthorized = false
    nonisolated(unsafe) var evObservation: NSKeyValueObservation?
    nonisolated(unsafe) var evTimer: Timer?
    nonisolated(unsafe) var firstExposureCIImage: CIImage?
    nonisolated(unsafe) var capturingFirstExposure: Bool = false
    nonisolated(unsafe) var burstActive: Bool = false
    nonisolated(unsafe) var currentDevice: AVCaptureDevice?
    nonisolated(unsafe) weak var editorPreviewRenderer: FilteredPreviewRenderer?
    nonisolated(unsafe) weak var metalPreviewView: MetalFilteredPreviewView?
    nonisolated(unsafe) weak var peakingView: PeakingUIView?
    nonisolated(unsafe) weak var previewLayer: AVCaptureVideoPreviewLayer?
    nonisolated(unsafe) weak var previewUIView: PreviewUIView?

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

    nonisolated func loadSettings() {
        // Read all values synchronously on this thread (UserDefaults is thread-safe for reads)
        let ud = UserDefaults.standard
        let simRaw         = ud.string(forKey: "cc_selectedSim")
        let arRaw          = ud.string(forKey: "cc_aspectRatio")
        let grainEnabled   = ud.object(forKey: "cc_grainEnabled")   != nil ? ud.bool(forKey: "cc_grainEnabled")   : nil as Bool?
        let grainAmount    = ud.object(forKey: "cc_grainAmount")    != nil ? ud.float(forKey: "cc_grainAmount")   : nil as Float?
        let showGrid       = ud.object(forKey: "cc_showGrid")       != nil ? ud.bool(forKey: "cc_showGrid")       : nil as Bool?
        let showLevel      = ud.object(forKey: "cc_showLevel")      != nil ? ud.bool(forKey: "cc_showLevel")      : nil as Bool?
        let showPeaking    = ud.object(forKey: "cc_showPeaking")    != nil ? ud.bool(forKey: "cc_showPeaking")    : nil as Bool?
        let halationOn     = ud.object(forKey: "cc_halationEnabled") != nil ? ud.bool(forKey: "cc_halationEnabled") : nil as Bool?
        let halationAmt    = ud.object(forKey: "cc_halationAmount") != nil ? ud.float(forKey: "cc_halationAmount") : nil as Float?
        let crosstalkOn    = ud.object(forKey: "cc_crosstalkEnabled") != nil ? ud.bool(forKey: "cc_crosstalkEnabled") : nil as Bool?
        let crosstalkAmt   = ud.object(forKey: "cc_crosstalkAmount") != nil ? ud.float(forKey: "cc_crosstalkAmount") : nil as Float?
        let rolloffOn      = ud.object(forKey: "cc_rolloffEnabled") != nil ? ud.bool(forKey: "cc_rolloffEnabled") : nil as Bool?
        let rolloffThresh  = ud.object(forKey: "cc_rolloffThreshold") != nil ? ud.float(forKey: "cc_rolloffThreshold") : nil as Float?
        let rawOn          = ud.object(forKey: "cc_rawEnabled")     != nil ? ud.bool(forKey: "cc_rawEnabled")     : nil as Bool?
        let burstOn        = ud.object(forKey: "cc_burstMode")      != nil ? ud.bool(forKey: "cc_burstMode")      : nil as Bool?
        let quality        = ud.object(forKey: "cc_photoQuality")   != nil ? ud.integer(forKey: "cc_photoQuality") : nil as Int?
        let focalIdx       = ud.object(forKey: "cc_focalIndex")     != nil ? ud.integer(forKey: "cc_focalIndex")  : nil as Int?
        let leRaw          = ud.string(forKey: "cc_longExposureMode")
        let leDur          = ud.object(forKey: "cc_longExposureDuration") != nil ? ud.double(forKey: "cc_longExposureDuration") : nil as Double?
        let brushSize      = ud.object(forKey: "cc_maskBrushSize")  != nil ? ud.double(forKey: "cc_maskBrushSize") : nil as Double?

        DispatchQueue.main.async {
            if let raw = simRaw, let sim = FilmSimulation(rawValue: raw) { self.selectedSim = sim }
            if let raw = arRaw, let ar = AspectRatio(rawValue: raw) { self.selectedAspectRatio = ar }
            if let v = grainEnabled   { self.grainEnabled = v }
            if let v = grainAmount    { self.grainAmount = v }
            if let v = showGrid       { self.showGrid = v }
            if let v = showLevel      { self.showLevel = v }
            if let v = showPeaking    { self.showPeaking = v }
            if let v = halationOn     { self.halationEnabled = v }
            if let v = halationAmt    { self.halationAmount = v }
            if let v = crosstalkOn    { self.crosstalkEnabled = v }
            if let v = crosstalkAmt   { self.crosstalkAmount = v }
            if let v = rolloffOn      { self.rolloffEnabled = v }
            if let v = rolloffThresh  { self.rolloffThreshold = v }
            if let v = rawOn          { self.rawEnabled = v }
            if let v = burstOn        { self.burstMode = v }
            if let v = quality        { self.photoQuality = v }
            if let idx = focalIdx, idx < focalPresets.count { self.selectedFocalIndex = idx }
            if let raw = leRaw, let mode = LongExposureMode(rawValue: raw) { self.longExposureMode = mode }
            if let v = leDur          { self.longExposureDuration = v }
            if let v = brushSize      { self.maskBrushSize = CGFloat(v) }
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

    nonisolated(unsafe) var videoOutputAdded = false

    /// Select the best device format: highest photo resolution while keeping video preview >= 1080p
    /// Must be called while device is locked for configuration
    nonisolated func selectBestFormat(for device: AVCaptureDevice) {
        // Filter to formats with decent video preview (at least 1080p width)
        // then pick the one with the highest photo resolution
        let candidates = device.formats.filter { f in
            let mediaType = CMFormatDescriptionGetMediaType(f.formatDescription)
            guard mediaType == kCMMediaType_Video else { return false }
            let videoDims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return videoDims.width >= 1920
        }
        // Among candidates with good preview, pick highest photo res
        let best = (candidates.isEmpty ? device.formats : candidates)
            .max { a, b in
                let aMax = a.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height })
                let bMax = b.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height })
                let aPixels = Int(aMax?.width ?? 0) * Int(aMax?.height ?? 0)
                let bPixels = Int(bMax?.width ?? 0) * Int(bMax?.height ?? 0)
                return aPixels < bPixels
            }
        guard let best else { return }
        device.activeFormat = best
    }

    nonisolated func configureSession() {
        session.beginConfiguration()
        // Use inputPriority so we can manually select formats (needed for 48MP)
        session.sessionPreset = .inputPriority

        // Default device (wide angle) — use direct lookup for speed
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            session.commitConfiguration()
            return
        }
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
            device.unlockForConfiguration()
        } catch {}

        session.commitConfiguration()

        // Set max photo dimensions AFTER commit
        if let maxDim = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = maxDim
        }
        // Enable max quality and wide color
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = true
        }

        // Start running immediately — don't wait for video data output
        session.startRunning()
        startEVObservation()

        // Defer video data output (only needed for long exposure) to avoid blocking startup
        sessionQueue.async { [self] in
            addVideoDataOutputIfNeeded()
        }
    }

    nonisolated func addVideoDataOutputIfNeeded() {
        guard !videoOutputAdded else { return }
        videoOutputAdded = true
        session.beginConfiguration()
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: frameOutputQueue)
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }
        session.commitConfiguration()
        if let connection = videoDataOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    nonisolated func bestDevice(for preset: FocalPreset) -> AVCaptureDevice? {
        AVCaptureDevice.default(preset.deviceType, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    nonisolated func swapInputDevice(to preset: FocalPreset, animateFromZoom: CGFloat? = nil) {
        // Snapshot current preview on main thread BEFORE the session swap
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

        sessionQueue.async { [self] in
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
                device.unlockForConfiguration()
            } catch {}

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

            // Animate zoom to target smoothly
            if animateFromZoom != nil {
                animateZoom(to: preset.zoomFactor, on: device, duration: 0.6)
            } else {
                applyZoom(factor: preset.zoomFactor, on: device)
            }
            startEVObservation()
        }
    }

    /// Smoothly animate zoom using AVCaptureDevice's ramp API
    nonisolated func animateZoom(to factor: CGFloat, on device: AVCaptureDevice, duration: TimeInterval) {
        do {
            try device.lockForConfiguration()
            let clamped = max(device.minAvailableVideoZoomFactor,
                              min(factor, device.maxAvailableVideoZoomFactor))
            device.ramp(toVideoZoomFactor: clamped, withRate: Float(abs(device.videoZoomFactor - clamped) / CGFloat(duration)))
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
            let position: AVCaptureDevice.Position = goingFront ? .front : .back
            let deviceType: AVCaptureDevice.DeviceType = goingFront ? .builtInWideAngleCamera : (currentDevice?.deviceType ?? .builtInWideAngleCamera)
            guard let device = AVCaptureDevice.default(deviceType, for: .video, position: position)
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else { return }

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
                device.unlockForConfiguration()
            } catch {}

            // Apply rotation and mirror INSIDE config block — no rotation glitch
            for output in session.outputs {
                if let conn = output.connection(with: .video),
                   conn.isVideoRotationAngleSupported(90) {
                    conn.videoRotationAngle = 90
                }
            }
            if let conn = photoOutput.connection(with: .video) {
                conn.isVideoMirrored = goingFront
            }

            session.commitConfiguration()
            videoDataOutput.setSampleBufferDelegate(self, queue: frameOutputQueue)

            let dims = device.activeFormat.supportedMaxPhotoDimensions
            if let maxDim = dims.max(by: { $0.width * $0.height < $1.width * $1.height }), maxDim.width > 0 {
                photoOutput.maxPhotoDimensions = maxDim
            }
            startEVObservation()
        }
    }

    nonisolated func startEVObservation() {
        guard let device = currentDevice else { return }
        evObservation?.invalidate()
        evTimer?.invalidate()

        // Poll ISO + shutter speed to compute scene EV
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let iso = device.iso
            let duration = device.exposureDuration.seconds
            guard duration > 0 else { return }
            // EV = log2(100/ISO) + log2(1/duration) — maps to roughly -3..+3 for typical scenes
            let ev = log2(100.0 / Float(iso)) + log2(Float(1.0 / duration))
            DispatchQueue.main.async { self.evReading = ev }
        }
        RunLoop.main.add(timer, forMode: .common)
        evTimer = timer
    }

    // MARK: Focus and Exposure

    func tapToFocus(at point: CGPoint) {
        guard let device = currentDevice else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    // Use autoFocus first for immediate snap, then switch to continuous
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()

                // After the initial focus snap, switch back to continuous AF
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
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
                    device.setFocusModeLocked(lensPosition: value)
                }
                device.unlockForConfiguration()
            } catch {}
        }
        manualFocusValue = value
    }

    func toggleFlash() {
        switch flashMode {
        case .off:  flashMode = .on
        case .on:   flashMode = .auto
        case .auto: flashMode = .off
        @unknown default: flashMode = .off
        }
    }

    var flashLabel: String {
        switch flashMode {
        case .off:  return "OFF"
        case .on:   return "ON"
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
        isCapturing = true
        pendingSim = selectedSim
        pendingGrain = grainAmount
        pendingAspectRatio = selectedAspectRatio
        pendingIsLandscape = isLandscape
        pendingDeviceAngle = deviceAngle
        pendingGrainEnabled = grainEnabled
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
            // Max quality → full sensor resolution (48MP on Pro), otherwise use default binned
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

    // MARK: Burst Capture

    func startBurst() {
        guard !isBursting else { return }
        isBursting = true
        burstActive = true
        burstCount = 0
        // Snapshot pending values for burst processing
        pendingSim = selectedSim
        pendingCustomSim = activeCustomSim
        pendingGrain = grainAmount
        pendingGrainEnabled = grainEnabled
        pendingAspectRatio = selectedAspectRatio
        pendingIsLandscape = isLandscape
        pendingDeviceAngle = deviceAngle
        pendingCrosstalk = crosstalkAmount
        pendingCrosstalkEnabled = crosstalkEnabled
        pendingHalation = halationAmount
        pendingHalationEnabled = halationEnabled
        pendingRolloff = rolloffThreshold
        pendingRolloffEnabled = rolloffEnabled
        fireBurstShot()
    }

    func stopBurst() {
        isBursting = false
        burstActive = false
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

    /// Fast zoom on current lens only — no device swap, safe to call rapidly from slider
    func setZoomOnCurrentLens(_ factor: CGFloat) {
        guard let device = currentDevice else { return }
        let baseMM: Double = switch device.deviceType {
        case .builtInUltraWideCamera: 13.0
        case .builtInTelephotoCamera: 120.0
        default: 26.0
        }
        let targetMM = 26.0 * Double(factor)
        let deviceZoom = CGFloat(targetMM / baseMM)

        // Deselect focal preset — manual zoom is active
        selectedFocalIndex = -1

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let clamped = max(device.minAvailableVideoZoomFactor,
                                  min(deviceZoom, device.maxAvailableVideoZoomFactor))
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Full zoom with lens swap — debounced, only called when slider pauses
    func setZoom(_ factor: CGFloat) {
        // factor is a "global" zoom: 0.5x = ultrawide, 1x = wide, ~4.6x = telephoto native
        // Convert to target mm
        let targetMM = 26.0 * Double(factor)
        let (bestPreset, deviceZoom) = bestLensForMM(targetMM)

        let needsSwap = currentDevice?.deviceType != bestPreset.deviceType

        if needsSwap {
            // Swap lens then set zoom
            sessionQueue.async { [self] in
                guard let device = bestDevice(for: bestPreset) else { return }
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                guard let newInput = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(newInput) else {
                    session.commitConfiguration()
                    return
                }
                session.addInput(newInput)
                currentDevice = device
                session.commitConfiguration()

                if let maxDim = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width < $1.width }) {
                    photoOutput.maxPhotoDimensions = maxDim
                }
                for output in session.outputs {
                    if let conn = output.connection(with: .video),
                       conn.isVideoRotationAngleSupported(90) {
                        conn.videoRotationAngle = 90
                    }
                }

                applyZoom(factor: CGFloat(deviceZoom), on: device)
                startEVObservation()

                DispatchQueue.main.async {
                    self.currentZoomFactor = factor
                    self.currentMM = Int(round(targetMM))
                }
            }
        } else {
            // Same lens, just adjust zoom
            sessionQueue.async { [self] in
                guard let device = currentDevice else { return }
                applyZoom(factor: CGFloat(deviceZoom), on: device)
                DispatchQueue.main.async {
                    self.currentZoomFactor = factor
                    self.currentMM = Int(round(targetMM))
                }
            }
        }
    }

    /// Pick the best physical lens and compute the device-level zoom factor for a target mm.
    private func bestLensForMM(_ mm: Double) -> (FocalPreset, Double) {
        // Ultra wide: native ~13mm (factor 1x on ultrawide)
        // Wide: native ~26mm (factor 1x on wide)
        // Telephoto: native ~120mm (factor 1x on tele)

        if mm < 26 {
            // Use ultrawide — its native is ~13mm, so zoom = mm / 13
            let zoom = max(1.0, mm / 13.0)
            return (focalPresets[0], zoom)  // ultrawide preset
        }

        // Check if telephoto gives better quality
        // Telephoto is native 120mm. Use it when target >= 90mm (less digital zoom needed)
        let teleAvailable = bestDevice(for: focalPresets[5]) != nil
        if mm >= 90 && teleAvailable {
            let zoom = max(1.0, mm / 120.0)
            return (focalPresets[5], zoom)  // telephoto preset
        }

        // Use wide — native 26mm, zoom = mm / 26
        let zoom = mm / 26.0
        return (focalPresets[1], zoom)  // wide preset
    }

    func syncZoomState() {
        guard let device = currentDevice else { return }
        let deviceZoom = Double(device.videoZoomFactor)
        let baseMM: Double
        switch device.deviceType {
        case .builtInUltraWideCamera: baseMM = 13.0
        case .builtInTelephotoCamera: baseMM = 120.0
        default: baseMM = 26.0
        }
        let mm = baseMM * deviceZoom
        currentMM = Int(round(mm))
        currentZoomFactor = CGFloat(mm / 26.0)  // normalize to wide-equivalent
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
        guard !frameStack.isEmpty else {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }
        let stack = frameStack
        frameStack.removeAll()
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

            let processed = applySimAndGrain(to: ciImage)
            renderAndSave(ciImage: processed, metadata: originalMetadata)
        }
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
                }) { _, _ in
                    try? FileManager.default.removeItem(at: tempURL)
                }
            } catch {}
        }
    }

    nonisolated func cropRect(for extent: CGRect) -> CGRect {
        guard let baseRatio = pendingAspectRatio.ratio else { return extent }
        // In landscape, flip the aspect ratio (e.g. 16:9 portrait → 9:16 landscape output)
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

        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

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

        guard photoLibAuthorized else { return }
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: finalData, options: nil)
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

        // Grain
        if pendingGrainEnabled && pendingGrain > 0 {
            image = addGrain(input: image, amount: pendingGrain)
        }

        // Double exposure compositing
        if let first = firstExposureCIImage {
            image = compositeDoubleExposure(base: first, overlay: image, opacity: Float(pendingDoubleExposureOpacity), mask: pendingMask)
            firstExposureCIImage = nil
            DispatchQueue.main.async { self.firstExposurePreview = nil }
        }

        return image
    }

    nonisolated func applyFilmSim(to image: CIImage) -> CIImage {
        switch pendingSim {
        case .none:
            return image

        case .leica:
            // Leica M: subtle warmth, gentle contrast, slight desaturation for that rangefinder look
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.92
            cc.contrast = 1.08
            cc.brightness = 0.01
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5900, y: 0)
            let curved = toneCurve(input: warm.outputImage ?? image, shadows: -0.02, mid: 0.0, highlights: 0.04)
            return curved

        case .fujiProvia:
            // Provia: balanced, slightly boosted saturation, neutral tones
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.1
            cc.contrast = 1.05
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6600, y: 0)
            return toneCurve(input: temp.outputImage ?? image, shadows: 0.02, mid: 0.0, highlights: -0.02)

        case .fujiVelvia:
            // Velvia: high saturation, deep contrast, vivid
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.4
            cc.contrast = 1.15
            cc.brightness = 0.0
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 6000, y: 0)
            let sharpened = claritySharpen(input: warm.outputImage ?? image)
            return sharpened

        case .fujiColor200:
            // Fuji C200: daylight film, slightly cool, moderate saturation
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.05
            cc.contrast = 1.02
            cc.brightness = 0.01
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 7000, y: 0)
            return toneCurve(input: cool.outputImage ?? image, shadows: 0.03, mid: 0.0, highlights: -0.02)

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
            // Portra: warm skin tones, moderate saturation, smooth highlights
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.95
            cc.contrast = 1.04
            cc.brightness = 0.01
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5800, y: 5)
            return toneCurve(input: warm.outputImage ?? image, shadows: 0.02, mid: 0.0, highlights: -0.02)

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
            // Ultramax 400: punchy, saturated, slightly blue shadows
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.25
            cc.contrast = 1.1
            cc.brightness = 0.0
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 6800, y: -5)
            return toneCurve(input: cool.outputImage ?? image, shadows: 0.04, mid: 0.0, highlights: -0.03)

        case .kodakColorplus:
            // ColorPlus: budget warm film, moderate saturation, warm cast
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.1
            cc.contrast = 1.05
            cc.brightness = 0.01
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5700, y: 5)
            return toneCurve(input: warm.outputImage ?? image, shadows: 0.02, mid: 0.0, highlights: 0.0)

        case .kodakEktar:
            // Ektar 100: extremely saturated, fine grain simulation, deep colors
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.45
            cc.contrast = 1.12
            cc.brightness = -0.01
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 6200, y: 0)
            let sharpened = claritySharpen(input: warm.outputImage ?? image)
            return toneCurve(input: sharpened, shadows: 0.01, mid: 0.0, highlights: -0.04)

        case .digiCam:
            // DigiCam: early 2000s digital look, crushed, low-fi, slightly magenta
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.8
            cc.contrast = 1.2
            cc.brightness = 0.03
            let tint = CIFilter.temperatureAndTint()
            tint.inputImage = cc.outputImage
            tint.neutral = CIVector(x: 6500, y: 0)
            tint.targetNeutral = CIVector(x: 7200, y: 15)
            let crushed = toneCurve(input: tint.outputImage ?? image, shadows: 0.08, mid: 0.0, highlights: -0.06)
            // Reduce resolution feel via slight blur
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = crushed
            blur.radius = 0.5
            return blur.outputImage?.cropped(to: image.extent) ?? crushed

        case .nightShot:
            // Night shot: infrared-ish green cast, blown highlights
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.6
            cc.contrast = 1.3
            cc.brightness = 0.05
            let greenShift = CIFilter.colorMatrix()
            greenShift.inputImage = cc.outputImage
            greenShift.rVector = CIVector(x: 0.7, y: 0.2, z: 0.0, w: 0)
            greenShift.gVector = CIVector(x: 0.1, y: 1.0, z: 0.1, w: 0)
            greenShift.bVector = CIVector(x: 0.0, y: 0.2, z: 0.7, w: 0)
            greenShift.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: greenShift.outputImage ?? image, shadows: 0.06, mid: 0.02, highlights: -0.08)

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
            // Superia 400: warm amber shadows, faded lifted blacks, muted greens, golden cast
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.92
            cc.contrast = 1.1
            cc.brightness = 0.0
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5200, y: -12)
            // Push amber into shadows, mute greens
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.06, y: 0.04, z: 0.0, w: 0)
            matrix.gVector = CIVector(x: 0.02, y: 0.96, z: 0.0, w: 0)
            matrix.bVector = CIVector(x: 0.0, y: 0.0, z: 0.88, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.015, y: 0.008, z: 0.0, w: 0)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.08, mid: 0.02, highlights: -0.03)
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.6
            vignette.radius = 1.2
            return vignette.outputImage ?? curved

        case .cinestill800T:
            // CineStill 800T: strong teal-orange split, neon halation glow, deep blacks
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.2
            cc.contrast = 1.25
            cc.brightness = -0.02
            // Heavy teal shadows / warm orange highlights
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.15, y: 0.0, z: 0.0, w: 0)
            matrix.gVector = CIVector(x: 0.0, y: 0.88, z: 0.08, w: 0)
            matrix.bVector = CIVector(x: 0.0, y: 0.12, z: 1.2, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: -0.01, z: 0.03, w: 0)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.04, mid: -0.01, highlights: -0.06)
            // Warm halation bloom on highlights — the CineStill signature
            let bloom = CIFilter.bloom()
            bloom.inputImage = curved
            bloom.intensity = 0.3
            bloom.radius = 12
            let bloomed = bloom.outputImage?.cropped(to: image.extent) ?? curved
            // Warm the bloom
            let warmBloom = CIFilter.temperatureAndTint()
            warmBloom.inputImage = bloomed
            warmBloom.neutral = CIVector(x: 6500, y: 0)
            warmBloom.targetNeutral = CIVector(x: 5000, y: 0)
            return warmBloom.outputImage ?? bloomed

        case .kodakVision3:
            // Vision3 500T: deep crushed blacks, strong teal shadows, warm neon highlights, cinematic
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.1
            cc.contrast = 1.35
            cc.brightness = -0.04
            // Teal in shadows, preserve warm highlights
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.0, y: 0.0, z: 0.0, w: 0)
            matrix.gVector = CIVector(x: 0.0, y: 0.92, z: 0.06, w: 0)
            matrix.bVector = CIVector(x: 0.0, y: 0.1, z: 1.18, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.0, y: 0.0, z: 0.02, w: 0)
            // Crush blacks hard, soft rolloff on highlights
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.02, mid: -0.02, highlights: -0.06)
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 1.0
            vignette.radius = 1.5
            return vignette.outputImage ?? curved

        case .agfaVista:
            // Agfa Vista: intense golden hour amber, punchy warm contrast, deep rich shadows
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.3
            cc.contrast = 1.18
            cc.brightness = 0.01
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 4800, y: 12)
            // Boost reds/oranges, warm shadows
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.1, y: 0.03, z: 0.0, w: 0)
            matrix.gVector = CIVector(x: 0.0, y: 1.0, z: 0.0, w: 0)
            matrix.bVector = CIVector(x: 0.0, y: 0.0, z: 0.82, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.05, mid: 0.02, highlights: -0.04)
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
        }
    }

    // MARK: Custom Sim Processing

    nonisolated func applyCustomSim(to image: CIImage, sim: CustomSimulation) -> CIImage {
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

        // 7. Vignette
        if sim.vignetteIntensity > 0 {
            let vignette = CIFilter.vignette()
            vignette.inputImage = result
            vignette.intensity = sim.vignetteIntensity
            vignette.radius = 1.5
            result = vignette.outputImage ?? result
        }

        return result
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

    nonisolated func addGrain(input: CIImage, amount: Float) -> CIImage {
        // Generate monochrome noise
        let noise = CIFilter.randomGenerator().outputImage!
        let cropped = noise.cropped(to: input.extent)
        let mono = CIFilter.colorControls()
        mono.inputImage = cropped
        mono.saturation = 0.0
        mono.brightness = -0.5  // Centre noise around mid-grey so it darkens AND lightens
        mono.contrast = 1.0
        guard let grainImage = mono.outputImage else { return input }

        // Blend: mix original with (original + grain) using amount as weight
        // dissolve = original * (1 - amount) + grained * amount
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = grainImage
        blend.backgroundImage = input
        guard let grained = blend.outputImage else { return input }

        // Mix original and grained result by amount (0 = no grain, 0.5 = max grain)
        let mix = CIFilter(name: "CIDissolveTransition", parameters: [
            kCIInputImageKey: grained,
            kCIInputTargetImageKey: input,
            "inputTime": NSNumber(value: 1.0 - amount * 2.0)  // amount 0..0.5 → time 1..0
        ])
        return mix?.outputImage ?? grained
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
            // Mask mode: use painted mask to control blend per-pixel
            // Scale mask to match overlay extent
            var maskCI = CIImage(cgImage: cgMask)
            let msx = targetExtent.width / maskCI.extent.width
            let msy = targetExtent.height / maskCI.extent.height
            maskCI = maskCI.transformed(by: CGAffineTransform(scaleX: msx, y: msy))

            // Apply global opacity on top of per-pixel mask
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

    func selectFocalPreset(_ index: Int) {
        guard index >= 0, index < focalPresets.count else { return }
        let preset = focalPresets[index]
        let previousDevice = currentDevice
        let needsLensSwap = previousDevice?.deviceType != preset.deviceType
        selectedFocalIndex = index

        // No zoom smoothing for 24mm (ultrawide) and 120mm (telephoto) — instant switch
        let isInstantPreset = preset.deviceType == .builtInUltraWideCamera || preset.deviceType == .builtInTelephotoCamera

        if needsLensSwap {
            if isInstantPreset {
                swapInputDevice(to: preset, animateFromZoom: nil)
            } else {
                // Use actual current mm (from zoom state) for accurate FOV matching
                let currentMM = Double(self.currentMM)
                let targetBaseMM: Double = 26.0  // wide lens base
                let startZoom = max(1.0, currentMM / targetBaseMM)
                swapInputDevice(to: preset, animateFromZoom: CGFloat(startZoom))
            }
        } else {
            sessionQueue.async { [self] in
                guard let device = currentDevice else { return }
                if isInstantPreset {
                    self.applyZoom(factor: preset.zoomFactor, on: device)
                } else {
                    self.animateZoom(to: preset.zoomFactor, on: device, duration: 0.3)
                }
            }
        }
        // Sync mm display after animation settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.syncZoomState()
        }
    }

    func captureDoubleExposureFirst() {
        isCapturing = true
        capturingFirstExposure = true
        pendingQuality = effectiveQualityPrioritization
        // Snapshot sim settings for first exposure
        pendingSim = selectedSim
        pendingCustomSim = activeCustomSim
        pendingGrain = grainAmount
        pendingGrainEnabled = grainEnabled
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

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Long exposure frame stacking
        if isCollectingFrames, frameStack.count < 300 {
            frameStack.append(CIImage(cvPixelBuffer: pixelBuffer))
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

        // Downscale for preview — half resolution is plenty for screen display
        let previewScale: CGFloat = 0.5
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: previewScale, y: previewScale))

        // Apply sim to downscaled image
        let filtered: CIImage
        if let customSim {
            filtered = applyCustomSim(to: scaled, sim: customSim)
        } else {
            let prevPending = pendingSim
            pendingSim = cachedSim
            filtered = applyFilmSim(to: scaled)
            pendingSim = prevPending
        }

        if let metal {
            // GPU path — set CIImage directly, trigger draw
            metal.currentImage = filtered
            DispatchQueue.main.async { metal.setNeedsDisplay() }
        } else {
            // Fallback: CGImage path (slower)
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastFilterFrameTime > 0.05 else { return }
            lastFilterFrameTime = now
            guard let cgImage = ciContext.createCGImage(filtered, from: filtered.extent) else { return }
            DispatchQueue.main.async { self.objectWillChange.send(); self.liveFilteredFrame = cgImage }
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
                // Apply film sim to first exposure so both shots match
                let processed = applySimAndGrain(to: oriented)
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

        // For burst mode, process in background and chain next shot immediately
        if burstActive {
            let capturedData = data
            processQueue.async { [self] in
                guard var ciImage = CIImage(data: capturedData) else { return }
                let metadata = ciImage.properties
                ciImage = ciImage.oriented(forExifOrientation: Int32(ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1))
                let processed = applySimAndGrain(to: ciImage)
                renderAndSave(ciImage: processed, metadata: metadata)
            }
            burstDidCapture()
            return
        }

        processAndSaveJPEG(imageData: data)
    }
}

// MARK: - PreviewUIView

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private var observation: NSKeyValueObservation?
    private var snapshotView: UIView?

    func configure(session: AVCaptureSession) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        applyRotation()

        // Re-apply rotation whenever the session's inputs change (i.e. lens swap)
        observation = session.observe(\.inputs, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyRotation() }
        }
    }

    func applyRotation() {
        if let conn = previewLayer.connection,
           conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
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

    deinit { observation?.invalidate() }
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
    private var commandQueue: MTLCommandQueue!
    nonisolated(unsafe) var sharedCIContext: CIContext?
    private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
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
        // Scale image to fill the drawable (aspect fill)
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

final class MotionManager: ObservableObject {
    @Published var roll: Double = 0.0
    @Published var pitch: Double = 0.0
    /// Snapped rotation angle for UI elements: 0, 90, -90, or 180
    @Published var iconAngle: Double = 0.0
    @Published var isLandscape: Bool = false
    nonisolated(unsafe) var motionManager = CMMotionManager()

    func startUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
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
            // In landscape, flip the ratio so the overlay matches the output crop
            let ratio = isLandscape ? (1.0 / baseRatio) : baseRatio
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
            draw(from: pt, to: pt)
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let pt = gesture.location(in: gesture.view)
            switch gesture.state {
            case .began:
                lastPoint = pt
                draw(from: pt, to: pt)
            case .changed:
                draw(from: lastPoint ?? pt, to: pt)
                lastPoint = pt
            default:
                lastPoint = nil
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
    @ObservedObject var camera: CameraManager
    let geoSize: CGSize

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
                brushSize: camera.maskBrushSize,
                brushOpacity: camera.maskBrushOpacity,
                viewSize: geoSize
            )
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

// MARK: - ExposureDial

struct ExposureDial: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    @State private var dragOffset: CGFloat = 0

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
            DragGesture(minimumDistance: 1)
                .onChanged { gesture in
                    let delta = Float(-gesture.translation.height / 200.0)
                    let newVal = max(range.lowerBound, min(range.upperBound, value + delta))
                    value = newVal
                }
        )
    }
}

// MARK: - OpacityDial

struct OpacityDial: View {
    @Binding var value: Double
    let label: String

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
                    let delta = -gesture.translation.height / 200.0
                    let newVal = max(0, min(1, value + delta))
                    value = newVal
                }
        )
    }
}

// MARK: - Focus Peaking

struct FocusPeakingView: UIViewRepresentable {
    let camera: CameraManager

    func makeUIView(context: Context) -> PeakingUIView {
        let view = PeakingUIView()
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

    required init?(coder: NSCoder) { fatalError() }

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

final class VolumeButtonObserver: ObservableObject {
    private var volumeObservation: NSKeyValueObservation?
    private var foregroundObserver: Any?
    private let session = AVAudioSession.sharedInstance()
    private var ignoreNextChange = false
    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?

    // The actual system volume slider from the MPVolumeView in the hierarchy
    weak var systemSlider: UISlider? {
        didSet {
            guard let slider = systemSlider else { return }
            setSystemVolume(0.5, on: slider)
        }
    }

    init() {
        activateSession()
        startObserving()

        // Re-activate audio session when app returns to foreground
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reactivate()
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

    private func activateSession() {
        try? session.setCategory(.playback, options: .mixWithOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
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
                if wentUp {
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
    }
}

// MARK: - Hidden Volume Slider (prevents system HUD)

struct HiddenVolumeSlider: UIViewRepresentable {
    var observer: VolumeButtonObserver

    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        v.alpha = 0.001
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        // Slider may not exist on first layout — check each update
        if observer.systemSlider == nil,
           let slider = uiView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            observer.systemSlider = slider
        }
    }
}

// MARK: - CameraContentView

struct CameraContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var motion = MotionManager()
    @StateObject private var volumeObserver = VolumeButtonObserver()
    @StateObject private var customSimStore = CustomSimStore()
    @State private var focusPoint: CGPoint?
    @State private var showFocusIndicator = false
    @State private var showViewMenu = false
    @State private var showZoomSlider = false
    @State private var zoomSliderValue: Double = 1.0
    @State private var isDraggingZoom = false
    @State private var showCustomSimEditor = false
    @State private var editingSim: CustomSimulation?

    var body: some View {
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
                    LevelOverlay(roll: motion.roll)
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

                // Focus indicator
                if showFocusIndicator, let pt = focusPoint {
                    FocusIndicator(position: pt)
                        .allowsHitTesting(false)
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
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .background { HiddenVolumeSlider(observer: volumeObserver).frame(width: 0, height: 0) }
        .onChange(of: motion.isLandscape) { _, newValue in
            camera.isLandscape = newValue
        }
        .onChange(of: motion.iconAngle) { _, newValue in
            camera.deviceAngle = newValue
        }
        .onAppear {
            motion.startUpdates()
            let evStep: Float = 0.33
            let opacityStep: Double = 0.1
            volumeObserver.onVolumeUp = {
                if camera.doubleExposureEnabled {
                    camera.doubleExposureOpacity = min(camera.doubleExposureOpacity + opacityStep, 1.0)
                } else {
                    let newBias = min(camera.exposureBias + evStep, 3.0)
                    camera.setExposureBias(newBias)
                }
            }
            volumeObserver.onVolumeDown = {
                if camera.doubleExposureEnabled {
                    camera.doubleExposureOpacity = max(camera.doubleExposureOpacity - opacityStep, 0.0)
                } else {
                    let newBias = max(camera.exposureBias - evStep, -3.0)
                    camera.setExposureBias(newBias)
                }
            }
        }
        .onDisappear {
            motion.stopUpdates()
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

    private var topBar: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Top pill row — right-aligned
            HStack(spacing: 8) {
                Spacer()

                TopPill(
                    icon: "square.stack",
                    text: camera.doubleExposureEnabled ? "2X" : "1X"
                )
                .onTapGesture {
                    camera.doubleExposureEnabled.toggle()
                    if !camera.doubleExposureEnabled {
                        camera.firstExposureCIImage = nil
                        camera.firstExposurePreview = nil
                    }
                }

                TopPill(text: camera.rawEnabled ? "RAW" : "JPEG")
                    .onTapGesture {
                        camera.rawEnabled.toggle()
                    }

                TopPill(
                    icon: "timer",
                    text: camera.isLongExposure ? String(format: "%.0fs", camera.longExposureDuration) : "BULB"
                )
                .onTapGesture {
                    camera.isLongExposure.toggle()
                }

                TopPill(
                    icon: "viewfinder",
                    text: camera.manualFocusEnabled ? "MF" : "AF"
                )
                .onTapGesture {
                    camera.manualFocusEnabled.toggle()
                }

            }

            // View options button + dropdown
            HStack {
                Spacer()
                Button {
                    withAnimation(.spring(duration: 0.25)) { showViewMenu.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "aspectratio").font(.system(size: 11))
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

                    // Grid + Level + Peaking
                    HStack(spacing: 10) {
                        viewMenuToggle(icon: "grid", title: "Grid", isOn: $camera.showGrid)
                        viewMenuToggle(icon: "level", title: "Level", isOn: $camera.showLevel)
                        viewMenuToggle(icon: "eye", title: "Peaking", isOn: $camera.showPeaking)
                    }
                    .padding(.vertical, 8)

                    Divider().background(Color.white.opacity(0.2))

                    // Film effects
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FILM EFFECTS")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.top, 4)

                        HStack(spacing: 8) {
                            viewMenuToggle(icon: "drop.fill", title: "Halation", isOn: $camera.halationEnabled)
                            viewMenuToggle(icon: "paintpalette", title: "Crosstalk", isOn: $camera.crosstalkEnabled)
                            viewMenuToggle(icon: "waveform", title: "Rolloff", isOn: $camera.rolloffEnabled)
                        }
                    }

                    Divider().background(Color.white.opacity(0.2))

                    // Shooting mode
                    HStack(spacing: 10) {
                        viewMenuToggle(icon: "bolt.circle", title: "Burst", isOn: $camera.burstMode)
                    }
                    .padding(.vertical, 8)

                    // Double exposure mask controls (only visible when double exposure is active)
                    if camera.doubleExposureEnabled {
                        Divider().background(Color.white.opacity(0.2))

                        VStack(alignment: .leading, spacing: 8) {
                            Text("DOUBLE EXPOSURE MASK")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.top, 4)

                            // Mask mode toggle
                            HStack(spacing: 10) {
                                viewMenuToggle(icon: "paintbrush.fill", title: "Mask Mode", isOn: $camera.doubleExposureMaskEnabled)
                            }

                            if camera.doubleExposureMaskEnabled {
                                // Brush size
                                VStack(alignment: .leading, spacing: 3) {
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
                                }

                                // Paint / Erase toggle
                                HStack(spacing: 8) {
                                    Button {
                                        camera.maskBrushOpacity = 1.0
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "plus.circle.fill").font(.system(size: 12))
                                            Text("Expose").font(.system(size: 12))
                                        }
                                        .foregroundStyle(camera.maskBrushOpacity > 0.5 ? .black : .white)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Capsule().fill(camera.maskBrushOpacity > 0.5 ? Color.white : Color.white.opacity(0.15)))
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        camera.maskBrushOpacity = 0.0
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "minus.circle.fill").font(.system(size: 12))
                                            Text("Erase").font(.system(size: 12))
                                        }
                                        .foregroundStyle(camera.maskBrushOpacity <= 0.5 ? .black : .white)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Capsule().fill(camera.maskBrushOpacity <= 0.5 ? Color.white : Color.white.opacity(0.15)))
                                    }
                                    .buttonStyle(.plain)

                                    Spacer()

                                    // Clear mask
                                    Button {
                                        camera.doubleExposureMask = nil
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "trash").font(.system(size: 12))
                                            Text("Clear").font(.system(size: 12))
                                        }
                                        .foregroundStyle(.red.opacity(0.9))
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Capsule().fill(Color.red.opacity(0.15)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.bottom, 6)
                    }

                    Divider().background(Color.white.opacity(0.2))

                    // Photo quality
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PHOTO QUALITY")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.top, 4)

                        HStack(spacing: 6) {
                            ForEach(Array(["Speed", "Balanced", "Max"].enumerated()), id: \.offset) { idx, label in
                                let sel = camera.photoQuality == idx
                                Button {
                                    camera.photoQuality = idx
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
                    }
                    .padding(.bottom, 8)

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
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.75)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.trailing, 20)
    }

    @ViewBuilder
    private func viewMenuToggle(icon: String, title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 12, weight: isOn.wrappedValue ? .bold : .regular))
            }
            .foregroundStyle(isOn.wrappedValue ? .yellow : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(isOn.wrappedValue ? Color.yellow.opacity(0.2) : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(spacing: 16) {
            // MF toggle + slider row
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        camera.manualFocusEnabled.toggle()
                    }
                } label: {
                    Text("MF")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(camera.manualFocusEnabled ? .black : .white)
                        .frame(width: 38, height: 30)
                        .background(Capsule().fill(camera.manualFocusEnabled ? Color.yellow : Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)

                if camera.manualFocusEnabled {
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
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.horizontal, 8)

            // Zoom slider (iPhone-style, toggleable)
            if showZoomSlider {
                VStack(spacing: 6) {
                    Text("\(Int(round(26.0 * zoomSliderValue)))mm")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.yellow)

                    HStack(spacing: 8) {
                        Text("0.5x")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                        Slider(value: $zoomSliderValue, in: 0.5...10.0)
                            .tint(.yellow)
                            .onChange(of: zoomSliderValue) { _, newValue in
                                camera.setZoomOnCurrentLens(CGFloat(newValue))
                            }
                            .onReceive(Just(zoomSliderValue).debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { value in
                                camera.setZoom(CGFloat(value))
                            }
                        Text("10x")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 8)
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

            // Film simulation scroll
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Built-in sims
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

                    // Divider
                    if !customSimStore.simulations.isEmpty {
                        Rectangle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 1, height: 24)
                    }

                    // Custom sims
                    ForEach(customSimStore.simulations) { sim in
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

                    // Create/edit custom sims button
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
                .padding(.horizontal, 32)
            }
            .padding(.horizontal, -32)
            .fullScreenCover(isPresented: $showCustomSimEditor) {
                CustomSimEditorView(store: customSimStore, camera: camera)
            }

            // Grain toggle + slider (when a sim is active)
            if camera.selectedSim != .none || customSimStore.activeCustomSimID != nil {
                HStack(spacing: 10) {
                    Button {
                        camera.grainEnabled.toggle()
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
                    }
                }
                .padding(.horizontal, 8)
            }

            // Long exposure controls
            if camera.isLongExposure {
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
    }

    // MARK: - Shutter Row

    private var shutterRow: some View {
        ZStack {
            // Shutter button — always centred
            shutterButton

            // Zoom toggle button — right of shutter
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showZoomSlider.toggle()
                    if showZoomSlider {
                        camera.syncZoomState()
                        zoomSliderValue = Double(camera.currentZoomFactor)
                    }
                }
            } label: {
                Image(systemName: "infinity")
                    .font(.system(size: 13))
                    .iconRotation(motion.iconAngle)
                    .foregroundStyle(showZoomSlider ? .black : .white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(showZoomSlider ? Color.yellow : Color.white.opacity(0.18))
                    )
            }
            .buttonStyle(.plain)
            .offset(x: 72)

            // Left side: EV dial + flash
            HStack {
                ExposureDial(
                    value: Binding(
                        get: { camera.exposureBias },
                        set: { camera.setExposureBias($0) }
                    ),
                    range: -3.0...3.0
                )
                .frame(width: 72, height: 72)

                Button {
                    camera.toggleFlash()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: camera.flashMode == .off ? "bolt.slash.fill" : (camera.flashMode == .on ? "bolt.fill" : "bolt.badge.automatic"))
                            .font(.system(size: 16))
                        Text(camera.flashLabel)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .iconRotation(motion.iconAngle)
                    .foregroundStyle(camera.flashMode == .on ? .yellow : (camera.flashMode == .off ? .white.opacity(0.4) : .white))
                    .frame(width: 44, height: 38)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.45))
                            .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)

                Spacer()
            }

            // Right side: flip camera + opacity dial or burst count
            HStack {
                Spacer()
                if camera.doubleExposureEnabled {
                    OpacityDial(
                        value: $camera.doubleExposureOpacity,
                        label: "BLEND"
                    )
                    .frame(width: 72, height: 72)
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
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            camera.flipCamera()
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                            .font(.system(size: 22))
                            .iconRotation(motion.iconAngle)
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 50)
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
        // Burst mode: hold to burst, tap for single
        ZStack {
            Circle()
                .stroke(camera.burstMode ? Color.yellow.opacity(0.5) : Color.white.opacity(0.5), lineWidth: 3)
                .frame(width: 84, height: 84)
            Circle()
                .fill(camera.isBursting ? Color.yellow : (camera.isCapturing ? Color.gray : Color.white))
                .frame(width: 70, height: 70)

            if camera.isCapturing && !camera.isBursting {
                ProgressView()
                    .tint(.white)
            }

            if camera.doubleExposureEnabled && camera.firstExposurePreview != nil {
                Text("2nd")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
            }

            if camera.burstMode && !camera.isBursting {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.black.opacity(0.4))
            }
        }
        .onTapGesture {
            if camera.doubleExposureEnabled && camera.firstExposurePreview == nil {
                camera.captureDoubleExposureFirst()
            } else {
                camera.capturePhoto()
            }
        }
        .onLongPressGesture(minimumDuration: 0.3, pressing: { pressing in
            if camera.burstMode {
                if pressing {
                    camera.startBurst()
                } else {
                    camera.stopBurst()
                }
            }
        }, perform: {})
        .disabled(camera.isCapturing && !camera.burstMode)
    }

}

// MARK: - Top Pill

private struct TopPill: View {
    var icon: String? = nil
    var text: String
    var showChevron: Bool = false

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
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.5))
        .clipShape(Capsule())
    }
}

// MARK: - Custom Sim Editor

// MARK: - Live Filtered Preview for Editor

final class FilteredPreviewRenderer: NSObject, ObservableObject {
    @Published var previewImage: CGImage?
    nonisolated(unsafe) var currentSim: CustomSimulation = CustomSimulation()
    nonisolated(unsafe) var applyCustomSim: ((CIImage, CustomSimulation) -> CIImage)?
    nonisolated(unsafe) var lastFrameTime: CFAbsoluteTime = 0
    nonisolated(unsafe) var sharedContext: CIContext?
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
    @ObservedObject var store: CustomSimStore
    var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var editing: CustomSimulation?
    @State private var showDeleteConfirm = false
    @StateObject private var previewRenderer = FilteredPreviewRenderer()

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
