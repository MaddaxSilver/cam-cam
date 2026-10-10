//
//  SmartExposure.swift
//  cam cam
//
//  "Smart" auto exposure, layered on top of Apple's continuous AE.
//
//  Apple's AE aims the average at middle grey. That's safe but it clips
//  bright skies and windows, and underexposes dark scenes that could take
//  more light. Smart mode watches the live luma histogram ~5×/s and nudges
//  the exposure target bias:
//
//   • Highlight protection (expose-to-the-right, the approach pro camera apps
//     use): place the 99.5th-percentile luma just under clipping. Film looks
//     roll highlights off nicely only if they weren't clipped by the sensor.
//   • Shadow lift: if there's headroom and the frame is mostly dark, brighten,
//     but never so far that mid-tones wash out (median capped).
//   • Face priority: when a face is in frame, Apple's face-driven AE already
//     meters on it, so smart mode won't darken more than −0.5 EV for sky.
//   • Calm: changes are smoothed and small ones ignored, so the preview
//     doesn't pump; it stands still while capturing, recording, during a
//     long exposure or while you've tapped to lock focus/exposure.
//
//  Your exposure ruler still works: it's an offset added on top.
//

import AVFoundation
import CoreImage
import Observation

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
    @ObservationIgnored nonisolated(unsafe) private var smart: Float = 0
    @ObservationIgnored nonisolated(unsafe) private var lastApplied: Float = .nan
    @ObservationIgnored nonisolated(unsafe) private var lastStatus = ""

    nonisolated private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
        .cacheIntermediates: false,
    ])

    /// Called for every video frame; does real work ~5 times a second.
    nonisolated func process(_ pixelBuffer: CVPixelBuffer, time: Double, camera: CameraManager) {
        if needsReset {
            needsReset = false
            smart = 0
            apply(bias: camera.cachedUserBias, camera: camera)
            publish(status: "", correction: 0)
        }
        guard cachedEnabled, time - lastTick >= 0.2 else { return }
        lastTick = time
        guard let device = camera.currentDevice,
              device.exposureMode == .continuousAutoExposure,
              !camera.cachedIsRecording, !camera.isCollectingFrames,
              let h = Self.histogram(pixelBuffer) else { return }

        let median = Self.percentile(h, 0.5)
        let p995 = Self.percentile(h, 0.995)
        let clipped = h.suffix(2).reduce(0, +)          // share of pixels at the very top

        // Expose-to-the-right: put the brightest 0.5% just under clipping.
        // Histogram is gamma-encoded; ×2.2 converts the ratio to stops.
        var target: Float
        if clipped > 0.01 {
            target = -0.33 - min(clipped * 10, 0.67)       // genuinely clipping: step down
        } else {
            target = 2.2 * log2(0.93 / max(p995, 0.05))
        }
        // Don't let shadows-lifting wash out the mid-tones.
        let maxUp = 2.2 * log2(0.56 / max(median, 0.02))
        target = min(target, max(maxUp, 0))
        if faceHint { target = max(target, -0.5) }

        // Smooth toward the target; clamp the total correction.
        let next = max(-2.0, min(1.0, smart + 0.35 * target))
        smart = next
        let status: String
        if next < -0.15 { status = faceHint ? "Face priority" : "Protecting highlights" }
        else if next > 0.15 { status = "Lifting shadows" }
        else { status = "" }
        apply(bias: next + camera.cachedUserBias, camera: camera)
        if status != lastStatus { lastStatus = status; publish(status: status, correction: next) }
    }

    nonisolated private func apply(bias: Float, camera: CameraManager) {
        guard lastApplied.isNaN || abs(bias - lastApplied) > 0.08 else { return }
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

    // MARK: Histogram (64 bins, fractions summing to 1)

    nonisolated private static func histogram(_ pb: CVPixelBuffer) -> [Float]? {
        let img = CIImage(cvPixelBuffer: pb)
        let s = 160 / max(img.extent.width, 1)
        let small = ExposureAids.luma(img).transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let hist = CIFilter(name: "CIAreaHistogram", parameters: [
            kCIInputImageKey: small, "inputExtent": CIVector(cgRect: small.extent),
            "inputCount": 64, "inputScale": 1,
        ])?.outputImage else { return nil }
        var buf = [Float](repeating: 0, count: 64 * 4)
        context.render(hist, toBitmap: &buf, rowBytes: 64 * 16,
                       bounds: CGRect(x: 0, y: 0, width: 64, height: 1), format: .RGBAf, colorSpace: nil)
        var out = (0..<64).map { buf[$0 * 4] }
        let sum = out.reduce(0, +)
        guard sum > 0 else { return nil }
        out = out.map { $0 / sum }
        return out
    }

    nonisolated private static func percentile(_ h: [Float], _ p: Float) -> Float {
        var acc: Float = 0
        for (i, v) in h.enumerated() {
            acc += v
            if acc >= p { return (Float(i) + 0.5) / Float(h.count) }
        }
        return 1
    }
}
