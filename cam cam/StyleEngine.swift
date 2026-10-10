//
//  StyleEngine.swift
//  cam cam
//
//  cam cam's take on iPhone 16 "Photographic Styles" — which Apple doesn't
//  expose to apps (private AVCaptureSmartStyle, rendered in the iPhone 16
//  ISP), so we build the equivalent in our own pipeline, on any iPhone.
//
//  What makes Apple's styles different from a filter: they treat SKIN
//  separately from the rest of the scene.
//   • Undertones (Amber, Gold, Rose Gold, Neutral, Cool Rose) mostly shift
//     skin, gently touching the rest.
//   • Moods (Vibrant, Natural, Luminous, Dramatic, Quiet, Cozy, Ethereal,
//     Muted B&W, Stark B&W) grade the scene but keep skin close to natural.
//  Skin comes from Vision person segmentation (fast on the live preview,
//  accurate on the saved photo). Three controls, like Apple's pad:
//   Tone (shadows/contrast), Colour (vibrance) and Palette (strength).
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import Observation

nonisolated enum StyleKind: String, CaseIterable, Sendable {
    case amber, gold, roseGold, neutral, coolRose
    case vibrant, natural, luminous, dramatic, quiet, cozy, ethereal, mutedBW, starkBW

    /// Scene grade + skin treatment for each style.
    struct Grade {
        var temp: Float = 0          // + warmer, − cooler (Kelvin-ish shift)
        var tint: Float = 0          // + magenta, − green
        var sat: Float = 1
        var contrast: Float = 1
        var lift: Float = 0          // raise blacks (fade)
        var bright: Float = 0
        var mono = false
        var skinTemp: Float = 0      // extra warmth on skin only
        var skinTint: Float = 0      // extra magenta on skin only
        var keepSkin: Float = 0      // 0…1: how much original skin is kept
    }

    var grade: Grade {
        switch self {
        case .amber:    return Grade(temp: 250, sat: 1.02, skinTemp: 700, skinTint: 4)
        case .gold:     return Grade(temp: 350, tint: -4, sat: 1.04, skinTemp: 600, skinTint: -6)
        case .roseGold: return Grade(temp: 200, tint: 8, sat: 1.02, skinTemp: 350, skinTint: 14)
        case .neutral:  return Grade(temp: -150, sat: 0.98, skinTemp: -350, skinTint: -2)
        case .coolRose: return Grade(temp: -350, tint: 6, sat: 1.0, skinTemp: -300, skinTint: 12)
        case .vibrant:  return Grade(sat: 1.30, contrast: 1.06, keepSkin: 0.55)
        case .natural:  return Grade(sat: 0.96, contrast: 0.98, lift: 0.01, keepSkin: 0.4)
        case .luminous: return Grade(temp: 120, sat: 1.12, contrast: 0.96, lift: 0.02, bright: 0.04, keepSkin: 0.5)
        case .dramatic: return Grade(temp: -180, sat: 0.95, contrast: 1.22, bright: -0.03, keepSkin: 0.45)
        case .quiet:    return Grade(temp: 80, sat: 0.72, contrast: 0.9, lift: 0.05, keepSkin: 0.4)
        case .cozy:     return Grade(temp: 650, tint: 4, sat: 1.05, contrast: 1.04, keepSkin: 0.35)
        case .ethereal: return Grade(temp: -120, tint: 10, sat: 0.82, contrast: 0.86, lift: 0.07, bright: 0.04, keepSkin: 0.35)
        case .mutedBW:  return Grade(contrast: 0.85, lift: 0.05, mono: true)
        case .starkBW:  return Grade(contrast: 1.35, bright: -0.02, mono: true)
        }
    }
}

/// The three style controls, shared by preview, capture and the UI.
@MainActor @Observable
final class StyleSettings {
    static let shared = StyleSettings()
    var tone: Float = UserDefaults.standard.object(forKey: "cc_styleTone") as? Float ?? 0 {
        didSet { UserDefaults.standard.set(tone, forKey: "cc_styleTone"); StyleSettings.cTone = tone }
    }
    var color: Float = UserDefaults.standard.object(forKey: "cc_styleColor") as? Float ?? 0 {
        didSet { UserDefaults.standard.set(color, forKey: "cc_styleColor"); StyleSettings.cColor = color }
    }
    var palette: Float = UserDefaults.standard.object(forKey: "cc_stylePalette") as? Float ?? 1 {
        didSet { UserDefaults.standard.set(palette, forKey: "cc_stylePalette"); StyleSettings.cPalette = palette }
    }
    // Off-main mirrors.
    nonisolated(unsafe) static var cTone: Float = UserDefaults.standard.object(forKey: "cc_styleTone") as? Float ?? 0
    nonisolated(unsafe) static var cColor: Float = UserDefaults.standard.object(forKey: "cc_styleColor") as? Float ?? 0
    nonisolated(unsafe) static var cPalette: Float = UserDefaults.standard.object(forKey: "cc_stylePalette") as? Float ?? 1
}

