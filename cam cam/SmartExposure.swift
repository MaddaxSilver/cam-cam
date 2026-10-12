//
//  SmartExposure.swift
//  cam cam
//
//  "Smart" auto exposure, layered on top of Apple's continuous AE through the
//  exposure target bias. Modelled on the open camera stacks' AGC (libcamera
//  AgcMeanLuminance and the Raspberry Pi AGC), adapted to a phone that runs
//  its own AE underneath:
//
//   1. Meter: a 64×48 luminance grid of the live frame, centre-weighted, and
//      weighted toward the subject by Vision attention saliency (~2×/s).
//      With a face in frame, smart mode steps aside: Apple's AE meters the face.
//   2. Predict: Apple's AE is usually still converging; its exposure target
//      offset says by how much, so we judge the frame as it will look once
//      Apple settles. Without this the two loops chase each other (pumping).
//   3. Solve the gain to the target in one go (iterated, because clipped
//      areas don't brighten) instead of nudging a fraction of the error.
//   4. Target by light level: night is aimed darker than daylight, so night
//      still looks like night.
//   5. Histogram constraints: the brightest 2% must reach at least ~0.45
//      (no muddy flat scenes; skipped at night), and the 99–99.5% band must
//      stay under ~0.9 so skies and windows keep detail (at most −0.4 EV; skipped when a face
//      is in frame: the face matters more than the sky). Small speculars
//      (<0.5% of the frame) may clip.
//   6. Smooth: do nothing inside a stable region (±0.06 EV); otherwise an
//      exponential filter that finishes small moves quickly instead of
//      creeping, is instant for the first ticks, and cuts exposure in one
//      step when the frame is clipping badly.
//
//  Your exposure ruler still works: it's an offset added on top.
//

import AVFoundation
import CoreImage
import Observation
import Vision

@MainActor @Observable
final class SmartExposure {
    static let shared = SmartExposure()

