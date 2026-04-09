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
    @Published var selectedSim: FilmSimulation = .none
    @Published var selectedAspectRatio: AspectRatio = .full
    @Published var grainAmount: Float = 0.0
    @Published var grainEnabled: Bool = false
    @Published var exposureBias: Float = 0.0
    @Published var isoValue: Float = 100.0
    @Published var shutterSpeed: Double = 1.0 / 60.0
    @Published var isCapturing = false
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published var focusLocked: Bool = false
    @Published var manualFocusEnabled: Bool = false
    @Published var manualFocusValue: Float = 0.5
    @Published var selectedFocalIndex: Int = 1
    @Published var isLongExposure: Bool = false
    @Published var longExposureMode: LongExposureMode = .frameStack
    @Published var longExposureDuration: Double = 2.0
    @Published var doubleExposureEnabled: Bool = false
    @Published var showGrid: Bool = false
    @Published var showLevel: Bool = false
    @Published var showPeaking: Bool = false
    @Published var evReading: Float = 0.0
    @Published var crosstalkAmount: Float = 0.1
    @Published var crosstalkEnabled: Bool = false
    @Published var halationAmount: Float = 0.2
    @Published var halationEnabled: Bool = false
    @Published var rolloffEnabled: Bool = false
    @Published var rolloffThreshold: Float = 0.9
    @Published var rawEnabled: Bool = false
    @Published var doubleExposureOpacity: Double = 0.5
    @Published var firstExposurePreview: CGImage?
    @Published var burstMode: Bool = false
    @Published var isBursting: Bool = false
    @Published var burstCount: Int = 0
    @Published var currentZoomFactor: CGFloat = 1.0
    @Published var currentMM: Int = 28

    // MARK: nonisolated(unsafe) stored properties
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) var sessionQueue = DispatchQueue(label: "cam.session", qos: .userInitiated)
    nonisolated(unsafe) var ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!
    ])
    nonisolated(unsafe) var photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) var videoDataOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) var frameStack: [CIImage] = []
    nonisolated(unsafe) var frameTimer: Timer?
    nonisolated(unsafe) var isCollectingFrames = false
    nonisolated(unsafe) var pendingSim: FilmSimulation = .none
    nonisolated(unsafe) var pendingGrain: Float = 0.0
    nonisolated(unsafe) var pendingAspectRatio: AspectRatio = .full
    nonisolated(unsafe) var pendingGrainEnabled: Bool = false
    nonisolated(unsafe) var pendingISO: Float = 100
    nonisolated(unsafe) var pendingCrosstalk: Float = 0.1
    nonisolated(unsafe) var pendingHalation: Float = 0.2
    nonisolated(unsafe) var pendingRolloff: Float = 0.9
    nonisolated(unsafe) var pendingCrosstalkEnabled: Bool = false
    nonisolated(unsafe) var pendingHalationEnabled: Bool = false
    nonisolated(unsafe) var pendingRolloffEnabled: Bool = false
    nonisolated(unsafe) var evObservation: NSKeyValueObservation?
    nonisolated(unsafe) var evTimer: Timer?
    nonisolated(unsafe) var firstExposureCIImage: CIImage?
    nonisolated(unsafe) var capturingFirstExposure: Bool = false
    nonisolated(unsafe) var burstActive: Bool = false
    nonisolated(unsafe) var currentDevice: AVCaptureDevice?

    // MARK: Init

    override nonisolated init() {
        super.init()
        requestPermissionAndStart()
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

    nonisolated func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

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

        session.commitConfiguration()

        // Set max photo dimensions AFTER commit
        if let maxDim = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width < $1.width }) {
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
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "cam.frame.output", qos: .userInteractive))
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

    nonisolated func swapInputDevice(to preset: FocalPreset) {
        sessionQueue.async { [self] in
            guard let device = bestDevice(for: preset) else { return }
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

            // Must be AFTER commitConfiguration — format descriptions reset during config
            if let maxDim = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width < $1.width }) {
                photoOutput.maxPhotoDimensions = maxDim
            }
            if photoOutput.isAppleProRAWSupported {
                photoOutput.isAppleProRAWEnabled = true
            }
            // Re-apply rotation on ALL video connections after input swap
            for output in session.outputs {
                if let conn = output.connection(with: .video),
                   conn.isVideoRotationAngleSupported(90) {
                    conn.videoRotationAngle = 90
                }
            }

            applyZoom(factor: preset.zoomFactor, on: device)
            startEVObservation()
        }
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

    nonisolated func startEVObservation() {
        guard let device = currentDevice else { return }
        evObservation?.invalidate()
        evTimer?.invalidate()

        // Poll ISO + shutter speed to compute scene EV
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
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
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
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

    // MARK: Capture

    func capturePhoto() {
        isCapturing = true
        pendingSim = selectedSim
        pendingGrain = grainAmount
        pendingAspectRatio = selectedAspectRatio
        pendingGrainEnabled = grainEnabled
        pendingISO = isoValue
        pendingCrosstalk = crosstalkAmount
        pendingHalation = halationAmount
        pendingRolloff = rolloffThreshold
        pendingCrosstalkEnabled = crosstalkEnabled
        pendingHalationEnabled = halationEnabled
        pendingRolloffEnabled = rolloffEnabled

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
            // Max quality — full sensor processing pipeline
            settings.photoQualityPrioritization = .quality
            if let maxDim = currentDevice?.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width < $1.width }) {
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
        fireBurstShot()
    }

    func stopBurst() {
        isBursting = false
        burstActive = false
    }

    private nonisolated func fireBurstShot() {
        guard burstActive else { return }
        sessionQueue.async { [self] in
            let settings = AVCapturePhotoSettings(format: [
                AVVideoCodecKey: AVVideoCodecType.jpeg
            ])
            settings.flashMode = .off
            settings.photoQualityPrioritization = .speed
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
        let teleAvailable = bestDevice(for: focalPresets[4]) != nil
        if mm >= 90 && teleAvailable {
            let zoom = max(1.0, mm / 120.0)
            return (focalPresets[4], zoom)  // telephoto preset
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
        let duration = DispatchQueue.main.sync { self.longExposureDuration }
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

        renderAndSave(ciImage: averaged.cropped(to: extent))
    }

    // MARK: Long Exposure - Native

    nonisolated func startNativeExposure() {
        guard let device = currentDevice else {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }
        let duration = DispatchQueue.main.sync { self.longExposureDuration }
        do {
            try device.lockForConfiguration()
            let targetDuration = CMTimeMakeWithSeconds(duration, preferredTimescale: 1000000)
            let maxDuration = device.activeFormat.maxExposureDuration
            let clampedDuration = CMTimeMinimum(targetDuration, maxDuration)
            device.setExposureModeCustom(duration: clampedDuration, iso: device.iso)
            device.unlockForConfiguration()
        } catch {}

        // After the exposure time, take a photo
        let dispatchDuration = duration + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + dispatchDuration) { [weak self] in
            guard let self = self else { return }
            let settings = AVCapturePhotoSettings(format: [
                AVVideoCodecKey: AVVideoCodecType.jpeg
            ])
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: Film Processing & Save

    nonisolated func processAndSaveJPEG(imageData: Data) {
        guard var ciImage = CIImage(data: imageData) else {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }

        // Apply EXIF orientation so the image is upright before processing
        ciImage = ciImage.oriented(forExifOrientation: Int32(ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1))

        let processed = applySimAndGrain(to: ciImage)
        renderAndSave(ciImage: processed)
    }

    nonisolated func saveRAW(data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.isCapturing = false }
                return
            }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("dng")
            do {
                try data.write(to: tempURL)
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCreationRequest.forAsset()
                        .addResource(with: .photo, fileURL: tempURL, options: nil)
                }) { success, error in
                    try? FileManager.default.removeItem(at: tempURL)
                    DispatchQueue.main.async { self.isCapturing = false }
                }
            } catch {
                DispatchQueue.main.async { self.isCapturing = false }
            }
        }
    }

    nonisolated func cropRect(for extent: CGRect) -> CGRect {
        guard let ratio = pendingAspectRatio.ratio else { return extent }
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

    nonisolated func renderAndSave(ciImage: CIImage) {
        let cropped = ciImage.cropped(to: cropRect(for: ciImage.extent))
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

        // Render in Display P3 for wide color gamut
        guard let cgImage = ciContext.createCGImage(cropped, from: cropped.extent, format: .RGBA16, colorSpace: p3) else {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }

        // Save as HEIF (10-bit, P3) when possible, otherwise max quality JPEG in P3
        let imageData: Data?
        let uiImage = UIImage(cgImage: cgImage)
        if let heicData = uiImage.heicData() {
            imageData = heicData
        } else {
            imageData = uiImage.jpegData(compressionQuality: 1.0)
        }

        guard let finalData = imageData else {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.isCapturing = false }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: finalData, options: nil)
            }) { _, _ in
                DispatchQueue.main.async { self.isCapturing = false }
            }
        }
    }

    // MARK: Film Simulation Pipeline

    nonisolated func applySimAndGrain(to input: CIImage) -> CIImage {
        var image = applyFilmSim(to: input)

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
            let opacity = DispatchQueue.main.sync { self.doubleExposureOpacity }
            image = compositeDoubleExposure(base: first, overlay: image, opacity: Float(opacity))
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

        case .fujiSuperia:
            // Superia 400: warm everyday film, green-shifted shadows, slightly muted
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.08
            cc.contrast = 1.06
            cc.brightness = 0.01
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 6000, y: -8)
            return toneCurve(input: warm.outputImage ?? image, shadows: 0.04, mid: 0.0, highlights: -0.02)

        case .cinestill800T:
            // CineStill 800T: tungsten cinema film — teal shadows, warm highlights, halation glow
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.15
            cc.contrast = 1.1
            cc.brightness = 0.0
            // Teal/orange split: cool shadows, warm highlights
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.05, y: 0.0, z: 0.0, w: 0)
            matrix.gVector = CIVector(x: 0.0, y: 0.95, z: 0.05, w: 0)
            matrix.bVector = CIVector(x: 0.0, y: 0.08, z: 1.1, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.05, mid: 0.0, highlights: -0.04)
            // Subtle halation on highlights (warm bloom)
            let bloom = CIFilter.bloom()
            bloom.inputImage = curved
            bloom.intensity = 0.15
            bloom.radius = 8
            return bloom.outputImage?.cropped(to: image.extent) ?? curved

        case .kodakVision3:
            // Kodak Vision3 500T: cinema tungsten, deep shadows, rich midtones, cool blue cast
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.05
            cc.contrast = 1.12
            cc.brightness = -0.01
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 7500, y: -5)
            return toneCurve(input: cool.outputImage ?? image, shadows: 0.06, mid: 0.01, highlights: -0.05)

        case .agfaVista:
            // Agfa Vista 200: warm sunshine film, golden cast, punchy greens
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.2
            cc.contrast = 1.08
            cc.brightness = 0.02
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5400, y: 8)
            return toneCurve(input: warm.outputImage ?? image, shadows: 0.04, mid: 0.01, highlights: -0.02)

        case .ilfordHP5:
            // Ilford HP5 Plus 400: classic B&W, rich tones, visible grain character
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = image
            let cc = CIFilter.colorControls()
            cc.inputImage = mono.outputImage
            cc.contrast = 1.15
            cc.brightness = 0.02
            return toneCurve(input: cc.outputImage ?? image, shadows: 0.03, mid: 0.0, highlights: -0.04)

        case .lomography:
            // Lomography: high saturation, heavy vignette, cross-processed color shift
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.5
            cc.contrast = 1.2
            cc.brightness = 0.02
            // Cross-process shift: boost greens/yellows, shift blues
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.1, y: 0.05, z: 0.0, w: 0)
            matrix.gVector = CIVector(x: 0.0, y: 1.15, z: 0.0, w: 0)
            matrix.bVector = CIVector(x: 0.0, y: 0.0, z: 0.85, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.06, mid: 0.02, highlights: -0.05)
            // Vignette
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 1.2
            vignette.radius = 1.5
            return vignette.outputImage ?? curved
        }
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

    nonisolated func compositeDoubleExposure(base: CIImage, overlay: CIImage, opacity: Float) -> CIImage {
        // Scale base to match overlay extent if they differ
        var scaledBase = base
        let targetExtent = overlay.extent
        if base.extent.size != targetExtent.size {
            let sx = targetExtent.width / base.extent.width
            let sy = targetExtent.height / base.extent.height
            scaledBase = base.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

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
        let needsLensSwap = currentDevice?.deviceType != preset.deviceType
        selectedFocalIndex = index

        if needsLensSwap {
            swapInputDevice(to: preset)
        } else {
            sessionQueue.async { [self] in
                guard let device = currentDevice else { return }
                applyZoom(factor: preset.zoomFactor, on: device)
            }
        }
        // Sync mm display
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.syncZoomState()
        }
    }

    func captureDoubleExposureFirst() {
        isCapturing = true
        capturingFirstExposure = true
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
            settings.photoQualityPrioritization = .quality
            if let maxDim = currentDevice?.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width < $1.width }) {
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
        // Only collect frames for long exposure frame stacking
        guard isCollectingFrames,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Throttle to ~10fps, cap at 300 frames
        if frameStack.count < 300 {
            frameStack.append(CIImage(cvPixelBuffer: pixelBuffer))
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

        // Double exposure first shot — store CIImage, don't save
        if capturingFirstExposure {
            capturingFirstExposure = false
            if let ciImage = CIImage(data: data) {
                let oriented = ciImage.oriented(forExifOrientation: Int32(ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1))
                firstExposureCIImage = oriented
                // Generate preview CGImage for overlay
                let preview = ciContext.createCGImage(oriented, from: oriented.extent)
                DispatchQueue.main.async {
                    self.firstExposurePreview = preview
                    self.isCapturing = false
                }
            } else {
                DispatchQueue.main.async { self.isCapturing = false }
            }
            return
        }

        // For burst mode, save JPEG directly without film processing for speed
        if burstActive {
            saveBurstJPEG(data: data)
            burstDidCapture()
            return
        }

        processAndSaveJPEG(imageData: data)
    }
}

