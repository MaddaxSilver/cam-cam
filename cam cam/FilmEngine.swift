//
//  FilmEngine.swift
//  cam cam
//
//  Film stocks modelled in exposure rather than as a stack of filters
//  (saturation, contrast, warmth, vignette). See `filmEngine` in
//  shaders/FilmProcess.ci.metal for the model; this file holds each stock's
//  numbers and solves its print curve so mid grey prints neutral.
//
//  Engine stocks: Superia, Tri-X (no measured data for them). Stocks with
//  spektrafilm data use baked LUTs (FilmSimulation.bundledLUT) instead;
//  everything else still uses its hand-built look in applyFilmSim.
//

import CoreImage

nonisolated enum FilmEngine {

    /// Off = the old filter-stack looks (used by the look audit to compare).
    nonisolated(unsafe) static var enabled = true

    struct Stock: Sendable {
        /// How the three dye layers see the scene (rows: red, green, blue layer).
        var sensitivity: [SIMD3<Float>] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        var exposure: Float = 0
        /// Per-layer slope / speed of the characteristic curve.
        var slope: SIMD3<Float> = [1, 1, 1]
        var speed: SIMD3<Float> = [0, 0, 0]
        /// Shadow (toe) and highlight (shoulder) softness multipliers.
        var toe: Float = 1
        var shoulder: Float = 1
        /// Inter-layer effects: > 0 pushes layers apart (more saturation).
        var saturation: Float = 0
        var cross: [SIMD3<Float>] = [.zero, .zero, .zero]
        /// Print black (max density), white (paper/base) and mid grey, linear.
        var black: SIMD3<Float> = [0.002, 0.002, 0.002]
        var white: SIMD3<Float> = [0.985, 0.985, 0.985]
        var mid: SIMD3<Float> = [0.18, 0.18, 0.18]
        /// B&W: average the layers and tone by the silver colour.
        var mono = false
        var tone: SIMD3<Float> = [1, 1, 1]
    }

    /// Fitted base response: matches a normal photo's mid-tones, rolls off
    /// highlights and holds a toe. Stocks give multipliers on these.
    static let baseSlope: Float = 0.55, baseToe: Float = 0.85, baseShoulder: Float = 1.55

    static let stocks: [FilmSimulation: Stock] = [
        // Superia 400: punchy greens, slightly green-cool, magenta-leaning reds.
        .fujiSuperia: Stock(
            sensitivity: [[0.93, 0.05, 0.02], [0.03, 0.95, 0.02], [0.00, 0.06, 0.94]],
            slope: [0.98, 1.04, 1.0], shoulder: 0.968, saturation: 0.14,
            cross: [[0, -0.02, 0.02], .zero, .zero],
            black: [0.003, 0.005, 0.005], white: [0.975, 0.985, 0.975], mid: [0.175, 0.184, 0.178]),
        // Tri-X 400: panchromatic (blue-heavy, red-shy), punchy mid-tones with a
        // held toe and gentle shoulder, faintly warm silver.
        .kodakTriX: Stock(
            sensitivity: [[0.24, 0.62, 0.14], [0.24, 0.62, 0.14], [0.24, 0.62, 0.14]],
            slope: [1.15, 1.15, 1.15], toe: 1.071, shoulder: 0.895,
            black: [0.004, 0.004, 0.004], white: [0.97, 0.97, 0.97], mid: [0.17, 0.17, 0.17],
            mono: true, tone: [1.0, 0.99, 0.96]),
    ]

    /// The engine's version of `sim`, or nil when the sim isn't on the engine
    /// (or the kernel is missing) so the caller falls back to its old look.
    static func apply(_ image: CIImage, sim: FilmSimulation) -> CIImage? {
        guard enabled, let st = stocks[sim],
              let kernel = CameraManager.filmKernel("filmEngine") else { return nil }
        let p = prepared(st)
        let v = { (x: SIMD3<Float>) in CIVector(x: CGFloat(x.x), y: CGFloat(x.y), z: CGFloat(x.z)) }
        return kernel.apply(extent: image.extent, arguments: [
            image, v(st.sensitivity[0]), v(st.sensitivity[1]), v(st.sensitivity[2]), st.exposure,
            v(p.slope), v(st.speed), p.toe, p.shoulder,
            v(p.coupling[0]), v(p.coupling[1]), v(p.coupling[2]),
            v(p.printGamma), v(st.black), v(st.white), st.mono ? 1 : 0, v(st.tone),
        ])
    }

    // MARK: Preparation (absolute curve values + solved print exponents)

    struct Prepared {
        var slope: SIMD3<Float>
        var toe: Float
        var shoulder: Float
        var coupling: [SIMD3<Float>]
        var printGamma: SIMD3<Float>
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Prepared] = [:]

    static func prepared(_ st: Stock) -> Prepared {
        let key = "\(st)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let p = cache[key] { return p }
        let slope = st.slope * baseSlope
        let toe = st.toe * baseToe, shoulder = st.shoulder * baseShoulder
        // Inter-layer matrix: identity + saturation·(I − 1/3) + cross terms.
        var c: [SIMD3<Float>] = []
        for i in 0..<3 {
            var row = SIMD3<Float>(repeating: -st.saturation / 3)
            row[i] += 1 + st.saturation
            c.append(row + st.cross[i])
        }
        // Mid grey through the negative, then solve n^g = target per layer.
        var nGrey = SIMD3<Float>()
        for i in 0..<3 {
            let rowSum = st.sensitivity[i].sum()
            let x = log2(max(rowSum, 1e-6)) + st.exposure - st.speed[i]
            let k = x < 0 ? slope[i] * toe : slope[i] * shoulder
            nGrey[i] = 1 / (1 + exp(-k * x))
        }
        var gamma = SIMD3<Float>()
        for i in 0..<3 {
            let n = min(max((c[i] * nGrey).sum(), 1e-4), 0.9999)
            let target = min(max((st.mid[i] - st.black[i]) / (st.white[i] - st.black[i]), 1e-4), 0.9999)
            gamma[i] = log(target) / log(n)
        }
        let p = Prepared(slope: slope, toe: toe, shoulder: shoulder, coupling: c, printGamma: gamma)
        cache[key] = p
        return p
    }
}
