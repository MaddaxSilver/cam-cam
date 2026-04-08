//  CameraManager.swift
//  cam cam
//
//  Manages the AVFoundation capture session and applies FilmSimulator
//  to each frame on a background queue, publishing processed CGImages
//  back to the main actor for display.

import AVFoundation
import CoreImage
import SwiftUI
import Combine

#if os(iOS)

// Runs entirely on the capture queue — explicitly opts out of the module-wide
// @MainActor default so AVFoundation can call captureOutput from any thread.
private final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated(unsafe) var sim: FilmSim = .none
    nonisolated(unsafe) var settings = CameraSettings()
    nonisolated(unsafe) var onFrame: ((CGImage) -> Void)?

    // CIContext is thread-safe; keeping one instance avoids per-frame allocation.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let simulator = FilmSimulator(settings: settings)
        let processed = simulator.apply(sim: sim, to: ciImage)
        guard let cgImage = ciContext.createCGImage(processed, from: ciImage.extent) else { return }
        onFrame?(cgImage)
    }
}

@MainActor
final class CameraManager: ObservableObject {
    @Published var filteredFrame: CGImage?
    @Published var isAuthorized = false
    @Published var isDenied = false

    @Published var selectedSim: FilmSim = .none {
        didSet { processor.sim = selectedSim }
    }
    @Published var settings = CameraSettings() {
        didSet { processor.settings = settings }
    }

    private let session = AVCaptureSession()
    private let processor = FrameProcessor()
    private let outputQueue = DispatchQueue(label: "cam.frame.output", qos: .userInteractive)

    init() {
        processor.onFrame = { [weak self] image in
            DispatchQueue.main.async { self?.filteredFrame = image }
        }
    }

    func start() {
        Task {
            await resolvePermission()
            guard isAuthorized else { return }
            configureSession()
            let s = session
            Task.detached(priority: .userInitiated) { s.startRunning() }
        }
    }

    func stop() {
        let s = session
        Task.detached { s.stopRunning() }
    }

    private func resolvePermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
        case .notDetermined:
            isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            if !isAuthorized { isDenied = true }
        default:
            isDenied = true
        }
    }

    private func configureSession() {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { session.commitConfiguration(); return }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(processor, queue: outputQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
            if let connection = output.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }

        session.commitConfiguration()
    }
}

#else

// Non-iOS stub so the rest of the app compiles on macOS / visionOS.
@MainActor
final class CameraManager: ObservableObject {
    @Published var filteredFrame: CGImage? = nil
    @Published var isAuthorized = false
    @Published var isDenied = false
    @Published var selectedSim: FilmSim = .none
    @Published var settings = CameraSettings()
    func start() {}
    func stop() {}
}

#endif
