//
//  SmartTake.swift
//  cam cam
//
//  Smart Take: the camera takes the picture when everyone in frame is posed,
//  so nobody has to count down or press the shutter (the idea behind the
//  iPhone Duo feature of the same name, built here with Vision so it runs on
//  any iPhone).
//
//  ~6 times a second, on a small copy of the live frame:
//   • faces with landmarks and pose (yaw / pitch)
//   • Apple's face capture quality (sharpness, pose, expression in one score)
//  A face is "ready" when it faces the camera, both eyes are open and its
//  quality is decent. When every face is ready AND everyone has held still
//  for a moment, the shutter fires. It then waits for someone to move (the
//  group to un-pose) before it can fire again, so you get one picture per
//  pose, not a burst.
//

@preconcurrency import AVFoundation
import CoreImage
import Observation
import UIKit
import Vision

@MainActor @Observable
final class SmartTake {
    nonisolated static let shared = SmartTake()
    nonisolated init() {}

    var enabled = UserDefaults.standard.bool(forKey: "cc_smartTake") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "cc_smartTake")
            cachedEnabled = enabled
            ready = 0; faces = 0; holdProgress = 0
            if !enabled { stopSession() }
        }
    }

    // MARK: Session (like the iPhone Duo: tap the yellow shutter to start,
    // set the phone down, it shoots each new pose, up to 24 in ~2 minutes)

    static let maxShots = 24
    static let maxDuration: TimeInterval = 120
    private(set) var sessionActive = false
    private(set) var shots = 0
    @ObservationIgnored private var sessionTimer: Timer?

    func toggleSession() { sessionActive ? stopSession() : startSession() }

    func startSession() {
        guard enabled, !sessionActive else { return }
        sessionActive = true; cachedActive = true
        shots = 0
        armed = true; readySince = nil
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: Self.maxDuration, repeats: false) { _ in
            Task { @MainActor in SmartTake.shared.stopSession() }
        }
    }

    func stopSession() {
        sessionActive = false; cachedActive = false
        sessionTimer?.invalidate(); sessionTimer = nil
        holdProgress = 0
    }

    fileprivate func didShoot() {
        shots += 1
        if shots >= Self.maxShots { stopSession() }
    }
    /// Faces in frame and how many are posed (for "2 of 3 ready").
    private(set) var faces = 0
    private(set) var ready = 0
    /// 0…1 while everyone is posed and holding still.
    private(set) var holdProgress: Double = 0

    @ObservationIgnored nonisolated(unsafe) var cachedEnabled = UserDefaults.standard.bool(forKey: "cc_smartTake")
    @ObservationIgnored nonisolated(unsafe) var cachedActive = false
    /// Someone is still moving into place (for "Wait — someone's still moving").
    private(set) var someoneMoving = false
    @ObservationIgnored nonisolated(unsafe) private var lastTick: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var busy = false
    @ObservationIgnored nonisolated(unsafe) private var readySince: Double?
    @ObservationIgnored nonisolated(unsafe) private var armed = true
    @ObservationIgnored nonisolated(unsafe) private var lastFire: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var lastCentres: [CGPoint] = []

    nonisolated private static let queue = DispatchQueue(label: "cam.smarttake", qos: .userInitiated)

    /// How long everyone must be posed and still before the shutter fires.
    nonisolated static let holdTime = 1.2

    /// Called for every video frame; analyses ~6 times a second off the camera queue.
    nonisolated func process(_ pixelBuffer: CVPixelBuffer, time: Double, camera: CameraManager) {
        guard cachedEnabled, cachedActive, !busy, time - lastTick >= 0.16 else { return }
        guard !camera.cachedIsRecording, !camera.isCollectingFrames else { return }
        lastTick = time
        busy = true
        let s = 640 / CGFloat(max(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)))
        let small = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: CGAffineTransform(scaleX: s, y: s))
        Self.queue.async { [self] in
            defer { busy = false }
            analyse(small, time: time, camera: camera)
        }
    }

    nonisolated private func analyse(_ image: CIImage, time: Double, camera: CameraManager) {
        let landmarks = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(ciImage: image)
        guard (try? handler.perform([landmarks])) != nil,
              let all = landmarks.results, !all.isEmpty,
              // Ignore tiny faces in the background (posters, people far behind).
              case let found = Self.mainFaces(all), !found.isEmpty else {
            readySince = nil
            armed = true            // nobody in frame: re-arm for the next group
            lastCentres = []
            publish(faces: 0, ready: 0, progress: 0, moving: false)
            return
        }
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = found
        try? handler.perform([quality])
        let scores = (quality.results ?? []).map { $0.faceCaptureQuality }
        let scored = found

        var readyCount = 0
        for (i, face) in scored.enumerated() {
            let q = i < scores.count ? scores[i] : nil
            if Self.isPosed(face, quality: q) { readyCount += 1 }
        }

        // Stillness: every face centre within ~2.5% of the frame since the last tick.
        let centres = scored.map { CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY) }
        let still = centres.count == lastCentres.count && zip(centres.sorted { $0.x < $1.x },
                                                             lastCentres.sorted { $0.x < $1.x })
            .allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.012 }
        lastCentres = centres

        let allPosed = readyCount == scored.count && still
        var progress = 0.0
        if allPosed {
            if readySince == nil { readySince = time }
            progress = min(1, (time - readySince!) / Self.holdTime)
            if progress >= 1, armed, time - lastFire > 3 {
                armed = false
                lastFire = time
                readySince = nil
                DispatchQueue.main.async {
                    guard !camera.isCapturing, SmartTake.shared.sessionActive else { return }
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    camera.capturePhoto()
                    SmartTake.shared.didShoot()
                    SmartTake.shared.blinkFlash(camera)
                }
            }
        } else {
            readySince = nil
            // Someone moved or looked away: the group is re-posing, so the
            // next pose may fire again.
            if readyCount < scored.count { armed = true }
        }
        let moving = readyCount == scored.count && !still
        publish(faces: scored.count, ready: readyCount, progress: armed ? progress : 0, moving: moving)
    }

    /// Facing the camera, eyes open, decent capture quality.
    nonisolated static func isPosed(_ face: VNFaceObservation, quality: Float?) -> Bool {
        let yaw = abs(face.yaw?.doubleValue ?? 0), pitch = abs(face.pitch?.doubleValue ?? 0)
        guard yaw < 0.26, pitch < 0.26 else { return false }
        if let q = quality, q < 0.42 { return false }
        guard let lm = face.landmarks,
              eyeOpen(lm.leftEye), eyeOpen(lm.rightEye) else { return false }
        return true
    }

    /// Faces that are part of the shot: at least ~35% the size of the largest
    /// face and not tiny overall.
    nonisolated static func mainFaces(_ faces: [VNFaceObservation]) -> [VNFaceObservation] {
        let biggest = faces.map { $0.boundingBox.width }.max() ?? 0
        return faces.filter { $0.boundingBox.width >= max(0.035, biggest * 0.35) }
    }

    /// Eye openness from the eye contour's height-to-width ratio.
    nonisolated static func eyeOpen(_ region: VNFaceLandmarkRegion2D?) -> Bool {
        guard let pts = region?.normalizedPoints, pts.count >= 4 else { return true }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let w = (xs.max() ?? 0) - (xs.min() ?? 0), h = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard w > 0 else { return true }
        return h / w > 0.2
    }

    /// The rear flash blinks after each shot so the group knows it fired.
    func blinkFlash(_ camera: CameraManager) {
        guard let dev = camera.currentDevice, dev.position == .back, dev.hasTorch else { return }
        nonisolated(unsafe) let device = dev
        camera.sessionQueue.asyncAfter(deadline: .now() + 0.35) {
            guard (try? device.lockForConfiguration()) != nil else { return }
            try? device.setTorchModeOn(level: 0.3)
            device.unlockForConfiguration()
            camera.sessionQueue.asyncAfter(deadline: .now() + 0.15) {
                guard (try? device.lockForConfiguration()) != nil else { return }
                device.torchMode = .off
                device.unlockForConfiguration()
            }
        }
    }

    nonisolated private func publish(faces: Int, ready: Int, progress: Double, moving: Bool) {
        Task { @MainActor in
            let st = SmartTake.shared
            if st.someoneMoving != moving { st.someoneMoving = moving }
            if st.faces != faces { st.faces = faces }
            if st.ready != ready { st.ready = ready }
            if abs(st.holdProgress - progress) > 0.05 || (progress == 0) != (st.holdProgress == 0) {
                st.holdProgress = progress
            }
        }
    }
}