    var enabled: Bool = UserDefaults.standard.object(forKey: "cc_smartAE") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "cc_smartAE")
            cachedEnabled = enabled
            if !enabled { needsReset = true }
        }
    }
    /// What smart mode is doing right now, for the UI ("Protecting highlights").
    private(set) var status: String = ""
    /// Smart mode's own correction in EV (before your offset).
    private(set) var correction: Float = 0

    // Read on the capture queue.
    @ObservationIgnored nonisolated(unsafe) var cachedEnabled = UserDefaults.standard.object(forKey: "cc_smartAE") as? Bool ?? true
    @ObservationIgnored nonisolated(unsafe) var faceHint = false
    @ObservationIgnored nonisolated(unsafe) private var needsReset = false
    @ObservationIgnored nonisolated(unsafe) private var lastTick: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var lastSaliency: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var ticks = 0
    @ObservationIgnored nonisolated(unsafe) private var smart: Float = 0
    @ObservationIgnored nonisolated(unsafe) private var lastApplied: Float = .nan
    @ObservationIgnored nonisolated(unsafe) private var lastStatus = ""
    /// Saliency weights on the metering grid (gw×gh), nil until the first pass.
    @ObservationIgnored nonisolated(unsafe) private var saliency: [Float]?
    /// EV the current film look shifts mid-grey by (+ = the look prints
    /// brighter). Smart AE exposes against it so every film lands at a normal
    /// exposure instead of some printing dark and some bright.
    @ObservationIgnored nonisolated(unsafe) private(set) var lookOffset: Float = 0
    @ObservationIgnored nonisolated(unsafe) private var lookMeasuredAt: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var lookBusy = false
    nonisolated private static let lookQueue = DispatchQueue(label: "cam.smartae.look", qos: .utility)

    nonisolated static let gw = 64, gh = 48

    nonisolated private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
        .cacheIntermediates: false,
    ])

    /// Centre weighting: a broad Gaussian with a floor, so edges still count.
    nonisolated private static let centreWeights: [Float] = {
        var w = [Float](repeating: 0, count: gw * gh)
        for y in 0..<gh {
            for x in 0..<gw {
                let dx = (Float(x) + 0.5) / Float(gw) - 0.5
                let dy = (Float(y) + 0.5) / Float(gh) - 0.5
                w[y * gw + x] = 0.35 + 0.65 * exp(-(dx * dx + dy * dy) / (2 * 0.22 * 0.22))
            }
        }
        return w
    }()

    /// The camera switched lens/device: the new device starts with no bias,
    /// so forget what we applied and re-solve from scratch on the next tick.
    nonisolated func deviceChanged() {
        smart = 0
        ticks = 0
        lastApplied = .nan
        saliency = nil
    }

    /// Called for every video frame; meters ~7 times a second.
    nonisolated func process(_ pixelBuffer: CVPixelBuffer, time: Double, camera: CameraManager) {
        if needsReset {
            needsReset = false
            smart = 0; ticks = 0
            apply(bias: camera.cachedUserBias, camera: camera)
            publish(status: "", correction: 0)
        }
        guard time - lastTick >= 0.15 else { return }
        lastTick = time
        guard let device = camera.currentDevice,
              device.exposureMode == .continuousAutoExposure,
              !camera.cachedIsRecording, !camera.isCollectingFrames else { return }

        camera.cachedLiveISO = device.iso         // context-aware grain in the preview
        // Every film, every custom sim and imported LUT: measure how the
        // active look moves mid-grey (re-measured ~every 1.5 s).
        if time - lookMeasuredAt > 1.5, !lookBusy {
            lookMeasuredAt = time; lookBusy = true
            Self.lookQueue.async { [self] in
                defer { lookBusy = false }
                if let o = Self.measureLook(camera) { lookOffset = o }
            }
        }
        // AUTO (Smart AE off): Apple's exposure, corrected only for the film.
        guard cachedEnabled else {
            if smart != 0 { smart = 0 }
            apply(bias: camera.cachedUserBias - lookOffset, camera: camera)
            let status = abs(lookOffset) >= 0.05 ? String(format: "Film %+.1f EV", -lookOffset) : ""
            if status != lastStatus { lastStatus = status; publish(status: status, correction: -lookOffset) }
            return
        }

        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        guard let grid = Self.lumaGrid(frame) else { return }
        if time - lastSaliency > 0.5 {
            lastSaliency = time
            updateSaliency(frame)
        }

        // 2. Judge the frame as it will be once Apple's AE has settled.
        let pending = max(-2, min(2, device.exposureTargetOffset))
        // Apple is still mid-move: wait for it, or the two loops fight
        // (our correction lands on top of its own and overshoots).
        guard abs(pending) < 0.3 else { return }
        let settle = pow(2, -pending)
        let lum = grid.map { min($0 * settle, 4) }

        // Weights: centre × subject (saliency); faces are already metered by
        // Apple's AE (we point its metering at the largest face).
        var w = Self.centreWeights
        if !faceHint, let sal = saliency {
            for i in w.indices { w[i] *= 0.4 + 1.6 * sal[i] }
        }
        let wSum = w.reduce(0, +)

        // 4. Target by light level (EV100 of the scene).
        let ev = Self.sceneEV(device)
        // Expose for the film: a look that prints mid-grey brighter needs
        // less exposure, a darker-printing one more.
        let look = lookOffset
        let target = Self.target(ev: ev) * pow(2, -look)

        // 3. Solve the gain, accounting for clipping.
        var g: Float = 1
        for _ in 0..<8 {
            var y: Float = 0
            for i in lum.indices { y += w[i] * min(lum[i] * g, 1) }
            y /= max(wSum, 1e-6)
            let step = max(0.1, min(10, target / max(y, 1e-4)))
            g *= step
            if abs(step - 1) < 0.01 { break }
        }

        // 5. Histogram constraints (unweighted).
        let sorted = lum.sorted()
        func bandMean(_ lo: Float, _ hi: Float) -> Float {
            let a = Int(Float(sorted.count) * lo), b = max(a + 1, Int(Float(sorted.count) * hi))
            return sorted[a..<min(b, sorted.count)].reduce(0, +) / Float(min(b, sorted.count) - a)
        }
        var reason = ""
        let top = bandMean(0.98, 1.0)
        if ev >= 4, top * g < 0.45, top > 0.01 {
            g = 0.45 / top; reason = "Lifting shadows"
        }
        let highlights = bandMean(0.99, 0.995)
        if !faceHint, highlights * g > 0.9, highlights > 0.01 {
            // Protect, but never darken the subject more than ~0.4 EV below
            // the mean solution for the sake of a window or lamp (users found
            // stronger protection made everyday shots look dark).
            let protect = 0.9 / highlights
            g = max(protect, g * 0.76)
            reason = "Protecting highlights"
        }

        let delta = log2(max(g, 1e-3))
        // A face is in frame: Apple's AE is already metering it (we point it
        // at the largest face). Ease our correction back out of its way.
        let desired = faceHint ? -look : max(-2.0, min(1.5, smart + delta))
        let error = desired - smart

        // 6. Stable region, then the adaptive filter.
        ticks += 1
        guard abs(error) > 0.06 || ticks <= 1 else { return }
        var speed: Float = 0.35
        if ticks <= 1 { speed = 1 }                                 // startup: go straight there
        else if abs(error) < 0.26 { speed = speed.squareRoot() }    // close: finish the move
        let clipped = Float(sorted.reversed().prefix { $0 >= 0.98 }.count) / Float(sorted.count)
        if clipped > 0.04 && error < -0.3 { speed = 1 }             // badly over: cut at once
        smart += speed * error

        if reason.isEmpty {
            if abs(look) >= 0.05 { reason = String(format: "Film %+.1f EV", -look) }
            else if faceHint { reason = "Face priority" }
            else if ev < 4 { reason = "Night" }
            else if smart > 0.15 { reason = "Brightening" }
            else if smart < -0.15 { reason = "Darkening" }
        }
        apply(bias: smart + camera.cachedUserBias, camera: camera)
        if reason != lastStatus || abs(smart - lastApplied) > 0.05 {
            lastStatus = reason
            publish(status: reason, correction: smart)
        }
    }

    // MARK: Light-level target

    /// Linear mean-luminance target: night is aimed darker than daylight.
    nonisolated static func target(ev: Float) -> Float {
        // Calibrated on device: under Apple's own AE a normal daylight/indoor
        // frame meters ~0.26 here, so that's "no correction"; darker scenes
        // are aimed progressively darker than Apple would make them.
        let pts: [(Float, Float)] = [(0, 0.14), (3, 0.20), (6, 0.26), (8, 0.29), (11, 0.30)]
        if ev <= pts[0].0 { return pts[0].1 }
        for i in 1..<pts.count where ev <= pts[i].0 {
            let (e0, t0) = pts[i - 1], (e1, t1) = pts[i]
            return t0 + (t1 - t0) * (ev - e0) / (e1 - e0)
        }
        return pts.last!.1
    }

    /// Scene EV100 from the current exposure (aperture, shutter, ISO).
    nonisolated static func sceneEV(_ device: AVCaptureDevice) -> Float {
        let n = max(device.lensAperture, 1)
        let t = max(Float(CMTimeGetSeconds(device.exposureDuration)), 1e-5)
        let iso = max(device.iso, 1)
        return log2(n * n / t) - log2(iso / 100)
    }

    // MARK: Apply / publish

    nonisolated private func apply(bias: Float, camera: CameraManager) {
        guard lastApplied.isNaN || abs(bias - lastApplied) > 0.03 else { return }
        lastApplied = bias
        camera.sessionQueue.async {
            guard let device = camera.currentDevice,
                  (try? device.lockForConfiguration()) != nil else { return }
            device.setExposureTargetBias(max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias)))
            device.unlockForConfiguration()
        }
    }

    nonisolated private func publish(status: String, correction: Float) {
        Task { @MainActor in
            SmartExposure.shared.status = status
            SmartExposure.shared.correction = correction
        }
    }

    // MARK: Film look calibration

    /// Run a grey ramp through the active look (exactly as the preview
    /// renders it) and return how many EV it moves mid-grey. nil if unknown.
    nonisolated static func measureLook(_ camera: CameraManager) -> Float? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let levels: [Float] = (1...12).map { Float($0) / 13 }          // encoded greys 0.08…0.92
        var outs: [Float] = []
        for v in levels {
            let patch = CIImage(color: CIColor(red: CGFloat(v), green: CGFloat(v), blue: CGFloat(v), colorSpace: srgb)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 48))
            let look = camera.applyLiveLook(patch, grainTextures: false)
            var px = [Float](repeating: 0, count: 4)
            context.render(look, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 24, y: 24, width: 1, height: 1),
                           format: .RGBAf, colorSpace: srgb)
            let y = 0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]
            guard y.isFinite else { return nil }
            outs.append(y)
        }
        // Which input grey comes out as mid-grey (0.46 encoded ≈ 18%)?
        let mid: Float = 0.46
        guard outs.count == levels.count else { return nil }
        var inNeeded: Float?
        for i in 1..<outs.count {
            let (a, b) = (outs[i - 1], outs[i])
            if (a - mid) * (b - mid) <= 0, a != b {
                inNeeded = levels[i - 1] + (levels[i] - levels[i - 1]) * (mid - a) / (b - a); break
            }
        }
        guard let vIn = inNeeded, vIn > 0.02 else {
            // Mid-grey never reached (very flat/extreme look): nudge by its middle output.
            let m = outs[outs.count / 2]
            return max(-1, min(1, 2.2 * log2(max(m, 0.02) / mid) * 0.5))
        }
        // + when the look brightens (it needs a darker input to print mid-grey).
        let ev = 2.2 * log2(mid / vIn)
        return max(-1, min(1, ev))   // creative looks (Aerochrome, circuit bent) remap grey wildly
    }

    // MARK: Metering grid + saliency

    /// Linear luminance on a gw×gh grid.
    nonisolated private static func lumaGrid(_ img: CIImage) -> [Float]? {
        let sx = CGFloat(gw) / max(img.extent.width, 1), sy = CGFloat(gh) / max(img.extent.height, 1)
        let small = ExposureAids.luma(img)
            .transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        var buf = [Float](repeating: 0, count: gw * gh * 4)
        context.render(small, toBitmap: &buf, rowBytes: gw * 16,
                       bounds: CGRect(x: 0, y: 0, width: gw, height: gh), format: .RGBAf, colorSpace: nil)
        // The luma is gamma-encoded; meter in linear light.
        return (0..<(gw * gh)).map { pow(max(buf[$0 * 4], 0), 2.2) }
    }

    /// Vision attention saliency resampled onto the metering grid (0…1).
    nonisolated private func updateSaliency(_ frame: CIImage) {
        let s = 256 / max(frame.extent.width, frame.extent.height)
        let small = frame.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        guard (try? VNImageRequestHandler(ciImage: small).perform([request])) != nil,
              let obs = request.results?.first as? VNSaliencyImageObservation else { return }
        let map = CIImage(cvPixelBuffer: obs.pixelBuffer)
        let gw = Self.gw, gh = Self.gh
        let scaled = map.transformed(by: CGAffineTransform(scaleX: CGFloat(gw) / map.extent.width,
                                                           y: CGFloat(gh) / map.extent.height))
        var buf = [Float](repeating: 0, count: gw * gh * 4)
        Self.context.render(scaled, toBitmap: &buf, rowBytes: gw * 16,
                            bounds: CGRect(x: 0, y: 0, width: gw, height: gh), format: .RGBAf, colorSpace: nil)
        var vals = (0..<(gw * gh)).map { buf[$0 * 4] }
        let mx = vals.max() ?? 0
        guard mx > 0.05 else { saliency = nil; return }
        vals = vals.map { $0 / mx }
        saliency = vals
    }
}
