//
//  ExposureAids.swift
//  cam cam
//
//  Live histogram + highlight zebras for the Sony live view. Both are measured
//  on the image BEFORE the display-only +0.7 EV lift (i.e. what the photo will
//  actually record), so zebras mean "this will clip", not "the preview is
//  bright". Display only — never written into saved photos.
//

import SwiftUI
import CoreImage

nonisolated enum ExposureAids {

    private static let lumaWeights = (r: CGFloat(0.2126), g: CGFloat(0.7152), b: CGFloat(0.0722))

    /// Grayscale (Rec.709 luma in every channel).
    static func luma(_ image: CIImage) -> CIImage {
        let w = lumaWeights
        let v = CIVector(x: w.r, y: w.g, z: w.b, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v, "inputGVector": v, "inputBVector": v,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Diagonal zebra stripes over every pixel whose luma (measured on
    /// `source`) is at or above `threshold`, composited onto `display`.
    static func zebras(over display: CIImage, measuring source: CIImage, threshold: Float = 0.95) -> CIImage {
        let extent = display.extent
        let mask = luma(source).applyingFilter("CIColorThreshold", parameters: ["inputThreshold": threshold])
        guard let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0),
            "inputWidth": 5, "inputSharpness": 1,
            "inputCenter": CIVector(x: 0, y: 0),
        ])?.outputImage else { return display }
        let diagonal = stripes.transformed(by: CGAffineTransform(rotationAngle: .pi / 4)).cropped(to: extent)
        return diagonal.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: display,
            kCIInputMaskImageKey: mask.cropped(to: extent),
        ]).cropped(to: extent)
    }

    /// 64-bin luma histogram, normalised so the tallest bin = 1.
    static func histogram(_ image: CIImage, context: CIContext, bins: Int = 64) -> [Float]? {
        // Measure a small copy — the shape is identical and it's ~free.
        let e = image.extent
        guard e.width > 1, e.height > 1 else { return nil }
        let s = min(1, 320 / e.width)
        let small = luma(image).transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let hist = CIFilter(name: "CIAreaHistogram", parameters: [
            kCIInputImageKey: small,
            "inputExtent": CIVector(cgRect: small.extent),
            "inputCount": bins,
            "inputScale": 1,
        ])?.outputImage else { return nil }
        var buf = [Float](repeating: 0, count: bins * 4)
        context.render(hist, toBitmap: &buf, rowBytes: bins * 16,
                       bounds: CGRect(x: 0, y: 0, width: bins, height: 1),
                       format: .RGBAf, colorSpace: nil)
        var out = (0..<bins).map { buf[$0 * 4] }      // R channel = luma (gray input)
        let peak = out.max() ?? 0
        if peak > 0 { out = out.map { $0 / peak } }
        return out
    }
}

/// Compact histogram overlay. Clipped ends glow red (shadows/highlights).
struct HistogramView: View {
    let bins: [Float]

    var body: some View {
        Canvas { ctx, size in
            guard bins.count > 1 else { return }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in bins.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(v))))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            ctx.fill(path, with: .color(.white.opacity(0.75)))
            if (bins.first ?? 0) > 0.6 { ctx.fill(Path(CGRect(x: 0, y: 0, width: 3, height: size.height)), with: .color(.red)) }
            if (bins.last ?? 0) > 0.6 {
                ctx.fill(Path(CGRect(x: size.width - 3, y: 0, width: 3, height: size.height)), with: .color(.red))
            }
        }
        .frame(width: 120, height: 54)
        .padding(6)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
    }
}
