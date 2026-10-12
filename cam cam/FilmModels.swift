//
//  FilmModels.swift
//  cam cam
//
//  Film sim models: FilmSimulation, CustomSimulation (+store), focal presets, aspect ratios, long-exposure modes, icon rotation.
//

import SwiftUI
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import Observation
import CoreMotion
import MediaPlayer
import MetalKit
import UniformTypeIdentifiers
import CoreLocation

// MARK: - Orientation-Aware Icon/Text Rotation BZHNNY
private struct IconRotation: ViewModifier {
    let angle: Double
    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(angle))
    }
}

extension View {
    func iconRotation(_ angle: Double) -> some View {
        modifier(IconRotation(angle: angle))
    }

    @ViewBuilder
    func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Custom Film Simulation Model

/// `nonisolated` + `Sendable`: a plain value type that travels inside a
/// ShotRecipe across threads (render queues, Sony parser, Photos re-grade).
/// Without this the project's default MainActor isolation made even its
/// Equatable/Codable conformances main-only.
nonisolated struct CustomSimulation: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String = "My Film"

    // Exposure
    var brightness: Float = 0.0       // -0.1 ... 0.1
    var contrast: Float = 1.0         // 0.7 ... 1.5
    var saturation: Float = 1.0       // 0.0 ... 2.0

    // Temperature
    var temperature: Float = 6500     // 3000 ... 10000
    var tint: Float = 0               // -50 ... 50

    // Tone curve
    var shadowLift: Float = 0.0       // 0 ... 0.15
    var midShift: Float = 0.0         // -0.1 ... 0.1
    var highlightRolloff: Float = 0.0 // -0.1 ... 0.0

    // Color channels
    var redMult: Float = 1.0          // 0.7 ... 1.3
    var greenMult: Float = 1.0        // 0.7 ... 1.3
    var blueMult: Float = 1.0         // 0.7 ... 1.3

    // Red bias (adds warmth to shadows)
    var redBias: Float = 0.0          // -0.05 ... 0.05
    var greenBias: Float = 0.0
    var blueBias: Float = 0.0

    /// Optional .cube LUT filename (in Documents/LUTs/). When non-nil, the
    /// pipeline applies the LUT and SKIPS the parameter-based color grading
    /// — the LUT is the entire look. Other effects (grain, vignette, bloom,
    /// halation, etc.) still apply after the LUT.
    /// Backward-compatible: existing simulations decode with nil here.
    var lutFilename: String? = nil

    // Quality: 0 = speed, 1 = balanced, 2 = quality (Deep Fusion)
    var quality: Int = 2

    // Effects
    var vignetteIntensity: Float = 0.0 // 0 ... 2.0
    var fadeAmount: Float = 0.0        // 0 ... 0.15 (lifts black point)
    var bloomIntensity: Float = 0.0    // 0 ... 0.5
    var bloomRadius: Float = 8.0       // 2 ... 20
    var hazeAmount: Float = 0.0        // 0 = clear, 1 = heavy atmospheric haze
    var redEyeStrength: Float = 0.0    // 0 = off, 1 = full correction; blended at capture time

    // Saved-camera extras (all optional so older saved films still load)
    /// Start from a built-in film, then apply this film's adjustments on top.
    var baseSim: FilmSimulation? = nil
    /// Lens character (LensKind raw value).
    var lens: String? = nil
    /// Grain amount to switch to when this film is picked (nil = leave as is).
    var grainAmount: Float? = nil
    /// Aspect ratio to switch to when this film is picked (AspectRatio raw value).
    var aspect: String? = nil

    var lensKind: LensKind { lens.flatMap(LensKind.init(rawValue:)) ?? .none }
}