/// Person/skin mask. Live preview reuses a mask refreshed a few times a
/// second; stills get an accurate mask of their own.
nonisolated final class SkinMask: @unchecked Sendable {
    static let shared = SkinMask()
    private let lock = NSLock()
    private var latest: CIImage?
    private var lastTime: Double = 0
    private var busy = false
    private let queue = DispatchQueue(label: "cam.skinmask", qos: .utility)

    /// Called with live frames; refreshes the cached mask ~6×/s.
    func update(_ pb: CVPixelBuffer, time: Double) {
        lock.lock()
        guard !busy, time - lastTime > 0.16 else { lock.unlock(); return }
        busy = true; lastTime = time
        lock.unlock()
        let image = CIImage(cvPixelBuffer: pb)
        queue.async { [weak self] in
            let m = SkinMask.segment(image, quality: .fast)
            self?.lock.lock(); self?.latest = m; self?.busy = false; self?.lock.unlock()
        }
    }

    /// Latest live mask, scaled to `extent`.
    func live(for extent: CGRect) -> CIImage? {
        lock.lock(); let m = latest; lock.unlock()
        guard let m else { return nil }
        return SkinMask.fit(m, to: extent)
    }

    /// Fast person mask (live frames from the Sony / re-grade preview).
    static func fast(_ image: CIImage) -> CIImage? { segment(image, quality: .fast) }

    /// Accurate person mask for a still.
    static func accurate(_ image: CIImage) -> CIImage? { segment(image, quality: .accurate) }

    static func segment(_ image: CIImage, quality: VNGeneratePersonSegmentationRequest.QualityLevel) -> CIImage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = quality
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([req])) != nil,
              let buf = req.results?.first?.pixelBuffer else { return nil }
        return fit(CIImage(cvPixelBuffer: buf), to: image.extent)
    }

    static func fit(_ m: CIImage, to extent: CGRect) -> CIImage {
        let sx = extent.width / max(m.extent.width, 1), sy = extent.height / max(m.extent.height, 1)
        return m.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: extent.minX - m.extent.minX * sx,
                                               y: extent.minY - m.extent.minY * sy))
            .applyingGaussianBlur(sigma: Double(max(extent.width, extent.height)) * 0.004)
            .cropped(to: extent)
    }
}

nonisolated enum StyleEngine {

    /// Apply a style. `mask` = person/skin mask (white = person), or nil.
    static func apply(_ input: CIImage, kind: StyleKind, tone: Float, color: Float, palette: Float,
                      mask: CIImage?) -> CIImage {
        let g = kind.grade
        let extent = input.extent

        // Scene grade.
        var scene = whiteBalance(input, temp: g.temp, tint: g.tint)
        let cc = CIFilter.colorControls()
        cc.inputImage = scene
        cc.saturation = g.mono ? 0 : g.sat * (1 + color * 0.2)
        cc.contrast = g.contrast * (1 + tone * 0.18)
        cc.brightness = g.bright
        scene = cc.outputImage ?? scene
        if !g.mono && color != 0 {
            let vib = CIFilter.vibrance()
            vib.inputImage = scene
            vib.amount = color * 0.6
            scene = vib.outputImage ?? scene
        }
        // Tone: deeper (+) or lifted (−) shadows; style fade on top.
        let lift = g.lift - tone * 0.04
        if abs(lift) > 0.001 || tone != 0 {
            let curve = CIFilter.toneCurve()
            curve.inputImage = scene
            curve.point0 = CGPoint(x: 0, y: CGFloat(max(0, lift)))
            curve.point1 = CGPoint(x: 0.25, y: 0.25 - Double(tone) * 0.04 + Double(max(0, lift)) * 0.6)
            curve.point2 = CGPoint(x: 0.5, y: 0.5)
            curve.point3 = CGPoint(x: 0.75, y: 0.75 + Double(tone) * 0.02)
            curve.point4 = CGPoint(x: 1, y: 1)
            scene = curve.outputImage ?? scene
        }

        // Skin: undertone shift on skin, and/or keep skin closer to natural.
        if let mask, !g.mono {
            var skin = whiteBalance(scene, temp: g.skinTemp, tint: g.skinTint)
            if g.keepSkin > 0 {
                skin = blend(skin, over: input, amount: 1 - g.keepSkin)
            }
            let b = CIFilter.blendWithMask()
            b.inputImage = skin
            b.backgroundImage = scene
            b.maskImage = mask
            scene = b.outputImage ?? scene
        } else if !g.mono {
            // No mask (no people found): undertones still nudge the whole frame a little.
            scene = whiteBalance(scene, temp: g.skinTemp * 0.3, tint: g.skinTint * 0.3)
        }

        // Palette = strength of the whole style.
        return blend(scene, over: input, amount: max(0, min(1, palette))).cropped(to: extent)
    }

    private static func whiteBalance(_ img: CIImage, temp: Float, tint: Float) -> CIImage {
        guard temp != 0 || tint != 0 else { return img }
        let f = CIFilter.temperatureAndTint()
        f.inputImage = img
        f.neutral = CIVector(x: 6500, y: 0)
        f.targetNeutral = CIVector(x: CGFloat(6500 - temp), y: CGFloat(-tint))
        return f.outputImage ?? img
    }

    /// `amount` of `top` over `base` (0 = base, 1 = top).
    private static func blend(_ top: CIImage, over base: CIImage, amount: Float) -> CIImage {
        guard amount < 0.999 else { return top }
        guard amount > 0.001 else { return base }
        let faded = top.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount)),
        ])
        return faded.composited(over: base)
    }
}
