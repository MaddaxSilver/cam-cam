//
//  SubjectDepth.swift
//  cam cam
//
//  Portrait depth, the Pixel 2 way: a phone's depth map is coarse (the
//  live depth stream is ~320×240), so on its own it blurs hair and edges
//  wrongly and can put focus on the background. The Pixel 2 got good
//  portraits from one camera by combining a rough depth estimate with a
//  machine-learned segmentation of the subject. iOS doesn't expose the
//  iPhone's dual-pixel focus data, but the segmentation half works here too:
//
//   • Vision's foreground-instance mask (any subject: people, pets,
//     objects), or person segmentation when that finds nothing, at ~2K;
//   • inside the mask the depth is set to the subject's own depth (so the
//     whole subject is in focus, edges crisp), outside it stays as measured;
//   • the blur focuses on the subject's box, not the frame centre.
//

import CoreImage
import Vision

nonisolated enum SubjectDepth {
    struct Result {
        var disparity: CIImage      // refined, at the image's extent
        var focusRect: CGRect       // the subject, in image coordinates
    }

    /// `disparity` already scaled to `image` (bright = near).
    static func refine(disparity: CIImage, image: CIImage, context: CIContext) -> Result? {
        let e = image.extent
        guard e.width > 1, let (mask, box) = subjectMask(image) else { return nil }
        // The subject's own disparity: mask-weighted average.
        func avg(_ x: CIImage) -> Float {
            let a = x.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: e)])
            var px = [Float](repeating: 0, count: 4)
            context.render(a, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
            return px[0]
        }
        let disp = disparity.cropped(to: e)
        let weighted = disp.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        let m = avg(mask)
        guard m > 0.01 else { return nil }
        let ds = CGFloat(avg(weighted) / m)
        let subject = CIImage(color: CIColor(red: ds, green: ds, blue: ds)).cropped(to: e)
        // Never push part of the subject further away than measured.
        let lifted = subject.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: disp])
        let refined = lifted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: disp, kCIInputMaskImageKey: mask]).cropped(to: e)
        return Result(disparity: refined, focusRect: box)
    }

    /// Soft subject mask at the image's extent, plus the subject's box.
    static func subjectMask(_ image: CIImage) -> (CIImage, CGRect)? {
        let e = image.extent
        let s = min(1, 2048 / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        let handler = VNImageRequestHandler(ciImage: small)
        var buffer: CVPixelBuffer?
        let fg = VNGenerateForegroundInstanceMaskRequest()
        if (try? handler.perform([fg])) != nil, let obs = fg.results?.first, !obs.allInstances.isEmpty {
            buffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        }
        if buffer == nil {
            let person = VNGeneratePersonSegmentationRequest()
            person.qualityLevel = .accurate
            if (try? handler.perform([person])) != nil { buffer = person.results?.first?.pixelBuffer }
        }
        guard let buf = buffer, let box = boundingBox(buf) else { return nil }
        let m = CIImage(cvPixelBuffer: buf)
        let k = e.width / m.extent.width, ky = e.height / m.extent.height
        let mask = m.transformed(by: CGAffineTransform(scaleX: k, y: ky))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .cropped(to: e)
        // Box: buffer rows run top-down; Core Image's y runs up.
        let rect = CGRect(x: e.minX + box.minX * e.width, y: e.minY + (1 - box.maxY) * e.height,
                          width: box.width * e.width, height: box.height * e.height)
        return (mask, rect)
    }

    /// Normalised (top-left) box of mask values > 0.5.
    static func boundingBox(_ buf: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(buf, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), rb = CVPixelBufferGetBytesPerRow(buf)
        let fmt = CVPixelBufferGetPixelFormatType(buf)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in stride(from: 0, to: h, by: 2) {
            let row = base.advanced(by: y * rb)
            for x in stride(from: 0, to: w, by: 2) {
                let v: Float
                switch fmt {
                case kCVPixelFormatType_OneComponent32Float: v = row.assumingMemoryBound(to: Float.self)[x]
                case kCVPixelFormatType_OneComponent8: v = Float(row.assumingMemoryBound(to: UInt8.self)[x]) / 255
                case kCVPixelFormatType_OneComponent16Half: v = Float(row.assumingMemoryBound(to: Float16.self)[x])
                default: return nil
                }
                if v > 0.5 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
                      width: CGFloat(maxX - minX + 1) / CGFloat(w), height: CGFloat(maxY - minY + 1) / CGFloat(h))
    }
}
