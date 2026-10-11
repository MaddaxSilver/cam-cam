//
//  FrameAdvisor.swift
//  cam cam
//
//  Framing suggestions on the rear camera, for landscapes and group shots.
//  ~3 times a second, on a small copy of the live frame:
//
//   • Landscape: Vision finds the horizon. Tilted → "Tilt 2° right" with a
//     level line. A horizon cutting the frame in half → suggest putting it on
//     a third (more sky or more ground).
//   • Group: Vision finds faces. Someone touching the edge → "Step back";
//     heads crowding the top → "Tilt down"; everyone bunched to one side →
//     "Move left/right". If the group is small in a wide frame, it suggests a
//     tighter frame that one tap applies as a zoom.
//
//  Suggestions are only shown once they're stable for a moment, so the hint
//  doesn't flicker while you move.
//

import AVFoundation
import CoreImage
import Observation
import Vision

@MainActor @Observable
final class FrameAdvisor {
    static let shared = FrameAdvisor()

    var enabled = UserDefaults.standard.object(forKey: "cc_frameAdvisor") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "cc_frameAdvisor")
            cachedEnabled = enabled
            if !enabled { hint = nil; horizonTilt = nil; suggestedZoom = nil; suggestedFrame = nil }
        }
    }
    /// Short instruction ("Tilt 2° right", "Step back"), nil when the shot is fine.
    private(set) var hint: String?
    /// Horizon tilt in degrees (for the level line), nil without a horizon.
    private(set) var horizonTilt: Double?
    /// A tighter frame worth zooming to (relative zoom > 1), nil otherwise.
    private(set) var suggestedZoom: Double?
    /// That frame in normalized image coordinates (top-left origin).
    private(set) var suggestedFrame: CGRect?
    /// Width / height of the analysed camera image, to map the box on screen.
    private(set) var imageAspect: CGFloat = 3.0 / 4.0

    @ObservationIgnored nonisolated(unsafe) var cachedEnabled = UserDefaults.standard.object(forKey: "cc_frameAdvisor") as? Bool ?? false
    @ObservationIgnored nonisolated(unsafe) private var lastTick: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var busy = false
    @ObservationIgnored nonisolated(unsafe) private var candidate: String?
    @ObservationIgnored nonisolated(unsafe) private var candidateSince: Double = 0
    nonisolated private static let queue = DispatchQueue(label: "cam.frameadvisor", qos: .utility)

    nonisolated func process(_ pixelBuffer: CVPixelBuffer, time: Double, camera: CameraManager) {
        guard cachedEnabled, !busy, time - lastTick >= 0.33,
              camera.currentDevice?.position == .back else { return }
        lastTick = time
        busy = true
        let s = 512 / CGFloat(max(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)))
        let small = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: CGAffineTransform(scaleX: s, y: s))
        let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(max(CVPixelBufferGetHeight(pixelBuffer), 1))
        Self.queue.async { [self] in
            defer { busy = false }
            analyse(small, time: time, aspect: aspect)
        }
    }

    nonisolated private func analyse(_ image: CIImage, time: Double, aspect: CGFloat) {
        let horizonReq = VNDetectHorizonRequest()
        let faceReq = VNDetectFaceRectanglesRequest()
        let subjectReq = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(ciImage: image)
        try? handler.perform([horizonReq, faceReq, subjectReq])
        let faces = (faceReq.results ?? []).map(\.boundingBox)   // normalized, bottom-left origin
        var tilt: Double? = nil
        if let h = horizonReq.results?.first { tilt = Double(h.angle) * 180 / .pi }

        var hint: String? = nil
        var zoom: Double? = nil
        var frame: CGRect? = nil

        if !faces.isEmpty {
            // Group / portrait framing
            let u = faces.dropFirst().reduce(faces[0]) { $0.union($1) }
            // Bodies extend below faces: pad generously down and to the sides.
            let fh = faces.map(\.height).max() ?? 0.1
            let body = CGRect(x: u.minX - fh * 0.6, y: u.minY - fh * 2.2,
                              width: u.width + fh * 1.2, height: u.height + fh * 2.6)
            if u.minX < 0.03 || u.maxX > 0.97 {
                hint = faces.count > 1 ? "Step back — someone's cut off" : "Step back"
            } else if u.maxY > 0.93 {
                hint = "Tilt down — give heads some room"
            } else if faces.count > 1, abs(u.midX - 0.5) > 0.18 {
                hint = u.midX < 0.5 ? "Move left to centre the group" : "Move right to centre the group"
            }
            // The framing box: the group with room for bodies and a margin.
            frame = Self.box(around: body)
            if let f = frame { zoom = Self.zoom(for: f) }
            if hint == nil, zoom != nil { hint = faces.count > 1 ? "Frame the group in the box" : "Frame them in the box" }
        } else if let objects = (subjectReq.results?.first as? VNSaliencyImageObservation)?.salientObjects,
                  !objects.isEmpty, faces.isEmpty,
                  let f = Self.box(around: objects.dropFirst().reduce(objects[0].boundingBox) { $0.union($1.boundingBox) }),
                  let z = Self.zoom(for: f) {
            // Landscape / scene: box the main subject.
            frame = f; zoom = z
            if let t = tilt, abs(t) > 1.2, abs(t) < 20 {
                hint = String(format: "Tilt %.0f° %@", abs(t), t > 0 ? "right" : "left")
            } else {
                hint = "Frame the subject in the box"
            }
        } else if let t = tilt, abs(t) > 1.2, abs(t) < 20 {
            hint = String(format: "Tilt %.0f° %@", abs(t), t > 0 ? "right" : "left")
        } else if tilt != nil {
            // Level horizon: is it splitting the frame in half? Find it from the
            // brightness edge (sky above, ground below) along the centre column.
            if let y = Self.horizonHeight(image), abs(y - 0.5) < 0.08 {
                hint = "Put the horizon on a third"
            }
        }

        // Only show a hint once it's held for ~0.7 s (no flicker while moving).
        if hint != candidate { candidate = hint; candidateSince = time }
        let stable = time - candidateSince > 0.7
        let shown = stable ? hint : nil
        let level = tilt.map { abs($0) < 20 ? $0 : 0 }
        Task { @MainActor in
            let a = FrameAdvisor.shared
            if a.hint != shown { a.hint = shown }
            a.imageAspect = aspect
            a.horizonTilt = level
            a.suggestedZoom = stable ? zoom : nil
            a.suggestedFrame = stable ? frame : nil
        }
    }

    /// Bottom-left normalized subject rect → a margin-padded framing box in
    /// top-left coordinates, or nil when it's basically the whole frame.
    nonisolated static func box(around r: CGRect) -> CGRect? {
        let m: CGFloat = 0.06
        var b = r.insetBy(dx: -m, dy: -m).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !b.isNull, b.width > 0.08, b.height > 0.08 else { return nil }
        b = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        return (b.width > 0.82 && b.height > 0.82) ? nil : b
    }

    /// How far to zoom so the box fills the frame (only when it's worth it).
    nonisolated static func zoom(for box: CGRect) -> Double? {
        let z = Double(min(1 / box.width, 1 / box.height)) * 0.95
        return z > 1.2 ? min(z, 3) : nil
    }

    /// Height (0 bottom … 1 top) of the strongest brightness step along the
    /// frame's vertical centre — where sky meets land or sea.
    nonisolated private static func horizonHeight(_ image: CIImage) -> Double? {
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let n = 48
        let col = image.cropped(to: CGRect(x: image.extent.midX - 20, y: image.extent.minY, width: 40, height: image.extent.height))
            .transformed(by: CGAffineTransform(translationX: -(image.extent.midX - 20), y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: 1.0 / 40, y: CGFloat(n) / image.extent.height))
        var buf = [Float](repeating: 0, count: n * 4)
        ctx.render(col, toBitmap: &buf, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: n),
                   format: .RGBAf, colorSpace: nil)
        let lum = (0..<n).map { 0.2126 * buf[$0 * 4] + 0.7152 * buf[$0 * 4 + 1] + 0.0722 * buf[$0 * 4 + 2] }
        var best = 0, bestStep: Float = 0
        for i in 2..<(n - 2) {
            let step = (lum[i + 1] + lum[i + 2]) - (lum[i - 1] + lum[i - 2])   // brighter above
            if step > bestStep { bestStep = step; best = i }
        }
        return bestStep > 0.25 ? Double(best) / Double(n - 1) : nil
    }
}
