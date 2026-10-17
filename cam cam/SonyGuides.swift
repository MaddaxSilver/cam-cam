//
//  SonyGuides.swift
//  cam cam
//
//  Frame guide and Pose guide for the Sony camera, on its live view.
//
//  The iPhone Frame guide holds its box in place with the phone's gyro and
//  zooms the phone's lenses; neither exists for a Sony on its own body. So
//  here every live-view frame is re-analysed with the same detectors and
//  composition rules (FrameAdvisor.detect / SceneFraming), and the guide
//  draws where the shot should be and says how to get there: pan, zoom in or
//  out by how much, until it lines up — then a haptic, and optionally the
//  Sony's shutter.
//
//  Pose guide runs its own analysis (PoseGuide) on the same frames, and its
//  "matched" shot fires the Sony.
//

import CoreImage
import CoreMotion
import SwiftUI
import Vision

@MainActor @Observable
final class SonyGuides {
    nonisolated static let shared = SonyGuides()
    nonisolated init() {}

    var frameOn = UserDefaults.standard.bool(forKey: "cc_sonyFrameGuide") {
        didSet {
            UserDefaults.standard.set(frameOn, forKey: "cc_sonyFrameGuide"); cachedFrameOn = frameOn
            if !frameOn { target = nil; hint = nil; aligned = false; picks = []; chosenPick = nil }
            // First time on with this mount: calibrate the level before guiding.
            if frameOn && !oldValue && !calibrated { showCalibration = true }
            updateMotion()
        }
    }

    // MARK: Level (the phone rides on the camera)
    //
    // The phone is mounted on the Sony at whatever angle suits you (on top,
    // tilted back ~47° toward you). Calibrating records which way is "down"
    // and "forward" for the CAMERA in the phone's own axes, so from then on
    // the phone's gravity sensor gives the camera's roll and pitch.

    /// Camera axes in phone coordinates (saved; redo after remounting).
    private(set) var calibrated = UserDefaults.standard.array(forKey: "cc_sonyMount") != nil
    var showCalibration = false
    /// Camera roll (horizon tilt, + = clockwise) and pitch (+ = pointing up), degrees.
    private(set) var roll: Double = 0
    private(set) var pitch: Double = 0
    @ObservationIgnored private var axes: (right: SIMD3<Double>, up: SIMD3<Double>, fwd: SIMD3<Double>)? = {
        guard let a = UserDefaults.standard.array(forKey: "cc_sonyMount") as? [Double], a.count == 9 else { return nil }
        return (SIMD3(a[0], a[1], a[2]), SIMD3(a[3], a[4], a[5]), SIMD3(a[6], a[7], a[8]))
    }()
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored nonisolated(unsafe) private var cachedRoll: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var cachedCalibrated = UserDefaults.standard.array(forKey: "cc_sonyMount") != nil
    @ObservationIgnored private var lastGravity: SIMD3<Double>?