/// Lens character for saved cameras (applied after the film).
nonisolated enum LensKind: String, CaseIterable, Identifiable, Sendable {
    case none, swirl, glow, toy, anamorphic, pinhole
    case takumar, petzval, proMist, sonnar, dream, fisheye
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "Clean"
        case .swirl: "Swirly"
        case .glow: "Soft glow"
        case .toy: "Toy lens"
        case .anamorphic: "Anamorphic"
        case .pinhole: "Pinhole"
        case .takumar: "Takumar"
        case .petzval: "Petzval"
        case .proMist: "Pro-Mist"
        case .sonnar: "Sonnar pop"
        case .dream: "Dream lens"
        case .fisheye: "Fisheye"
        }
    }
    var detail: String {
        switch self {
        case .none: "Modern, sharp corner to corner"
        case .swirl: "Helios-44 style: edges swirl around the centre"
        case .glow: "Uncoated vintage glass: highlights bloom softly"
        case .toy: "Plastic lens: colour fringes, soft corners, dark edges"
        case .anamorphic: "Cinema lens: horizontal streaks, oval falloff"
        case .pinhole: "No lens at all: soft, deep vignette"
        case .takumar: "Super-Takumar 50/1.4: yellowed thorium glass, warm and gentle"
        case .petzval: "Petzval portrait lens: razor centre, wild swirl at the edges"
        case .proMist: "Black Pro-Mist ¼ filter: highlights bloom, cinematic haze"
        case .sonnar: "Zeiss Sonnar: micro-contrast 3D pop, smooth falloff"
        case .dream: "Canon 50mm f/0.95: glowing, low contrast, soft swirling corners"
        case .fisheye: "Zenitar 16mm fisheye: bulging barrel distortion, dark rim"
        }
    }
    var symbol: String {
        switch self {
        case .none: "camera.aperture"
        case .swirl: "tornado"
        case .glow: "sparkle"
        case .toy: "camera.fill"
        case .anamorphic: "rectangle.ratio.16.to.9"
        case .pinhole: "circle.dotted"
        case .takumar: "sun.max"
        case .petzval: "hurricane"
        case .proMist: "cloud.fog"
        case .sonnar: "cube"
        case .dream: "moon.stars"
        case .fisheye: "globe"
        }
    }
}

// MARK: - Custom Sim Store

@Observable final class CustomSimStore {
    var simulations: [CustomSimulation] = []
    var activeCustomSimID: UUID?

    private let key = "cam_cam_custom_sims"

    init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CustomSimulation].self, from: data) else { return }
        simulations = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(simulations) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func addNew() -> CustomSimulation {
        var sim = CustomSimulation()
        sim.name = "Custom \(simulations.count + 1)"
        simulations.append(sim)
        save()
        return sim
    }

    func update(_ sim: CustomSimulation) {
        if let idx = simulations.firstIndex(where: { $0.id == sim.id }) {
            simulations[idx] = sim
            save()
        }
    }

    func delete(_ sim: CustomSimulation) {
        simulations.removeAll { $0.id == sim.id }
        if activeCustomSimID == sim.id { activeCustomSimID = nil }
        save()
    }

    var activeSim: CustomSimulation? {
        guard let id = activeCustomSimID else { return nil }
        return simulations.first { $0.id == id }
    }
}

// MARK: - Film Simulation Enum

