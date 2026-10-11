//
//  LUTExporter.swift
//  cam cam
//
//  Bakes any film sim (built-in or custom) into a standard 33³ `.cube` LUT, so
//  the same look can be applied to Sony RAWs in Lightroom / Resolve / Final Cut.
//
//  How: a lattice image with one solid colour block per LUT entry is pushed
//  through the real look pipeline, then each block's centre is read back.
//  Blocks are 8×8 so small spatial filters (clarity sharpen, slight blur,
//  colour fringing) don't leak into the sampled centre.
//
//  Limits (inherent to LUTs): only COLOUR transfers. Grain, glitches, halation,
//  leaks and other spatial effects can't be expressed and are left out; Bent's
//  base look is chaotic per-region, so its export is one frozen sample of it.
//

import Foundation
import CoreImage

nonisolated enum LUTExporter {

    /// Build `.cube` text. `render` must apply ONLY the colour look (the caller
    /// passes a grain/effects-free recipe).
    static func cube(title: String, size n: Int = 33,
                     render: (CIImage) -> CIImage) -> String? {
        let block = 8
        let w = n * n * block, h = n * block
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

        // Lattice: column = g*n + r, row = b  →  read back b,g,r with R fastest.
        var px = [Float](repeating: 1, count: w * h * 4)
        let step = 1 / Float(n - 1)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let x0 = (g * n + r) * block, y0 = b * block
            for yy in 0..<block {
                var i = ((y0 + yy) * w + x0) * 4
                for _ in 0..<block {
                    px[i] = Float(r) * step; px[i + 1] = Float(g) * step; px[i + 2] = Float(b) * step
                    i += 4
                }
            }
        }}}
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        let input = CIImage(bitmapData: data, bytesPerRow: w * 16,
                            size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: srgb)
        let out = render(input).cropped(to: input.extent)

        // Evaluate the look in the app's working space (Display P3) so the
        // exported LUT matches what cam cam renders; lattice in/out are sRGB.
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                      .outputColorSpace: srgb, .cacheIntermediates: false])
        var res = [Float](repeating: 0, count: w * h * 4)
        res.withUnsafeMutableBytes {
            ctx.render(out, toBitmap: $0.baseAddress!, rowBytes: w * 16,
                       bounds: input.extent, format: .RGBAf, colorSpace: srgb)
        }

        var lines = ["# Created with cam cam", "TITLE \"\(title.replacingOccurrences(of: "\"", with: "'"))\"",
                     "LUT_3D_SIZE \(n)", "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"]
        lines.reserveCapacity(n * n * n + 6)
        let c = block / 2
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = ((b * block + c) * w + (g * n + r) * block + c) * 4
            func v(_ x: Float) -> String { String(format: "%.6f", min(max(x.isFinite ? x : 0, 0), 1)) }
            lines.append("\(v(res[i])) \(v(res[i + 1])) \(v(res[i + 2]))")
        }}}
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write a .cube file into Documents/Exports and return its URL.
    static func write(_ text: String, name: String) throws -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let url = dir.appendingPathComponent("cam cam - \(safe).cube")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - Share sheet (export / share .cube files)

import SwiftUI
import UIKit

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
