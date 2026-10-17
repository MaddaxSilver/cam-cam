//
//  MultiFrameZoom.swift
//  cam cam
//
//  Multi-frame zoom (after Project Indigo / Google's handheld super-res):
//  a zoomed photo is a crop of the sensor, so the camera delivers only a few
//  real pixels, enlarged. Instead of one frame, a quick bracket of 4–8
//  identical frames is taken (~75 ms apart). Natural hand shake shifts each
//  one by a fraction of a pixel, so together they sample the scene more
//  finely than any single frame:
//
//   1. the sharpest frame is the reference;
//   2. every other frame is aligned to it (Vision homographic registration
//      on small copies, scaled up to full size);
//   3. all frames are resampled onto the 48MP output grid;
//   4. they're averaged with per-pixel weights from how well each agrees
//      with the reference (slightly blurred, so noise doesn't decide):
//      noise drops by up to √N, moving things fall back to the reference
//      instead of ghosting;
//   5. a gentle sharpen, now that the noise is gone.
//

import CoreImage
import Vision

extension simd_float3x3 {
    /// The homography `H` (output grid) expressed in frame pixels (grid = frame × up).
    init(S0 up: CGFloat, H: simd_float3x3) {
        let u = Float(up)
        let U = simd_float3x3(diagonal: [u, u, 1]), Ui = simd_float3x3(diagonal: [1 / u, 1 / u, 1])
        self = Ui * H * U
    }
}

