//
//  LookAudit.swift
//  cam cam
//
//  DEBUG-only: renders every film simulation and Style through the real
//  pipeline and writes contact sheets + measurements to Documents/audit.
//  Run in the simulator with the launch argument `-lookAudit`; test photos
//  are read from Documents/audit-in (any images), plus a built-in chart.
//
//  Measured per look, on a ColorChecker-style chart:
//   • neutral patches' colour cast and tone (does grey stay grey? lifted
//     blacks, clipped whites)
//   • skin patches' hue/sat
//   • NaN / out-of-range pixels
//   • how far the live preview path differs from the saved-photo path
//   • render time at 12MP
//

#if DEBUG
import UIKit
import CoreImage

nonisolated enum PipelineAudit {
    /// Set while -pipelineAudit runs: shots are measured and written to
    /// Documents/pipeline instead of going to Photos.
    nonisolated(unsafe) static var tag: String?
    nonisolated(unsafe) static var lines: [String] = []

    static func log(_ s: String) { print("[pipe] " + s); lines.append(s) }

    struct Stats { var w = 0, h = 0; var mean: Float = 0, p1: Float = 0, p50: Float = 0, p99: Float = 0
                   var clipHi: Float = 0, crushLo: Float = 0, detail: Float = 0 }

    static func stats(_ img: CIImage, ctx: CIContext) -> Stats {
        var st = Stats(); st.w = Int(img.extent.width); st.h = Int(img.extent.height)
        let e = img.extent
        let s = 512 / max(e.width, e.height)
        let small = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
        let sw = Int(e.width * s), sh = Int(e.height * s)
        var buf = [Float](repeating: 0, count: sw * sh * 4)
        ctx.render(small, toBitmap: &buf, rowBytes: sw * 16, bounds: CGRect(x: 0, y: 0, width: sw, height: sh),
                   format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var y = (0..<(sw * sh)).map { 0.2126 * buf[$0 * 4] + 0.7152 * buf[$0 * 4 + 1] + 0.0722 * buf[$0 * 4 + 2] }
        st.mean = y.reduce(0, +) / Float(max(y.count, 1))
        st.clipHi = Float(y.filter { $0 > 0.98 }.count) / Float(y.count)
        st.crushLo = Float(y.filter { $0 < 0.02 }.count) / Float(y.count)
        y.sort()
        st.p1 = y[y.count / 100]; st.p50 = y[y.count / 2]; st.p99 = y[y.count * 99 / 100]
        // Fine texture at 100%: mean |high-pass| on a centre 512² crop.
        let c = CGRect(x: e.midX - 256, y: e.midY - 256, width: 512, height: 512).integral
        let hp = LookAudit.highPass(img, crop: c, ctx: ctx)
        st.detail = hp.map { abs($0) }.reduce(0, +) / Float(hp.count) * 1000
        return st
    }

    static func describe(_ s: Stats) -> String {
        String(format: "%dx%d (%.1fMP) mean %.3f p1 %.3f p50 %.3f p99 %.3f clip %.2f%% crush %.2f%% detail %.2f",
               s.w, s.h, Double(s.w * s.h) / 1e6, s.mean, s.p1, s.p50, s.p99, s.clipHi * 100, s.crushLo * 100, s.detail)
    }

    static func dump(base: CIImage?, rendered: CIImage, ctx: CIContext) {
        guard let tag else { return }
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("pipeline")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func save(_ img: CIImage, _ name: String) {
            let e = img.extent
            let c = CGRect(x: e.midX - 400, y: e.midY - 400, width: 800, height: 800).integral
            try? ctx.writePNGRepresentation(of: img.cropped(to: c), to: dir.appendingPathComponent("\(tag)-\(name)-crop.png"),
                                            format: .RGBA8, colorSpace: srgb)
            let s = 1600 / max(e.width, e.height)
            let small = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
            try? ctx.writeJPEGRepresentation(of: small, to: dir.appendingPathComponent("\(tag)-\(name).jpg"), colorSpace: srgb)
        }
        if let base { log("\(tag) base " + describe(stats(base, ctx: ctx))); save(base, "base") }
        log("\(tag) film " + describe(stats(rendered, ctx: ctx))); save(rendered, "film")
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
    }
}

nonisolated enum LookAudit {

    // MARK: Lens samples (-lensSamples <image>) — every lens profile on one photo.
    static func runLenses(camera: CameraManager, path: String) {
        let fm = FileManager.default
        let out = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("lenses")
        try? fm.removeItem(at: out); try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        guard var input = CIImage(contentsOf: URL(fileURLWithPath: path)) else { print("[lens] no image"); return }
        input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        let s = 1200 / max(input.extent.width, input.extent.height)
        input = input.transformed(by: CGAffineTransform(scaleX: s, y: s))
        input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        for kind in LensKind.allCases {
            let img = camera.applyLens(input, kind).cropped(to: input.extent)
            try? camera.photoContext.writeJPEGRepresentation(of: img, to: out.appendingPathComponent("\(kind.rawValue).jpg"), colorSpace: srgb)
            print("[lens] \(kind.rawValue)")
        }
    }

    // MARK: Grain samples (-grainSamples <image>)
    // 100% crops of a few stocks' grain + a black→white ramp, as PNGs in
    // Documents/grain, to judge the grain's structure by eye.
    static func runGrain(camera: CameraManager, path: String) {
        let fm = FileManager.default
        let out = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("grain")
        try? fm.removeItem(at: out); try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        guard var input = CIImage(contentsOf: URL(fileURLWithPath: path)) else { print("[grain] no image"); return }
        input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        // Upscale to a 48MP-like width so grain is judged at photo scale.
        let s = 8064 / input.extent.width
        input = input.transformed(by: CGAffineTransform(scaleX: s, y: s)).cropped(to: CGRect(x: 0, y: 0, width: 8064, height: 6048))
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 8064, y: 0),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 8064, height: 6048))
        let ctx = camera.photoContext
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let crop = CGRect(x: 3600, y: 2800, width: 600, height: 600)
        let rampCrops = [CGRect(x: 400, y: 2800, width: 300, height: 200), CGRect(x: 2400, y: 2800, width: 300, height: 200),
                         CGRect(x: 4000, y: 2800, width: 300, height: 200), CGRect(x: 6400, y: 2800, width: 300, height: 200)]
        let sims: [FilmSimulation] = [.none, .fujiVelvia, .kodakPortra, .kodakPortra800Push2, .fujiClassicChrome, .kodakTriX]
        for sim in sims {
            var r = ShotRecipe(); r.sim = sim; r.grainEnabled = sim != .none; r.grain = 0.2
            r.contextAwareGrain = true; r.sceneISO = 400
            let img = camera.renderLook(input, recipe: r, flatten: true).cropped(to: input.extent)
            try? ctx.writePNGRepresentation(of: img.cropped(to: crop), to: out.appendingPathComponent("\(sim.rawValue).png"),
                                            format: .RGBA8, colorSpace: srgb)
            let rr = camera.renderLook(ramp, recipe: r, flatten: true).cropped(to: ramp.extent)
            for (i, c) in rampCrops.enumerated() {
                try? ctx.writePNGRepresentation(of: rr.cropped(to: c), to: out.appendingPathComponent("ramp-\(sim.rawValue)-\(i).png"),
                                                format: .RGBA8, colorSpace: srgb)
            }
            print("[grain] \(sim.rawValue)")
        }
    }

    // MARK: Detail audit (-qualityAudit)
    //
    // Does a look soften a full-resolution photo? On a 1024² centre crop of
    // a big detailed image: how much of the original fine detail survives
    // (slope of the output's high-pass against the input's, 1 = all of it)
    // and how much new texture is added (residual noise, relative to the
    // input's detail). Baselines: the same image resampled down to 16MP and
    // 12MP and back up.
    static func detail(_ img: CIImage, vs ref: [Float], crop: CGRect, ctx: CIContext) -> (slope: Float, noise: Float) {
        let hp = highPass(img, crop: crop, ctx: ctx)
        var cov: Float = 0, varR: Float = 0
        for i in hp.indices { cov += hp[i] * ref[i]; varR += ref[i] * ref[i] }
        let slope = cov / max(varR, 1e-9)
        var res: Float = 0
        for i in hp.indices { let r = hp[i] - slope * ref[i]; res += r * r }
        return (slope, (res / max(varR, 1e-9)).squareRoot())
    }

    static func highPass(_ img: CIImage, crop: CGRect, ctx: CIContext) -> [Float] {
        let n = Int(crop.width)
        var buf = [Float](repeating: 0, count: n * n * 4)
        ctx.render(img, toBitmap: &buf, rowBytes: n * 16, bounds: crop, format: .RGBAf,
                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var y = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) { y[i] = 0.2126 * buf[i * 4] + 0.7152 * buf[i * 4 + 1] + 0.0722 * buf[i * 4 + 2] }
        // high-pass = luma − 3×3 mean
        var out = [Float](repeating: 0, count: n * n)
        for r in 1..<(n - 1) { for c in 1..<(n - 1) {
            var m: Float = 0
            for dy in -1...1 { for dx in -1...1 { m += y[(r + dy) * n + c + dx] } }
            out[r * n + c] = y[r * n + c] - m / 9
        } }
        return out
    }

    static func runQuality(camera: CameraManager, path: String) {
        guard var input = CIImage(contentsOf: URL(fileURLWithPath: path)) else { print("[quality] no image"); return }
        input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        // Crop to 4:3 like the camera.
        let w = input.extent.width, h = min(input.extent.height, w * 3 / 4)
        input = input.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let ctx = camera.photoContext
        let crop = CGRect(x: (w - 1024) / 2, y: (h - 1024) / 2, width: 1024, height: 1024).integral
        let ref = highPass(input, crop: crop, ctx: ctx)
        let mp = Double(w * h) / 1e6
        print(String(format: "[quality] input %.0f×%.0f (%.1f MP)", w, h, mp))
        func resampled(_ targetMP: Double) -> CIImage {
            let s = CGFloat((targetMP / mp).squareRoot())
            let down = input.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
            return down.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 1 / s, "inputAspectRatio": 1])
                .cropped(to: input.extent)
        }
        for (name, img) in [("16MP baseline", resampled(16)), ("12MP baseline", resampled(12))] {
            let d = detail(img, vs: ref, crop: crop, ctx: ctx)
            print(String(format: "[quality] %@  detail %.2f  added %.2f", name, d.slope, d.noise))
        }
        func row(_ label: String, _ r: ShotRecipe) {
            let out = camera.renderLook(input, recipe: r, flatten: true).cropped(to: input.extent)
            let d = detail(out, vs: ref, crop: crop, ctx: ctx)
            let st = PipelineAudit.stats(out, ctx: ctx)
            print(String(format: "[quality] %@  detail %.2f  added %.2f | mean %.3f p1 %.3f p99 %.3f crush %.1f%% clip %.1f%%",
                         label, d.slope, d.noise, st.mean, st.p1, st.p99, st.crushLo * 100, st.clipHi * 100))
        }
        let inSt = PipelineAudit.stats(input, ctx: ctx)
        print(String(format: "[quality] INPUT | mean %.3f p1 %.3f p99 %.3f crush %.1f%% clip %.1f%%",
                     inSt.mean, inSt.p1, inSt.p99, inSt.crushLo * 100, inSt.clipHi * 100))
        if ProcessInfo.processInfo.arguments.contains("-noScan") { CameraManager.scanEnabled = false }
        if ProcessInfo.processInfo.arguments.contains("-dumpSims") {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sims")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let sc = 1400 / max(w, h)
            let small = input.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": sc, "inputAspectRatio": 1])
            let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
            for sim in [FilmSimulation.none, .kodakPortra, .fujiVelvia, .ilfordHP5, .cinestill800T, .kodakGold, .fujiClassicChrome] {
                var x = ShotRecipe(); x.sim = sim
                for on in [false, true] {
                    CameraManager.scanEnabled = on
                    let o = camera.renderLook(small, recipe: x, flatten: true).cropped(to: small.extent)
                    try? ctx.writeJPEGRepresentation(of: o, to: dir.appendingPathComponent("\(sim.rawValue)-\(on ? "scan" : "old").jpg"), colorSpace: p3)
                }
            }
            CameraManager.scanEnabled = true
            print("[quality] dumped")
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-simsOnly") {
            for sim in FilmSimulation.allCases { var x = ShotRecipe(); x.sim = sim; row("sim \(sim.rawValue)", x) }
            return
        }
        var base = ShotRecipe(); base.sim = .kodakPortra
        row("Portra look only", base)
        if ProcessInfo.processInfo.arguments.contains("-grainOnly") {
            for g: Float in [0.1, 0.2, 0.3] { var r = base; r.grainEnabled = true; r.grain = g; row("Portra grain \(g)", r) }
            return
        }
        for g: Float in [0.1, 0.2, 0.3] { var r = base; r.grainEnabled = true; r.grain = g; row("Portra grain \(g)", r) }
        var r = base; r.halationEnabled = true; row("Portra halation", r)
        r = base; r.development = 0.6; row("Portra development 0.6", r)
        r = base; r.crosstalkEnabled = true; row("Portra crosstalk", r)
        r = base; r.rolloffEnabled = true; row("Portra rolloff", r)
        for sim in FilmSimulation.allCases {
            var x = ShotRecipe(); x.sim = sim
            row("sim \(sim.rawValue)", x)
        }
    }

    // ColorChecker 24 (sRGB 8-bit), row-major from dark skin to black.
    static let patches: [(String, Int, Int, Int)] = [
        ("dark skin", 115, 82, 68), ("light skin", 194, 150, 130), ("blue sky", 98, 122, 157),
        ("foliage", 87, 108, 67), ("blue flower", 133, 128, 177), ("bluish green", 103, 189, 170),
        ("orange", 214, 126, 44), ("purplish blue", 80, 91, 166), ("moderate red", 193, 90, 99),
        ("purple", 94, 60, 108), ("yellow green", 157, 188, 64), ("orange yellow", 224, 163, 46),
        ("blue", 56, 61, 150), ("green", 70, 148, 73), ("red", 175, 54, 60),
        ("yellow", 231, 199, 31), ("magenta", 187, 86, 149), ("cyan", 8, 133, 161),
        ("white", 243, 243, 242), ("n8", 200, 200, 200), ("n6.5", 160, 160, 160),
        ("n5", 122, 122, 121), ("n3.5", 85, 85, 85), ("black", 52, 52, 52),
    ]
    static let cell: CGFloat = 60

    /// 6×4 chart (360×240) with a grey ramp strip underneath (360×40).
    static func chart() -> CIImage {
        var img = CIImage.empty()
        for (i, p) in patches.enumerated() {
            let col = i % 6, row = i / 6
            let c = CIColor(red: CGFloat(p.1) / 255, green: CGFloat(p.2) / 255, blue: CGFloat(p.3) / 255,
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
            let r = CGRect(x: CGFloat(col) * cell, y: 40 + CGFloat(3 - row) * cell, width: cell, height: cell)
            img = CIImage(color: c).cropped(to: r).composited(over: img)
        }
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 360, y: 0),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 360, height: 40))
        return ramp.composited(over: img)
    }

    static func patchRect(_ i: Int) -> CGRect {
        let col = i % 6, row = i / 6
        return CGRect(x: CGFloat(col) * cell + 15, y: 40 + CGFloat(3 - row) * cell + 15, width: 30, height: 30)
    }

    static func run(camera: CameraManager) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outDir = docs.appendingPathComponent("audit")
        try? fm.removeItem(at: outDir)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let ctx = camera.ciContext
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

        // Neutral live settings so the preview path matches a plain recipe.
        camera.cachedActiveCustomSim = nil
        camera.cachedGrainEnabled = false; camera.cachedGrainAmount = 0
        camera.cachedContextAwareGrain = false
        camera.cachedCrosstalkEnabled = false; camera.cachedHalationEnabled = false
        camera.cachedRolloffEnabled = false; camera.cachedPushPullEnabled = false
        camera.cachedThermalThrottle = false
        StyleSettings.cTone = 0; StyleSettings.cColor = 0; StyleSettings.cPalette = 1

        var inputs: [(String, CIImage)] = [("chart", chart())]
        let inDir = docs.appendingPathComponent("audit-in")
        for f in ((try? fm.contentsOfDirectory(atPath: inDir.path)) ?? []).sorted() {
            if let img = CIImage(contentsOf: inDir.appendingPathComponent(f)) {
                let s = 300 / max(img.extent.width, img.extent.height)
                let small = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
                inputs.append((f, small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))))
            }
        }
        let big = chart().transformed(by: CGAffineTransform(scaleX: 4032 / 360, y: 3024 / 280))

        func avg(_ img: CIImage, _ r: CGRect, _ cs: CGColorSpace = srgb) -> [Float] {
            let a = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
            var px = [Float](repeating: 0, count: 4)
            ctx.render(a, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: cs)
            return px
        }
        func minMax(_ img: CIImage) -> (Float, Float) {
            let mn = img.applyingFilter("CIAreaMinimum", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
            let mx = img.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
            var a = [Float](repeating: 0, count: 4), b = [Float](repeating: 0, count: 4)
            ctx.render(mn, toBitmap: &a, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            ctx.render(mx, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return (min(a[0], a[1], a[2]), max(b[0], b[1], b[2]))
        }
        func hsv(_ c: [Float]) -> (Float, Float, Float) {
            let ui = UIColor(red: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            ui.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            return (Float(h * 360), Float(s), Float(v))
        }

        let chartImg = chart()
        let baseline = (0..<24).map { avg(chartImg, patchRect($0)) }
        var csv = "sim,label,greyCast,blackOut,whiteOut,n5Out,midContrast,skinHueShift,skinSatX,meanSatX,minVal,maxVal,nan,livePhotoDiff,ms12MP\n"
        var tiles: [[(String, CIImage)]] = Array(repeating: [], count: inputs.count)

        for sim in FilmSimulation.allCases {
            camera.cachedSim = sim
            var r = ShotRecipe(); r.sim = sim
            for (k, input) in inputs.enumerated() {
                let out = camera.renderLook(input.1, recipe: r, flatten: true).cropped(to: input.1.extent)
                tiles[k].append((sim.label, out))
            }
            let out = camera.renderLook(chartImg, recipe: r, flatten: true).cropped(to: chartImg.extent)
            let live = camera.applyLiveLook(chartImg, grainTextures: false).cropped(to: chartImg.extent)
            let pa = (0..<24).map { avg(out, patchRect($0)) }
            // Neutral cast: worst channel spread across the six grey patches.
            let cast = (18..<24).map { i in pa[i][0...2].max()! - pa[i][0...2].min()! }.max() ?? 0
            let lum = { (c: [Float]) in 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] }
            let midContrast = (lum(pa[19]) - lum(pa[22])) / max(lum(baseline[19]) - lum(baseline[22]), 0.001)
            let (h0, s0, _) = hsv(baseline[1]); let (h1, s1, _) = hsv(pa[1])
            var dh = h1 - h0; if dh > 180 { dh -= 360 }; if dh < -180 { dh += 360 }
            let satX = (0..<18).map { hsv(pa[$0]).1 }.reduce(0, +) / max((0..<18).map { hsv(baseline[$0]).1 }.reduce(0, +), 0.001)
            let (mn, mx) = minMax(out)
            let nan = mn.isNaN || mx.isNaN || mn.isInfinite || mx.isInfinite
            let pl = (0..<24).map { avg(live, patchRect($0)) }
            let diff = zip(pa, pl).map { a, b in (0..<3).map { abs(a[$0] - b[$0]) }.max()! }.max() ?? 0
            // Time the second of two renders: the first includes compiling the
            // look's GPU program, which happens once per app run.
            var ms = 0.0
            for _ in 0..<2 {
                let t0 = CACurrentMediaTime()
                let bigOut = camera.renderLook(big, recipe: r, flatten: true).cropped(to: big.extent)
                _ = ctx.createCGImage(bigOut, from: bigOut.extent, format: .RGBA8, colorSpace: p3)
                ms = (CACurrentMediaTime() - t0) * 1000
            }
            csv += String(format: "%@,%@,%.3f,%.3f,%.3f,%.3f,%.2f,%.1f,%.2f,%.2f,%.3f,%.3f,%@,%.3f,%.0f\n",
                          sim.rawValue, sim.label.replacingOccurrences(of: ",", with: " "),
                          cast, lum(pa[23]), lum(pa[18]), lum(pa[21]), midContrast, dh, s1 / max(s0, 0.001), satX,
                          mn, mx, nan ? "NAN" : "ok", diff, ms)
            print("AUDIT \(sim.rawValue) \(Int(ms))ms")
        }
        try? csv.write(to: outDir.appendingPathComponent("metrics.csv"), atomically: true, encoding: .utf8)

        // Effects and lens looks, each on top of Portra.
        var variants: [(String, ShotRecipe)] = []
        func v(_ name: String, _ f: (inout ShotRecipe) -> Void) {
            var r = ShotRecipe(); r.sim = .kodakPortra; f(&r); variants.append((name, r))
        }
        v("Portra") { _ in }
        v("Grain 0.15") { $0.grainEnabled = true; $0.grain = 0.15 }
        v("Grain 0.35") { $0.grainEnabled = true; $0.grain = 0.35 }
        v("Grain ctx") { $0.grainEnabled = true; $0.grain = 0.2; $0.contextAwareGrain = true }
        v("Halation") { $0.halationEnabled = true; $0.halation = 0.5 }
        v("Crosstalk") { $0.crosstalkEnabled = true; $0.crosstalk = 0.3 }
        v("Rolloff") { $0.rolloffEnabled = true; $0.rolloff = 0.7 }
        v("Push +2") { $0.pushPullEnabled = true; $0.pushPull = 2 }
        v("Pull -1") { $0.pushPullEnabled = true; $0.pushPull = -1 }
        v("Anamorphic") { $0.anamorphicFlare = true }
        v("Light leaks") { $0.lightArtifacts = true; $0.randomSeed = 7 }
        v("Scratches") { $0.filmScratches = true; $0.randomSeed = 7 }
        v("Randomize") { $0.randomization = true; $0.randomSeed = 7 }
        v("Cross-dev") { $0.crossProcessed = true }
        v("Develop 0.5") { $0.development = 0.5 }
        v("Stand dev") { $0.development = 1 }
        for kind in LensKind.allCases where kind != .none {
            v("Lens \(kind.label)") { r in
                var c = CustomSimulation(); c.name = "Audit"; c.baseSim = .kodakPortra; c.lens = kind.rawValue
                r.custom = c
            }
        }
        var ecsv = "variant,minVal,maxVal,nan,lumaShift,ms12MP\n"
        let scene = inputs.count > 1 ? inputs[1].1 : chartImg
        var etiles: [(String, CIImage)] = []
        let portraBase = avg(camera.renderLook(scene, recipe: variants[0].1, flatten: true).cropped(to: scene.extent), scene.extent)
        for (name, r) in variants {
            let out = camera.renderLook(scene, recipe: r, flatten: true).cropped(to: scene.extent)
            etiles.append((name, out))
            let (mn, mx) = minMax(out)
            let nan = mn.isNaN || mx.isNaN || mn.isInfinite || mx.isInfinite
            let a = avg(out, scene.extent)
            let lumaShift = (0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2]) - (0.2126 * portraBase[0] + 0.7152 * portraBase[1] + 0.0722 * portraBase[2])
            var ms = 0.0
            for _ in 0..<2 {
                let t0 = CACurrentMediaTime()
                let o = camera.renderLook(big, recipe: r, flatten: true).cropped(to: big.extent)
                _ = ctx.createCGImage(o, from: o.extent, format: .RGBA8, colorSpace: p3)
                ms = (CACurrentMediaTime() - t0) * 1000
            }
            ecsv += String(format: "%@,%.3f,%.3f,%@,%.3f,%.0f\n", name, mn, mx, nan ? "NAN" : "ok", lumaShift, ms)
            print("AUDIT effect \(name) \(Int(ms))ms")
        }
        try? ecsv.write(to: outDir.appendingPathComponent("effects.csv"), atomically: true, encoding: .utf8)
        tiles.append(etiles)
        inputs.append(("effects", scene))

        // Film engine pilot: each pilot stock's old look next to the engine.
        let pilot: [FilmSimulation] = [.kodakPortra, .kodakEktar, .kodakGold, .fujiVelvia, .kodakVision3, .fujiSuperia, .kodakTriX]
        let photoInputs = inputs.filter { $0.0 != "effects" }
        for input in photoInputs {
            var row: [(String, CIImage)] = [("Original", input.1)]
            for sim in pilot {
                var r = ShotRecipe(); r.sim = sim
                FilmEngine.enabled = false
                row.append(("Old \(sim.label)", camera.renderLook(input.1, recipe: r, flatten: true).cropped(to: input.1.extent)))
                FilmEngine.enabled = true
                row.append(("New \(sim.label)", camera.renderLook(input.1, recipe: r, flatten: true).cropped(to: input.1.extent)))
            }
            tiles.append(row)
            inputs.append(("pilot-\((input.0 as NSString).deletingPathExtension)", input.1))
        }

        // Contact sheets: 8 per row, labelled.
        for (k, input) in inputs.enumerated() {
            let w = input.1.extent.width, h = input.1.extent.height
            let perRow = inputs[k].0.hasPrefix("pilot-") ? 15 : 8, labelH: CGFloat = 22
            let rows = Int(ceil(Double(tiles[k].count) / Double(perRow)))
            let size = CGSize(width: CGFloat(perRow) * (w + 6) + 6, height: CGFloat(rows) * (h + labelH + 6) + 6)
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
            let sheet = UIGraphicsImageRenderer(size: size, format: fmt).image { c in
                UIColor(white: 0.12, alpha: 1).setFill(); c.fill(CGRect(origin: .zero, size: size))
                for (i, t) in tiles[k].enumerated() {
                    let x = 6 + CGFloat(i % perRow) * (w + 6), y = 6 + CGFloat(i / perRow) * (h + labelH + 6)
                    if let cg = ctx.createCGImage(t.1, from: input.1.extent, format: .RGBA8, colorSpace: p3) {
                        UIImage(cgImage: cg).draw(in: CGRect(x: x, y: y, width: w, height: h))
                    }
                    (t.0 as NSString).draw(at: CGPoint(x: x + 2, y: y + h + 3), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: UIColor.white])
                }
            }
            let name = (input.0 as NSString).deletingPathExtension
            try? sheet.jpegData(compressionQuality: 0.9)?.write(to: outDir.appendingPathComponent("sheet-\(name).jpg"))
        }
        try? "done".write(to: outDir.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
        print("AUDIT DONE \(outDir.path)")
    }
}
#endif