nonisolated enum FilmSimulation: String, CaseIterable, Identifiable, Sendable, Codable {
    case none

    // Leicas — modern bodies + B&W + vintage glass + cinematic
    case leica, leicaQ3, leicaMonochrom, leicaClassic, leicaEternal

    // Fujifilm — pro chromes first, then negatives, then consumer
    case fujiProvia, fujiAstia, fujiVelvia, fujiClassicChrome, fujiEterna
    case fujiPro400H, fujiSuperia, fujiColor200
    case fujiReala100, fuji160NS, fujiSensia

    // Kodak color negatives — pro to consumer
    case kodakPortra, kodakEktar, kodakGold, kodakUltramax, kodakColorplus
    case kodakPortra160, kodakProImage100, kodakAdvantix
    // Spectral (spektrafilm data, baked to LUTs) — Portra 800 and its pushes
    case kodakPortra800, kodakPortra800Push1, kodakPortra800Push2, kodakVerita200D
    case fujiXtra400, fujiC200

    // Cinema / Cinestill — daylight then tungsten
    case cinestill50D, cinestill400D, cinestill800T, kodakVision3
    case kodak2383, fujiEternaVivid
    case kodakVision3_50D, kodakVision3_200T, kodakVision3_250D

    // Slide film
    case kodachrome64, ektachrome100
    case fujiProvia400X, agfaRSX

    // Instant
    case polaroid600, polaroidSX70, polaroidSpectra, polaroidiType
    case fujiInstax

    // Black & white
    case fujiAcros, kodakTriX, kodakTmax400, ilfordHP5
    case ilfordDelta3200, ilfordDelta100, ilfordXP2
    case kodakDoubleX, kodakP3200

    // Stylized / effects looks
    case agfaVista, lomography, lomochromePurple
    case kodakAerochrome
    case lomochromeMetropolis, lomochromeTurquoise
    case nightShot, urbanJade, goldenHaze, digiCam

    // Experimental / darkroom / alternative process
    case crossProcess, bleachBypass, expiredFilm
    case cyanotype, daguerreotype, duotone
    case tintype, platinum, vanDyke, saltPrint
    case retroChrome, neonNoir, circuitBent, circuitBentHeavy

    // Styles (cam cam's take on Photographic Styles)
    case styleAmber, styleGold, styleRoseGold, styleNeutral, styleCoolRose, styleVibrant, styleNatural, styleLuminous, styleDramatic, styleQuiet, styleCozy, styleEthereal, styleMutedBW, styleStarkBW

    var id: String { rawValue }

    /// Bundled film LUT (Films/*.cube), baked from spektrafilm's spectral
    /// film + print models (CC BY-SA 4.0, Andrea Volpato). Nil for the rest.
    var bundledLUT: String? {
        switch self {
        case .kodakPortra800:      return "Portra800.cube"
        case .kodakPortra800Push1: return "Portra800Push1.cube"
        case .kodakPortra800Push2: return "Portra800Push2.cube"
        case .kodakVerita200D:     return "Verita200D.cube"
        case .fujiXtra400:         return "FujiXtra400.cube"
        case .fujiC200:            return "FujiC200.cube"
        case .kodakVision3_50D:    return "Vision3_50D.cube"
        case .kodakVision3_200T:   return "Vision3_200T.cube"
        case .kodakVision3_250D:   return "Vision3_250D.cube"
        // Measured replacements for hand-built looks
        case .kodakPortra:         return "Portra400.cube"
        case .kodakPortra160:      return "Portra160.cube"
        case .kodakEktar:          return "Ektar100.cube"
        case .kodakGold:           return "Gold200.cube"
        case .kodakUltramax:       return "Ultramax400.cube"
        case .fujiPro400H:         return "FujiPro400H.cube"
        case .kodakVision3:        return "Vision3_500T.cube"
        case .ektachrome100:       return "Ektachrome100.cube"
        case .kodachrome64:        return "Kodachrome64.cube"
        case .fujiVelvia:          return "Velvia100.cube"
        case .fujiProvia:          return "Provia100F.cube"
        default: return nil
        }
    }

    /// Stocks that only exist as measured LUTs (no hand-built fallback).
    var spectralOnly: Bool {
        switch self {
        case .kodakPortra800, .kodakPortra800Push1, .kodakPortra800Push2, .kodakVerita200D,
             .fujiXtra400, .fujiC200, .kodakVision3_50D, .kodakVision3_200T, .kodakVision3_250D: return true
        default: return false
        }
    }

    /// Non-nil for the Styles (rendered by StyleEngine, skin-aware).
    var styleKind: StyleKind? {
        switch self {
        case .styleAmber: return .amber
        case .styleGold: return .gold
        case .styleRoseGold: return .roseGold
        case .styleNeutral: return .neutral
        case .styleCoolRose: return .coolRose
        case .styleVibrant: return .vibrant
        case .styleNatural: return .natural
        case .styleLuminous: return .luminous
        case .styleDramatic: return .dramatic
        case .styleQuiet: return .quiet
        case .styleCozy: return .cozy
        case .styleEthereal: return .ethereal
        case .styleMutedBW: return .mutedBW
        case .styleStarkBW: return .starkBW
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .none:           return "None"
        case .kodakPortra800:      return "Portra 800"
        case .kodakPortra800Push1: return "Portra 800 +1"
        case .kodakPortra800Push2: return "Portra 800 +2"
        case .kodakVerita200D:     return "Verita 200D"
        case .fujiXtra400:         return "Xtra 400"
        case .fujiC200:            return "C200"
        case .kodakVision3_50D:    return "Vision3 50D"
        case .kodakVision3_200T:   return "Vision3 200T"
        case .kodakVision3_250D:   return "Vision3 250D"
        case .leica:          return "Leica M"
        case .fujiProvia:     return "Provia"
        case .fujiVelvia:     return "Velvia"
        case .fujiColor200:   return "Fuji 200"
        case .fujiPro400H:    return "Pro 400H"
        case .fujiSuperia:    return "Superia"
        case .kodakPortra:    return "Portra"
        case .kodakGold:      return "Gold"
        case .kodakUltramax:  return "Ultramax"
        case .kodakColorplus: return "ColorPlus"
        case .kodakEktar:     return "Ektar"
        case .cinestill800T:  return "800T"
        case .kodakVision3:   return "Vision3"
        case .cinestill50D:   return "50D"
        case .agfaVista:      return "Vista"
        case .ilfordHP5:      return "HP5"
        case .kodakTriX:      return "Tri-X"
        case .fujiAcros:      return "Acros"
        case .lomography:     return "Lomo"
        case .digiCam:        return "DigiCam"
        case .nightShot:      return "Night"
        case .urbanJade:      return "Urban Jade"
        case .kodachrome64:   return "Kodachrome"
        case .ektachrome100:  return "Ektachrome"
        case .polaroid600:    return "Polaroid"
        case .goldenHaze:     return "Golden Haze"
        case .fujiEterna:           return "Eterna"
        case .fujiClassicChrome:    return "Classic Chrome"
        case .fujiAstia:            return "Astia"
        case .fujiReala100:         return "Reala 100"
        case .fuji160NS:            return "160NS"
        case .fujiSensia:           return "Sensia"
        case .cinestill400D:        return "400D"
        case .kodakAerochrome:      return "Aerochrome"
        case .kodakPortra160:       return "Portra 160"
        case .kodakProImage100:     return "Pro Image"
        case .kodakAdvantix:        return "Advantix"
        case .kodak2383:            return "Kodak 2383"
        case .fujiEternaVivid:      return "Eterna Vivid"
        case .fujiProvia400X:       return "Provia 400X"
        case .agfaRSX:              return "Agfa RSX"
        case .fujiInstax:           return "Instax"
        case .ilfordDelta3200:      return "Delta 3200"
        case .ilfordDelta100:       return "Delta 100"
        case .ilfordXP2:            return "XP2 Super"
        case .kodakDoubleX:         return "Double-X"
        case .kodakP3200:           return "P3200"
        case .lomochromeMetropolis: return "Metropolis"
        case .lomochromeTurquoise:  return "Turquoise"
        case .polaroidSX70:         return "SX-70"
        case .polaroidSpectra:      return "Spectra"
        case .polaroidiType:        return "i-Type"
        case .lomochromePurple:     return "Lomo Purple"
        case .crossProcess:         return "X-Process"
        case .bleachBypass:         return "Silver Ret."
        case .expiredFilm:          return "Expired"
        case .cyanotype:            return "Cyanotype"
        case .daguerreotype:        return "Daguerreotype"
        case .duotone:              return "Duotone"
        case .tintype:              return "Tintype"
        case .platinum:             return "Platinum"
        case .vanDyke:              return "Van Dyke"
        case .saltPrint:            return "Salt Print"
        case .styleAmber: return "Amber"
        case .styleGold: return "Gold"
        case .styleRoseGold: return "Rose Gold"
        case .styleNeutral: return "Neutral"
        case .styleCoolRose: return "Cool Rose"
        case .styleVibrant: return "Vibrant"
        case .styleNatural: return "Natural"
        case .styleLuminous: return "Luminous"
        case .styleDramatic: return "Dramatic"
        case .styleQuiet: return "Quiet"
        case .styleCozy: return "Cozy"
        case .styleEthereal: return "Ethereal"
        case .styleMutedBW: return "Muted B&W"
        case .styleStarkBW: return "Stark B&W"
        case .retroChrome:          return "RetroChrm"
        case .neonNoir:             return "Neon Noir"
        case .circuitBent:          return "Bent"
        case .circuitBentHeavy:     return "Bent++"
        case .kodakTmax400:         return "T-Max 400"
        case .leicaMonochrom:       return "Leica Mono"
        case .leicaQ3:              return "Leica Q3"
        case .leicaClassic:         return "Leica Classic"
        case .leicaEternal:         return "Leica Eternal"
        }
    }
}

