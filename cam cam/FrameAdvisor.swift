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
//  2. Lock — tap the box: it focuses there and zooms so the subject fills
//     the frame, then follows THAT subject with Vision object tracking (so
//     moving subjects stay locked). The phone pulses with haptics, faster the
//     further off you are, and a hint says what to change ("Move left",
//     "Tilt down", "Tilt 1° right"). When the subject is centred and the
//     horizon level, the box turns green, a success haptic plays and the
//     shutter fires.
//
//  What it frames, in order: faces (group), people's bodies, cats and dogs
//  (Apple's on-device detectors), then the single strongest stand-out
//  object (objectness saliency — the fallback, and the least smart).
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
    // Object tracking after the lock (follows a moving subject)
    @ObservationIgnored nonisolated(unsafe) private var tracker: VNSequenceRequestHandler?
    @ObservationIgnored nonisolated(unsafe) private var tracked: VNDetectedObjectObservation?
    @ObservationIgnored nonisolated(unsafe) private var trackStartAt: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var lockedIsGroup = false

    nonisolated private static let queue = DispatchQueue(label: "cam.frameadvisor", qos: .userInitiated)
    /// How much of the frame the subject should fill when lined up.
    nonisolated static let targetFill: CGFloat = 0.82

    // MARK: Lock

    /// Tap on the box: commit to this framing and start guiding.
    func lock(camera: CameraManager) {
        guard let b = box else { return }
        stage = .locked; cachedLocked = true
        alignedSince = nil; lostSince = nil; fired = false
        tracked = nil; tracker = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        camera.tapToFocus(at: CGPoint(x: b.midY, y: 1 - b.midX))   // focus on the subject
        // Auto zoom so the subject fills the frame (the zoom is centred, so
        // you then move the phone to centre it).
        let z = min(max(Double(Self.targetFill / max(b.width, b.height)), 1), 4)
        if z > 1.08 {
            camera.setZoom(CGFloat(Double(max(camera.currentMM, 13)) / 26 * z))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { camera.syncZoomState() }
        }
        // Start tracking once the zoom has settled.
        trackStartAt = CACurrentMediaTime() + (z > 1.08 ? 0.6 : 0.1)
    }

    func unlock() {
        stage = .suggesting; cachedLocked = false
        alignedSince = nil; lostSince = nil
        tracked = nil; tracker = nil
    }

    // MARK: Frames

    nonisolated func process(_ pixelBuffer: CVPixelBuffer, time: Double, camera: CameraManager) {
        let interval = cachedLocked ? 0.08 : 0.3
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
        let handler = VNImageRequestHandler(ciImage: image)

        if cachedLocked {
            try? handler.perform([horizonReq])
            let tilt = Self.tilt(horizonReq)
            // Wait for the lock's zoom to settle, then pick the subject again
            // (nearest the centre) and track it from then on.
            if tracked == nil {
                guard CACurrentMediaTime() >= trackStartAt else { return }
                guard let f = Self.detect(handler, preferCentre: true) else {
                    guide(nil, tilt: tilt, time: time, aspect: aspect, camera: camera); return
                }
                lockedIsGroup = f.isGroup
                tracked = VNDetectedObjectObservation(boundingBox: Self.toVision(f.box))
                tracker = VNSequenceRequestHandler()
                guide(f, tilt: tilt, time: time, aspect: aspect, camera: camera)
                return
            }
            let req = VNTrackObjectRequest(detectedObjectObservation: tracked!)
            req.trackingLevel = .accurate
            if (try? tracker?.perform([req], on: image)) != nil,
               let obs = req.results?.first as? VNDetectedObjectObservation, obs.confidence > 0.3 {
                tracked = obs
                guide((Self.fromVision(obs.boundingBox), lockedIsGroup), tilt: tilt, time: time, aspect: aspect, camera: camera)
            } else {
                guide(nil, tilt: tilt, time: time, aspect: aspect, camera: camera)
            }
            return
        }

        try? handler.perform([horizonReq])
        suggest(Self.detect(handler, preferCentre: false), tilt: Self.tilt(horizonReq), time: time, aspect: aspect)
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
        shown = shown.map { Self.lerp($0, f.box, 0.6) } ?? f.box
        let b = shown!

        // Errors: centre offset, fill, horizon tilt.
        let dx = b.midX - 0.5, dy = b.midY - 0.5
        let fill = max(b.width, b.height)
        let fillErr = fill - Self.targetFill
        let tiltErr = tilt ?? 0
        _ = fillErr   // zoom is handled by the lock's auto zoom (and your pinch)
        let centred = abs(dx) < 0.05 && abs(dy) < 0.065
        let level = abs(tiltErr) < 1.0
        let aligned = centred && level

        var tip: String
        if !level { tip = String(format: "Tilt %.0f° %@", max(1, abs(tiltErr)), tiltErr > 0 ? "right" : "left") }
        else if !centred {
            tip = abs(dx) >= abs(dy) ? (dx < 0 ? "Move left" : "Move right") : (dy < 0 ? "Tilt up" : "Tilt down")
        } else { tip = "Hold it…" }

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
            let err = min(1, Double(abs(dx) + abs(dy)) * 2.2 + abs(tiltErr) / 8)
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

    /// The thing to frame, smartest first: faces (group, padded for bodies),
    /// people's bodies, cats and dogs, then the single strongest stand-out
    /// object. Top-left normalized box out.
    nonisolated static func detect(_ handler: VNImageRequestHandler, preferCentre: Bool) -> (box: CGRect, isGroup: Bool)? {
        let faceReq = VNDetectFaceRectanglesRequest()
        let humanReq = VNDetectHumanRectanglesRequest()
        humanReq.upperBodyOnly = false
        let animalReq = VNRecognizeAnimalsRequest()
        try? handler.perform([faceReq, humanReq, animalReq])

        let faces = (faceReq.results ?? []).map(\.boundingBox).filter { $0.width > 0.03 }
        if !faces.isEmpty {
            let u = faces.dropFirst().reduce(faces[0]) { $0.union($1) }
            let fh = faces.map(\.height).max() ?? 0.1
            let body = CGRect(x: u.minX - fh * 0.6, y: u.minY - fh * 2.2,
                              width: u.width + fh * 1.2, height: u.height + fh * 2.6)
            if let b = box(around: body) { return (b, true) }
        }
        let people = (humanReq.results ?? []).filter { $0.confidence > 0.6 && $0.boundingBox.height > 0.15 }.map(\.boundingBox)
        if !people.isEmpty {
            let u = people.dropFirst().reduce(people[0]) { $0.union($1) }
            if let b = box(around: u) { return (b, true) }
        }
        let animals = (animalReq.results ?? []).filter { $0.confidence > 0.6 }.map(\.boundingBox)
        if let a = pick(animals, preferCentre: preferCentre), let b = box(around: a) { return (b, false) }

        let salReq = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? handler.perform([salReq])
        let objs = ((salReq.results?.first as? VNSaliencyImageObservation)?.salientObjects ?? [])
            .filter { $0.confidence > 0.5 && $0.boundingBox.width * $0.boundingBox.height > 0.01 }
        if let o = pick(objs.map(\.boundingBox), preferCentre: preferCentre), let b = box(around: o) { return (b, false) }
        return nil
    }

    /// One subject, not a merge of everything: the biggest, or (when locking)
    /// the one nearest the centre.
    nonisolated static func pick(_ rects: [CGRect], preferCentre: Bool) -> CGRect? {
        if preferCentre {
            return rects.min { hypot($0.midX - 0.5, $0.midY - 0.5) < hypot($1.midX - 0.5, $1.midY - 0.5) }
        }
        return rects.max { $0.width * $0.height < $1.width * $1.height }
    }

    nonisolated static func tilt(_ req: VNDetectHorizonRequest) -> Double? {
        guard let t = req.results?.first.map({ Double($0.angle) * 180 / .pi }), abs(t) <= 20 else { return nil }
        return t
    }

    /// Top-left box ⇄ Vision's bottom-left rect.
    nonisolated static func toVision(_ b: CGRect) -> CGRect { CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height) }
    nonisolated static func fromVision(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

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