    private func updateMotion() {
        let want = attached && frameOn && motion.isDeviceMotionAvailable
        if want && !motion.isDeviceMotionActive {
            motion.deviceMotionUpdateInterval = 1.0 / 20
            motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
                guard let self, let g = m?.gravity else { return }
                let v = SIMD3(g.x, g.y, g.z)
                lastGravity = v
                guard let a = axes else { return }
                let gc = SIMD3((v * a.right).sum(), (v * a.up).sum(), (v * a.fwd).sum())
                let r = atan2(gc.x, -gc.y) * 180 / .pi
                let pt = atan2(-gc.z, -gc.y) * 180 / .pi
                // Light smoothing so the level doesn't shimmer.
                roll += (r - roll) * 0.35; pitch += (pt - pitch) * 0.35
                cachedRoll = roll
            }
        } else if !want && motion.isDeviceMotionActive {
            motion.stopDeviceMotionUpdates()
        }
    }

    /// Camera held level and pointed straight ahead: record the mount.
    func calibrate() {
        guard let g = lastGravity ?? motion.deviceMotion.map({ SIMD3($0.gravity.x, $0.gravity.y, $0.gravity.z) }) else { return }
        let up = -g / max(simd_length(g), 1e-6)
        // The phone faces you from the top of the camera, so the camera looks
        // out of the phone's back (−z). Keep the part of that square to "up".
        var fwd = SIMD3<Double>(0, 0, -1)
        fwd -= up * (fwd * up).sum()
        if simd_length(fwd) < 0.2 { fwd = SIMD3(0, 1, 0) - up * up.y }    // phone mounted flat: use its top
        fwd /= max(simd_length(fwd), 1e-6)
        let right = simd_cross(fwd, up)
        axes = (right, up, fwd)
        UserDefaults.standard.set([right.x, right.y, right.z, up.x, up.y, up.z, fwd.x, fwd.y, fwd.z], forKey: "cc_sonyMount")
        calibrated = true; cachedCalibrated = true
        roll = 0; pitch = 0; cachedRoll = 0
        showCalibration = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: Shot finder (numbered picks of the current view)

    /// Up to three framings of the current live view; tap one to be guided to it.
    private(set) var picks: [CGRect] = []
    var chosenPick: Int? { didSet { cachedChosen = chosenPick.flatMap { picks.indices.contains($0) ? picks[$0] : nil } } }
    @ObservationIgnored nonisolated(unsafe) private var cachedChosen: CGRect?
    @ObservationIgnored nonisolated(unsafe) private var lastFrame: CGImage?

    func findShots() {
        guard let cg = lastFrame else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Self.queue.async {
            let img = CIImage(cgImage: cg)
            let r = SceneFraming.top(handler: VNImageRequestHandler(ciImage: img), image: img, context: Self.ctx,
                                     minScale: 0.2, n: 3, margin: 0.1)
            Task { @MainActor in
                let g = SonyGuides.shared
                g.picks = r.map(\.view); g.chosenPick = nil
                if r.isEmpty { g.hint = "Nothing better than this framing" }
            }
        }
    }
    /// The Pose guide is the same setting as on the iPhone camera.
    var poseOn: Bool {
        get { PoseGuide.shared.enabled }
        set { PoseGuide.shared.enabled = newValue }
    }
    /// Fire the Sony when the framing lines up (Frame guide).
    var autoShoot = UserDefaults.standard.bool(forKey: "cc_sonyFrameAuto") {
        didSet { UserDefaults.standard.set(autoShoot, forKey: "cc_sonyFrameAuto") }
    }

    /// The suggested framing, top-left normalised in the live-view frame.
    private(set) var target: CGRect?
    private(set) var hint: String?
    private(set) var aligned = false

    @ObservationIgnored weak var sony: SonyConnector?
    @ObservationIgnored nonisolated(unsafe) weak var cameraRef: CameraManager?

    @ObservationIgnored nonisolated(unsafe) var cachedFrameOn = UserDefaults.standard.bool(forKey: "cc_sonyFrameGuide")
    nonisolated var cachedPoseOn: Bool { PoseGuide.shared.cachedEnabled }
    @ObservationIgnored nonisolated(unsafe) private var busy = false
    @ObservationIgnored nonisolated(unsafe) private var lastTick: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var alignedSince: Double?
    @ObservationIgnored nonisolated(unsafe) private var firedAt: Double = 0
    nonisolated private static let queue = DispatchQueue(label: "cam.sony.guides", qos: .userInitiated)
    nonisolated private static let ctx = CIContext(options: [.cacheIntermediates: false])

    nonisolated var active: Bool { attached && (cachedFrameOn || cachedPoseOn) }
    @ObservationIgnored nonisolated(unsafe) private var attached = false

    /// The Sony screen is showing: guides read its live view and fire it.
    func attach(sony: SonyConnector, camera: CameraManager) {
        self.sony = sony; cameraRef = camera; attached = true
        updateMotion()
        PoseGuide.shared.externalShutter = { Task { @MainActor in SonyGuides.shared.fire() } }
    }
    func detach() {
        attached = false; target = nil; hint = nil; aligned = false
        updateMotion()
        PoseGuide.shared.externalShutter = nil
    }

    private func fire() {
        guard let sony else { return }          // triggerShutter ignores taps while busy
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        sony.triggerShutter()
    }

    /// A decoded live-view frame (un-graded). Called from the live-view loop.
    nonisolated func feed(_ frame: CIImage) {
        let t = CACurrentMediaTime()
        guard active, !busy, t - lastTick >= 0.25 else { return }
        lastTick = t; busy = true
        let e = frame.extent
        let s = 640 / max(e.width, e.height)
        let small = frame.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        Self.queue.async { [self] in
            defer { busy = false }
            guard let cg = Self.ctx.createCGImage(small, from: small.extent) else { return }
            lastFrame = cg
            if cachedPoseOn, let cam = cameraRef { PoseGuide.shared.analyseExternal(cg, time: t, camera: cam) }
            if cachedFrameOn { frameGuide(CIImage(cgImage: cg), time: t) }
        }
    }

    nonisolated private func frameGuide(_ image: CIImage, time: Double) {
        let handler = VNImageRequestHandler(ciImage: image)
        var rect: CGRect?
        if let chosen = cachedChosen {
            rect = chosen                                   // a Shot finder pick
        } else if let subj = FrameAdvisor.detect(handler, preferCentre: false), !subj.comp.isScene {
            // Zoom so the subject fills `fill` of the frame, then put its
            // anchor (eye line, centre…) on the composition's target point.
            let b = subj.box, c = subj.comp
            let z = max(0.4, min(6, c.fill / max(b.width, b.height, 0.01)))
            let w = 1 / z, h = 1 / z
            let ax = b.minX + c.anchor.x * b.width, ay = b.minY + c.anchor.y * b.height
            rect = CGRect(x: ax - c.target.x * w, y: ay - c.target.y * h, width: w, height: h)
        } else if let r = SceneFraming.best(handler: handler, image: image, context: Self.ctx, minScale: 0.25) {
            rect = r.view
        }
        var hint: String?, ok = false
        if let r = rect {
            let dx = r.midX - 0.5, dy = r.midY - 0.5
            let zoom = 1 / max(r.width, r.height)
            var parts: [String] = []
            // The camera's own level, from the calibrated phone on top.
            if cachedCalibrated, abs(cachedRoll) > 1.5 {
                parts.append(String(format: "Level the camera (%.0f°)", abs(cachedRoll)))
            }
            if abs(dx) > 0.05 { parts.append(dx > 0 ? "Pan right" : "Pan left") }
            if abs(dy) > 0.05 { parts.append(dy > 0 ? "Tilt down" : "Tilt up") }
            if zoom > 1.15 { parts.append(String(format: "Zoom in ×%.1f", zoom)) }
            else if zoom < 0.87 { parts.append(String(format: "Zoom out ×%.1f", 1 / zoom)) }
            ok = parts.isEmpty
            hint = ok ? "Lined up" : parts.joined(separator: " · ")
        }
        if ok { if alignedSince == nil { alignedSince = time } } else { alignedSince = nil }
        let shoot = ok && (time - (alignedSince ?? time)) > 0.6 && time - firedAt > 4
        if shoot { firedAt = time }
        let shown = rect.map { $0.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let (hintNow, okNow) = (hint, ok)
        Task { @MainActor in
            let g = SonyGuides.shared
            guard g.frameOn else { return }
            if okNow && !g.aligned { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            g.target = shown; g.hint = hintNow; g.aligned = okNow
            if shoot && g.autoShoot { g.fire() }
        }
    }
}

/// Shot finder picks, numbered, over the live view.
struct SonyShotPicksOverlay: View {
    let guides: SonyGuides
    var body: some View {
        GeometryReader { geo in
            ForEach(Array(guides.picks.enumerated()), id: \.offset) { i, r in
                let rect = CGRect(x: r.minX * geo.size.width, y: r.minY * geo.size.height,
                                  width: r.width * geo.size.width, height: r.height * geo.size.height)
                let on = guides.chosenPick == i
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).stroke(on ? Color.yellow : Color.white.opacity(0.8), lineWidth: on ? 2 : 1.5)
                    Text("\(i + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 22, height: 22).background(Circle().fill(on ? Color.yellow : .white)).padding(4)
                }
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .onTapGesture { guides.chosenPick = on ? nil : i }
                .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}

/// The camera's level (calibrated phone gyro): a horizon line, green when level.
struct SonyLevelOverlay: View {
    let guides: SonyGuides
    var body: some View {
        if guides.calibrated && guides.frameOn {
            let level = abs(guides.roll) < 1
            VStack(spacing: 4) {
                Capsule().fill(level ? Color.green : Color.white.opacity(0.85))
                    .frame(width: 140, height: 2)
                    .rotationEffect(.degrees(-guides.roll))
                Text(String(format: "%+.0f° · tilt %+.0f°", guides.roll, guides.pitch))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(level ? .green : .white.opacity(0.8))
            }
            .allowsHitTesting(false)
        }
    }
}

/// The suggested framing drawn over the Sony live view (same coordinates as
/// the image it overlays).
struct SonyFrameGuideOverlay: View {
    let guides: SonyGuides
    var body: some View {
        GeometryReader { geo in
            if let r = guides.target {
                let rect = CGRect(x: r.minX * geo.size.width, y: r.minY * geo.size.height,
                                  width: r.width * geo.size.width, height: r.height * geo.size.height)
                RoundedRectangle(cornerRadius: 6)
                    .stroke(guides.aligned ? Color.green : Color.yellow, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.smooth(duration: 0.25), value: r)
            }
        }
        .allowsHitTesting(false)
    }
}
