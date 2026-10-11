//
//  FrameAdvisor.swift
//  cam cam
//
//  Frame guide (rear camera). Two stages:
//
//  1. Suggest — a yellow corner-bracket box marks the shot worth taking: the
//     group (faces padded for bodies) or the main subject of a scene
//     (objectness saliency). It's calm: it glides instead of jumping, stays
//     for a few seconds after the subject was last seen, and only switches
//     to a different suggestion once that one has held for a while.
//
//  2. Lock — tap the box (it also focuses there). Now the phone guides you:
//     it pulses with haptics, faster the further off you are, and a hint
//     says what to change ("Move left", "Zoom in", "Tilt 1° right"). When the
//     subject is centred, fills the frame and the horizon is level, the box
//     turns green, a success haptic plays and the shutter fires.
//

import AVFoundation
import CoreImage
import Observation
import UIKit
import Vision

@MainActor @Observable
final class FrameAdvisor {
    static let shared = FrameAdvisor()

    enum Stage: Equatable { case suggesting, locked, aligned }

    var enabled = UserDefaults.standard.object(forKey: "cc_frameAdvisor") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "cc_frameAdvisor")
            cachedEnabled = enabled
            if !enabled { unlock(); box = nil; hint = nil }
        }
    }
    /// The box on screen, normalized image coordinates (top-left origin).
    private(set) var box: CGRect?
    private(set) var stage: Stage = .suggesting
    /// What to change ("Move left", "Zoom in", "Tilt 2° right"), or a tip.
    private(set) var hint: String?
    /// Width / height of the analysed camera image, to map the box on screen.
    private(set) var imageAspect: CGFloat = 3.0 / 4.0

    // Read on the analysis queue.
    @ObservationIgnored nonisolated(unsafe) var cachedEnabled = UserDefaults.standard.object(forKey: "cc_frameAdvisor") as? Bool ?? false
    @ObservationIgnored nonisolated(unsafe) private var cachedLocked = false
    @ObservationIgnored nonisolated(unsafe) private var lastTick: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var busy = false
    // Suggestion smoothing
    @ObservationIgnored nonisolated(unsafe) private var shown: CGRect?
    @ObservationIgnored nonisolated(unsafe) private var lastSeen: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var rival: CGRect?
    @ObservationIgnored nonisolated(unsafe) private var rivalSince: Double = 0
    // Lock tracking
    @ObservationIgnored nonisolated(unsafe) private var alignedSince: Double?
    @ObservationIgnored nonisolated(unsafe) private var lostSince: Double?
    @ObservationIgnored nonisolated(unsafe) private var lastPulse: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var fired = false

    nonisolated private static let queue = DispatchQueue(label: "cam.frameadvisor", qos: .userInitiated)
    /// How much of the frame the subject should fill when lined up.
    nonisolated static let targetFill: CGFloat = 0.82

    // MARK: Lock

    /// Tap on the box: commit to this framing and start guiding.
    func lock(camera: CameraManager) {
        guard let b = box else { return }
        stage = .locked; cachedLocked = true
        alignedSince = nil; lostSince = nil; fired = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        camera.tapToFocus(at: CGPoint(x: b.midY, y: 1 - b.midX))   // focus on the subject
    }

    func unlock() {
        stage = .suggesting; cachedLocked = false
        alignedSince = nil; lostSince = nil
    }

    // MARK: Frames

    nonisolated func process(_ pixelBuffer: CVPixelBuffer, time: Double, camera: CameraManager) {
        let interval = cachedLocked ? 0.12 : 0.3
        guard cachedEnabled, !busy, time - lastTick >= interval,
              camera.currentDevice?.position == .back else { return }
        lastTick = time
        busy = true
        let s = 512 / CGFloat(max(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)))
        let small = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: CGAffineTransform(scaleX: s, y: s))
        let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(max(CVPixelBufferGetHeight(pixelBuffer), 1))
        Self.queue.async { [self] in
            defer { busy = false }
            analyse(small, time: time, aspect: aspect, camera: camera)
        }
    }

    nonisolated private func analyse(_ image: CIImage, time: Double, aspect: CGFloat, camera: CameraManager) {
        let horizonReq = VNDetectHorizonRequest()
        let faceReq = VNDetectFaceRectanglesRequest()
        let subjectReq = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? VNImageRequestHandler(ciImage: image).perform([horizonReq, faceReq, subjectReq])
        var tilt: Double? = horizonReq.results?.first.map { Double($0.angle) * 180 / .pi }
        if let t = tilt, abs(t) > 20 { tilt = nil }

        let found = Self.subjectBox(faces: faceReq.results ?? [],
                                    saliency: subjectReq.results?.first as? VNSaliencyImageObservation)

        if cachedLocked {
            guide(found, tilt: tilt, time: time, aspect: aspect, camera: camera)
        } else {
            suggest(found, tilt: tilt, time: time, aspect: aspect)
        }
    }

    // MARK: Stage 1 — suggest (calm)

    nonisolated private func suggest(_ found: (box: CGRect, isGroup: Bool)?, tilt: Double?, time: Double, aspect: CGFloat) {
        if let f = found, Self.worthFraming(f.box) {
            lastSeen = time
            if let cur = shown {
                if Self.iou(cur, f.box) > 0.35 {
                    shown = Self.lerp(cur, f.box, 0.2)          // glide
                    rival = nil
                } else {
                    // A different suggestion: switch only once it's held ~1.2 s.
                    if rival == nil || Self.iou(rival!, f.box) < 0.35 { rival = f.box; rivalSince = time }
                    else { rival = Self.lerp(rival!, f.box, 0.3) }
                    if time - rivalSince > 1.2 { shown = rival; rival = nil }
                }
            } else {
                shown = f.box
            }
        } else if time - lastSeen > 4 {
            shown = nil                                        // linger ~4 s after it's gone
        }
        var tip: String? = nil
        if let t = tilt, abs(t) > 1.5 { tip = String(format: "Tilt %.0f° %@", abs(t), t > 0 ? "right" : "left") }
        else if shown != nil { tip = (found?.isGroup ?? false) ? "Tap the box to frame the group" : "Tap the box to frame this shot" }
        publish(box: shown, stage: .suggesting, hint: tip, aspect: aspect)
    }

    // MARK: Stage 2 — locked: guide until it's right, then shoot

    nonisolated private func guide(_ found: (box: CGRect, isGroup: Bool)?, tilt: Double?, time: Double, aspect: CGFloat, camera: CameraManager) {
        guard let f = found else {
            if lostSince == nil { lostSince = time }
            if time - (lostSince ?? time) > 2.5 {
                DispatchQueue.main.async {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    FrameAdvisor.shared.unlock()
                }
            }
            publish(box: shown, stage: .locked, hint: "Lost the subject", aspect: aspect)
            return
        }
        lostSince = nil
        shown = shown.map { Self.lerp($0, f.box, 0.4) } ?? f.box
        let b = shown!

        // Errors: centre offset, fill, horizon tilt.
        let dx = b.midX - 0.5, dy = b.midY - 0.5
        let fill = max(b.width, b.height)
        let fillErr = fill - Self.targetFill
        let tiltErr = tilt ?? 0
        let centred = abs(dx) < 0.045 && abs(dy) < 0.06
        let filled = abs(fillErr) < 0.08
        let level = abs(tiltErr) < 1.0
        let aligned = centred && filled && level

        var tip: String
        if !level { tip = String(format: "Tilt %.0f° %@", max(1, abs(tiltErr)), tiltErr > 0 ? "right" : "left") }
        else if !centred {
            tip = abs(dx) >= abs(dy) ? (dx < 0 ? "Move left" : "Move right") : (dy < 0 ? "Tilt up" : "Tilt down")
        } else if !filled { tip = fillErr < 0 ? "Zoom in" : "Zoom out" }
        else { tip = "Hold it…" }

        if aligned {
            if alignedSince == nil { alignedSince = time }
            if time - alignedSince! > 0.4, !fired {
                fired = true
                DispatchQueue.main.async {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    if !camera.isCapturing { camera.capturePhoto() }
                }
                publish(box: b, stage: .aligned, hint: "Got it", aspect: aspect)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { FrameAdvisor.shared.unlock() }
                return
            }
            publish(box: b, stage: .aligned, hint: tip, aspect: aspect)
        } else {
            alignedSince = nil
            // Haptic guidance: pulse faster the further off it is.
            let err = min(1, Double(abs(dx) + abs(dy)) * 2 + Double(abs(fillErr)) * 1.5 + abs(tiltErr) / 10)
            let interval = 0.12 + 0.55 * err
            if time - lastPulse >= interval {
                lastPulse = time
                let strength = CGFloat(0.35 + 0.5 * (1 - err))
                DispatchQueue.main.async {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: strength)
                }
            }
            publish(box: b, stage: .locked, hint: tip, aspect: aspect)
        }
    }

    // MARK: Detection

    /// The thing to frame: the group (faces padded for bodies), else the main
    /// salient subject. Bottom-left Vision coords in, top-left box out.
    nonisolated static func subjectBox(faces: [VNFaceObservation], saliency: VNSaliencyImageObservation?) -> (box: CGRect, isGroup: Bool)? {
        let rects = faces.map(\.boundingBox).filter { $0.width > 0.03 }
        if !rects.isEmpty {
            let u = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            let fh = rects.map(\.height).max() ?? 0.1
            let body = CGRect(x: u.minX - fh * 0.6, y: u.minY - fh * 2.2,
                              width: u.width + fh * 1.2, height: u.height + fh * 2.6)
            return box(around: body).map { ($0, true) }
        }
        if let objs = saliency?.salientObjects, !objs.isEmpty {
            let u = objs.dropFirst().reduce(objs[0].boundingBox) { $0.union($1.boundingBox) }
            return box(around: u).map { ($0, false) }
        }
        return nil
    }

    nonisolated static func box(around r: CGRect) -> CGRect? {
        let m: CGFloat = 0.05
        let b = r.insetBy(dx: -m, dy: -m).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !b.isNull, b.width > 0.08, b.height > 0.08 else { return nil }
        return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
    }

    /// Only suggest framings that are a real change (not the whole frame).
    nonisolated static func worthFraming(_ b: CGRect) -> Bool {
        max(b.width, b.height) < 0.75 || abs(b.midX - 0.5) > 0.12
    }

    nonisolated static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let ia = i.width * i.height
        return ia / (a.width * a.height + b.width * b.height - ia)
    }

    nonisolated static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    nonisolated private func publish(box: CGRect?, stage: Stage, hint: String?, aspect: CGFloat) {
        Task { @MainActor in
            let a = FrameAdvisor.shared
            guard a.cachedEnabled else { return }
            a.imageAspect = aspect
            a.box = box
            if a.cachedLocked || stage == .suggesting { a.stage = stage }
            if a.hint != hint { a.hint = hint }
        }
    }
}
