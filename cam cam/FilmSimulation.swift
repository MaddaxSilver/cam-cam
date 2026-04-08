//  FilmSimulation.swift
//  cam cam
//
//  Created by Assistant on 2026-04-03.
//
//  This file defines film simulation types and Core Image pipelines approximating
//  popular Fuji and Leica looks. These are original approximations and do NOT
//  use any proprietary profiles.

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

struct CameraSettings: Sendable {
    var isHighlightRolloffEnabled: Bool = false
    var rolloffThreshold: Float = 0.9

    var isColorCrosstalkEnabled: Bool = false
    var crossTalkAmount: Float = 0.1

    var isHalationEnabled: Bool = false
    var halationAmount: Float = 0.2

    var isAutoGrainEnabled: Bool = false
}

enum FilmSim: String, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case fujiClassicChrome = "Fuji Classic Chrome"
    case fujiVelvia = "Fuji Velvia"
    case leicaMonochrom = "Leica Monochrom"
    case leicaWarm = "Leica Warm"

    var id: String { rawValue }

    var chipLabel: String {
        switch self {
        case .none: return "None"
        case .leicaMonochrom: return "Leica M"
        case .fujiClassicChrome: return "Provia"
        case .fujiVelvia: return "Velvia"
        case .leicaWarm: return "Fuji 200"
        }
    }
}