nonisolated enum MultiFrameZoom {
    /// Settings toggle ("Multi-frame zoom", on by default).
    static var enabled: Bool { UserDefaults.standard.object(forKey: "cc_multiFrameZoom") as? Bool ?? true }
    /// DEBUG audits: ignore the good-light gate.
    nonisolated(unsafe) static var testing = false
    /// Merge RAW (ProRAW) frames instead of processed ones.
    static var useRAW: Bool { UserDefaults.standard.object(forKey: "cc_multiFrameRAW") as? Bool ?? true }
    /// DNG (TIFF-based) rather than HEIC/JPEG bytes.
    static func isDNG(_ d: Data) -> Bool {
        guard d.count > 4 else { return false }
        let b = [UInt8](d.prefix(4))
        return (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A) || (b[0] == 0x4D && b[1] == 0x4D && b[3] == 0x2A)
    }

    /// Merge upright frames of the same shot into one image of `outputPixels`.
    static func merge(_ frames: [CIImage], outputPixels: CGFloat = 48_771_072, reference: Int? = nil,
                      sharpen: Bool = true, context: CIContext) -> CIImage? {
        guard frames.count >= 2,
              let kW = CameraManager.filmKernel("mfWeighted"), let kO = CameraManager.filmKernel("mfWeight"),
              let kAdd = CameraManager.filmKernel("mfAdd"), let kDiv = CameraManager.filmKernel("mfDivide")
        else { return frames.first }
        let atOrigin = frames.map { f in f.transformed(by: CGAffineTransform(translationX: -f.extent.minX, y: -f.extent.minY)) }
        let e = atOrigin[0].extent
        guard atOrigin.allSatisfy({ abs($0.extent.width - e.width) < 1 && abs($0.extent.height - e.height) < 1 }) else { return frames.first }

        // 1. Reference: the sharpest frame (least motion blur).
        let refIndex = reference ?? atOrigin.indices.max { sharpness(atOrigin[$0], context) < sharpness(atOrigin[$1], context) } ?? 0
        let ref = atOrigin[refIndex]

        // Output grid.
        let up = max(1, (outputPixels / (e.width * e.height)).squareRoot())
        let out = CGRect(x: 0, y: 0, width: (e.width * up).rounded(.down), height: (e.height * up).rounded(.down))
        func toGrid(_ img: CIImage) -> CIImage {
            img.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": up, "inputAspectRatio": 1])
                .cropped(to: out)
        }

        // 2. Alignment on small copies (~1024 px).
        let small = 1024 / max(e.width, e.height)
        func shrink(_ img: CIImage) -> CIImage { img.transformed(by: CGAffineTransform(scaleX: small, y: small)) }
        let refSmall = shrink(ref)

        var aligned: [CIImage] = [toGrid(ref)]
        for (i, f) in atOrigin.enumerated() where i != refIndex {
            let req = VNHomographicImageRegistrationRequest(targetedCIImage: shrink(f))
            guard (try? VNImageRequestHandler(ciImage: refSmall).perform([req])) != nil,
                  let obs = req.results?.first as? VNImageHomographicAlignmentObservation else { continue }
            let H = obs.warpTransform
            // Scale the small-image homography to the output grid: S·H·S⁻¹.
            let k = Float(up / small)
            let S = simd_float3x3(diagonal: [k, k, 1]), Si = simd_float3x3(diagonal: [1 / k, 1 / k, 1])
            let Ho = S * H * Si
            // Reject wild alignments (large rotation/scale = registration failed).
            let col0 = Ho.columns.0, col1 = Ho.columns.1
            guard abs(col0.x - 1) < 0.05, abs(col1.y - 1) < 0.05, abs(col0.y) < 0.05, abs(col1.x) < 0.05 else { continue }
            // Vision's estimate comes from 1024 px copies (±0.4 px at full
            // size); super-resolution needs better. Refine the translation
            // at the frame's own resolution (Lucas–Kanade on a centre patch).
            var Ho2 = Ho
            if let (rx, ry) = refineShift(ref: ref, frame: f, coarse: simd_float3x3(S0: up, H: Ho), context: context) {
                Ho2.columns.2.x += Float(rx * up); Ho2.columns.2.y += Float(ry * up)
            }
            let Hf = Ho2
            let g = toGrid(f)
            func warp(_ x: CGFloat, _ y: CGFloat) -> CIVector {
                let p = Hf * SIMD3<Float>(Float(x), Float(y), 1)
                return CIVector(x: CGFloat(p.x / p.z), y: CGFloat(p.y / p.z))
            }
            let w = g.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputBottomLeft": warp(0, 0), "inputBottomRight": warp(out.width, 0),
                "inputTopLeft": warp(0, out.height), "inputTopRight": warp(out.width, out.height)])
            // Edges the frame doesn't cover: the reference shows through.
            aligned.append(w.composited(over: aligned[0]).cropped(to: out))
        }
        guard aligned.count >= 2 else { return toGrid(ref) }

        // 4. Robust weighted average.
        let sigma = Double(max(1.0, up * 1.2))
        func blur(_ x: CIImage) -> CIImage { x.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: out) }
        let rb = blur(aligned[0])
        let invS2: Float = 1 / (0.035 * 0.035)
        var sum = aligned[0], wsum = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: out)
        for f in aligned.dropFirst() {
            let fb = blur(f)
            guard let wf = kW.apply(extent: out, arguments: [f, fb, rb, invS2]),
                  let wo = kO.apply(extent: out, arguments: [fb, rb, invS2]),
                  let s2 = kAdd.apply(extent: out, arguments: [sum, wf]),
                  let w2 = kAdd.apply(extent: out, arguments: [wsum, wo]) else { continue }
            sum = s2; wsum = w2
        }
        guard let merged = kDiv.apply(extent: out, arguments: [sum, wsum]) else { return aligned[0] }

        // 5. Gentle sharpen: averaging N aligned frames softens a touch, and
        //    with less noise there's room for it.
        guard sharpen else { return merged }
        // Tuned against a ground truth (-mfTest -synth): radius 0.8 output
        // px at 30% scored best; the merge stays ~1–1.5 dB ahead of a single
        // frame at any sharpening, since there's less noise to sharpen.
        return merged.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 0.8 * up, kCIInputIntensityKey: 0.3])
            .cropped(to: out)
    }

    /// Residual shift (frame pixels) of `frame` against `ref` after applying
    /// the coarse homography `coarse` (frame pixels), by Lucas–Kanade on a
    /// 384 px centre patch. nil if it doesn't converge sensibly.
    static func refineShift(ref: CIImage, frame: CIImage, coarse H: simd_float3x3, context: CIContext) -> (CGFloat, CGFloat)? {
        let e = ref.extent
        let n = 384
        let c = CGRect(x: (e.midX - CGFloat(n) / 2).rounded(), y: (e.midY - CGFloat(n) / 2).rounded(), width: CGFloat(n), height: CGFloat(n))
        func warped(_ dx: CGFloat, _ dy: CGFloat) -> CIImage {
            func p(_ x: CGFloat, _ y: CGFloat) -> CIVector {
                let v = H * SIMD3<Float>(Float(x), Float(y), 1)
                return CIVector(x: CGFloat(v.x / v.z) + dx, y: CGFloat(v.y / v.z) + dy)
            }
            return frame.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputBottomLeft": p(0, 0), "inputBottomRight": p(e.width, 0),
                "inputTopLeft": p(0, e.height), "inputTopRight": p(e.width, e.height)])
        }
        let r = LookAuditShared.luma(ref, crop: c, ctx: context)
        // Gradients of the reference (central differences).
        var gx = [Float](repeating: 0, count: n * n), gy = gx
        for y in 1..<(n - 1) { for x in 1..<(n - 1) {
            let i = y * n + x
            gx[i] = (r[i + 1] - r[i - 1]) / 2
            gy[i] = (r[i - n] - r[i + n]) / 2          // bitmap rows run down; CI y runs up
        } }
        var a11: Float = 0, a12: Float = 0, a22: Float = 0
        for i in gx.indices { a11 += gx[i] * gx[i]; a12 += gx[i] * gy[i]; a22 += gy[i] * gy[i] }
        let det = a11 * a22 - a12 * a12
        guard det > 1e-6 else { return nil }
        var dx: CGFloat = 0, dy: CGFloat = 0
        for _ in 0..<4 {
            let f = LookAuditShared.luma(warped(dx, dy), crop: c, ctx: context)
            var b1: Float = 0, b2: Float = 0
            for i in r.indices { let d = f[i] - r[i]; b1 += gx[i] * d; b2 += gy[i] * d }
            let ux = (a22 * b1 - a12 * b2) / det, uy = (a11 * b2 - a12 * b1) / det
            dx += CGFloat(ux); dy += CGFloat(uy)
            if abs(ux) < 0.01 && abs(uy) < 0.01 { break }
        }
        guard abs(dx) < 3, abs(dy) < 3 else { return nil }
        return (dx, dy)
    }

    /// A tone curve that maps `img`'s brightness distribution onto `ref`'s
    /// (luma percentiles 2/25/50/75/98, in the working space), so RAW frames
    /// match Apple's processed exposure and contrast but keep their detail.
    static func matchTone(_ img: CIImage, to ref: CIImage, context: CIContext) -> ((CIImage) -> CIImage)? {
        func pct(_ x: CIImage) -> [CGFloat]? {
            let e = x.extent
            let s = 384 / max(e.width, e.height)
            let sm = x.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: s, y: s))
            let w = Int(e.width * s), h = Int(e.height * s)
            guard w > 8, h > 8 else { return nil }
            var b = [Float](repeating: 0, count: w * h * 4)
            context.render(sm, toBitmap: &b, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBAf, colorSpace: context.workingColorSpace)
            var y = (0..<(w * h)).map { 0.2126 * b[$0 * 4] + 0.7152 * b[$0 * 4 + 1] + 0.0722 * b[$0 * 4 + 2] }
            y.sort()
            return [0.02, 0.25, 0.5, 0.75, 0.98].map { CGFloat(y[min(y.count - 1, Int(Float(y.count) * $0))]) }
        }
        guard let a = pct(img), let b = pct(ref) else {
            #if DEBUG
            print("[mf] tone match: no percentiles")
            #endif
            return nil
        }
        // Strictly increasing x for CIToneCurve.
        var xs = a, ys = b
        for i in 1..<5 where xs[i] <= xs[i - 1] + 0.005 { xs[i] = xs[i - 1] + 0.005 }
        for i in 0..<5 { xs[i] = min(max(xs[i], 0), 1); ys[i] = min(max(ys[i], 0), 1) }
        let pts = (0..<5).map { CIVector(x: xs[$0], y: ys[$0]) }
        #if DEBUG
        print("[mf] tone match raw \(a.map { String(format: "%.3f", $0) }) -> ref \(b.map { String(format: "%.3f", $0) })")
        #endif
        return { x in
            x.applyingFilter("CIToneCurve", parameters: ["inputPoint0": pts[0], "inputPoint1": pts[1], "inputPoint2": pts[2],
                                                         "inputPoint3": pts[3], "inputPoint4": pts[4]]).cropped(to: x.extent)
        }
    }

    /// Mean |Laplacian| of a centre crop at reduced size (relative sharpness).
    static func sharpness(_ img: CIImage, _ context: CIContext) -> Float {
        let e = img.extent
        let s = 768 / max(e.width, e.height)
        let small = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let c = CGRect(x: small.extent.midX - 128, y: small.extent.midY - 128, width: 256, height: 256).integral
        let hp = LookAuditShared.highPass(small, crop: c, ctx: context)
        return hp.map { abs($0) }.reduce(0, +) / Float(max(hp.count, 1))
    }
}