extension CameraManager {
    nonisolated func saveBurstJPEG(data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                request.creationDate = Date()
            }) { _, _ in }
        }
    }
}

// MARK: - PreviewUIView

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private var observation: NSKeyValueObservation?

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

    deinit { observation?.invalidate() }
}

// MARK: - CameraPreviewView

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.configure(session: session)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.applyRotation()
    }
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
    nonisolated(unsafe) var motionManager = CMMotionManager()

    func startUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion = motion else { return }
            self?.roll = motion.attitude.roll * 180.0 / .pi
            self?.pitch = motion.attitude.pitch * 180.0 / .pi
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

    var body: some View {
        if let ratio = aspectRatio.ratio {
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
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PeakingUIView {
        let view = PeakingUIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.setSession(session)
        return view
    }

    func updateUIView(_ uiView: PeakingUIView, context: Context) {}
}

@MainActor
class PeakingUIView: UIView, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var peakingOutput = AVCaptureVideoDataOutput()
    private let peakingQueue = DispatchQueue(label: "cam.peaking", qos: .userInteractive)
    nonisolated(unsafe) var ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!
    ])
    private var overlayLayer = CALayer()

    func setSession(_ session: AVCaptureSession) {
        peakingOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        peakingOutput.alwaysDiscardsLateVideoFrames = true
        peakingOutput.setSampleBufferDelegate(self, queue: peakingQueue)

        session.beginConfiguration()
        if session.canAddOutput(peakingOutput) {
            session.addOutput(peakingOutput)
            if let connection = peakingOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
        session.commitConfiguration()

        overlayLayer.frame = bounds
        overlayLayer.contentsGravity = .resizeAspectFill
        layer.addSublayer(overlayLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlayLayer.frame = bounds
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Edge detection for peaking
        let edges = CIFilter.edges()
        edges.inputImage = ciImage
        edges.intensity = 5.0
        guard let edgeImage = edges.outputImage else { return }

        // Color the edges red
        let colorMatrix = CIFilter.colorMatrix()
        colorMatrix.inputImage = edgeImage
        colorMatrix.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        colorMatrix.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        colorMatrix.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        colorMatrix.aVector = CIVector(x: 1, y: 0, z: 0, w: 0)

        guard let colored = colorMatrix.outputImage,
              let cgImage = ciContext.createCGImage(colored, from: ciImage.extent) else { return }

        DispatchQueue.main.async {
            self.overlayLayer.contents = cgImage
        }
    }
}

// MARK: - Volume Button EV Observer

final class VolumeButtonObserver: ObservableObject {
    private var volumeObservation: NSKeyValueObservation?
    private var lastVolume: Float = -1
    private let session = AVAudioSession.sharedInstance()
    private var isResetting = false
    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    // Held reference to the volume slider from the actual view hierarchy
    weak var volumeSlider: UISlider?

    init() {
        try? session.setActive(true)
        lastVolume = session.outputVolume

        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self, let newVolume = change.newValue else { return }
            // Ignore KVO callbacks from our own reset
            guard !self.isResetting else { return }
            let prev = self.lastVolume
            guard prev >= 0 else {
                self.lastVolume = newVolume
                return
            }
            // Detect direction before resetting
            let wentUp = newVolume > prev
            let wentDown = newVolume < prev
            DispatchQueue.main.async {
                if wentUp {
                    self.onVolumeUp?()
                } else if wentDown {
                    self.onVolumeDown?()
                }
                // Reset volume to midpoint so buttons always work
                self.resetVolumeToMidpoint()
            }
        }
    }

    func resetVolumeToMidpoint() {
        isResetting = true
        volumeSlider?.value = 0.5
        lastVolume = 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.isResetting = false
        }
    }

    deinit {
        volumeObservation?.invalidate()
    }
}

