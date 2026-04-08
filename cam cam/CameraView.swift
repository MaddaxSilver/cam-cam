//
//  CameraView.swift
//  cam cam
//
//  Complete camera implementation: types, CameraManager, and all UI views.

import SwiftUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import Combine
import CoreMotion

// MARK: - Film Simulation Enum

nonisolated enum FilmSimulation: String, CaseIterable, Identifiable, Sendable {
    case none
    case leica
    case fujiProvia, fujiVelvia, fujiColor200, fujiPro400H
    case kodakPortra, kodakGold, kodakUltramax, kodakColorplus, kodakEktar
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
        case .kodakPortra:    return "Portra"
        case .kodakGold:      return "Gold"
        case .kodakUltramax:  return "Ultramax"
        case .kodakColorplus: return "ColorPlus"
        case .kodakEktar:     return "Ektar"
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

    // MARK: nonisolated(unsafe) stored properties
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) var sessionQueue = DispatchQueue(label: "cam.session", qos: .userInitiated)
    nonisolated(unsafe) var ciContext = CIContext(options: [.useSoftwareRenderer: false])
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

    nonisolated func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        // Default device (wide angle)
        guard let device = bestDevice(for: focalPresets[1]) else {
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

        // Photo output
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoDimensions = device.activeFormat.supportedMaxPhotoDimensions.last ?? CMVideoDimensions(width: 4032, height: 3024)
        }

        // Video data output for live preview processing
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "cam.frame.output", qos: .userInteractive))
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            if let connection = videoDataOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }

        session.commitConfiguration()
        session.startRunning()
        startEVObservation()
    }

    nonisolated func bestDevice(for preset: FocalPreset) -> AVCaptureDevice? {
        AVCaptureDevice.default(preset.deviceType, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    nonisolated func swapInputDevice(to preset: FocalPreset) {
        sessionQueue.async { [self] in
            guard let device = bestDevice(for: preset) else { return }
            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            guard let newInput = try? AVCaptureDeviceInput(device: device) else {
                session.commitConfiguration()
                return
            }
            if session.canAddInput(newInput) {
                session.addInput(newInput)
            }
            session.commitConfiguration()
            currentDevice = device
            applyZoom(factor: preset.zoomFactor, on: device)
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
        evObservation = device.observe(\.iso, options: [.new]) { [weak self] dev, _ in
            let iso = dev.iso
            let duration = dev.exposureDuration.seconds
            guard duration > 0 else { return }
            let ev = log2(100.0 / Float(iso)) + log2(Float(1.0 / duration))
            DispatchQueue.main.async {
                self?.evReading = ev
            }
        }
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

        let settings: AVCapturePhotoSettings
        if rawEnabled, let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        } else {
            settings = AVCapturePhotoSettings(format: [
                AVVideoCodecKey: AVVideoCodecType.jpeg
            ])
        }
        if photoOutput.supportedFlashModes.contains(flashMode) {
            settings.flashMode = flashMode
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
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
        guard let ciImage = CIImage(data: imageData) else {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }

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
        guard let cgImage = ciContext.createCGImage(cropped, from: cropped.extent) else {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.95) else {
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
                request.addResource(with: .photo, data: jpegData, options: nil)
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
        let noise = CIFilter.randomGenerator().outputImage!
        let scaled = noise.cropped(to: input.extent)
        let mono = CIFilter.colorControls()
        mono.inputImage = scaled
        mono.saturation = 0.0
        mono.brightness = 0.0
        mono.contrast = 1.0
        let blend = CIFilter.overlayBlendMode()
        blend.inputImage = mono.outputImage
        blend.backgroundImage = input
        let opacity = CIFilter.colorMatrix()
        opacity.inputImage = blend.outputImage
        opacity.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount))
        return opacity.outputImage ?? input
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
        let opacityFilter = CIFilter.colorMatrix()
        opacityFilter.inputImage = overlay
        opacityFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        let adjusted = opacityFilter.outputImage ?? overlay
        let blend = CIFilter.screenBlendMode()
        blend.inputImage = adjusted
        blend.backgroundImage = base
        return blend.outputImage ?? base
    }

    func selectFocalPreset(_ index: Int) {
        guard index >= 0, index < focalPresets.count else { return }
        selectedFocalIndex = index
        swapInputDevice(to: focalPresets[index])
    }

    func captureDoubleExposureFirst() {
        // Store current frame as first exposure
        if let frame = filteredFrame {
            let ci = CIImage(cgImage: frame)
            firstExposureCIImage = ci
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
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Collect frames for frame stacking if active
        if isCollectingFrames {
            frameStack.append(ciImage)
        }

        // Apply live preview sim
        let sim = DispatchQueue.main.sync { self.selectedSim }
        pendingSim = sim
        let grainOn = DispatchQueue.main.sync { self.grainEnabled }
        let grain = DispatchQueue.main.sync { self.grainAmount }
        pendingGrainEnabled = grainOn
        pendingGrain = grain
        pendingCrosstalkEnabled = DispatchQueue.main.sync { self.crosstalkEnabled }
        pendingCrosstalk = DispatchQueue.main.sync { self.crosstalkAmount }
        pendingHalationEnabled = DispatchQueue.main.sync { self.halationEnabled }
        pendingHalation = DispatchQueue.main.sync { self.halationAmount }
        pendingRolloffEnabled = DispatchQueue.main.sync { self.rolloffEnabled }
        pendingRolloff = DispatchQueue.main.sync { self.rolloffThreshold }

        ciImage = applyFilmSim(to: ciImage)

        if pendingCrosstalkEnabled {
            ciImage = applyColorCrosstalk(input: ciImage, amount: pendingCrosstalk)
        }
        if pendingHalationEnabled {
            ciImage = applyHalation(input: ciImage, amount: pendingHalation)
        }
        if pendingRolloffEnabled {
            ciImage = applyHighlightRolloff(input: ciImage, threshold: pendingRolloff)
        }
        if pendingGrainEnabled && pendingGrain > 0 {
            ciImage = addGrain(input: ciImage, amount: pendingGrain)
        }

        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        DispatchQueue.main.async {
            self.filteredFrame = cgImage
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
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }

        // Check if RAW
        if photo.isRawPhoto, let data = photo.fileDataRepresentation() {
            saveRAW(data: data)
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }
        processAndSaveJPEG(imageData: data)
    }
}

// MARK: - PreviewUIView

@MainActor
class PreviewUIView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer?

    func setSession(_ session: AVCaptureSession) {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

// MARK: - CameraPreviewView

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.setSession(session)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

// MARK: - ExposureMeterBar

struct ExposureMeterBar: View {
    let evValue: Float
    let bias: Float

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let centerX = width / 2.0
            let centerY = height / 2.0
            let radius = min(width, height) * 0.4

            ZStack {
                // Arc background
                Path { path in
                    path.addArc(center: CGPoint(x: centerX, y: centerY),
                                radius: radius,
                                startAngle: .degrees(200),
                                endAngle: .degrees(340),
                                clockwise: false)
                }
                .stroke(Color.gray.opacity(0.3), lineWidth: 3)

                // Colored arc sections
                let arcStart: Double = 200
                let arcEnd: Double = 340
                let arcRange = arcEnd - arcStart

                // Under-exposed (blue), center (green), over-exposed (yellow/red)
                Path { path in
                    path.addArc(center: CGPoint(x: centerX, y: centerY),
                                radius: radius,
                                startAngle: .degrees(arcStart),
                                endAngle: .degrees(arcStart + arcRange * 0.33),
                                clockwise: false)
                }
                .stroke(Color.blue.opacity(0.5), lineWidth: 3)

                Path { path in
                    path.addArc(center: CGPoint(x: centerX, y: centerY),
                                radius: radius,
                                startAngle: .degrees(arcStart + arcRange * 0.33),
                                endAngle: .degrees(arcStart + arcRange * 0.66),
                                clockwise: false)
                }
                .stroke(Color.green.opacity(0.5), lineWidth: 3)

                Path { path in
                    path.addArc(center: CGPoint(x: centerX, y: centerY),
                                radius: radius,
                                startAngle: .degrees(arcStart + arcRange * 0.66),
                                endAngle: .degrees(arcEnd),
                                clockwise: false)
                }
                .stroke(Color.red.opacity(0.5), lineWidth: 3)

                // Tick marks
                ForEach(-3..<4, id: \.self) { tick in
                    let fraction = (Double(tick) + 3.0) / 6.0
                    let angle = Angle.degrees(arcStart + arcRange * fraction)
                    let tickStart = radius - 6
                    let tickEnd = radius + 6
                    Path { path in
                        path.move(to: CGPoint(
                            x: centerX + tickStart * cos(CGFloat(angle.radians)),
                            y: centerY + tickStart * sin(CGFloat(angle.radians))
                        ))
                        path.addLine(to: CGPoint(
                            x: centerX + tickEnd * cos(CGFloat(angle.radians)),
                            y: centerY + tickEnd * sin(CGFloat(angle.radians))
                        ))
                    }
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
                }

                // EV marker (current metered value)
                let evClamped = max(-3, min(3, evValue))
                let evFraction = (Double(evClamped) + 3.0) / 6.0
                let evAngle = Angle.degrees(arcStart + arcRange * evFraction)
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .position(
                        x: centerX + (radius) * cos(CGFloat(evAngle.radians)),
                        y: centerY + (radius) * sin(CGFloat(evAngle.radians))
                    )

                // Bias marker (user-set compensation)
                let biasClamped = max(-3, min(3, bias))
                let biasFraction = (Double(biasClamped) + 3.0) / 6.0
                let biasAngle = Angle.degrees(arcStart + arcRange * biasFraction)
                Triangle()
                    .fill(Color.yellow)
                    .frame(width: 10, height: 8)
                    .position(
                        x: centerX + (radius + 14) * cos(CGFloat(biasAngle.radians)),
                        y: centerY + (radius + 14) * sin(CGFloat(biasAngle.radians))
                    )
            }
        }
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
    nonisolated(unsafe) var ciContext = CIContext(options: [.useSoftwareRenderer: false])
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

// MARK: - CameraContentView

struct CameraContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var motion = MotionManager()
    @State private var focusPoint: CGPoint?
    @State private var showFocusIndicator = false
    @State private var showAspectMenu = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            // Camera layer
            cameraLayer
                .ignoresSafeArea()

            GeometryReader { geo in
                // Aspect ratio overlay
                AspectRatioOverlay(aspectRatio: camera.selectedAspectRatio, geoSize: geo.size)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()

            // Grid
            if camera.showGrid {
                GridOverlay()
                    .ignoresSafeArea()
            }

            // Level
            if camera.showLevel {
                LevelOverlay(roll: motion.roll)
                    .ignoresSafeArea()
            }

            // Focus peaking
            if camera.showPeaking {
                FocusPeakingView(session: camera.session)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // Focus indicator
            if showFocusIndicator, let pt = focusPoint {
                FocusIndicator(position: pt)
                    .allowsHitTesting(false)
            }

            // Main UI overlay
            VStack(spacing: 0) {
                topBar
                    .padding(.top, 4)
                Spacer()
                bottomSection
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            motion.startUpdates()
        }
        .onDisappear {
            motion.stopUpdates()
        }
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onEnded { value in
                                let point = value.location
                                focusPoint = point
                                showFocusIndicator = false
                                showFocusIndicator = true

                                // Convert to camera coordinates (0...1)
                                let camPoint = CGPoint(
                                    x: point.y / geo.size.height,
                                    y: 1.0 - point.x / geo.size.width
                                )
                                camera.tapToFocus(at: camPoint)
                            }
                    )
            }
            .allowsHitTesting(true)
        }
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
    }

    // MARK: - Camera Layer

    @ViewBuilder
    private var cameraLayer: some View {
        if let frame = camera.filteredFrame {
            Image(decorative: frame, scale: 1.0)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            Color.black.overlay {
                if camera.isDenied {
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
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(alignment: .top) {
            // Exposure dial
            ExposureDial(
                value: Binding(
                    get: { camera.exposureBias },
                    set: { camera.setExposureBias($0) }
                ),
                range: -3.0...3.0
            )

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    // Double exposure toggle
                    TopPill(
                        icon: "square.stack",
                        text: camera.doubleExposureEnabled ? "2X" : "1X"
                    )
                    .onTapGesture {
                        camera.doubleExposureEnabled.toggle()
                    }

                    // RAW / JPEG toggle
                    TopPill(text: camera.rawEnabled ? "RAW" : "JPEG")
                        .onTapGesture {
                            camera.rawEnabled.toggle()
                        }

                    // Long exposure
                    TopPill(
                        icon: "timer",
                        text: camera.isLongExposure ? String(format: "%.0fs", camera.longExposureDuration) : "BULB"
                    )
                    .onTapGesture {
                        camera.isLongExposure.toggle()
                    }

                    // AF/MF toggle
                    TopPill(
                        icon: "viewfinder",
                        text: camera.manualFocusEnabled ? "MF" : "AF"
                    )
                    .onTapGesture {
                        camera.manualFocusEnabled.toggle()
                    }
                }

                HStack(spacing: 8) {
                    // Aspect ratio selector
                    TopPill(
                        icon: "rectangle.split.2x1",
                        text: camera.selectedAspectRatio.label,
                        showChevron: true
                    )
                    .onTapGesture {
                        showAspectMenu.toggle()
                    }

                    // Settings gear
                    TopPill(icon: "gearshape", text: "")
                        .onTapGesture {
                            showSettings = true
                        }
                }

                // Aspect ratio popup
                if showAspectMenu {
                    VStack(spacing: 4) {
                        ForEach(AspectRatio.allCases) { ratio in
                            Button {
                                camera.selectedAspectRatio = ratio
                                showAspectMenu = false
                            } label: {
                                Text(ratio.label)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(camera.selectedAspectRatio == ratio ? .black : .white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity)
                                    .background(camera.selectedAspectRatio == ratio ? Color.yellow : Color.gray.opacity(0.4))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(width: 100)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(spacing: 14) {
            // EV meter bar
            ExposureMeterBar(evValue: camera.evReading, bias: camera.exposureBias)
                .frame(height: 40)
                .padding(.horizontal, 40)

            // MF Slider (only when manual focus is on)
            if camera.manualFocusEnabled {
                VStack(spacing: 4) {
                    Text("MF")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.gray.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Slider(
                        value: Binding(
                            get: { camera.manualFocusValue },
                            set: { camera.setManualFocus($0) }
                        ),
                        in: 0...1
                    )
                    .tint(.yellow)
                    .padding(.horizontal, 30)
                }
            }

            // Long exposure controls
            if camera.isLongExposure {
                VStack(spacing: 8) {
                    // Duration slider
                    HStack {
                        Text("Duration")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.gray)
                        Slider(
                            value: $camera.longExposureDuration,
                            in: 0.5...30.0,
                            step: 0.5
                        )
                        .tint(.yellow)
                        Text(String(format: "%.1fs", camera.longExposureDuration))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 45, alignment: .trailing)
                    }
                    .padding(.horizontal, 20)

                    // Mode picker
                    HStack(spacing: 10) {
                        ForEach(LongExposureMode.allCases) { mode in
                            Button {
                                camera.longExposureMode = mode
                            } label: {
                                Text(mode.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(camera.longExposureMode == mode ? .black : .white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(camera.longExposureMode == mode ? Color.yellow : Color.gray.opacity(0.35))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Focal lengths
            HStack(spacing: 14) {
                ForEach(Array(focalPresets.enumerated()), id: \.offset) { index, preset in
                    Button {
                        camera.selectFocalPreset(index)
                    } label: {
                        VStack(spacing: 1) {
                            Text("\(preset.mm)")
                                .font(.system(size: 20, weight: .semibold))
                            Text("mm")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(camera.selectedFocalIndex == index ? Color.yellow : .white)
                        .frame(width: 54, height: 54)
                        .overlay(
                            Circle().stroke(
                                camera.selectedFocalIndex == index ? Color.yellow : .gray.opacity(0.5),
                                lineWidth: camera.selectedFocalIndex == index ? 2 : 1
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Film sims
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilmSimulation.allCases) { sim in
                        Button {
                            camera.selectedSim = sim
                        } label: {
                            Text(sim.label)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(camera.selectedSim == sim ? Color.yellow : .gray.opacity(0.35))
                                .foregroundStyle(camera.selectedSim == sim ? .black : .white)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            // Grain slider (when a sim is selected)
            if camera.selectedSim != .none {
                HStack(spacing: 10) {
                    Button {
                        camera.grainEnabled.toggle()
                    } label: {
                        Image(systemName: camera.grainEnabled ? "circle.grid.3x3.fill" : "circle.grid.3x3")
                            .font(.system(size: 16))
                            .foregroundStyle(camera.grainEnabled ? .yellow : .gray)
                    }
                    .buttonStyle(.plain)

                    if camera.grainEnabled {
                        Slider(
                            value: $camera.grainAmount,
                            in: 0...0.5
                        )
                        .tint(.yellow)

                        Text(String(format: "%.0f%%", camera.grainAmount * 200))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 20)
            }

            // Shutter row
            shutterRow
                .padding(.bottom, 24)
        }
    }

    // MARK: - Shutter Row

    private var shutterRow: some View {
        HStack {
            HStack(spacing: 14) {
                // EV display button
                ZStack(alignment: .top) {
                    Circle()
                        .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                        .frame(width: 50, height: 50)
                    VStack(spacing: -1) {
                        Image(systemName: "plusminus")
                            .font(.system(size: 7))
                        Text(String(format: "%+.1f", camera.exposureBias))
                            .font(.system(size: 18, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 5, height: 5)
                        .offset(y: -2)
                }

                // Flash button
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                        .frame(width: 50, height: 50)
                    VStack(spacing: -2) {
                        Image(systemName: camera.flashMode == .off ? "bolt.slash.fill" : "bolt.fill")
                            .font(.system(size: 14))
                        Text(camera.flashLabel)
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(camera.flashMode == .on ? .yellow : .white)
                }
                .onTapGesture {
                    camera.toggleFlash()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)

            // Shutter button
            Button {
                if camera.doubleExposureEnabled && camera.firstExposureCIImage == nil {
                    camera.captureDoubleExposureFirst()
                } else {
                    camera.capturePhoto()
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.35), lineWidth: 3)
                        .frame(width: 76, height: 76)
                    Circle()
                        .fill(camera.isCapturing ? Color.gray : Color.white)
                        .frame(width: 66, height: 66)

                    if camera.isCapturing {
                        ProgressView()
                            .tint(.white)
                    }

                    if camera.doubleExposureEnabled && camera.firstExposureCIImage != nil {
                        Text("2nd")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(camera.isCapturing)
            .frame(maxWidth: .infinity)

            // Double exposure opacity dial or empty space
            if camera.doubleExposureEnabled {
                OpacityDial(
                    value: $camera.doubleExposureOpacity,
                    label: "BLEND"
                )
                .frame(maxWidth: .infinity)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section("Overlays") {
                    Toggle("Grid", isOn: $camera.showGrid)
                    Toggle("Level", isOn: $camera.showLevel)
                    Toggle("Focus Peaking", isOn: $camera.showPeaking)
                }

                Section("Film Effects") {
                    Toggle("Color Crosstalk", isOn: $camera.crosstalkEnabled)
                    if camera.crosstalkEnabled {
                        Slider(value: $camera.crosstalkAmount, in: 0...0.2) {
                            Text("Amount")
                        }
                    }

                    Toggle("Halation", isOn: $camera.halationEnabled)
                    if camera.halationEnabled {
                        Slider(value: $camera.halationAmount, in: 0...1.0) {
                            Text("Amount")
                        }
                    }

                    Toggle("Highlight Rolloff", isOn: $camera.rolloffEnabled)
                    if camera.rolloffEnabled {
                        Slider(value: $camera.rolloffThreshold, in: 0.5...0.98) {
                            Text("Threshold")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSettings = false }
                }
            }
        }
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
