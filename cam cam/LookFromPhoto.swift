//
//  LookFromPhoto.swift
//  cam cam
//
//  "New look from a photo": measure a reference photo's tone and palette
//  and bake a 3D LUT that moves your shots toward it (Reinhard colour
//  transfer in CIE Lab, against a neutral scene's statistics), kept within
//  photographic limits and at 75% strength. Saved as a .cube in the LUTs
//  folder, so it becomes an ordinary custom film.
//

import CoreGraphics
import Foundation

nonisolated enum LookFromPhoto {
    // sRGB ⇄ Lab (D65)
    static func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gam(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
    static func toLab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let R = lin(r), G = lin(g), B = lin(b)
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
    static func fromLab(_ L: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
        let fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func fi(_ t: Double) -> Double { let t3 = t * t * t; return t3 > 0.008856 ? t3 : (t - 16 / 116) / 7.787 }
        let x = fi(fx) * 0.95047, y = fi(fy), z = fi(fz) * 1.08883
        let R = 3.2406 * x - 1.5372 * y - 0.4986 * z
        let G = -0.9689 * x + 1.8758 * y + 0.0415 * z
        let B = 0.0557 * x - 0.2040 * y + 1.0570 * z
        func c(_ v: Double) -> Double { min(max(gam(max(v, 0)), 0), 1) }
        return (c(R), c(G), c(B))
    }

    struct Stats { var mean: (Double, Double, Double); var std: (Double, Double, Double) }

    static func stats(_ image: CGImage) -> Stats? {
        let side = 192
        let w = side, h = max(1, side * image.height / max(image.width, 1))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Weighted: near-black pixels say nothing about the palette.
        var s = (0.0, 0.0, 0.0), q = (0.0, 0.0, 0.0), n = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let (L, a, b) = toLab(Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255)
            let w = min(max((L - 8) / 17, 0), 1)
            s.0 += w * L; s.1 += w * a; s.2 += w * b; q.0 += w * L * L; q.1 += w * a * a; q.2 += w * b * b; n += w
        }
        guard n > 1 else { return nil }
        let m = (s.0 / n, s.1 / n, s.2 / n)
        return Stats(mean: m, std: ((q.0 / n - m.0 * m.0).squareRoot(), (q.1 / n - m.1 * m.1).squareRoot(),
                                    (q.2 / n - m.2 * m.2).squareRoot()))
    }

    /// Bake the LUT and save it; returns the file name.
    static func makeLUT(from image: CGImage, name: String, directory: URL) throws -> String {
        guard let ref = stats(image) else { throw NSError(domain: "LookFromPhoto", code: 1) }
        // A neutral, well-exposed scene: the "from" side of the transfer.
        let src = Stats(mean: (50, 0, 0), std: (22, 12, 12))
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        let kL = clamp(ref.std.0 / src.std.0, 0.75, 1.3)
        let ka = clamp(ref.std.1 / src.std.1, 0.6, 1.5), kb = clamp(ref.std.2 / src.std.2, 0.6, 1.5)
        // A look, not an exposure change: only a gentle brightness shift.
        let mL = clamp((ref.mean.0 - src.mean.0) * 0.3, -6, 6)
        let ma = clamp(ref.mean.1, -8, 8), mb = clamp(ref.mean.2, -9, 9)   // influence the tint, never a heavy cast
        let strength = 0.75
        let n = 33
        var out = "TITLE \"\(name)\"\n# cam cam look from a photo (Reinhard Lab transfer)\nLUT_3D_SIZE \(n)\n"
        out.reserveCapacity(n * n * n * 28)
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let r = Double(ri) / Double(n - 1), g = Double(gi) / Double(n - 1), b = Double(bi) / Double(n - 1)
            let (L, a, bb) = toLab(r, g, b)
            // Keep the very ends anchored (no lifted pure black / dimmed white).
            let ends = min(L / 8, (100 - L) / 8, 1)
            let L2 = L + ((L - 50) * kL + 50 + mL - L) * strength * ends
            let a2 = a + (a * ka + ma - a) * strength
            let b2 = bb + (bb * kb + mb - bb) * strength
            let (R, G, B) = fromLab(L2, a2, b2)
            out += String(format: "%.6f %.6f %.6f\n", R, G, B)
        } } }
        let file = name.replacingOccurrences(of: "/", with: "-") + ".cube"
        try out.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return file
    }
}