/// The high-pass measure, available in release builds too.
nonisolated enum LookAuditShared {
    /// Luma (sRGB) of a square crop.
    static func luma(_ img: CIImage, crop: CGRect, ctx: CIContext) -> [Float] {
        let n = Int(crop.width), m = Int(crop.height)
        var buf = [Float](repeating: 0, count: n * m * 4)
        ctx.render(img, toBitmap: &buf, rowBytes: n * 16, bounds: crop, format: .RGBAf,
                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (0..<(n * m)).map { 0.2126 * buf[$0 * 4] + 0.7152 * buf[$0 * 4 + 1] + 0.0722 * buf[$0 * 4 + 2] }
    }

    static func highPass(_ img: CIImage, crop: CGRect, ctx: CIContext) -> [Float] {
        let n = Int(crop.width)
        var buf = [Float](repeating: 0, count: n * n * 4)
        ctx.render(img, toBitmap: &buf, rowBytes: n * 16, bounds: crop, format: .RGBAf,
                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var y = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) { y[i] = 0.2126 * buf[i * 4] + 0.7152 * buf[i * 4 + 1] + 0.0722 * buf[i * 4 + 2] }
        var out = [Float](repeating: 0, count: n * n)
        for r in 1..<(n - 1) { for c in 1..<(n - 1) {
            var m: Float = 0
            for dy in -1...1 { for dx in -1...1 { m += y[(r + dy) * n + c + dx] } }
            out[r * n + c] = y[r * n + c] - m / 9
        } }
        return out
    }
}
