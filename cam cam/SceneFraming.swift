//
//  SceneFraming.swift
//  cam cam
//
//  Frame guide for scenes with no person or pet in them — coastlines,
//  mountains, skylines, landscapes. Instead of boxing "an object", it tries
//  a few dozen candidate framings (zoom × position) of the view and scores
//  each the way a landscape photographer would:
//
//   • keep what the eye goes to (Apple's attention saliency), tighter is
//     better when the interest is concentrated
//   • put that interest on a thirds point
//   • horizon on a third, never through the middle: more sky when the sky
//     has the detail (sunsets, clouds), more foreground when the ground does
//   • don't cut through the interesting part at the frame's edges
//
//  The best framing becomes the box (its size is the zoom). If the full view
//  already wins, there's no box — or, when the interest runs off every
//  edge, a tip to go wider.
//
//  Self-contained (Vision + Core Image only) so it can also be tested on
//  landscape photos on the Mac.
//

import CoreImage
import Foundation
import Vision

nonisolated enum SceneFraming {
    struct Result {
        /// The suggested view, top-left normalized in the analysed image.
        var view: CGRect
        /// Why (for the hint): "horizon on the top third".
        var why: String
        var score: Double
        var fullScore: Double
    }

    /// Where the horizon sits (top-left y, 0…1) and whether the sky half has
    /// more detail than the ground half, from luminance down the frame.
    static func horizonPlacement(_ image: CIImage, context: CIContext) -> (y: CGFloat, skyBusier: Bool)? {
        let n = 48
        let e = image.extent
        let strip = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: 8 / e.width, y: CGFloat(n) / e.height))
        var buf = [Float](repeating: 0, count: 8 * n * 4)
        context.render(strip, toBitmap: &buf, rowBytes: 8 * 16,
                       bounds: CGRect(x: 0, y: 0, width: 8, height: n), format: .RGBAf, colorSpace: nil)
        // Row luminance indexed from the BOTTOM (bitmap memory row 0 is the top).
        var lum = [Float](repeating: 0, count: n), detail = [Float](repeating: 0, count: n)
        for r in 0..<n {
            let mr = n - 1 - r
            let row = (0..<8).map { c -> Float in let i = (mr * 8 + c) * 4; return 0.2126 * buf[i] + 0.7152 * buf[i + 1] + 0.0722 * buf[i + 2] }
            lum[r] = row.reduce(0, +) / 8
            let m = lum[r]; detail[r] = row.map { abs($0 - m) }.reduce(0, +) / 8
        }
        var best = 0, bestStep: Float = 0
        for i in 2..<(n - 2) {
            let step = (lum[i + 1] + lum[i + 2]) - (lum[i - 1] + lum[i - 2])     // brighter above
            if step > bestStep { bestStep = step; best = i }
        }
        guard bestStep > 0.2 else { return nil }
        let skyDetail = detail[(best + 1)...].reduce(0, +) / Float(n - best - 1)
        let groundDetail = detail[..<best].reduce(0, +) / Float(max(best, 1))
        return (1 - CGFloat(best) / CGFloat(n - 1), skyDetail > groundDetail * 1.15)
    }

    /// Attention saliency as a g×g grid (row 0 = top), normalized to sum 1.
    static func saliencyGrid(_ handler: VNImageRequestHandler, g: Int = 32) -> [Double]? {
        let req = VNGenerateAttentionBasedSaliencyImageRequest()
        guard (try? handler.perform([req])) != nil,
              let obs = req.results?.first as? VNSaliencyImageObservation else { return nil }
        let pb = obs.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent32Float else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        var grid = [Double](repeating: 0, count: g * g)
        for y in 0..<h {
            let row = base.advanced(by: y * rb).assumingMemoryBound(to: Float.self)
            let gy = min(g - 1, y * g / h)
            for x in 0..<w {
                grid[gy * g + min(g - 1, x * g / w)] += Double(max(row[x], 0))
            }
        }
        let sum = grid.reduce(0, +)
        guard sum > 1e-6 else { return nil }
        return grid.map { $0 / sum }
    }

    /// Best framing of the scene, or nil when the full view is already best.
    /// - minScale: smallest view (1 / max zoom allowed from here).
    static func best(handler: VNImageRequestHandler, image: CIImage, context: CIContext,
                     minScale: CGFloat = 0.3) -> Result? {
        guard let sal = saliencyGrid(handler) else { return nil }
        let horizon = horizonPlacement(image, context: context)
        let objReq = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? handler.perform([objReq])
        let objects = ((objReq.results?.first as? VNSaliencyImageObservation)?.salientObjects ?? [])
            .filter { $0.confidence > 0.4 }
            .map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY,
                          width: $0.boundingBox.width, height: $0.boundingBox.height) }
        return choose(sal: sal, g: 32, horizon: horizon, objects: objects, minScale: minScale)
    }

    /// The scoring, separated from Vision so it can be unit-tested.
    static func choose(sal: [Double], g: Int, horizon: (y: CGFloat, skyBusier: Bool)?,
                       objects: [CGRect], minScale: CGFloat) -> Result? {
        func mass(_ r: CGRect) -> Double {
            let x0 = max(0, Int((r.minX * CGFloat(g)).rounded(.down))), x1 = min(g, Int((r.maxX * CGFloat(g)).rounded(.up)))
            let y0 = max(0, Int((r.minY * CGFloat(g)).rounded(.down))), y1 = min(g, Int((r.maxY * CGFloat(g)).rounded(.up)))
            guard x1 > x0, y1 > y0 else { return 0 }
            var m = 0.0
            for y in y0..<y1 { for x in x0..<x1 { m += sal[y * g + x] } }
            return m
        }
        func centroid(_ r: CGRect) -> CGPoint? {
            let x0 = max(0, Int(r.minX * CGFloat(g))), x1 = min(g, Int((r.maxX * CGFloat(g)).rounded(.up)))
            let y0 = max(0, Int(r.minY * CGFloat(g))), y1 = min(g, Int((r.maxY * CGFloat(g)).rounded(.up)))
            var m = 0.0, cx = 0.0, cy = 0.0
            for y in y0..<y1 { for x in x0..<x1 {
                let v = sal[y * g + x]; m += v
                cx += v * (Double(x) + 0.5) / Double(g); cy += v * (Double(y) + 0.5) / Double(g)
            } }
            guard m > 1e-9 else { return nil }
            return CGPoint(x: (CGFloat(cx / m) - r.minX) / r.width, y: (CGFloat(cy / m) - r.minY) / r.height)
        }
        let t: CGFloat = 1.0 / 3
        let thirds = [CGPoint(x: t, y: t), CGPoint(x: 1 - t, y: t), CGPoint(x: t, y: 1 - t), CGPoint(x: 1 - t, y: 1 - t)]

        func score(_ r: CGRect) -> (Double, String) {
            let area = Double(r.width * r.height)
            let content = mass(r)
            guard content > 0.05 else { return (-1, "") }
            // Keep the interest; reward tightening when it's concentrated.
            var s = content + 0.25 * log(max(content / area, 1e-3))
            var why = ""
            // Interest on a thirds point (or dead centre for symmetric scenes).
            if let c = centroid(r) {
                let d = thirds.map { hypot($0.x - c.x, $0.y - c.y) }.min() ?? 1
                let dc = hypot(c.x - 0.5, c.y - 0.5)
                s += 0.3 * exp(-pow(Double(d) / 0.12, 2))
                s += 0.12 * exp(-pow(Double(dc) / 0.08, 2))
                if d < 0.1 { why = "subject on a third" }
            }
            // Horizon on a third, not through the middle.
            if let h = horizon {
                let v = (h.y - r.minY) / r.height
                if v > 0.2 && v < 0.8 {        // near an edge counts as lost
                    let want: CGFloat = h.skyBusier ? 2.0 / 3 : 1.0 / 3
                    let hs = exp(-pow(Double(v - want) / 0.08, 2))
                    s += 0.35 * hs - 0.15 * exp(-pow(Double(v - 0.5) / 0.06, 2))
                    if hs > 0.5 { why = h.skyBusier ? "horizon low — more sky" : "horizon on the top third" }
                } else {
                    s -= 0.25          // a landscape crop that loses the horizon
                }
            }
            // Don't slice through the interest at the edges.
            let band = r.width * 0.06
            let inner = r.insetBy(dx: band, dy: band)
            let edge = max(0, content - mass(inner)) / content
            s -= 0.6 * max(0, edge - 0.2)
            for o in objects {
                let i = o.intersection(r)
                guard !i.isNull else { continue }
                let f = (i.width * i.height) / max(o.width * o.height, 1e-6)
                if f > 0.12 && f < 0.85 { s -= 0.15 }          // object cut in two
            }
            return (s, why)
        }

        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let (fullScore, _) = score(full)
        var best: (CGRect, Double, String)?
        var sc: CGFloat = 0.9
        while sc >= minScale - 1e-6 {
            let step = max(0.04, sc * 0.1)
            var y: CGFloat = 0
            while y <= 1 - sc + 1e-6 {
                var x: CGFloat = 0
                while x <= 1 - sc + 1e-6 {
                    let r = CGRect(x: x, y: y, width: sc, height: sc)
                    let (s, why) = score(r)
                    if best == nil || s > best!.1 { best = (r, s, why) }
                    x += step
                }
                y += step
            }
            sc -= 0.1
        }
        // Only suggest a crop that's clearly better than what you have.
        guard let b = best, b.1 > fullScore + 0.18 else { return nil }
        return Result(view: b.0, why: b.2.isEmpty ? "tighter framing" : b.2, score: b.1, fullScore: fullScore)
    }

    /// The interest runs off the edges of the full view: a wider lens would help.
    static func wantsWider(handler: VNImageRequestHandler) -> Bool {
        guard let sal = saliencyGrid(handler, g: 16) else { return false }
        var edge = 0.0
        for y in 0..<16 { for x in 0..<16 where x == 0 || y == 0 || x == 15 || y == 15 { edge += sal[y * 16 + x] } }
        return edge > 0.45
    }
}
