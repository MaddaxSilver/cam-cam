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

    init() { _ = FrameLearning.folder }   // exists from the start, so the Mac can pull it

    enum Stage: Equatable { case suggesting, locked, aligned }

    /// Where the subject should sit when the shot is right (not just centred):
    /// `anchor` is a point inside the subject box (e.g. the eye line),
    /// `target` where it goes in the frame (e.g. upper third), `fill` how much
    /// of the frame the subject box should fill after the lock's auto zoom.
    struct Composition: Equatable, Sendable {
        var anchor = CGPoint(x: 0.5, y: 0.5)
        var target = CGPoint(x: 0.5, y: 0.5)
        var fill: CGFloat = 0.82
        /// Shortest focal length that suits the subject (faces and food look
        /// distorted on the 13 mm), and whether the subject runs off the frame.
        var minMM: Int = 13
        var cutOff = false
        /// A scene framing (coastline, landscape): the box IS the view to zoom
        /// to, held in place with the gyro rather than visual tracking.
        var isScene = false
        /// From the generic object detector (not a person or pet).
        var isObject = false
    }
    typealias Subject = (box: CGRect, isGroup: Bool, comp: Composition)

    var enabled = UserDefaults.standard.object(forKey: "cc_frameAdvisor") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "cc_frameAdvisor")
            cachedEnabled = enabled
            if !enabled { unlock(); box = nil; hint = nil; SceneMotion.stop() } else { SceneMotion.start() }
        }
    }
    /// The box on screen, normalized image coordinates (top-left origin).
    private(set) var box: CGRect?
    private(set) var stage: Stage = .suggesting
    /// What to change ("Move left", "Zoom in", "Tilt 2° right"), or a tip.
    private(set) var hint: String?
    /// Width / height of the analysed camera image, to map the box on screen.
    private(set) var imageAspect: CGFloat = 3.0 / 4.0
    /// Phone attitude when `box` was measured, and the lens field of view —
    /// the screen re-projects the box with the gyro so it stays on the scene.
    private(set) var boxAttitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private(set) var fovLong: Double = 70
    /// Composition of the box on screen (used for the lock's zoom).
    private(set) var lastComp = Composition()

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
    @ObservationIgnored nonisolated(unsafe) private var lockedComp = Composition()
    @ObservationIgnored nonisolated(unsafe) private var shownComp = Composition()
    // Attitude / FOV of the frame being analysed, and of the stored `shown` box
    @ObservationIgnored nonisolated(unsafe) private var frameAttitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    @ObservationIgnored nonisolated(unsafe) private var frameFov: Double = 70
    @ObservationIgnored nonisolated(unsafe) private var shownAttitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    // Orientation: analysis runs on an upright copy of the frame (the way
    // you hold the phone), so thirds, hints and the horizon are right in
    // landscape. Boxes are kept upright and converted for display.
    @ObservationIgnored nonisolated(unsafe) var cachedAngle: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var pauseUntil: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var fovReadAt: Double = 0
    // Zoom to restore after the lock (Frame guide zooms in for the shot;
    // staying at 120–200 mm afterwards left a slow, low-fps telephoto preview).
    @ObservationIgnored private var preLockMM: Int?
    @ObservationIgnored private var lastZoomTargetMM: Double?
    @ObservationIgnored private weak var lockCamera: CameraManager?
    /// The lock wanted to go wider than this lens allows (suggest the 13 mm).
    @ObservationIgnored nonisolated(unsafe) private var lensLimited = false
    @ObservationIgnored nonisolated(unsafe) private var resetShown = false
    @ObservationIgnored nonisolated(unsafe) private var sdx: CGFloat = 0
    @ObservationIgnored nonisolated(unsafe) private var sdy: CGFloat = 0
    @ObservationIgnored nonisolated(unsafe) private var sTilt: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var wasAligned = false
    // Scan ("find your shot"): numbered picks, pinned to the scene.
    private(set) var scanning = false
    private(set) var picks: [CGRect] = []                 // buffer coords, best first
    private(set) var picksAttitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    @ObservationIgnored nonisolated(unsafe) private var scanRequested = false
    @ObservationIgnored nonisolated(unsafe) private var picksActive = false
    // Scene framing
    @ObservationIgnored nonisolated(unsafe) private var sceneWhy = ""
    @ObservationIgnored nonisolated(unsafe) private var sceneLock: CGRect?          // expected box after the zoom
    @ObservationIgnored nonisolated(unsafe) private var sceneArmed = false
    @ObservationIgnored nonisolated(unsafe) private var lastSceneAt: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var lastScene: Subject?
    @ObservationIgnored nonisolated(unsafe) private var lastSceneAttitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    @ObservationIgnored nonisolated(unsafe) private var frameAngle: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var bufferAspect: CGFloat = 3.0 / 4.0
    // Auto zoom while locked
    @ObservationIgnored nonisolated(unsafe) private var offFillSince: Double?
    @ObservationIgnored nonisolated(unsafe) private var lastZoomAt: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var zoomSteps = 0
    // Learning
    @ObservationIgnored nonisolated(unsafe) private var lastUpright: CIImage?
    @ObservationIgnored nonisolated(unsafe) private var lockContext: (image: CIImage, box: CGRect)?
    @ObservationIgnored nonisolated(unsafe) private var learned: (box: CGRect, comp: Composition, at: Double)?

    nonisolated private static let queue = DispatchQueue(label: "cam.frameadvisor", qos: .userInitiated)
    /// One shared context (making one per frame is slow and memory-hungry).
    nonisolated static let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// How much of the frame the subject should fill when lined up.
    nonisolated static let targetFill: CGFloat = 0.82

    // MARK: Lock

    /// Tap on the box: commit to this framing and start guiding.
    func lock(camera: CameraManager) {
        guard let b = box else { return }
        stage = .locked; cachedLocked = true
        alignedSince = nil; lostSince = nil; fired = false
        tracked = nil; tracker = nil
        offFillSince = nil; zoomSteps = 0
        sdx = 0; sdy = 0; sTilt = 0; wasAligned = false
        if let img = lastUpright, let u = shown { lockContext = (img, u) } else { lockContext = nil }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        preLockMM = camera.currentMM; lastZoomTargetMM = nil; lockCamera = camera; lensLimited = false
        camera.tapToFocus(at: CGPoint(x: b.midY, y: 1 - b.midX))   // focus on the subject
        // Auto zoom — in OR out — so the subject fills what suits it. A
        // subject running off the frame (a group cut at the edges) zooms out,
        // switching to the 13 mm if it has to; faces and food never go wider
        // than ~24 mm (wide-angle distortion).
        var comp = lastComp
        if let down = Self.downAngle(SceneMotion.attitude), down < 35 { comp.minMM = max(comp.minMM, 24) }
        var ratio = Double(comp.fill / max(b.width, b.height))
        if comp.cutOff { ratio = min(ratio, 0.7) }
        // A scan pick you tapped may switch lenses to reach its framing
        // (from the 13 mm a pick is often 2–5×, beyond the ultra-wide).
        let switching = pickLock && camera.zoomNeedsLensSwap(CGFloat(Double(max(camera.currentMM, 13)) * ratio / 26))
        let applied = zoom(by: ratio, minMM: comp.minMM, camera: camera, allowLensSwitch: pickLock)
        pickLock = false
        // Scenes: where the suggested view lands after the (centred) zoom —
        // then held on the scene with the gyro while you aim at it.
        sceneLock = nil; sceneArmed = false
        if comp.isScene, let u = shown {
            let z = CGFloat(applied ?? 1)
            sceneLock = CGRect(x: (u.midX - 0.5) * z + 0.5 - u.width * z / 2,
                               y: (u.midY - 0.5) * z + 0.5 - u.height * z / 2,
                               width: u.width * z, height: u.height * z)
            lockedComp = comp; lockedIsGroup = false
        }
        // Start tracking once the zoom (or lens switch) has settled.
        trackStartAt = CACurrentMediaTime() + (switching ? 1.5 : applied != nil ? 0.9 : 0.6)
    }

    /// Zoom by `ratio` (>1 in, <1 out) within the subject's lens range.
    /// Returns the zoom ratio actually applied, or nil if it didn't change.
    @discardableResult
    func zoom(by ratio: Double, minMM: Int, camera: CameraManager, allowLensSwitch: Bool = false) -> Double? {
        let cur = Double(max(camera.currentMM, 13))
        let lo = Double(max(minMM, 13)), hi = min(cur * 6, 200)   // far-off subjects need the long end
        var want = min(max(cur * ratio, lo), max(hi, lo))
        // Stay on the lens you're on: switching lenses reconfigures the
        // camera (~1 s preview freeze, measured), and so does switching back.
        // When the subject doesn't fit, the hint suggests the 13 mm instead.
        if !allowLensSwitch, camera.zoomNeedsLensSwap(CGFloat(want / 26)) {
            let onUW = camera.currentDevice?.deviceType == .builtInUltraWideCamera
            if camera.currentDevice?.deviceType == .builtInTelephotoCamera { return nil }
            if onUW { want = min(want, 25) }                      // ultra-wide tops out below 1×
            else if want < 26 { want = 26; lensLimited = true }   // can't go wider without the 13 mm
            else { want = min(want, 129) }                        // main lens: below the 5× switch
            if camera.zoomNeedsLensSwap(CGFloat(want / 26)) { return nil }
        }
        guard abs(want / cur - 1) > 0.08 else { return nil }
        camera.setZoom(CGFloat(want / 26))
        lastZoomTargetMM = want
        lastZoomAt = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { camera.syncZoomState() }
        return want / cur
    }

    #if DEBUG
    /// Profiling: lock on whatever is suggested (or a centre box), then run
    /// the same path as an aligned auto shot.
    func debugGuidedShot(camera: CameraManager) {
        if box == nil { box = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3); lastComp.fill = 0.8 }
        print(String(format: "[perf] %.2f LOCK box %.2f", CACurrentMediaTime(), max(box!.width, box!.height)))
        lock(camera: camera)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            print(String(format: "[perf] %.2f FIRE", CACurrentMediaTime()))
            self.fired = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if !camera.isCapturing { camera.capturePhoto() }
            self.stage = .aligned
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { FrameAdvisor.shared.unlock() }
        }
    }
    #endif

    /// The phone turned (portrait ⇄ landscape): boxes are in the old upright
    /// frame, so start over.
    func orientationChanged(_ angle: Double) {
        cachedAngle = angle
        if stage != .suggesting { unlock() }
        box = nil; hint = nil
    }

    /// A photo was taken with Frame guide on: log it as a framing example.
    func noteShot(camera: CameraManager) {
        guard cachedEnabled, camera.currentDevice?.position == .back else { return }
        pauseUntil = CACurrentMediaTime() + 1.0
        let mm = camera.currentMM
        if let img = lastUpright {
            FrameLearning.log(img, view: CGRect(x: 0, y: 0, width: 1, height: 1), kind: "shot", mm: mm, subject: nil)
        }
    }

    func unlock() {
        #if DEBUG
        print(String(format: "[perf] %.2f UNLOCK", CACurrentMediaTime()))
        #endif
        stage = .suggesting; cachedLocked = false
        lockContext = nil; sceneLock = nil; sceneArmed = false
        // Clear now: analysis pauses while the photo renders, and the box and
        // "Got it" stayed on screen for seconds after the shot.
        box = nil; hint = nil
        resetShown = true          // the analysis queue clears its own state (no cross-thread writes)
        // Put the zoom back where you had it — unless you changed it yourself.
        // Never if it means switching lenses: that reconfigures the camera and
        // froze the preview ~1.3 s right after the shot (measured on device).
        if let cam = lockCamera, let pre = preLockMM, let target = lastZoomTargetMM,
           abs(Double(cam.currentMM) - target) <= max(3, target * 0.12), abs(Double(pre) - target) > 2,
           !cam.zoomNeedsLensSwap(CGFloat(Double(pre) / 26)) {
            #if DEBUG
            print(String(format: "[perf] %.2f RESTORE zoom %d→%dmm", CACurrentMediaTime(), cam.currentMM, pre))
            #endif
            cam.setZoom(CGFloat(Double(pre) / 26))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { cam.syncZoomState() }
        }
        preLockMM = nil; lastZoomTargetMM = nil
        alignedSince = nil; lostSince = nil
        tracked = nil; tracker = nil
    }

    // MARK: Frames

    nonisolated func process(_ pixelBuffer: CVPixelBuffer, time: Double, camera: CameraManager) {
        let interval = cachedLocked ? 0.08 : 0.3
        // Stand aside while a photo is captured and rendered (~1.5 s for iOS
        // to deliver a 48MP photo, then the film render): Vision competing
        // with it for the GPU / Neural Engine dropped preview frames right
        // after auto shots. A fixed 1 s pause ended just as the render began.
        guard CACurrentMediaTime() >= pauseUntil, !camera.hasShotsInFlight else { return }
        guard cachedEnabled, !busy, time - lastTick >= interval,
              camera.currentDevice?.position == .back else { return }
        lastTick = time
        busy = true
        // 640 px: far-off people and objects are only a few pixels at 512.
        let s = 640 / CGFloat(max(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)))
        let angle = cachedAngle
        var small = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: CGAffineTransform(scaleX: s, y: s))
        if let o = Self.orientation(angle) {
            small = small.oriented(o)
            small = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
        }
        let bufAspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(max(CVPixelBufferGetHeight(pixelBuffer), 1))
        let aspect = small.extent.width / max(small.extent.height, 1)     // upright
        SceneMotion.start()
        frameAttitude = SceneMotion.attitude(at: time)   // attitude when this frame was captured
        let device = camera.currentDevice
        Self.queue.async { [self] in
            defer { busy = false }
            // The lens FOV, read here, not on the camera queue: AVCaptureDevice
            // property reads can wait on the session's configuration lock.
            if time - fovReadAt > 0.5 || cachedLocked { frameFov = SceneMotion.fovLong(device); fovReadAt = time }
            if angle != frameAngle {           // turned since the last frame
                frameAngle = angle; shown = nil; rival = nil; tracked = nil; learned = nil
            }
            bufferAspect = bufAspect
            // Copy the small frame out of the camera's buffer before keeping
            // it: holding a reference to a live camera buffer (for logging and
            // the lock context) starves the camera's small buffer pool and the
            // preview stutters — most visibly right after a shot.
            guard let cg = Self.ciContext.createCGImage(small, from: small.extent) else { return }
            let frame = CIImage(cgImage: cg)
            lastUpright = frame
            #if DEBUG
            let t0 = CACurrentMediaTime()
            #endif
            analyse(frame, time: time, aspect: aspect, camera: camera)
            #if DEBUG
            let dt = CACurrentMediaTime() - t0
            if dt > 0.08 { print(String(format: "[perf] %.2f FG-ANALYSE %.0f ms %@", CACurrentMediaTime(), dt * 1000, cachedLocked ? "locked" : "suggest")) }
            #endif
        }
    }

    nonisolated private func analyse(_ image: CIImage, time: Double, aspect: CGFloat, camera: CameraManager) {
        if resetShown { resetShown = false; shown = nil; rival = nil; tracked = nil; lastScene = nil }
        let horizonReq = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(ciImage: image)

        if cachedLocked {
            try? handler.perform([horizonReq])
            let tilt = Self.tilt(horizonReq)
            // Scene: no tracking — the view is pinned to the scene with the
            // gyro, and you aim the phone until it fills the frame.
            if let sl = sceneLock {
                guard CACurrentMediaTime() >= trackStartAt else { return }
                if !sceneArmed { shown = sl; shownAttitude = frameAttitude; sceneArmed = true }
                anchorShown(aspect: aspect)
                guide((shown ?? sl, false, lockedComp), tilt: tilt, time: time, aspect: aspect, camera: camera)
                return
            }
            // Wait for the lock's zoom to settle, then pick the subject again
            // (nearest the centre) and track it from then on.
            if tracked == nil {
                guard CACurrentMediaTime() >= trackStartAt else { return }
                guard let f = Self.detect(handler, preferCentre: true) else {
                    guide(nil, tilt: tilt, time: time, aspect: aspect, camera: camera); return
                }
                lockedIsGroup = f.isGroup
                lockedComp = f.comp
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
                guide((Self.fromVision(obs.boundingBox), lockedIsGroup, lockedComp), tilt: tilt, time: time, aspect: aspect, camera: camera)
            } else {
                guide(nil, tilt: tilt, time: time, aspect: aspect, camera: camera)
            }
            return
        }

        try? handler.perform([horizonReq])
        if scanRequested {
            scanRequested = false
            // Tighter crops than the passive suggestion (up to 5×), top three.
            let r = SceneFraming.top(handler: handler, image: image, context: Self.ciContext,
                                     minScale: 0.2, n: 3, margin: 0.1)
            let a = frameAngle
            publishPicks(r.map { Self.toBuffer($0.view, angle: a) }, attitude: frameAttitude)
            return
        }
        if picksActive { publish(box: nil, stage: .suggesting, hint: nil, aspect: aspect); return }
        var found = Self.detect(handler, preferCentre: false)
        // Landscapes, coastlines, skylines: no person or pet in frame (and
        // either nothing found or just a generic object in a scene with a
        // horizon) — suggest the best framing of the whole scene instead.
        // Re-scored every ~0.9 s; between scorings the last one rides the gyro.
        if found == nil || (found!.comp.isObject && Self.tilt(horizonReq) != nil) {
            if time - lastSceneAt > 0.9 {
                lastSceneAt = time
                lastScene = nil
                if let r = SceneFraming.best(handler: handler, image: image, context: Self.ciContext) {
                    var c = Composition()
                    c.anchor = CGPoint(x: 0.5, y: 0.5); c.target = CGPoint(x: 0.5, y: 0.5)
                    c.fill = 0.97; c.isScene = true
                    lastScene = (r.view, false, c)
                    lastSceneAttitude = frameAttitude
                    sceneWhy = r.why
                } else if found == nil, frameFov < 90, SceneFraming.wantsWider(handler: handler) {
                    sceneWhy = "wider"
                } else {
                    sceneWhy = ""
                }
            }
            if var sc = lastScene {
                // Between scorings, carry it with the gyro (the phone moved).
                let a = frameAngle, ba = Double(bufferAspect)
                sc.box = Self.toUpright(SceneMotion.reproject(Self.toBuffer(sc.box, angle: a), from: lastSceneAttitude,
                                                              to: frameAttitude, fovLong: frameFov, aspect: ba), angle: a)
                lastScene = sc; lastSceneAttitude = frameAttitude
                found = sc
            }
        } else {
            lastScene = nil; sceneWhy = ""
        }
        // Learned placement (trained on the Mac from your shots), refreshed
        // every ~1.5 s for the same subject.
        if let f = found, !f.comp.isScene {
            if let l = learned, Self.iou(l.box, f.box) > 0.4, time - l.at < 1.5 {
                found!.comp = l.comp
            } else if let c = FrameLearning.refine(f.box, comp: f.comp, handler: handler) {
                learned = (f.box, c, time); found!.comp = c
            } else {
                learned = (f.box, f.comp, time)
            }
        }
        suggest(found, tilt: Self.tilt(horizonReq), time: time, aspect: aspect, image: image)
    }

    // MARK: Stage 1 — suggest (calm)

    nonisolated private func suggest(_ found: Subject?, tilt: Double?, time: Double, aspect: CGFloat, image: CIImage) {
        anchorShown(aspect: aspect)
        if let f = found, f.comp.isScene || Self.worthFraming(f.box) {
            lastSeen = time
            shownComp = f.comp
            if let cur = shown {
                if Self.iou(cur, f.box) > 0.35 {
                    // Glide — but ignore small detection jitter (the box
                    // twitched between analysis passes).
                    let shift = hypot(f.box.midX - cur.midX, f.box.midY - cur.midY) / max(cur.width, cur.height)
                    let grow = abs(f.box.width - cur.width) / max(cur.width, 0.01)
                    if shift > 0.06 || grow > 0.08 { shown = Self.lerp(cur, f.box, 0.18) }
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
        if let down = Self.downAngle(frameAttitude), down < 35 {
            // Overhead / flat lay (food, table): hold the phone parallel to it.
            tip = down < 2 ? "Flat ✓" : String(format: "Hold it flat — %.0f°", down)
        } else if let t = tilt, abs(t) > 1.5 {
            tip = String(format: "Tilt %.0f° %@", abs(t), t > 0 ? "right" : "left")
        } else if shown == nil, tilt != nil, let h = Self.horizonPlacement(image) {
            // Landscape: horizon on a third — more of whichever half has more
            // going on. Busy sky → horizon on the lower third (more sky);
            // busy ground → horizon on the upper third (more foreground).
            // Tilting the phone up moves the horizon DOWN the frame.
            let want: CGFloat = h.skyBusier ? 2.0 / 3 : 1.0 / 3       // top-left y
            if abs(h.y - want) > 0.08 {
                if h.y < want { tip = h.skyBusier ? "Tilt up — more sky" : "Tilt up a little" }
                else { tip = h.skyBusier ? "Tilt down a little" : "Tilt down — more foreground" }
            }
        } else if shown != nil, shownComp.isScene, let b = shown {
            let z = shownComp.fill / max(b.width, b.height)
            tip = String(format: "Tap the box · %@ (%.1f×)", sceneWhy.isEmpty ? "tighter framing" : sceneWhy, z)
        } else if shown == nil, sceneWhy == "wider" {
            tip = "Try 13mm — the scene runs off the edges"
        } else if shown != nil {
            tip = (found?.isGroup ?? false) ? "Tap the box to frame the group" : "Tap the box to frame this shot"
        }
        publish(box: shown, stage: .suggesting, hint: tip, aspect: aspect)
    }

    // MARK: Stage 2 — locked: guide until it's right, then shoot

    nonisolated private func guide(_ found: Subject?, tilt: Double?, time: Double, aspect: CGFloat, camera: CameraManager) {
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
        anchorShown(aspect: aspect)
        let b = shown.map { Self.lerp($0, f.box, 0.6) } ?? f.box
        shown = b

        // Errors: centre offset, fill, horizon tilt.
        // Composition, not just centring: put the anchor (eye line / subject)
        // on its target (thirds, headroom, lead room).
        let c = f.comp
        let ax = b.minX + c.anchor.x * b.width, ay = b.minY + c.anchor.y * b.height
        // Smoothed (hand shake and tracker jitter made the guidance twitch).
        let rdx = ax - c.target.x, rdy = ay - c.target.y
        sdx = sdx * 0.6 + rdx * 0.4; sdy = sdy * 0.6 + rdy * 0.4
        let dx = sdx, dy = sdy
        let fill = max(b.width, b.height)
        let fillErr = fill - Self.targetFill
        sTilt = sTilt * 0.6 + (tilt ?? 0) * 0.4
        let tiltErr = sTilt
        // Keep the size right as the subject moves closer / further (or the
        // lock's first zoom wasn't enough): re-zoom after it's been off ~1 s.
        if !c.isScene, (fillErr > 0.18 || fill > 0.97 || fillErr < -0.3), zoomSteps < 3, time - lastZoomAt > 2 {
            if offFillSince == nil { offFillSince = time }
            if time - offFillSince! > 1 {
                offFillSince = nil; zoomSteps += 1
                let ratio = Double(c.fill / max(fill, 0.05)) * (fill > 0.97 ? 0.8 : 1)
                let minMM = c.minMM
                lastZoomAt = time
                DispatchQueue.main.async {
                    if FrameAdvisor.shared.zoom(by: ratio, minMM: minMM, camera: camera) != nil {
                        FrameAdvisor.shared.retrack(after: 0.8)
                    }
                }
            }
        } else { offFillSince = nil }
        // Looser, with hysteresis: once lined up it stays lined up until you
        // drift clearly out (was 5% / 6.5% / 1°, flipping on every wobble).
        let k: CGFloat = wasAligned ? 1.5 : 1
        let centred = abs(dx) < 0.08 * k && abs(dy) < 0.1 * k
        let level = abs(tiltErr) < 2.0 * Double(k)
        wasAligned = centred && level
        let aligned = centred && level

        var tip: String
        if lensLimited && fill > 0.9 { tip = "Step back, or switch to 13mm to fit everyone" }
        else if !level { tip = String(format: "Tilt %.0f° %@", max(1, abs(tiltErr)), tiltErr > 0 ? "right" : "left") }
        else if !centred {
            tip = abs(dx) >= abs(dy) ? (dx < 0 ? "Move left" : "Move right") : (dy < 0 ? "Tilt up" : "Tilt down")
        } else { tip = "Hold it…" }

        if aligned {
            if alignedSince == nil { alignedSince = time }
            // Holding on target: quick firm ticks until it fires.
            if time - lastPulse >= 0.1 {
                lastPulse = time
                DispatchQueue.main.async { FrameAdvisor.pulse(0.8, rigid: true) }
            }
            if time - alignedSince! > 0.4, !fired {
                fired = true
                #if DEBUG
                print(String(format: "[perf] %.2f FIRE (auto)", CACurrentMediaTime()))
                #endif
                logGuided(final: b, comp: c, camera: camera)
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
            // Haptic guidance, never silent while guiding: a steady pulse that
            // quickens and firms up as you get closer (like a metal detector).
            let err = min(1, Double(abs(dx) + abs(dy)) * 1.6 + abs(tiltErr) / 12)
            let interval = 0.1 + 0.35 * err
            if time - lastPulse >= interval {
                lastPulse = time
                let strength = CGFloat(0.45 + 0.35 * (1 - err))
                DispatchQueue.main.async { FrameAdvisor.pulse(strength) }
            }
            publish(box: b, stage: .locked, hint: tip, aspect: aspect)
        }
    }

    /// One prepared generator per feel (making one per pulse adds latency
    /// and main-thread work).
    private static let softPulse = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidPulse = UIImpactFeedbackGenerator(style: .rigid)
    static func pulse(_ intensity: CGFloat, rigid: Bool = false) {
        let g = rigid ? rigidPulse : softPulse
        g.impactOccurred(intensity: intensity)
        g.prepare()
    }

    /// Scan: look over the whole view and pin up to three numbered framings
    /// to aim at (the iPhone 18 "finding your shot" idea).
    func scan() {
        guard enabled else { return }
        if stage != .suggesting { unlock() }
        picks = []; picksActive = false
        scanning = true; hint = "Finding your shot…"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let started = CACurrentMediaTime()
        scanStarted = started
        scanRequested = true
    }
    @ObservationIgnored private var scanStarted: Double = 0
    @ObservationIgnored private var pickLock = false

    /// Tap on a numbered pick: zoom to it and guide you there.
    func lockPick(_ i: Int, camera: CameraManager) {
        guard picks.indices.contains(i) else { return }
        let now = SceneMotion.attitude
        let b = SceneMotion.reproject(picks[i], from: picksAttitude, to: now, fovLong: fovLong, aspect: Double(imageAspect))
        shown = Self.toUpright(b, angle: cachedAngle); shownAttitude = now
        var c = Composition(); c.fill = 0.97; c.isScene = true
        lastComp = c; shownComp = c
        box = b
        picks = []; picksActive = false
        pickLock = true
        lock(camera: camera)
    }

    nonisolated private func publishPicks(_ rects: [CGRect], attitude: simd_quatd) {
        Task { @MainActor in
            let a = FrameAdvisor.shared
            // Let "Finding your shot…" read for a moment.
            let wait = max(0, 0.9 - (CACurrentMediaTime() - a.scanStarted))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            guard a.scanning else { return }
            a.scanning = false
            a.picks = rects; a.picksAttitude = attitude; a.picksActive = !rects.isEmpty
            a.hint = rects.isEmpty ? "Nothing better in this view — try another" : "Aim at a number and tap it"
            UINotificationFeedbackGenerator().notificationOccurred(rects.isEmpty ? .warning : .success)
            if !rects.isEmpty {
                // Picks fade after 20 s.
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if a.picksAttitude == attitude, a.stage == .suggesting { a.picks = []; a.picksActive = false; a.hint = nil }
            }
        }
    }

    /// After a zoom: detect the subject again and track it from there.
    func retrack(after delay: Double) {
        trackStartAt = CACurrentMediaTime() + delay
        tracked = nil; tracker = nil
    }

    /// Guided shot: in the wide view seen at the lock, mark where the final
    /// framing ended up (subject anchor on its target, at today's fill).
    nonisolated private func logGuided(final b: CGRect, comp c: Composition, camera: CameraManager) {
        guard let ctx = lockContext else { return }
        let fillNow = max(b.width, b.height)
        var cc = c; cc.fill = max(fillNow, 0.05)
        // The subject's box in the lock-time view, scaled to the final fill.
        if let v = FrameLearning.view(for: ctx.box, comp: cc) {
            let subj = lockedIsGroup ? "people" : "object"
            DispatchQueue.main.async {
                FrameLearning.log(ctx.image, view: v, kind: "guided", mm: camera.currentMM, subject: subj)
            }
        }
    }

    /// Image orientation that turns the (portrait) camera buffer upright for
    /// the way the phone is held. `iconAngle`: 90 = top of the phone to the left.
    nonisolated static func orientation(_ angle: Double) -> CGImagePropertyOrientation? {
        switch angle {
        case 90: return .left
        case -90: return .right
        case 180: return .down
        default: return nil
        }
    }

    /// Upright ⇄ buffer coordinates (top-left normalized rects).
    nonisolated static func toBuffer(_ r: CGRect, angle: Double) -> CGRect {
        switch angle {
        case 90: return CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
        case -90: return CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
        case 180: return CGRect(x: 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)
        default: return r
        }
    }
    nonisolated static func toUpright(_ r: CGRect, angle: Double) -> CGRect {
        switch angle {
        case 90: return CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
        case -90: return CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
        case 180: return CGRect(x: 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)
        default: return r
        }
    }

    // MARK: Detection

    /// The thing to frame, smartest first: faces (group, padded for bodies),
    /// people's bodies, cats and dogs, then the single strongest stand-out
    /// object. Top-left normalized box out.
    nonisolated static func detect(_ handler: VNImageRequestHandler, preferCentre: Bool) -> Subject? {
        // One detector at a time, stopping at the first that finds something
        // (faces are cheap; bodies, animals and saliency only run when needed).
        let faceReq = VNDetectFaceRectanglesRequest()
        try? handler.perform([faceReq])

        let third: CGFloat = 1.0 / 3
        func nearestThird(_ v: CGFloat) -> CGFloat { v < 0.5 ? third : 1 - third }

        let faceObs = (faceReq.results ?? []).filter { $0.boundingBox.width > 0.012 }   // far-off faces too
        if !faceObs.isEmpty {
            let faces = faceObs.map(\.boundingBox)
            let u = faces.dropFirst().reduce(faces[0]) { $0.union($1) }
            let edge: CGFloat = 0.04
            let facesCut = u.minX < edge || u.maxX > 1 - edge || u.maxY > 1 - edge
            let fh = faces.map(\.height).max() ?? 0.1
            let body = CGRect(x: u.minX - fh * 0.6, y: u.minY - fh * 2.2,
                              width: u.width + fh * 1.2, height: u.height + fh * 2.6)
            if let b = box(around: body) {
                // Eye line ~62% up each face box (Vision is bottom-left).
                let eyeY = 1 - (faces.map { $0.minY + $0.height * 0.62 }.reduce(0, +) / CGFloat(faces.count))
                let eyeX = faces.map(\.midX).reduce(0, +) / CGFloat(faces.count)
                var comp = Composition()
                comp.anchor = CGPoint(x: (eyeX - b.minX) / b.width, y: (eyeY - b.minY) / b.height)
                if faceObs.count == 1 {
                    // Portrait: eyes on the upper third; looking aside → lead
                    // room in front of the face (subject on the far third).
                    let yaw = faceObs[0].yaw?.doubleValue ?? 0
                    let x: CGFloat = abs(yaw) > 0.25 ? (yaw > 0 ? third : 1 - third) : 0.5
                    comp.target = CGPoint(x: x, y: third)
                    comp.fill = 0.7
                    comp.minMM = 24
                } else {
                    // Group: centred, eyes a little under the upper third (headroom).
                    comp.target = CGPoint(x: 0.5, y: 0.36)
                    comp.fill = 0.82
                    comp.cutOff = facesCut
                }
                return (b, true, comp)
            }
        }
        let humanReq = VNDetectHumanRectanglesRequest()
        humanReq.upperBodyOnly = false
        try? handler.perform([humanReq])
        let people = (humanReq.results ?? []).filter { $0.confidence > 0.5 && $0.boundingBox.height > 0.06 }.map(\.boundingBox)
        if !people.isEmpty {
            let u = people.dropFirst().reduce(people[0]) { $0.union($1) }
            if let b = box(around: u) {
                var comp = Composition()
                comp.anchor = CGPoint(x: 0.5, y: 0.12)            // roughly the head
                comp.target = CGPoint(x: b.width > 0.45 ? 0.5 : nearestThird(b.midX), y: 0.28)
                comp.fill = 0.8
                comp.cutOff = u.minX < 0.03 || u.maxX > 0.97 || u.maxY > 0.97
                return (b, true, comp)
            }
        }
        // Pets and objects: on the nearest thirds intersection unless big.
        func objectComp(_ b: CGRect) -> Composition {
            var comp = Composition()
            comp.anchor = CGPoint(x: 0.5, y: 0.5)
            comp.target = max(b.width, b.height) > 0.5 ? CGPoint(x: 0.5, y: 0.5)
                : CGPoint(x: nearestThird(b.midX), y: nearestThird(b.midY))
            comp.fill = 0.6
            comp.isObject = true
            return comp
        }
        let animalReq = VNRecognizeAnimalsRequest()
        try? handler.perform([animalReq])
        let animals = (animalReq.results ?? []).filter { $0.confidence > 0.5 }.map(\.boundingBox)
        if let a = pick(animals, preferCentre: preferCentre), let b = box(around: a) {
            var c = objectComp(b); c.minMM = 24; c.isObject = false
            return (b, false, c)
        }

        let salReq = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? handler.perform([salReq])
        let objs = ((salReq.results?.first as? VNSaliencyImageObservation)?.salientObjects ?? [])
            .filter { $0.confidence > 0.3 && $0.boundingBox.width * $0.boundingBox.height > 0.002 }
        if let o = pick(objs.map(\.boundingBox), preferCentre: preferCentre), let b = box(around: o), worthFraming(b) {
            return (b, false, objectComp(b))
        }
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

    /// Degrees between the camera's view and straight down (nil when it's
    /// not pointing downward at all).
    nonisolated static func downAngle(_ q: simd_quatd) -> Double? {
        let view = q.act(simd_double3(0, 0, -1))        // camera direction in the world (z up)
        guard view.z < 0 else { return nil }
        return acos(min(1, -view.z)) * 180 / .pi
    }

    /// Where the horizon sits (top-left y) and whether the sky half has more
    /// detail than the ground half — from luminance down the frame.
    nonisolated static func horizonPlacement(_ image: CIImage) -> (y: CGFloat, skyBusier: Bool)? {
        SceneFraming.horizonPlacement(image, context: ciContext)
    }

    nonisolated static func tilt(_ req: VNDetectHorizonRequest) -> Double? {
        guard let t = req.results?.first.map({ Double($0.angle) * 180 / .pi }), abs(t) <= 20 else { return nil }
        return t
    }

    /// Top-left box ⇄ Vision's bottom-left rect.
    nonisolated static func toVision(_ b: CGRect) -> CGRect { CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height) }
    nonisolated static func fromVision(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

    nonisolated static func box(around r: CGRect) -> CGRect? {
        // Margin scales with the subject, so a small far-off subject gets a
        // tight box (and the lock zooms in far enough) instead of a fixed 5%.
        let m = max(0.012, 0.12 * max(r.width, r.height))
        let b = r.insetBy(dx: -m, dy: -m).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !b.isNull, b.width > 0.03, b.height > 0.03 else { return nil }
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

    /// Carry the stored box to this frame's attitude (the phone moved since).
    nonisolated private func anchorShown(aspect: CGFloat) {
        // Reprojection works in the camera buffer's frame (the gyro's portrait axes).
        let a = frameAngle, ba = Double(bufferAspect)
        func carry(_ r: CGRect) -> CGRect {
            Self.toUpright(SceneMotion.reproject(Self.toBuffer(r, angle: a), from: shownAttitude, to: frameAttitude,
                                                 fovLong: frameFov, aspect: ba), angle: a)
        }
        if let b = shown { shown = carry(b) }
        if let r = rival { rival = carry(r) }
        shownAttitude = frameAttitude
    }

    nonisolated private func publish(box: CGRect?, stage: Stage, hint: String?, aspect: CGFloat) {
        let att = frameAttitude, fov = frameFov
        let comp = cachedLocked ? lockedComp : shownComp
        let angle = frameAngle, bufAspect = bufferAspect
        let box = box.map { Self.toBuffer($0, angle: angle) }      // screen draws buffer coords
        Task { @MainActor in
            let a = FrameAdvisor.shared
            guard a.cachedEnabled, a.cachedAngle == angle else { return }
            // Only touch what changed: every observed write redraws the box.
            if a.imageAspect != bufAspect { a.imageAspect = bufAspect }
            if a.fovLong != fov { a.fovLong = fov }
            if a.lastComp.target != comp.target || a.lastComp.fill != comp.fill
                || a.lastComp.minMM != comp.minMM || a.lastComp.cutOff != comp.cutOff { a.lastComp = comp }
            if a.box != box { a.boxAttitude = att; a.box = box }
            if (a.cachedLocked || stage == .suggesting), a.stage != stage { a.stage = stage }
            if a.hint != hint, !(a.picksActive || a.scanning) || hint != nil { a.hint = hint }
        }
    }
}

// MARK: - Scene anchoring (gyro reprojection)
//
// Keeps the box pinned to the scene between Vision updates, like AR: the box
// is stored with the phone's attitude at the moment it was measured, and
// every display frame its corners are turned into 3D view directions, rotated
// by how far the phone has turned since, and projected back to the screen.

import CoreMotion
import simd

nonisolated enum SceneMotion {
    private static let manager = CMMotionManager()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var latest = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    nonisolated(unsafe) private static var running = false

    static func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running, manager.isDeviceMotionAvailable else { return }
        running = true
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        let q = OperationQueue(); q.qualityOfService = .userInteractive
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: q) { m, _ in
            guard let m else { return }
            let a = m.attitude.quaternion
            let qd = simd_quatd(ix: a.x, iy: a.y, iz: a.z, r: a.w)
            #if DEBUG
            if history.isEmpty { print(String(format: "[perf] clocks motion %.3f media %.3f", m.timestamp, CACurrentMediaTime())) }
            #endif
            lock.lock()
            latest = qd
            history.append((m.timestamp, qd))
            if history.count > 90 { history.removeFirst(history.count - 90) }   // ~1.5 s
            lock.unlock()
        }
    }

    static func stop() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        running = false
        manager.stopDeviceMotionUpdates()
    }

    /// Device attitude (device → reference frame).
    static var attitude: simd_quatd { lock.lock(); defer { lock.unlock() }; return latest }

    nonisolated(unsafe) private static var history: [(TimeInterval, simd_quatd)] = []
    /// Capture time (host clock) of the frame now on screen.
    nonisolated(unsafe) static var displayedFrameTime: TimeInterval = 0

    /// Attitude at a moment in the last ~1.5 s (host clock, same as video
    /// frame timestamps), interpolated between gyro samples.
    static func attitude(at t: TimeInterval) -> simd_quatd {
        lock.lock(); defer { lock.unlock() }
        guard t > 0, let last = history.last, let first = history.first else { return latest }
        // Clocks disagree or the moment is out of range: use the live reading.
        if t > last.0 + 0.25 || t < first.0 - 0.05 { return latest }
        if t >= last.0 { return last.1 }
        guard let i = history.lastIndex(where: { $0.0 <= t }) else { return history.first?.1 ?? latest }
        let a = history[i], b = history[min(i + 1, history.count - 1)]
        let span = b.0 - a.0
        return span > 0 ? simd_slerp(a.1, b.1, (t - a.0) / span) : a.1
    }

    /// The attitude that matches what's on screen: the displayed preview
    /// frame was captured ~50–100 ms ago, and placing the box with "now"
    /// made it run ahead of the picture whenever the phone moved.
    static var displayedAttitude: simd_quatd { attitude(at: displayedFrameTime) }

    /// Move a top-left normalized image rect measured at attitude `from` to
    /// where that part of the scene appears at attitude `to`.
    /// - fovLong: field of view of the image's long side (degrees), after zoom.
    /// - aspect: image width / height (portrait < 1).
    static func reproject(_ r: CGRect, from: simd_quatd, to: simd_quatd, fovLong: Double, aspect: Double) -> CGRect {
        let tanLong = tan(fovLong * .pi / 360)
        // Portrait image: the long side is vertical.
        let ty = aspect < 1 ? tanLong : tanLong * (1 / aspect)
        let tx = aspect < 1 ? tanLong * aspect : tanLong
        let delta = to.inverse * from      // rotates directions from the old device frame to the new
        func move(_ u: Double, _ v: Double) -> (Double, Double)? {
            // Device frame (portrait): x right, y up, camera looks along -z.
            let d = simd_double3(tx * (2 * u - 1), -ty * (2 * v - 1), -1)
            let n = delta.act(d)
            guard n.z < -0.05 else { return nil }   // behind the camera
            let x = n.x / -n.z, y = n.y / -n.z
            return ((x / tx + 1) / 2, (-y / ty + 1) / 2)
        }
        let pts = [(r.minX, r.minY), (r.maxX, r.minY), (r.minX, r.maxY), (r.maxX, r.maxY)].compactMap { move($0.0, $0.1) }
        guard pts.count == 4 else { return r }
        let xs = pts.map(\.0), ys = pts.map(\.1)
        // Keep the size (rotation would inflate an axis-aligned bound); move the centre.
        let cx = (xs.min()! + xs.max()!) / 2, cy = (ys.min()! + ys.max()!) / 2
        return CGRect(x: cx - r.width / 2, y: cy - r.height / 2, width: r.width, height: r.height)
    }

    /// Long-side field of view of the current camera image, after zoom.
    static func fovLong(_ device: AVCaptureDevice?) -> Double {
        guard let d = device else { return 70 }
        let fov = Double(d.activeFormat.videoFieldOfView)
        let z = Double(max(d.videoZoomFactor, 1))
        return 2 * atan(tan(fov * .pi / 360) / z) * 180 / .pi
    }
}
