//
//  FrameLearning.swift
//  cam cam
//
//  Frame guide learns your framing. Nothing trains on the phone:
//
//   1. Logging (here): every shot taken with Frame guide on saves a small
//      upright copy of the view (512 px JPEG) and how it was framed to
//      Documents/FramingLog. Guided shots also save the wider view from
//      the moment you locked, with the final framing marked inside it.
//   2. Training (on the Mac, training/plug_train.sh): whenever the phone is
//      plugged in, the Mac pulls the log, embeds each framing with Apple's
//      Vision feature print, trains a small scoring layer so your framings
//      outrank shifted alternatives, and copies the weights back as
//      Documents/FrameScorer.json.
//   3. Inference (here): when that file exists, Frame guide scores a few
//      candidate placements of the subject (thirds, centre, headroom) with
//      the feature print + learned layer and suggests the best one.
//

import CoreImage
import ImageIO
import Foundation
import UIKit
import Vision

nonisolated enum FrameLearning {
    static let folder: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FramingLog", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let scorerURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FrameScorer.json")
    /// Keep the log bounded (~40 KB a sample).
    static let maxSamples = 1500

    private static let queue = DispatchQueue(label: "cam.framelearning", qos: .utility)
    private static let ctx = CIContext(options: [.cacheIntermediates: false])

    // MARK: Logging

    /// Save one framing example. `image` is the upright analysis frame;
    /// `view` is the framing that was chosen, top-left normalized in it.
    static func log(_ image: CIImage, view: CGRect, kind: String, mm: Int, subject: String?) {
        queue.async {
            let id = String(format: "%.0f-%04d", Date().timeIntervalSince1970 * 1000, Int.random(in: 0..<10000))
            let e = image.extent
            // CPU JPEG encode of the already-copied frame — no GPU work while
            // the photo itself is processing.
            let cg = image.cgImage ?? ctx.createCGImage(image, from: e)
            let jpgData = NSMutableData()
            guard let cg, let dest = CGImageDestinationCreateWithData(jpgData, "public.jpeg" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return }
            let jpg = jpgData as Data
            let meta: [String: Any] = [
                "kind": kind, "mm": mm, "subject": subject ?? "",
                "view": [view.minX, view.minY, view.width, view.height],
                "w": Int(e.width), "h": Int(e.height), "time": Date().timeIntervalSince1970,
            ]
            try? jpg.write(to: folder.appendingPathComponent(id + ".jpg"))
            if let j = try? JSONSerialization.data(withJSONObject: meta) {
                try? j.write(to: folder.appendingPathComponent(id + ".json"))
            }
            prune()
        }
    }

    static var sampleCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    private static func prune() {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        guard names.count > maxSamples else { return }
        for n in names.prefix(names.count - maxSamples) {
            let base = folder.appendingPathComponent(String(n.dropLast(5)))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("json"))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("jpg"))
        }
    }

    // MARK: Scorer

    struct Scorer: Decodable {
        let version: Int
        let trainedAt: String?
        let samples: Int?
        let accuracy: Double?
        let mean: [Float]
        let std: [Float]
        let w1: [[Float]]      // hidden × input
        let b1: [Float]
        let w2: [Float]        // hidden
        let b2: Float

        func score(_ x: [Float]) -> Float {
            guard x.count == mean.count else { return 0 }
            var z = [Float](repeating: 0, count: x.count)
            for i in 0..<x.count { z[i] = (x[i] - mean[i]) / max(std[i], 1e-6) }
            var out = b2
            for h in 0..<w1.count {
                var a = b1[h]
                let row = w1[h]
                for i in 0..<z.count { a += row[i] * z[i] }
                out += w2[h] * max(a, 0)
            }
            return out
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _scorer: Scorer?
    nonisolated(unsafe) private static var loadedAt: Date?

    /// The learned scorer, reloaded when the Mac drops in a new one.
    static var scorer: Scorer? {
        lock.lock(); defer { lock.unlock() }
        let mod = (try? FileManager.default.attributesOfItem(atPath: scorerURL.path))?[.modificationDate] as? Date
        if mod != loadedAt {
            loadedAt = mod
            _scorer = mod.flatMap { _ in try? Data(contentsOf: scorerURL) }
                .flatMap { try? JSONDecoder().decode(Scorer.self, from: $0) }
        }
        return _scorer
    }

    /// Feature print of a region (top-left normalized). Must match
    /// training/embed.swift exactly: revision 2, scale-fill of the region.
    static func embed(_ handler: VNImageRequestHandler, region r: CGRect) -> [Float]? {
        let req = VNGenerateImageFeaturePrintRequest()
        req.revision = VNGenerateImageFeaturePrintRequestRevision2
        req.imageCropAndScaleOption = .scaleFill
        req.regionOfInterest = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        guard (try? handler.perform([req])) != nil,
              let obs = req.results?.first as? VNFeaturePrintObservation,
              obs.elementType == .float else { return nil }
        return obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Where the view must be for the subject's anchor to land on `target`
    /// with the subject filling `fill` of the frame. nil if it leaves the image.
    static func view(for box: CGRect, comp: FrameAdvisor.Composition) -> CGRect? {
        let s = max(box.width, box.height) / max(comp.fill, 0.05)
        guard s <= 1.001 else { return nil }
        let ax = box.minX + comp.anchor.x * box.width, ay = box.minY + comp.anchor.y * box.height
        let v = CGRect(x: ax - comp.target.x * s, y: ay - comp.target.y * s, width: s, height: s)
        guard v.minX > -0.02, v.minY > -0.02, v.maxX < 1.02, v.maxY < 1.02 else { return nil }
        return v.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Learned placement: score the rule's composition against other target
    /// points at the same fill and return the winner (nil = keep the rule).
    static func refine(_ box: CGRect, comp: FrameAdvisor.Composition, handler: VNImageRequestHandler) -> FrameAdvisor.Composition? {
        guard let sc = scorer else { return nil }
        let t: CGFloat = 1.0 / 3
        var targets = [comp.target]
        for p in [CGPoint(x: t, y: t), CGPoint(x: 0.5, y: t), CGPoint(x: 1 - t, y: t),
                  CGPoint(x: t, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1 - t, y: 0.5),
                  CGPoint(x: 0.5, y: 0.4)] where hypot(p.x - comp.target.x, p.y - comp.target.y) > 0.04 {
            targets.append(p)
        }
        var best: (FrameAdvisor.Composition, Float)?
        var ruleScore: Float?
        for (i, tp) in targets.enumerated() {
            var c = comp; c.target = tp
            guard let v = view(for: box, comp: c), let x = embed(handler, region: v) else { continue }
            let s = sc.score(x)
            if i == 0 { ruleScore = s }
            if best == nil || s > best!.1 { best = (c, s) }
        }
        // Only overrule the rules when the model is clearly more confident.
        guard let b = best, b.0.target != comp.target else { return nil }
        if let r = ruleScore, b.1 - r < 0.25 { return nil }
        return b.0
    }
}