// MARK: - Focal Preset

nonisolated struct FocalPreset: Sendable {
    let mm: Int
    let deviceType: AVCaptureDevice.DeviceType
    let zoomFactor: CGFloat
    /// If true, route through the virtual triple camera so iOS handles
    /// lens switching (used for the 120mm tele where close-subject fallback matters).
    var useVirtualDevice: Bool = false
}

nonisolated let focalPresets: [FocalPreset] = [
    FocalPreset(mm: 13,  deviceType: .builtInUltraWideCamera, zoomFactor: 1.0),
    FocalPreset(mm: 28,  deviceType: .builtInWideAngleCamera, zoomFactor: 1.0),
    FocalPreset(mm: 35,  deviceType: .builtInWideAngleCamera, zoomFactor: 1.3),
    FocalPreset(mm: 50,  deviceType: .builtInWideAngleCamera, zoomFactor: 1.92),
    FocalPreset(mm: 70,  deviceType: .builtInWideAngleCamera, zoomFactor: 2.7),
    FocalPreset(mm: 120, deviceType: .builtInWideAngleCamera, zoomFactor: 4.615, useVirtualDevice: true),
]

// MARK: - Aspect Ratio

nonisolated enum AspectRatio: String, CaseIterable, Identifiable, Sendable {
    case full, square, widescreen, cinematic, portrait
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full:       return "4:3"
        case .square:     return "1:1"
        case .widescreen: return "16:9"
        case .cinematic:  return "2.39:1"
        case .portrait:   return "3:4"
        }
    }
    var ratio: CGFloat? {
        switch self {
        case .full:       return nil
        case .square:     return 1.0
        case .widescreen: return 16.0 / 9.0
        case .cinematic:  return 2.39
        case .portrait:   return 3.0 / 4.0
        }
    }
}

// MARK: - Long Exposure Mode

nonisolated enum LongExposureMode: String, CaseIterable, Identifiable, Sendable {
    case frameStack, nativeExposure
    var id: String { rawValue }
    var label: String {
        switch self {
        case .frameStack:     return "Frame Stack"
        case .nativeExposure: return "Native"
        }
    }
}
