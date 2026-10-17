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
import SwiftUI
import Vision

@MainActor @Observable
final class SonyGuides {
    static let shared = SonyGuides()

    var frameOn = UserDefaults.standard.bool(forKey: "cc_sonyFrameGuide") {
        didSet { UserDefaults.standard.set(frameOn, forKey: "cc_sonyFrameGuide"); cachedFrameOn = frameOn
            if !frameOn { target = nil; hint = nil; aligned = false } }
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
        PoseGuide.shared.externalShutter = { Task { @MainActor in SonyGuides.shared.fire() } }
    }
    func detach() {
        attached = false; target = nil; hint = nil; aligned = false
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
            if cachedPoseOn, let cam = cameraRef { PoseGuide.shared.analyseExternal(cg, time: t, camera: cam) }
            if cachedFrameOn { frameGuide(CIImage(cgImage: cg), time: t) }
        }
    }

    nonisolated private func frameGuide(_ image: CIImage, time: Double) {
        let handler = VNImageRequestHandler(ciImage: image)
        var rect: CGRect?
        if let subj = FrameAdvisor.detect(handler, preferCentre: false), !subj.comp.isScene {
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
        Task { @MainActor in
            let g = SonyGuides.shared
            guard g.frameOn else { return }
            if ok && !g.aligned { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            g.target = shown; g.hint = hint; g.aligned = ok
            if shoot && g.autoShoot { g.fire() }
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