// MARK: - Hidden Volume Slider (prevents system HUD)

struct HiddenVolumeSlider: UIViewRepresentable {
    var observer: VolumeButtonObserver

    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.alpha = 0.001
        // Find the UISlider inside MPVolumeView and hand it to the observer
        DispatchQueue.main.async {
            if let slider = v.subviews.first(where: { $0 is UISlider }) as? UISlider {
                observer.volumeSlider = slider
                slider.value = 0.5
                observer.resetVolumeToMidpoint()
            }
        }
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - CameraContentView

struct CameraContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var motion = MotionManager()
    @StateObject private var volumeObserver = VolumeButtonObserver()
    @State private var focusPoint: CGPoint?
    @State private var showFocusIndicator = false
    @State private var showViewMenu = false
    @State private var showZoomSlider = false
    @State private var zoomSliderValue: Double = 1.0
    @State private var isDraggingZoom = false

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
                AspectRatioOverlay(aspectRatio: camera.selectedAspectRatio, geoSize: geo.size)
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
                    FocusPeakingView(session: camera.session)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // Exposure meter — floating top left, fixed size
                ExposureMeterBar(evValue: camera.evReading, bias: camera.exposureBias)
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
        .onAppear {
            motion.startUpdates()
            let step: Float = 0.33
            volumeObserver.onVolumeUp = {
                let newBias = min(camera.exposureBias + step, 3.0)
                camera.setExposureBias(newBias)
            }
            volumeObserver.onVolumeDown = {
                let newBias = max(camera.exposureBias - step, -3.0)
                camera.setExposureBias(newBias)
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
            CameraPreviewView(session: camera.session)
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
                }
                .padding(.horizontal, 12)
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
                                // Only adjust zoom on current lens while dragging (fast)
                                camera.setZoomOnCurrentLens(CGFloat(newValue))
                            }
                            .onReceive(Just(zoomSliderValue).debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { value in
                                // Swap lens if needed after user pauses
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

            // Focal length presets + zoom toggle
            HStack(spacing: 18) {
                ForEach(Array(focalPresets.enumerated()), id: \.offset) { index, preset in
                    Button {
                        camera.selectFocalPreset(index)
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(preset.mm)")
                                .font(.system(size: 15, weight: camera.selectedFocalIndex == index ? .bold : .semibold, design: .rounded))
                            Text("mm")
                                .font(.system(size: 9))
                        }
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
                    }
                    .buttonStyle(.plain)
                }

                // Zoom toggle button
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
                        .font(.system(size: 14))
                        .foregroundStyle(showZoomSlider ? .black : .white)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(showZoomSlider ? Color.yellow : Color.white.opacity(0.18))
                        )
                }
                .buttonStyle(.plain)
            }

            // Film simulation scroll
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilmSimulation.allCases) { sim in
                        let isSelected = camera.selectedSim == sim
                        Button {
                            camera.selectedSim = sim
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
                .padding(.horizontal, 32)
            }
            .padding(.horizontal, -32)

            // Grain toggle + slider (when a sim is active)
            if camera.selectedSim != .none {
                HStack(spacing: 10) {
                    Button {
                        camera.grainEnabled.toggle()
                    } label: {
                        Image(systemName: camera.grainEnabled ? "circle.grid.3x3.fill" : "circle.grid.3x3")
                            .font(.system(size: 16))
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

            // Right side: opacity dial or burst count
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
                    .frame(width: 72, height: 72)
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
