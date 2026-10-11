// Embeds Frame guide framing examples pulled from the phone.
//
//   swiftc -O embed.swift -o .build/embed && .build/embed <FramingLog dir> <cache dir>
//
// For each sample (id.jpg + id.json) writes cache/id.emb.json once:
//   { "pos": [[Float]], "neg": [[[Float]]] }   (pos[i] should outrank every neg[i][j])
// Uses the same Vision feature print (revision 2, scale-fill of the region)
// as the app's FrameLearning.embed, so the trained layer transfers.

import Foundation
import Vision
import ImageIO

struct Meta: Decodable { let kind: String; let view: [Double] }

struct RNG: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
}

func embed(_ handler: VNImageRequestHandler, _ r: CGRect) -> [Float]? {
    let req = VNGenerateImageFeaturePrintRequest()
    req.revision = VNGenerateImageFeaturePrintRequestRevision2
    req.imageCropAndScaleOption = .scaleFill
    req.regionOfInterest = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    guard (try? handler.perform([req])) != nil, let o = req.results?.first, o.elementType == .float else { return nil }
    return o.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

func clampInside(_ r: CGRect) -> CGRect {
    var r = r
    r.origin.x = min(max(r.minX, 0), 1 - r.width)
    r.origin.y = min(max(r.minY, 0), 1 - r.height)
    return r
}

/// Same-size alternatives: the framing pushed off in 8 directions.
func shifted(_ p: CGRect, by f: CGFloat) -> [CGRect] {
    var out: [CGRect] = []
    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)] as [(CGFloat, CGFloat)] {
        let q = clampInside(p.offsetBy(dx: dx * f * p.width, dy: dy * f * p.height))
        if hypot(q.midX - p.midX, q.midY - p.midY) > 0.06 * p.width { out.append(q) }
    }
    return out
}

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: embed <FramingLog> <cache>"); exit(2) }
let data = URL(fileURLWithPath: args[1]), cache = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
let names = ((try? FileManager.default.contentsOfDirectory(atPath: data.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
var done = 0, skipped = 0
for n in names {
    let id = String(n.dropLast(5))
    let out = cache.appendingPathComponent(id + ".emb.json")
    if FileManager.default.fileExists(atPath: out.path) { skipped += 1; continue }
    guard let md = try? Data(contentsOf: data.appendingPathComponent(n)),
          let meta = try? JSONDecoder().decode(Meta.self, from: md), meta.view.count == 4,
          let src = CGImageSourceCreateWithURL(data.appendingPathComponent(id + ".jpg") as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
    let handler = VNImageRequestHandler(cgImage: img)
    var rng = RNG(s: UInt64(abs(id.hashValue)))
    var groups: [(CGRect, [CGRect])] = []
    let v = CGRect(x: meta.view[0], y: meta.view[1], width: meta.view[2], height: meta.view[3])
    if meta.kind == "guided" {
        // The framing you ended on vs the same view shifted around it.
        groups.append((v, shifted(v, by: CGFloat.random(in: 0.15...0.3, using: &rng))))
    } else {
        // A plain shot: its centre crop keeps your composition; the same crop
        // pushed toward the edges breaks it.
        for k in [0.85, 0.7] as [CGFloat] {
            let p = CGRect(x: (1 - k) / 2, y: (1 - k) / 2, width: k, height: k)
            groups.append((p, shifted(p, by: (1 - k) / k)))
        }
    }
    var pos: [[Float]] = [], neg: [[[Float]]] = []
    for (p, ns) in groups where !ns.isEmpty {
        guard let pe = embed(handler, p) else { continue }
        let ne = ns.compactMap { embed(handler, $0) }
        if ne.isEmpty { continue }
        pos.append(pe); neg.append(ne)
    }
    if let j = try? JSONSerialization.data(withJSONObject: ["pos": pos, "neg": neg, "kind": meta.kind]) {
        try? j.write(to: out); done += 1
    }
}
print("embedded \(done) new, \(skipped) cached")
