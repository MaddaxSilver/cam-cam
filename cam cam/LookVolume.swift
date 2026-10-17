//
//  LookVolume.swift
//  cam cam
//
//  How "loud" a film look is, measured like audio loudness: the 24 patches of
//  a ColorChecker plus a grey ramp go through the real pipeline (grain off),
//  and the difference between what goes in and what comes out is measured in
//  CIELAB:
//
//   • volume  mean ΔE (1 ≈ just visible, 10 = a clear look, 25+ = heavy)
//   • tone    how far mid-grey moves (EV) and the contrast slope
//   • colour  mean hue/chroma shift (Δab) and saturation (% vs the input)
//
//  The film library shows it next to each film, and Look strength (0–100%)
//  turns a look down by mixing it with the original before grain/effects.
//

import CoreImage
import Foundation

nonisolated struct LookVolume: Sendable, Equatable {
    var deltaE: Float        // overall
    var tone: Float          // mean |ΔL*|
    var colour: Float        // mean Δab
    var saturation: Float    // chroma out / in − 1 (+ = more saturated)
    var midEV: Float         // mid-grey shift in EV
    var contrast: Float      // slope of L* out vs in on the ramp (1 = same)

    var summary: String {
        String(format: "volume %.0f · tone %+.1f EV · saturation %+.0f%%", deltaE, midEV, saturation * 100)
    }

    // ColorChecker 24 (sRGB 8-bit) + 6-step grey ramp.
    static let patches: [(Float, Float, Float)] = [
        (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
        (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
        (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
        (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
    ].map { ($0.0 / 255, $0.1 / 255, $0.2 / 255) }
    static let ramp: [Float] = [0.1, 0.25, 0.4, 0.55, 0.7, 0.85]

    /// 6 × 5 grid of 64 px patches (photo-like size, so vignettes and borders
    /// affect it the way they affect a photo); each patch's centre is read.
    static let cell: CGFloat = 64, cols = 6, rows = 5
    static var chart: CIImage {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let all = patches + ramp.map { ($0, $0, $0) }
        var img = CIImage.empty()
        for (i, p) in all.enumerated() {
            let c = CIColor(red: CGFloat(p.0), green: CGFloat(p.1), blue: CGFloat(p.2), colorSpace: srgb)!
            let col = i % cols, row = i / cols
            let r = CGRect(x: CGFloat(col) * cell, y: CGFloat(rows - 1 - row) * cell, width: cell, height: cell)
            img = CIImage(color: c).cropped(to: r).composited(over: img)
        }
        return img
    }

    /// sRGB (encoded, 0…1) → CIELAB (D65).
    static func lab(_ c: (Float, Float, Float)) -> (Float, Float, Float) {
        func lin(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((max(v, 0) + 0.055) / 1.055, 2.4) }
        let r = lin(c.0), g = lin(c.1), b = lin(c.2)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// Measure `look` (a function of the image) with `context`.
    static func measure(_ look: (CIImage) -> CIImage, context: CIContext) -> LookVolume? {
        let input = chart
        let out = look(input).cropped(to: input.extent)
        let n = patches.count + ramp.count
        let W = Int(cell) * cols, H = Int(cell) * rows
        var full = [Float](repeating: 0, count: W * H * 4)
        context.render(out, toBitmap: &full, rowBytes: W * 16, bounds: CGRect(x: 0, y: 0, width: W, height: H),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var buf = [Float](repeating: 0, count: n * 4)
        let c = Int(cell), inset = c / 2 - 12
        for i in 0..<n {
            let col = i % cols, row = i / cols          // bitmap row 0 = top = chart row 0
            var acc: (Float, Float, Float) = (0, 0, 0)
            for y in (row * c + inset)..<(row * c + c - inset) {
                for x in (col * c + inset)..<(col * c + c - inset) {
                    let k = (y * W + x) * 4
                    acc.0 += full[k]; acc.1 += full[k + 1]; acc.2 += full[k + 2]
                }
            }
            let m = Float((c - 2 * inset) * (c - 2 * inset))
            buf[i * 4] = acc.0 / m; buf[i * 4 + 1] = acc.1 / m; buf[i * 4 + 2] = acc.2 / m
        }
        var dE: Float = 0, dL: Float = 0, dab: Float = 0, cin: Float = 0, cout: Float = 0
        for i in 0..<patches.count {
            let a = lab(patches[i]), b = lab((buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2]))
            guard b.0.isFinite else { return nil }
            dE += ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
            dL += abs(a.0 - b.0)
            dab += ((a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
            if i < 18 {                                            // chromatic patches
                cin += (a.1 * a.1 + a.2 * a.2).squareRoot(); cout += (b.1 * b.1 + b.2 * b.2).squareRoot()
            }
        }
        let k = Float(patches.count)
        // Ramp: L* in vs out → contrast (slope) and mid-grey shift.
        var lin: [Float] = [], lout: [Float] = []
        for (j, v) in ramp.enumerated() {
            let i = patches.count + j
            lin.append(lab((v, v, v)).0)
            lout.append(lab((buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2])).0)
        }
        let mi = lin.reduce(0, +) / Float(lin.count), mo = lout.reduce(0, +) / Float(lout.count)
        var cov: Float = 0, vr: Float = 0
        for j in lin.indices { cov += (lin[j] - mi) * (lout[j] - mo); vr += (lin[j] - mi) * (lin[j] - mi) }
        // Mid grey (patch n5, index 21): L* → luminance ratio in EV.
        func Y(_ L: Float) -> Float { L > 8 ? pow((L + 16) / 116, 3) : L / 903.3 }
        let g0 = lab(patches[21]).0, i21 = 21 * 4
        let g1 = lab((buf[i21], buf[i21 + 1], buf[i21 + 2])).0
        return LookVolume(deltaE: dE / k, tone: dL / k, colour: dab / k,
                          saturation: cin > 0 ? cout / cin - 1 : 0,
                          midEV: log2(max(Y(g1), 1e-4) / max(Y(g0), 1e-4)),
                          contrast: vr > 0 ? cov / vr : 1)
    }
}