nonisolated struct FilmSimulator: @unchecked Sendable {
    private let context = CIContext()
    var settings: CameraSettings?

    init(settings: CameraSettings? = nil) {
        self.settings = settings
    }

    func apply(sim: FilmSim, to image: CIImage) -> CIImage {
        switch sim {
        case .none:
            let img = image
            return applyFilmicToggles(to: img)
        case .fujiClassicChrome:
            let img = classicChrome(input: image)
            return applyFilmicToggles(to: img)
        case .fujiVelvia:
            let img = velvia(input: image)
            return applyFilmicToggles(to: img)
        case .leicaMonochrom:
            let img = leicaMono(input: image)
            return applyFilmicToggles(to: img)
        case .leicaWarm:
            let img = leicaWarm(input: image)
            return applyFilmicToggles(to: img)
        }
    }

    // MARK: - Approximations

    private func classicChrome(input: CIImage) -> CIImage {
        // Muted saturation, lifted shadows, cool tint
        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = input
        colorControls.saturation = 0.8
        colorControls.contrast = 1.05
        colorControls.brightness = 0.02
        let cool = CIFilter.temperatureAndTint()
        cool.inputImage = colorControls.outputImage
        cool.neutral = CIVector(x: 6500, y: 0)
        cool.targetNeutral = CIVector(x: 7000, y: 0) // slightly cooler
        let curve = toneCurve(input: cool.outputImage!, shadows: 0.06, mid: 0.0, highlights: -0.04)
        return curve
    }

    private func velvia(input: CIImage) -> CIImage {
        // High saturation, punchy contrast, slight warmth
        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = input
        colorControls.saturation = 1.35
        colorControls.contrast = 1.12
        colorControls.brightness = 0.0
        let warm = CIFilter.temperatureAndTint()
        warm.inputImage = colorControls.outputImage
        warm.neutral = CIVector(x: 6500, y: 0)
        warm.targetNeutral = CIVector(x: 6000, y: 0)
        let clarity = claritySharpen(input: warm.outputImage!)
        return clarity
    }

    private func leicaMono(input: CIImage) -> CIImage {
        // Rich monochrome with gentle S-curve
        let mono = CIFilter.photoEffectNoir()
        mono.inputImage = input
        let curved = toneCurve(input: mono.outputImage!, shadows: -0.03, mid: 0.0, highlights: 0.06)
        return curved
    }

    private func leicaWarm(input: CIImage) -> CIImage {
        // Subtle warmth, gentle contrast, slight grain
        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = input
        colorControls.saturation = 1.05
        colorControls.contrast = 1.06
        let warm = CIFilter.temperatureAndTint()
        warm.inputImage = colorControls.outputImage
        warm.neutral = CIVector(x: 6500, y: 0)
        warm.targetNeutral = CIVector(x: 5800, y: 0)
        let curved = toneCurve(input: warm.outputImage!, shadows: -0.01, mid: 0.0, highlights: 0.03)
        let grained = addGrain(input: curved, amount: 0.12)
        return grained
    }

    // MARK: - Building Blocks

    private func toneCurve(input: CIImage, shadows: Float, mid: Float, highlights: Float) -> CIImage {
        let curve = CIFilter.toneCurve()
        curve.inputImage = input
        curve.point0 = CGPoint(x: 0.0, y: max(0.0, min(1.0, 0.0 + CGFloat(shadows))))
        curve.point1 = CGPoint(x: 0.25, y: max(0.0, min(1.0, 0.25 + CGFloat(shadows * 0.5))))
        curve.point2 = CGPoint(x: 0.5, y: max(0.0, min(1.0, 0.5 + CGFloat(mid))))
        curve.point3 = CGPoint(x: 0.75, y: max(0.0, min(1.0, 0.75 + CGFloat(highlights * 0.5))))
        curve.point4 = CGPoint(x: 1.0, y: max(0.0, min(1.0, 1.0 + CGFloat(highlights))))
        return curve.outputImage ?? input
    }

    private func claritySharpen(input: CIImage) -> CIImage {
        // Unsharp mask-like clarity
        let filter = CIFilter.unsharpMask()
        filter.inputImage = input
        filter.intensity = 0.6
        filter.radius = 1.5
        return filter.outputImage ?? input
    }

    private func addGrain(input: CIImage, amount: Float) -> CIImage {
        let noise = CIFilter.randomGenerator().outputImage!
        let scaled = noise.cropped(to: input.extent)
        let mono = CIFilter.colorControls()
        mono.inputImage = scaled
        mono.saturation = 0.0
        mono.brightness = 0.0
        mono.contrast = 1.0

        let blend = CIFilter.overlayBlendMode()
        blend.inputImage = mono.outputImage
        blend.backgroundImage = input

        let opacity = CIFilter.colorMatrix()
        opacity.inputImage = blend.outputImage
        opacity.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount))

        return opacity.outputImage ?? input
    }

    // MARK: - Filmic Toggles and Helpers

    private func applyFilmicToggles(to input: CIImage) -> CIImage {
        var img = input
        if let settings = settings {
            if settings.isHighlightRolloffEnabled {
                img = applyHighlightRolloff(input: img, threshold: settings.rolloffThreshold)
            }
            if settings.isColorCrosstalkEnabled {
                img = applyColorCrosstalk(input: img, amount: settings.crossTalkAmount)
            }
            if settings.isHalationEnabled {
                img = applyHalation(input: img, amount: settings.halationAmount)
            }
            if settings.isAutoGrainEnabled {
                // For now, use a simple auto gain; you can wire actual ISO later
                let isoRef: Float = 100
                let isoCurrent: Float = 800 // TODO: replace with real ISO metadata
                let t = max(0, min(1, (isoCurrent - isoRef) / 1600))
                img = addGrain(input: img, amount: 0.05 + 0.25 * t)
            }
        }
        return img
    }

    private func applyColorCrosstalk(input: CIImage, amount: Float) -> CIImage {
        // 3x3 matrix with small off-diagonal bleed
        let a = CGFloat(max(0, min(0.2, amount)))
        let r = CIVector(x: 1 - a, y: a * 0.5, z: a * 0.5, w: 0)
        let g = CIVector(x: a * 0.5, y: 1 - a, z: a * 0.5, w: 0)
        let b = CIVector(x: a * 0.5, y: a * 0.5, z: 1 - a, w: 0)
        let m = CIFilter.colorMatrix()
        m.inputImage = input
        m.rVector = r
        m.gVector = g
        m.bVector = b
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage ?? input
    }

    private func applyHalation(input: CIImage, amount: Float) -> CIImage {
        // Extract highlights in red channel and blur
        let redExtract = CIFilter.colorMatrix()
        redExtract.inputImage = input
        redExtract.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        redExtract.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        redExtract.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        redExtract.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let redOnly = redExtract.outputImage ?? input

        let highlight = CIFilter.highlightShadowAdjust()
        highlight.inputImage = redOnly
        highlight.highlightAmount = 1.0
        highlight.shadowAmount = 0.0
        let bright = highlight.outputImage ?? redOnly

        let gaussian = CIFilter.gaussianBlur()
        gaussian.inputImage = bright
        gaussian.radius = Float(max(2, Double(amount) * 20.0))
        let blurred = gaussian.outputImage?.cropped(to: input.extent) ?? input

        let tint = CIFilter.colorMatrix()
        tint.inputImage = blurred
        tint.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0.2, y: 0, z: 0, w: 0)
        tint.bVector = CIVector(x: 0.0, y: 0, z: 0, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(0.15 + amount))
        let colored = tint.outputImage ?? blurred

        let composite = CIFilter.screenBlendMode()
        composite.inputImage = colored
        composite.backgroundImage = input
        return composite.outputImage ?? input
    }

    private func applyHighlightRolloff(input: CIImage, threshold: Float) -> CIImage {
        // Approximate shoulder curve using tone curve points
        let t = CGFloat(max(0.5, min(0.98, threshold)))
        let curve = CIFilter.toneCurve()
        curve.inputImage = input
        curve.point0 = CGPoint(x: 0.0, y: 0.0)
        curve.point1 = CGPoint(x: 0.5, y: 0.5)
        curve.point2 = CGPoint(x: t, y: t - 0.05)
        curve.point3 = CGPoint(x: (t + 1.0) * 0.5, y: (t + 1.0) * 0.5 - 0.02)
        curve.point4 = CGPoint(x: 1.0, y: 0.98)
        return curve.outputImage ?? input
    }
}
