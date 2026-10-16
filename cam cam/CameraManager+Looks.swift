//
//  CameraManager+Looks.swift
//  cam cam
//
//  The film-look pipeline: recipe-driven render core, live look (preview +
//  video), every film simulation, custom sims/LUTs, circuit-bent, DigiCam,
//  grain and the filter building blocks.
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

extension CameraManager {

    // MARK: Film Simulation Pipeline

    // MARK: - Live look (preview + video recording)

    /// The live-settings look for the viewfinder and recorded video — mirrors
    /// `renderLook` step order so what you see is what gets saved:
    /// sim → crosstalk/halation/rolloff/push → film grain (NOT for DigiCam/Bent,
    /// which own their noise) → DigiCam scanlines → Bent glitch.
    /// - grainTextures: true for the preview (cheap pre-baked grain textures);
    ///   false for video (procedural grain at recording resolution).
    nonisolated func applyLiveLook(_ input: CIImage, grainTextures: Bool, includeGrain: Bool = true) -> CIImage {
        let sim = cachedSim
        let custom = cachedActiveCustomSim
        let extent = input.extent
        var img: CIImage
        if let custom {
            img = applyCustomSim(to: input, sim: custom)
        } else {
            img = applyFilmSim(to: input, sim: sim, grainEnabled: cachedGrainEnabled,
                               grain: cachedGrainAmount, digiCamQuality: cachedDigiCamQuality)
            if let kind = sim.styleKind {
                img = StyleEngine.apply(img, kind: kind, tone: StyleSettings.cTone, color: StyleSettings.cColor,
                                        palette: StyleSettings.cPalette,
                                        mask: SkinMask.shared.live(for: img.extent))
            }
        }
        if !cachedThermalThrottle {
            let key = custom.map { "c-\(String(describing: $0).hashValue)" } ?? "s-\(sim.rawValue)"
            img = Self.scan(img, original: input, sim: custom == nil ? sim : nil, lookKey: key, measure: false) { [self] x in
                custom.map { applyCustomSim(to: x, sim: $0) }
                    ?? applyFilmSim(to: x, sim: sim, grainEnabled: false, grain: 0, digiCamQuality: cachedDigiCamQuality)
            }
        }
        // Under thermal pressure, keep the base look but drop the expensive
        // extras from the live path (captures are unaffected).
        if cachedDevelopment > 0 { img = applyDevelopment(img, strength: cachedDevelopment) }
        let throttled = cachedThermalThrottle
        if !throttled {
            if cachedCrosstalkEnabled { img = applyColorCrosstalk(input: img, amount: cachedCrosstalkAmount) }
            if cachedHalationEnabled  { img = applyHalation(input: img, amount: cachedHalationAmount) }
            if cachedRolloffEnabled   { img = applyHighlightRolloff(input: img, threshold: cachedRolloffThreshold) }
        }
        if cachedPushPullEnabled { img = applyPushPull(input: img, stops: cachedPushPullAmount) }

        let isDigiCam = custom == nil && sim == .digiCam
        let isBent = custom == nil && (sim == .circuitBent || sim == .circuitBentHeavy)
        let grainOn = cachedGrainEnabled && cachedGrainAmount > 0
        if grainOn && includeGrain && !isDigiCam && !isBent {
            img = Self.cleanSensorNoise(img, iso: cachedLiveISO)       // film grain replaces digital noise
            img = grainTextures ? applyPreviewGrain(img, extent: extent)
                                : addGrain(input: img, amount: cachedGrainAmount)
        }
        if isDigiCam && cachedContextAwareGrain && cachedDigiCamQuality >= 1 {
            img = applyScanlines(input: img)
        }
        if isBent && grainOn && !throttled {
            img = circuitBentGlitch(img, heavy: sim == .circuitBentHeavy,
                                    wild: cachedContextAwareGrain,
                                    intensity: min(1.0, CGFloat(cachedGrainAmount) / 0.5),
                                    flatten: false)
        }
        return img.cropped(to: extent)
    }

    /// Preview film grain: cycles 8 pre-baked textures (one softLight blend per frame).
    nonisolated private func applyPreviewGrain(_ input: CIImage, extent: CGRect) -> CIImage {
        var filtered = input
        // Grain preview — cycles through 8 pre-baked textures; cost = one softLight blend per frame.
        // Textures are built once on a background queue and reused until settings change.
        do {
            let previewExtent = extent
            // Trigger a (re)build if textures are missing or the frame size changed
            let gc = cachedActiveCustomSim == nil ? cachedSim.grainCharacter : .standard
            if grainPreviewTextures.isEmpty || grainPreviewExtent != previewExtent || grainPreviewSize != gc.size {
                buildGrainPreviewTextures(for: previewExtent)
            }
            if !grainPreviewTextures.isEmpty {
                let idx = grainPreviewFrameIdx % grainPreviewTextures.count
                grainPreviewFrameIdx &+= 1
                let grainTex = grainPreviewTextures[idx]
                // Layout: [fine ×4, coarse ×2, chroma ×2] — fine changes every
                // frame, the softer layers less often (like moving grain).
                let tex = grainPreviewTextures
                let fineTex = tex.count == 8 ? tex[grainPreviewFrameIdx % 4] : grainTex
                let coarseTex = tex.count == 8 ? tex[4 + (grainPreviewFrameIdx / 2) % 2] : grainTex
                let chromaTex = tex.count == 8 ? tex[6 + (grainPreviewFrameIdx / 3) % 2] : grainTex

                // Context-aware: re-sample scene luma every 30 frames (~1 s at 30 fps).
                // A 1×1 pixel render is near-zero GPU cost; throttling prevents any stall cadence.
                var grainAmt = cachedGrainAmount
                if cachedContextAwareGrain {
                    // Frame brightness from Smart AE's metering (measured on its own
                    // queue). Reading a pixel back here every second waited for
                    // the GPU and stalled the preview while a photo rendered.
                    if let l = cachedFrameLuma { grainPreviewLuma = l }
                    grainAmt = min(0.5, grainAmt * Self.contextGrainScale(iso: cachedLiveISO, luma: grainPreviewLuma))
                }

                let a = Double(max(0, min(0.35, grainAmt)))
                if let g = physicalGrain(filtered, amount: CGFloat(a), fine: fineTex, coarse: coarseTex, chroma: chromaTex,
                                         character: gc) {
                    return g.cropped(to: previewExtent)
                }
                let blend = CIFilter.softLightBlendMode()
                blend.inputImage = grainTex
                blend.backgroundImage = filtered
                if let blended = blend.outputImage?.cropped(to: previewExtent) {
                    let strength = max(0.0, 1.0 - a * 1.5)
                    if let mixed = CIFilter(name: "CIDissolveTransition", parameters: [
                        kCIInputImageKey: blended,
                        kCIInputTargetImageKey: filtered,
                        "inputTime": NSNumber(value: strength)
                    ])?.outputImage?.cropped(to: previewExtent) {
                        filtered = mixed
                    }
                }
            }
        }
        return filtered
    }

    // MARK: - Render core (recipe-driven)

    /// Build the recipe from the settings snapshotted at shutter time.
    nonisolated func pendingRecipe() -> ShotRecipe {
        var r = ShotRecipe()
        r.sim = pendingSim
        r.custom = pendingCustomSim
        r.grainEnabled = pendingGrainEnabled;   r.grain = pendingGrain
        r.contextAwareGrain = pendingContextAwareGrain
        r.digiCamQuality = cachedDigiCamQuality
        r.crosstalkEnabled = pendingCrosstalkEnabled; r.crosstalk = pendingCrosstalk
        r.halationEnabled = pendingHalationEnabled;   r.halation = pendingHalation
        r.rolloffEnabled = pendingRolloffEnabled;     r.rolloff = pendingRolloff
        r.pushPullEnabled = pendingPushPullEnabled;   r.pushPull = pendingPushPullAmount
        r.development = pendingDevelopment
        r.sceneISO = pendingSceneISO
        r.anamorphicFlare = pendingAnamorphicFlareEnabled
        r.lightArtifacts = pendingLightArtifactsEnabled
        r.filmScratches = pendingFilmScratchesEnabled
        r.randomization = pendingRandomizationEnabled
        r.randomSeed = pendingRandomSeed
        r.styleTone = StyleSettings.cTone; r.styleColor = StyleSettings.cColor; r.stylePalette = StyleSettings.cPalette
        return r
    }

    /// Build a recipe from the LIVE settings (thread-safe cached mirrors), for
    /// the Sony live view / Sony captures. `sim`/`custom` are passed in because
    /// Sony mode tracks its own selection.
    nonisolated func liveRecipe(sim: FilmSimulation, custom: CustomSimulation?,
                                seed: UInt64 = 0) -> ShotRecipe {
        var r = ShotRecipe()
        r.sim = sim
        r.custom = custom
        r.grainEnabled = cachedGrainEnabled;      r.grain = cachedGrainAmount
        r.contextAwareGrain = cachedContextAwareGrain
        r.digiCamQuality = cachedDigiCamQuality
        r.crosstalkEnabled = cachedCrosstalkEnabled; r.crosstalk = cachedCrosstalkAmount
        r.halationEnabled = cachedHalationEnabled;   r.halation = cachedHalationAmount
        r.rolloffEnabled = cachedRolloffEnabled;     r.rolloff = cachedRolloffThreshold
        r.pushPullEnabled = cachedPushPullEnabled;   r.pushPull = cachedPushPullAmount
        r.development = cachedDevelopment
        r.anamorphicFlare = cachedAnamorphicFlare
        r.lightArtifacts = cachedLightArtifacts
        r.filmScratches = cachedFilmScratches
        r.randomization = cachedFilmRandomization
        r.randomSeed = seed
        r.styleTone = StyleSettings.cTone; r.styleColor = StyleSettings.cColor; r.stylePalette = StyleSettings.cPalette
        return r
    }

    /// Capture-path entry (iPhone): shutter-time recipe, plus the capture-only
    /// extras that can't be re-rendered later (live depth blur, double exposure).
    nonisolated func applySimAndGrain(to input: CIImage) -> CIImage {
        var image = renderLook(input, recipe: pendingRecipe(),
                               portraitFStop: pendingPortraitEnabled ? pendingPortraitFStop : nil)

        // Double exposure compositing
        if let first = firstExposureCIImage {
            image = compositeDoubleExposure(base: first, overlay: image, opacity: Float(pendingDoubleExposureOpacity), mask: pendingMask)
            firstExposureCIImage = nil
            // Clear the mask + preview so the next double-exposure starts fresh.
            // (UI mask binding is cleared on main thread.)
            pendingMask = nil
            DispatchQueue.main.async {
                self.firstExposurePreview = nil
                self.doubleExposureMask = nil
            }
        }
        return image
    }

    /// The film-look pipeline as a PURE function of (image, recipe): reads no
    /// shared mutable state, so it's safe from any thread and gives the same
    /// result every time for the same recipe (that's what makes re-grading and
    /// LUT export possible).
    /// - portraitFStop: live depth blur (capture-time only; nil to skip).
    /// - flatten: bake the base look to pixels before the glitch pass (full-res
    ///   saves); live previews pass false.
    nonisolated func renderLook(_ input: CIImage, recipe r: ShotRecipe,
                                portraitFStop: Float? = nil,
                                flatten: Bool = true) -> CIImage {
        var image: CIImage
        if let custom = r.custom {
            image = applyCustomSim(to: input, sim: custom)
        } else {
            image = applyFilmSim(to: input, sim: r.sim, grainEnabled: r.grainEnabled,
                                 grain: r.grain, digiCamQuality: r.digiCamQuality)
            if let kind = r.sim.styleKind {
                // Stills get an accurate person mask of their own.
                image = StyleEngine.apply(image, kind: kind, tone: r.styleTone, color: r.styleColor,
                                          palette: r.stylePalette,
                                          mask: flatten ? SkinMask.accurate(input) : SkinMask.fast(input))
            }
        }
        // Developed as a cross-process: slide chemistry on top of the film.
        if r.crossProcessed {
            image = applyFilmSim(to: image, sim: .crossProcess, grainEnabled: false, grain: 0,
                                 digiCamQuality: r.digiCamQuality)
        }
        image = Self.scan(image, original: input, sim: r.custom == nil ? r.sim : nil,
                          lookKey: Self.lookKey(r), measure: !(portraitFStop != nil && !flatten)) { [self] x in
            r.custom.map { applyCustomSim(to: x, sim: $0) }
                ?? applyFilmSim(to: x, sim: r.sim, grainEnabled: false, grain: 0, digiCamQuality: r.digiCamQuality)
        }

        // Live portrait depth blur — applied BEFORE film sim effects so bokeh looks natural
        if let fStop = portraitFStop {
            image = applyLivePortraitBlur(to: image, fStop: fStop)
        }

        if r.development > 0 { image = applyDevelopment(image, strength: r.development) }
        if r.crosstalkEnabled { image = applyColorCrosstalk(input: image, amount: r.crosstalk) }
        if r.halationEnabled  { image = applyHalation(input: image, amount: r.halation) }
        if r.rolloffEnabled   { image = applyHighlightRolloff(input: image, threshold: r.rolloff) }
        if r.pushPullEnabled  { image = applyPushPull(input: image, stops: r.pushPull) }

        // DigiCam and circuit-bent sims handle their own noise/glitches
        // (DigiCam noise is baked into its sim case scaled by the grain slider;
        // circuit-bent uses the glitch pass), so film grain skips them.
        let isDigiCam = r.custom == nil && r.sim == .digiCam
        let isCircuitBentSim = r.custom == nil && (r.sim == .circuitBent || r.sim == .circuitBentHeavy)
        if r.grainEnabled && r.grain > 0 && !isCircuitBentSim && !isDigiCam {
            let pushExtra: Float = r.pushPullEnabled ? max(0, r.pushPull * 0.08) : 0
            var grainAmt = r.grain + pushExtra

            // Context-aware grain: more grain the less light there was (ISO).
            if r.contextAwareGrain {
                var luma: Float?
                // Frame brightness from a small copy (full-res would render the look twice).
                let s = 256 / max(input.extent.width, input.extent.height, 1)
                let probe = input.transformed(by: CGAffineTransform(scaleX: s, y: s))
                let avgFilter = CIFilter.areaAverage()
                avgFilter.inputImage = probe
                avgFilter.extent = probe.extent
                if let avgImg = avgFilter.outputImage {
                    var bitmap = [UInt8](repeating: 0, count: 4)
                    photoContext.render(avgImg, toBitmap: &bitmap, rowBytes: 4,
                                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                    luma = (Float(bitmap[0]) * 0.299 + Float(bitmap[1]) * 0.587 + Float(bitmap[2]) * 0.114) / 255.0
                }
                grainAmt = min(0.5, grainAmt * Self.contextGrainScale(iso: r.sceneISO, luma: luma))
            }
            image = Self.cleanSensorNoise(image, iso: r.sceneISO)     // film grain replaces digital noise
            image = addGrain(input: image, amount: grainAmt,
                             character: r.custom == nil ? r.sim.grainCharacter : .standard)
        } else if r.pushPullEnabled && r.pushPull > 0 && !isDigiCam {
            // Even with grain off, push adds a small amount of grain
            image = addGrain(input: image, amount: r.pushPull * 0.06)
        }

        // DigiCam scanlines — the context-aware button doubles as "lines".
        if isDigiCam && r.contextAwareGrain && r.digiCamQuality >= 1 {
            image = applyScanlines(input: image)
        }

        // Circuit-bent glitches — the grain slider is the "weirdness" dial;
        // context-aware = wild per-frame colour/light drift.
        if isCircuitBentSim && r.grainEnabled && r.grain > 0 {
            image = circuitBentGlitch(image,
                                      heavy: r.sim == .circuitBentHeavy,
                                      wild: r.contextAwareGrain,
                                      intensity: CGFloat(min(1.0, r.grain / 0.5)),
                                      flatten: flatten)
        }

        if r.anamorphicFlare { image = applyAnamorphicFlare(input: image) }

        // Derive per-shot random booleans from seed for the Randomize toggle
        // Using distinct bit-mixed offsets so leak/scratch decisions are independent.
        let randLeakChance  = Double(r.randomSeed &* 0x517CC1B727220A95 >> 33) / Double(1 << 31)
        let randScratchChance = Double(r.randomSeed &* 0xBF58476D1CE4E5B9 >> 33) / Double(1 << 31)

        if r.lightArtifacts || (r.randomization && randLeakChance < 0.40) {
            image = applyLightArtifacts(input: image, seed: r.randomSeed)
        }
        if r.filmScratches || (r.randomization && randScratchChance < 0.40) {
            image = applyFilmScratches(input: image, seed: r.randomSeed &+ 0x1234567890ABCDEF)
        }
        if r.randomization {
            image = applyFilmRandomization(input: image, seed: r.randomSeed)
        }
        return image
    }

    // MARK: - Scan (shadow floor, white point, detail) after every look

    nonisolated static func lookKey(_ r: ShotRecipe) -> String {
        r.custom.map { "c-\(String(describing: $0).hashValue)" } ?? "s-\(r.sim.rawValue)"
    }

    /// Per-film scan settings: (shadow floor, white-point lift allowed, detail).
    nonisolated static func scanProfile(_ sim: FilmSimulation?) -> (floor: Float, white: Bool, detail: Float)? {
        guard let sim else { return (0.35, true, 0.45) }          // custom sims / imported LUTs
        switch sim {
        case .none, .circuitBent, .circuitBentHeavy: return nil
        case .polaroid600, .polaroidSpectra, .polaroidSX70, .fujiInstax, .goldenHaze, .expiredFilm,
             .saltPrint, .platinum, .vanDyke, .cyanotype, .digiCam:
            return (0.35, true, 0)                                  // soft by design
        case .tintype, .daguerreotype:  return (0.25, false, 0)
        case .kodakAerochrome:          return (0.25, false, 0.4)
        case .neonNoir, .styleStarkBW, .styleDramatic, .bleachBypass, .nightShot:
            return (0.15, true, 0.5)                                 // contrast is the point
        default: return (0.35, true, 0.45)
        }
    }

    nonisolated(unsafe) private static var lookWhites: [String: Float] = [:]
    nonisolated(unsafe) private static var lookWhitesPending: Set<String> = []
    nonisolated private static let lookWhitesLock = NSLock()
    nonisolated private static let scanQueue = DispatchQueue(label: "cam.scan.measure", qos: .utility)
    nonisolated private static let scanContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, .cacheIntermediates: false])

    /// Linear luminance the look prints a near-white (0.96) at.
    nonisolated private static func measureWhite(_ look: (CIImage) -> CIImage) -> Float {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let patch = CIImage(color: CIColor(red: 0.96, green: 0.96, blue: 0.96, colorSpace: p3)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        var px = [Float](repeating: 0, count: 4)
        scanContext.render(look(patch), toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 16, y: 16, width: 1, height: 1),
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let y = 0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]
        return y.isFinite ? y : 1
    }

    /// - measure: true on the photo path (measures the look's white now if
    ///   unknown); the live path measures in the background and skips the
    ///   white lift until it's known.
    nonisolated static func scan(_ image: CIImage, original: CIImage, sim: FilmSimulation?, lookKey: String,
                                 measure: Bool, look: @escaping (CIImage) -> CIImage) -> CIImage {
        guard scanEnabled, let prof = scanProfile(sim), let k = filmKernel("scanGuard") else { return image }
        var white: Float = 1
        if prof.white {
            lookWhitesLock.lock()
            let known = lookWhites[lookKey]
            let pending = lookWhitesPending.contains(lookKey)
            if known == nil && !pending && !measure { lookWhitesPending.insert(lookKey) }
            lookWhitesLock.unlock()
            if let known { white = known }
            else if measure {
                white = measureWhite(look)
                lookWhitesLock.lock(); lookWhites[lookKey] = white; lookWhitesLock.unlock()
            } else if !pending {
                scanQueue.async {
                    let w = measureWhite(look)
                    lookWhitesLock.lock(); lookWhites[lookKey] = w; lookWhitesPending.remove(lookKey); lookWhitesLock.unlock()
                }
            }
        }
        // Lift to where 0.96 would sit untouched (0.91 linear), at most +0.5 EV.
        let gain = prof.white ? max(1, min(1.41, 0.91 / max(white, 0.05))) : 1
        let e = image.extent
        let radius = max(1.0, Double(max(e.width, e.height)) / 3000)
        func blur(_ x: CIImage) -> CIImage {
            x.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: e)
        }
        let detail = prof.detail
        let lb = detail > 0 ? blur(image) : image, ob = detail > 0 ? blur(original) : original
        return k.apply(extent: e, arguments: [image, original, lb, ob, prof.floor, gain, min(white, 1), detail]) ?? image
    }
    /// Off = looks exactly as before (for A/B in the audit).
    nonisolated(unsafe) static var scanEnabled = true

    /// Capture-path entry: renders with the settings snapshotted at shutter time.
    nonisolated func applyFilmSim(to image: CIImage) -> CIImage {
        applyFilmSim(to: image, sim: pendingSim,
                     grainEnabled: pendingGrainEnabled, grain: pendingGrain,
                     digiCamQuality: cachedDigiCamQuality)
    }

    /// Core film-sim renderer. Sim + grain settings are passed EXPLICITLY so the
    /// live preview can use its live (cached) values without mutating the shared
    /// capture-time `pending*` state. Previously the preview swapped `pendingSim`
    /// per frame (racing with in-flight captures on processQueue) and read
    /// `pendingGrain*` — i.e. the grain settings of the LAST PHOTO, so DigiCam
    /// noise and Bent speckle in the viewfinder ignored the current slider.
    nonisolated func applyFilmSim(to image: CIImage, sim: FilmSimulation,
                                  grainEnabled: Bool, grain: Float,
                                  digiCamQuality: Float) -> CIImage {
        // Bent speckle amount: 0 with grain off, ramps to 1 at the slider top.
        let speckle: CGFloat = grainEnabled ? min(1.0, CGFloat(grain) / 0.5) : 0
        // Stocks on the film engine (modelled in exposure, see FilmEngine).
        if let film = FilmEngine.apply(image, sim: sim) { return film }
        // Measured (spektrafilm) stocks; the audit turns `FilmEngine.enabled`
        // off to compare against the old hand-built looks.
        if let lut = sim.bundledLUT, FilmEngine.enabled || sim.spectralOnly {
            return LUTManager.shared.apply(filename: lut, to: image)
        }
        switch sim {
        case .none:
            return image
        case .kodakPortra800, .kodakPortra800Push1, .kodakPortra800Push2, .kodakVerita200D,
             .fujiXtra400, .fujiC200, .kodakVision3_50D, .kodakVision3_200T, .kodakVision3_250D:
            return image   // bundled LUT applied above; missing file = untouched

        case .leica:
            // Leica M: microcontrast 3D pop, cool-neutral cast, shadow-cool/highlight-warm split,
            // compressed highlights with deep luminous shadows — rangefinder character
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.90
            cc.contrast = 1.05
            cc.brightness = 0.0
            // Neutral-cool — Leica glass doesn't warm like a smartphone
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6300, y: 0)
            // Shadow-cool / highlight-warm split: pull blue slightly, suppress globally
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.96, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            // Leica tone curve: deep shadows, smooth midtone lift, compressed highlights
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: -0.01, mid: 0.02, highlights: -0.06)
            // Clarity pass for the microcontrast/3D pop Leica glass is known for
            return claritySharpen(input: curved)

        case .fujiProvia:
            // Provia/Standard: Fuji's most neutral stock — accurate color, no exaggeration.
            // It's the reference point; Velvia is "Provia but pushed hard". Should feel clinical.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.0   // neutral — Provia does NOT boost saturation
            cc.contrast = 1.04
            cc.brightness = 0.0
            // Barely neutral-cool: Provia is slightly cooler than daylight, not warm
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6700, y: 0)
            return toneCurve(input: temp.outputImage ?? image, shadows: 0.01, mid: 0.0, highlights: -0.02)

        case .fujiVelvia:
            // Velvia: ultra-vivid saturation, deep contrast, cool cast, electric greens & blues
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.65    // Velvia's signature extreme pop
            cc.contrast = 1.25     // punchy contrast
            cc.brightness = -0.01
            // Slightly cool — Velvia pops blues and greens, not warm
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 6900, y: 0)  // pull toward cool
            // Strong green channel push: foliage pops electric; slight blue lift for sky
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cool.outputImage
            matrix.rVector = CIVector(x: 1.0,  y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.12, z: 0.0,  w: 0)   // electric foliage
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.06, w: 0)   // sky pop
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.0, mid: -0.01, highlights: -0.04)
            return claritySharpen(input: curved)

        case .fujiColor200:
            // Fuji C200: affordable daylight film, distinctly cool-green vs Provia's neutral.
            // Lower contrast than Provia, noticeable green shift in daylight — cheap but characterful.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.04
            cc.contrast = 1.0
            cc.brightness = 0.01
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 7100, y: -6)  // cool + green tint
            // Green channel push to separate from Provia
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cool.outputImage
            matrix.rVector = CIVector(x: 1.0,  y: 0.0,  z: 0.0, w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.05, z: 0.0, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.96, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.03, mid: 0.0, highlights: -0.02)

        case .fujiPro400H:
            // Pro 400H: pastel tones, low contrast, slight green in shadows
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.85
            cc.contrast = 0.95
            cc.brightness = 0.02
            let tint = CIFilter.temperatureAndTint()
            tint.inputImage = cc.outputImage
            tint.neutral = CIVector(x: 6500, y: 0)
            tint.targetNeutral = CIVector(x: 6800, y: -10)
            return toneCurve(input: tint.outputImage ?? image, shadows: 0.05, mid: 0.01, highlights: -0.03)

        case .kodakPortra:
            // Portra 400: wide exposure latitude, natural skin rendering, subdued saturation.
            // The magic is in the orange-red midtone push that makes skin glow — not a blanket warm shift.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.90  // Portra is never punchy — colors stay natural
            cc.contrast = 1.02    // gentle — latitude is the point, not contrast
            cc.brightness = 0.01
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5700, y: 8)  // warm + slight magenta = skin rendering
            // Skin-tone matrix: red-orange push in midtones, suppress blue (removes digital coolness)
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.07, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.02, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.88, w: 0)  // pull blue hard
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.005, z: 0.0, w: 0)  // lifted warm blacks
            // Smooth highlight rolloff: Portra's latitude = no blowout
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.03, mid: 0.01, highlights: -0.05)

        case .kodakGold:
            // Kodak Gold 200: warm, saturated, yellow-shifted
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.2
            cc.contrast = 1.08
            cc.brightness = 0.02
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5500, y: 10)
            return toneCurve(input: warm.outputImage ?? image, shadows: 0.03, mid: 0.01, highlights: -0.01)

        case .kodakUltramax:
            // Ultramax 400: warm highlights, distinctly blue (not green) shadows, punchy
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.25
            cc.contrast = 1.1
            cc.brightness = 0.0
            // Warm shift — highlights lean golden/amber
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5900, y: 0)   // warm highlights
            // Blue push into shadows via bias — the signature Ultramax shadow color
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.0,  y: 0.0, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0, z: 1.06, w: 0)   // blue lift
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.0, y: 0.0, z: 0.03, w: 0)  // blue in the blacks
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.03, mid: 0.0, highlights: -0.03)

        case .kodakColorplus:
            // ColorPlus 200: budget consumer film — flat, slightly warm, nothing special.
            // Deliberately less punchy than Gold: lower contrast, muted sat, slight highlight lift
            // from cheap optics/processing. Should feel like a cheap disposable camera.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.0   // flat — budget film, no pop
            cc.contrast = 0.97    // slightly below neutral
            cc.brightness = 0.01
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5950, y: 3)  // subtle warm, nothing like Gold
            // Slight highlight lift from cheap film stock — whites feel slightly blown
            return toneCurve(input: warm.outputImage ?? image, shadows: 0.03, mid: 0.01, highlights: 0.02)

        case .kodakEktar:
            // Ektar 100: extreme reds, very fine grain, highly saturated, daylight balanced
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.5    // extremely saturated
            cc.contrast = 1.15
            cc.brightness = -0.01
            // Daylight balanced — neutral to slightly cool, not warm
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6400, y: 0)  // basically neutral
            // RED BOOST: Ektar's defining trait — reds are almost aggressive
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.2,  y: 0.0,  z: 0.0,  w: 0)   // extreme red push
            matrix.gVector = CIVector(x: 0.0,  y: 1.04, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.93, w: 0)   // slightly suppress blue
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let sharpened = claritySharpen(input: matrix.outputImage ?? image)
            return toneCurve(input: sharpened, shadows: 0.01, mid: 0.0, highlights: -0.04)

        case .digiCam:
            // DigiCam: early 2000s digital look — crushed shadows, slightly magenta white
            // balance, baked-in CCD noise, and a touch of edge softness (NOT haze).
            // Sharpened via clarity to keep crisp pixel-level detail like an old CCD sensor.
            //
            // Quality slider 0..20 maps to:
            //   q=0  → OFF: pass image through untouched. Lets the user keep
            //          DigiCam "selected" in the strip but bypass it on the fly.
            //   q=5  → heavy noise (~0.32), 6 posterize levels, crushed shadows (cheapest disposable)
            //   q=12 → moderate noise (~0.16), 18 posterize levels (early-2000s point-and-shoot, default)
            //   q=20 → minimal noise (~0.04), 32 posterize levels (mid-2000s prosumer compact)
            if digiCamQuality < 1 { return image }
            let q = max(5, min(20, digiCamQuality))
            let qNorm = (q - 5) / 15.0                                // 0 = worst, 1 = best
            let noiseAmt: Float    = 0.32 - 0.28 * qNorm              // 0.32 → 0.04
            // 6 → 32 levels: the default (q=12, 18 levels) shows a little
            // banding in skies like a real 8-bit JPEG compact; at 10 levels it
            // painted rainbow rings across every smooth gradient.
            let posterLevels: Int  = Int(6 + round(26 * Double(qNorm))) // 6 → 32
            let shadowCrush: Float = 0.06 + 0.04 * (1 - qNorm)        // crush more on low quality

            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.82
            cc.contrast = 1.22
            cc.brightness = 0.0
            let tint = CIFilter.temperatureAndTint()
            tint.inputImage = cc.outputImage
            tint.neutral = CIVector(x: 6500, y: 0)
            tint.targetNeutral = CIVector(x: 7000, y: 12)
            var staged: CIImage = tint.outputImage ?? image
            // Quality-driven posterize — fewer levels = more visible color banding,
            // mimicking older sensors' lower bit depth.
            if let poster = CIFilter(name: "CIColorPosterize") {
                poster.setValue(staged, forKey: kCIInputImageKey)
                poster.setValue(posterLevels, forKey: "inputLevels")
                staged = poster.outputImage ?? staged
            }
            let crushed = toneCurve(input: staged, shadows: shadowCrush, mid: 0.0, highlights: -0.05)
            // Tiny edge softness — old digital sensor lowpass, NOT a hazy blur
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = crushed
            blur.radius = 0.6
            let blurred = blur.outputImage?.cropped(to: image.extent) ?? crushed
            // Re-add micro-contrast so the result still feels crisp, not soft
            let crisped = claritySharpen(input: blurred)
            // CCD noise — quality sets the *character* (noiseAmt), the grain
            // slider acts as the master amount. At grain-min (or grain off)
            // the DigiCam look is clean: posterize + crush + tint, zero CCD
            // speckle. As the grain slider climbs, the quality-shaped noise
            // fades in. This is the SOLE source of DigiCam noise — the grain
            // block below skips DigiCam so it's never applied twice.
            if grainEnabled && grain > 0 {
                let mult = min(1.0, grain / 0.5)   // grain 0…0.5 → 0…1
                return addDigitalNoise(input: crisped, amount: noiseAmt * mult)
            }
            return crisped

        case .nightShot:
            // Night shot: warm point-and-shoot flash look — punchy contrast, warm skin,
            // deep dark background. Think candid party / street flash photography.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.12
            cc.contrast = 1.28
            cc.brightness = -0.03
            // Warm the image to match flash color temp (~5400K)
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5400, y: 7)   // warm amber + tiny magenta
            // Slight shadow crush to separate flash-lit subject from dark ambient background
            return toneCurve(input: warm.outputImage ?? image, shadows: -0.06, mid: 0.01, highlights: 0.04)

        case .urbanJade:
            // Urban Jade: lush saturated greens, warm golden sunlight, teal shadows,
            // punchy reds, rich contrast — subtropical city courtyard look
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.25        // rich color without oversaturating
            cc.contrast = 1.15          // good punch
            cc.brightness = 0.01

            // Slight warm shift — golden sunlight tone
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5800, y: 8)  // warm with slight green tint

            // Color matrix: boost greens, push teal into shadows, keep reds vivid
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.05, y: 0.0,  z: 0.0,  w: 0)  // reds stay punchy
            matrix.gVector = CIVector(x: 0.0,  y: 1.12, z: 0.03, w: 0)  // boost green, teal hint
            matrix.bVector = CIVector(x: 0.0,  y: 0.06, z: 0.92, w: 0)  // blue pulled toward teal
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.0, y: 0.008, z: 0.012, w: 0) // teal shadow bias

            // Tone curve: deep shadows, lifted midtones, smooth highlight rolloff
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.02, mid: 0.03, highlights: -0.04)

            // Subtle vignette to frame the scene
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.4
            vignette.radius = 1.5
            return vignette.outputImage ?? curved

        case .fujiSuperia:
            // Superia 400: ~5900K with green bias — not as warm as before, green-leaning daylight
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.95
            cc.contrast = 1.08
            cc.brightness = 0.01
            // 5900K + green tint: slightly warm but distinctly green-biased
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5900, y: -8)  // mild warm + green
            // Boost green channel, light amber in shadows, pull down blue slightly
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.01, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.06, z: 0.0,  w: 0)  // green push
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.93, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.008, y: 0.006, z: 0.0, w: 0)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.05, mid: 0.01, highlights: -0.02)
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.5
            vignette.radius = 1.3
            return vignette.outputImage ?? curved

        case .cinestill800T:
            // CineStill 800T: strong teal-orange split, orange-red halation around lights (not global warm)
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.2
            cc.contrast = 1.25
            cc.brightness = -0.02
            // Tungsten-balanced stock: cool in daylight, teal-lifted shadows.
            // (The old matrix lifted red AND blue over green — magenta — and
            // bloomed the whole frame back over itself, washing it pink.)
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 7300, y: -4)
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cool.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.02, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.03, z: 1.03, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.0, y: 0.012, z: 0.022, w: 0)   // teal blacks
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.04, mid: -0.01, highlights: -0.05)
            // The signature red halo: CineStill has no anti-halation layer, so
            // only the highlights spill red — physical halation, not a bloom.
            return applyHalation(input: curved, amount: 0.45).cropped(to: image.extent)

        case .kodakVision3:
            // Vision3 500T: cinema negative tungsten stock — shot in daylight it reads cool-teal.
            // Defining traits: flat/wide latitude, teal-orange grade, NO vignette (cinema, not still film).
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.04
            cc.contrast = 0.88    // intentionally flat — cinema negative latitude
            cc.brightness = 0.02  // lifted slightly, negative stock has no true black
            // Tungsten stock in daylight = blue-cool cast
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 7000, y: 0)
            // Teal-orange split: the classic cinema grade
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cool.outputImage
            // Teal, not purple: green must stay level with blue (cutting green
            // while lifting red and blue made the whole frame lavender).
            matrix.rVector = CIVector(x: 1.0,  y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.03, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.04, z: 1.05, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.0, y: 0.008, z: 0.02, w: 0)  // teal lifted blacks
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.05, mid: -0.01, highlights: -0.04)

        case .agfaVista:
            // Agfa Vista 200: warm-punchy consumer film, known for rich reds/yellows and high saturation.
            // NOT sunset-orange — the previous 4800K was too extreme. Vista reads warm-amber, ~5200-5300K.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.28
            cc.contrast = 1.16
            cc.brightness = 0.01
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5250, y: 10)  // warm-amber, not extreme orange
            // Boost reds, suppress blue — Vista's saturated warm rendering
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.08, y: 0.02, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.02, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.84, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.04, mid: 0.02, highlights: -0.04)
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.5
            vignette.radius = 1.0
            return vignette.outputImage ?? curved

        case .ilfordHP5:
            // Ilford HP5: high contrast B&W, deep crushed blacks, bright silver highlights
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = image
            let cc = CIFilter.colorControls()
            cc.inputImage = mono.outputImage
            cc.contrast = 1.3
            cc.brightness = -0.01
            let curved = toneCurve(input: cc.outputImage ?? image, shadows: 0.02, mid: -0.02, highlights: -0.06)
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.8
            vignette.radius = 1.3
            return vignette.outputImage ?? curved

        case .lomography:
            // Lomography: heavy cross-process, oversaturated, strong green/yellow shift, dark vignette
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.6
            cc.contrast = 1.3
            cc.brightness = 0.0
            // Strong cross-process: greens go electric, blues turn teal, reds go amber
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.15, y: 0.08, z: 0.0, w: 0)
            matrix.gVector = CIVector(x: 0.0, y: 1.2, z: 0.05, w: 0)
            matrix.bVector = CIVector(x: 0.0, y: 0.05, z: 0.75, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.02, y: 0.01, z: -0.02, w: 0)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.06, mid: 0.0, highlights: -0.08)
            // Heavy dark vignette
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 1.8
            vignette.radius = 1.8
            return vignette.outputImage ?? curved

        case .cinestill50D:
            // CineStill 50D: daylight cinema stock — clean, crisp, neutral-cool, low ISO character.
            // Teal-green shadows are the cinema stock signature; more readable than the previous imperceptible biases.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.06
            cc.contrast = 1.06
            cc.brightness = 0.01
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 6900, y: 0)
            // Teal-green in shadows — cinema stock signature, bumped to actually show
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cool.outputImage
            matrix.rVector = CIVector(x: 0.98, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.05, z: 0.03, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.04, z: 1.10, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.0, y: 0.006, z: 0.018, w: 0)  // visible teal in blacks
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.02, mid: 0.0, highlights: -0.03)

        case .kodakTriX:
            // Kodak Tri-X 400: the definitive photojournalism B&W — gritty, high contrast, chunky grain
            // Mono, not Noir: Noir is already a hard curve, and +35% on top of
            // it crushed half the frame to black. Tri-X is punchy but holds shadows.
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = image
            let cc = CIFilter.colorControls()
            cc.inputImage = mono.outputImage
            cc.contrast = 1.25   // punchy, street-photography contrast
            cc.brightness = -0.02
            cc.saturation = 0.0
            // Slightly warm/sepia tone (Tri-X has a warm silver tone)
            let toned = CIFilter.colorMatrix()
            toned.inputImage = cc.outputImage
            toned.rVector = CIVector(x: 1.0,  y: 0.0, z: 0.0, w: 0)
            toned.gVector = CIVector(x: 0.0,  y: 0.96, z: 0.0, w: 0)
            toned.bVector = CIVector(x: 0.0,  y: 0.0, z: 0.90, w: 0)
            toned.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: toned.outputImage ?? image, shadows: 0.0, mid: -0.02, highlights: -0.05)
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.5
            vignette.radius = 1.4
            return vignette.outputImage ?? curved

        case .fujiAcros:
            // Fuji Acros 100: ultra-fine grain B&W, smooth gradations, deep blacks, luminous highlights
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = image
            let cc = CIFilter.colorControls()
            cc.inputImage = mono.outputImage
            cc.contrast = 1.15   // refined contrast — not as crushed as Tri-X
            cc.brightness = 0.0
            cc.saturation = 0.0
            // Acros has a distinctly cooler/bluer tone than HP5 or Tri-X
            let cooled = CIFilter.colorMatrix()
            cooled.inputImage = cc.outputImage
            cooled.rVector = CIVector(x: 0.96, y: 0.0,  z: 0.0,  w: 0)
            cooled.gVector = CIVector(x: 0.0,  y: 0.97, z: 0.0,  w: 0)
            cooled.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.0,  w: 0)
            cooled.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: cooled.outputImage ?? image, shadows: 0.02, mid: 0.0, highlights: -0.03)
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.5
            vignette.radius = 1.6
            return vignette.outputImage ?? curved

        case .kodachrome64:
            // Kodachrome 64: the most iconic slide film — warm reds, saturated blues, deep greens
            // Distinct look: punchy primaries, slightly elevated blacks, unique color rendering
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.3
            cc.contrast = 1.2
            cc.brightness = 0.0
            // Slightly warm — Kodachrome's famous warm cast
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5800, y: 5)
            // The Kodachrome color matrix: reds push orange, blues go deep, greens stay rich
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.15, y: 0.05, z: 0.0,  w: 0)  // warm red push
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.12, w: 0)  // deep blue
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.0, z: 0.0, w: 0)  // lifted blacks
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.04, mid: 0.0, highlights: -0.04)
            return claritySharpen(input: curved)

        case .ektachrome100:
            // Ektachrome E100: cool, clinical slide film — fine detail, punchy blues, accurate colors
            // Popular for landscapes, aviation, underwater — very different from warm Kodachrome
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.2
            cc.contrast = 1.15
            cc.brightness = 0.0
            // Cool balanced — Ektachrome runs cool, blues and cyans are dominant
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 7200, y: -5)  // notably cool
            // Blue/cyan emphasis — the Ektachrome signature
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cool.outputImage
            matrix.rVector = CIVector(x: 0.97, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.05, z: 0.03, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.03, z: 1.15, w: 0)  // electric blue
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.02, mid: 0.0, highlights: -0.05)
            return claritySharpen(input: curved)

        case .goldenHaze:
            // Golden Haze: dreamy backlit look — lifted blacks, lush greens, warm glow,
            // heavy diffusion bloom and Pro-Mist softness. No true shadows, pure luminance.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.88   // slightly muted — dreaminess, not pop
            cc.contrast = 0.82     // low contrast, nothing is crushed
            cc.brightness = 0.05   // airy, slightly overexposed feel
            // Warm golden-hour cast
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = cc.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5300, y: 6)
            // Lush green boost + suppress blue for that sunlit foliage look
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = warm.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.02, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.12, z: 0.0,  w: 0)   // electric foliage
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.82, w: 0)   // suppress blue
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.03, y: 0.025, z: 0.01, w: 0) // milky lifted blacks
            // Lift shadows hard — no true blacks, everything is luminous
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.12, mid: 0.02, highlights: -0.01)
            // Heavy bloom — the backlit glow that defines this look
            let bloom = CIFilter.bloom()
            bloom.inputImage = curved
            bloom.intensity = 0.85
            bloom.radius = 28
            let bloomed = bloom.outputImage?.cropped(to: image.extent) ?? curved
            // Pro-Mist style diffusion — very slight gaussian to soften edges
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = bloomed
            blur.radius = 1.5
            let softened = blur.outputImage?.cropped(to: image.extent) ?? bloomed
            // Wide soft vignette — just enough to frame without darkening
            let vignette = CIFilter.vignette()
            vignette.inputImage = softened
            vignette.intensity = 0.25
            vignette.radius = 2.5
            return vignette.outputImage ?? softened

        case .polaroid600:
            // Polaroid 600: lo-fi instant film — faded, shifted colors, heavy vignette, soft
            // Colors shift toward blue-green, contrast is low, whites are milky
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.75   // muted — Polaroid colors are never punchy
            cc.contrast = 0.85    // low contrast, milky
            cc.brightness = 0.04  // lifted — Polaroid overexposes slightly
            // Cool-green shift characteristic of 600 film
            let cool = CIFilter.temperatureAndTint()
            cool.inputImage = cc.outputImage
            cool.neutral = CIVector(x: 6500, y: 0)
            cool.targetNeutral = CIVector(x: 6800, y: -8)   // cool + green
            // Fade and shift toward blue-green, lift shadows. Gentle: stacking
            // a hard red cut on the cool WB turned skin blue.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cool.outputImage
            matrix.rVector = CIVector(x: 0.95, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.01, z: 0.02, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.03, z: 0.99, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.025, y: 0.025, z: 0.03, w: 0)  // milky lifted blacks
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.08, mid: 0.02, highlights: -0.01)
            // Soft blur — Polaroid optics are never sharp
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = curved
            blur.radius = 0.8
            let softened = blur.outputImage?.cropped(to: image.extent) ?? curved
            // Heavy vignette — characteristic Polaroid frame darkening
            let vignette = CIFilter.vignette()
            vignette.inputImage = softened
            vignette.intensity = 1.4
            vignette.radius = 0.9
            return vignette.outputImage ?? softened

        // MARK: - Pro additions

        case .fujiEterna:
            // Fuji Eterna 250D — cinematic motion-picture stock. Low contrast, muted/desat
            // palette with subtle green-cyan in shadows, soft warm highlights. Grade-friendly.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.78
            cc.contrast = 0.88
            cc.brightness = 0.01
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5800, y: -6)   // cool with slight green
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 0.98, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.02, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.97, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.015, z: 0.005, w: 0)  // shadow lift
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.04, mid: 0.0, highlights: -0.03)

        case .fujiClassicChrome:
            // Fujifilm Classic Chrome — desaturated reds, slight cyan, retro magazine look
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.82
            cc.contrast = 1.05
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6400, y: -8)   // touch of cyan
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 0.92, y: 0.04, z: 0.0,  w: 0)   // pull reds toward orange/desat
            matrix.gVector = CIVector(x: 0.0,  y: 0.96, z: 0.04, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.02, z: 1.0,  w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.02, mid: 0.0, highlights: -0.02)

        case .fujiAstia:
            // Fuji Astia — soft pro portrait. Smooth mids, gentle skin tones, low contrast.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.95
            cc.contrast = 0.95
            cc.brightness = 0.01
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6400, y: 4)   // very slightly warm
            // Skin-friendly matrix: lift R/G slightly, keep B natural
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.04, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.01, y: 1.01, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.99, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.02, mid: 0.01, highlights: -0.02)

        case .cinestill400D:
            // Cinestill 400D — daylight color neg, modern, mild halation, balanced color.
            // Closer to neutral than 800T, less warm than 50D.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.04
            cc.contrast = 1.04
            cc.brightness = 0.005
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5500, y: 4)   // daylight WB
            // Subtle halation — a tiny red-channel bloom around highlights
            let bloom = CIFilter.bloom()
            bloom.inputImage = temp.outputImage
            bloom.intensity = 0.20
            bloom.radius = 8
            let bloomed = bloom.outputImage?.cropped(to: image.extent) ?? (temp.outputImage ?? image)
            return toneCurve(input: bloomed, shadows: 0.01, mid: 0.0, highlights: -0.02)

        case .kodakAerochrome:
            // Kodak Aerochrome — false-color IR slide film. Foliage goes red/pink,
            // skies stay cyan, skin shifts magenta. Very distinctive.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.35
            cc.contrast = 1.10
            cc.brightness = 0.0
            // Channel swap: green → red, red stays, blue stays
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 0.20, y: 1.10, z: 0.0,  w: 0)   // greens become reds
            matrix.gVector = CIVector(x: 0.10, y: 0.30, z: 0.05, w: 0)   // suppress green
            matrix.bVector = CIVector(x: 0.0,  y: 0.05, z: 0.95, w: 0)   // blues mostly preserved
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.02, mid: 0.0, highlights: -0.02)

        case .kodakTmax400:
            // Kodak T-Max 400 — pro B&W, fine grain, clean shadows, moderate contrast.
            // Cooler than Tri-X, smoother than HP5.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.10
            mono.brightness = 0.0
            return toneCurve(input: mono.outputImage ?? image, shadows: -0.02, mid: 0.01, highlights: -0.04)

        case .polaroidSX70:
            // Polaroid SX-70 — earlier instant film. Cooler than 600, more washed,
            // muted yellows/greens, wider tonal compression.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.70
            cc.contrast = 0.78           // very flat
            cc.brightness = 0.04         // milky
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6900, y: -4)   // cool, slight green
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 0.95, y: 0.04, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 0.92, z: 0.06, w: 0)
            matrix.bVector = CIVector(x: 0.04, y: 0.0,  z: 0.98, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.04, y: 0.04, z: 0.04, w: 0)   // milky lifted blacks
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.06, mid: 0.0, highlights: -0.03)
            // Light vignette — softer than 600
            let vignette = CIFilter.vignette()
            vignette.inputImage = curved
            vignette.intensity = 0.6
            vignette.radius = 1.4
            return vignette.outputImage ?? curved

        case .lomochromePurple:
            // Lomochrome Purple — purple/teal color shift, greens → purple, blues → teal.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.20
            cc.contrast = 1.05
            cc.brightness = 0.0
            // Hue rotation by ~120° via channel swap; greens become magenta/purple
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 0.85, y: 0.40, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.20, y: 0.50, z: 0.30, w: 0)
            matrix.bVector = CIVector(x: 0.30, y: 0.20, z: 1.05, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.02, mid: 0.0, highlights: -0.03)

        case .leicaMonochrom:
            // Leica M Monochrom — dedicated B&W sensor. Clean, slightly warm-toned blacks,
            // smooth gradient, micro-contrast pop.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.05
            mono.brightness = 0.0
            // Warm-toned B&W: very slight sepia bias
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = mono.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.97, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: -0.01, mid: 0.01, highlights: -0.04)
            return claritySharpen(input: curved)

        case .leicaQ3:
            // Leica Q3 / SL3 modern color profile. Balanced warm midtones, rich greens,
            // natural skin, slightly higher contrast than M.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.02
            cc.contrast = 1.08
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6200, y: 2)   // very slightly warm
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.03, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.04, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.0,  w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let curved = toneCurve(input: matrix.outputImage ?? image, shadows: -0.02, mid: 0.01, highlights: -0.03)
            return claritySharpen(input: curved)

        case .leicaClassic:
            // Leica Classic — pre-digital Leitz lens character. Warm cast, golden highlights,
            // softer contrast, slight glow in highlights.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.92
            cc.contrast = 0.95
            cc.brightness = 0.02
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5400, y: 4)   // warm
            let bloom = CIFilter.bloom()
            bloom.inputImage = temp.outputImage
            bloom.intensity = 0.30
            bloom.radius = 12
            let bloomed = bloom.outputImage?.cropped(to: image.extent) ?? (temp.outputImage ?? image)
            return toneCurve(input: bloomed, shadows: 0.04, mid: 0.0, highlights: -0.02)

        case .leicaEternal:
            // Leica Eternal — built-in cinematic profile in newer M11/Q3. Very low contrast,
            // smooth gradient, muted saturation, neutral WB. Designed for grading.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.80
            cc.contrast = 0.82
            cc.brightness = 0.01
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6500, y: 0)   // truly neutral
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 0.99, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.01, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.02, y: 0.02, z: 0.02, w: 0)  // shadow lift for grading
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.05, mid: 0.0, highlights: -0.04)

        // MARK: - Instant (additional)

        case .polaroidSpectra:
            // Polaroid Spectra (1986) — warmer and earthier than 600. Slight yellow-amber
            // cast, creamy lifted blacks, soft optics, strong vignette.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.82
            cc.contrast = 0.88
            cc.brightness = 0.03
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5700, y: 8)   // warm amber
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.05, y: 0.02, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.02, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.88, w: 0)  // blue suppressed → amber
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.03, y: 0.025, z: 0.01, w: 0)  // creamy black lift
            let spectraCurved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.06, mid: 0.01, highlights: -0.02)
            let spectraBlur = CIFilter.gaussianBlur()
            spectraBlur.inputImage = spectraCurved
            spectraBlur.radius = 0.7
            let spectraSoft = spectraBlur.outputImage?.cropped(to: image.extent) ?? spectraCurved
            let spectraVig = CIFilter.vignette()
            spectraVig.inputImage = spectraSoft
            spectraVig.intensity = 1.1
            spectraVig.radius = 1.0
            return spectraVig.outputImage ?? spectraSoft

        case .polaroidiType:
            // Polaroid i-Type / Originals Color — modern instant film. Green-tinted shadows,
            // faded mids, milky blacks, cool-neutral whites.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.78
            cc.contrast = 0.88
            cc.brightness = 0.02
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6800, y: -14)  // cool with green cast
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 0.93, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.07, z: 0.04, w: 0)  // green push
            matrix.bVector = CIVector(x: 0.0,  y: 0.04, z: 0.98, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.02, y: 0.035, z: 0.025, w: 0)  // green-milky lift
            let iTypeCurved = toneCurve(input: matrix.outputImage ?? image, shadows: 0.06, mid: 0.01, highlights: -0.02)
            let iTypeVig = CIFilter.vignette()
            iTypeVig.inputImage = iTypeCurved
            iTypeVig.intensity = 0.8
            iTypeVig.radius = 1.3
            return iTypeVig.outputImage ?? iTypeCurved

        // MARK: - Experimental / Alternative Process

        case .crossProcess:
            // E-6 slide film cross-processed in C-41 chemicals. High contrast, extreme
            // color shifts: shadows cyan, reds punch hard, blues go electric teal.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.50
            cc.contrast = 1.18
            cc.brightness = -0.02
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.20, y: 0.10, z: -0.10, w: 0)
            matrix.gVector = CIVector(x: 0.04, y: 1.05, z: -0.04, w: 0)
            matrix.bVector = CIVector(x: -0.14, y: 0.06, z: 1.12, w: 0)  // blues → electric cyan
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: -0.02, y: -0.01, z: 0.03, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.07, mid: 0.0, highlights: 0.02)

        case .bleachBypass:
            // Silver retention / bleach bypass — skip the bleach step so silver stays in
            // the emulsion alongside the dye. Result: crushed contrast, heavy desaturation,
            // metallic silver sheen in mids. Used in Se7en, Saving Private Ryan.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.30   // almost mono but traces of color survive
            cc.contrast = 1.35
            cc.brightness = -0.02
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.96, w: 0)  // very slightly warm/silver
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.07, mid: 0.0, highlights: -0.03)

        case .expiredFilm:
            // Expired color negative — dye layers degrade unevenly, magenta/cyan fog builds
            // in shadows, contrast collapses, colors go unpredictable. Green channel fades most.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.88
            cc.contrast = 0.80
            cc.brightness = 0.04
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.04, y: 0.0,  z: 0.06, w: 0)  // warm+magenta push
            matrix.gVector = CIVector(x: 0.0,  y: 0.84, z: 0.0,  w: 0)  // green layer degraded
            matrix.bVector = CIVector(x: 0.06, y: 0.0,  z: 1.10, w: 0)  // blue/cyan fog
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.05, y: 0.03, z: 0.07, w: 0)  // heavy shadow fog
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.09, mid: 0.02, highlights: -0.01)

        case .cyanotype:
            // Cyanotype (1842): iron-salt print, sensitive to blue/UV, Prussian
            // blue dye on cream rag paper — modelled in density (see
            // shaders/FilmProcess.ci.metal). Falls back to the old tint.
            if let printed = densityPrint(image, process: .cyanotype) { return printed }
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.08
            mono.brightness = 0.0
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = mono.outputImage
            // Map luminance to prussian-blue range: shadows deep cobalt, highlights pale cyan
            matrix.rVector = CIVector(x: 0.78, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 0.88, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.08, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.0, y: 0.02, z: 0.14, w: 0)  // blue base fog
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.02, mid: 0.0, highlights: -0.03)

        case .daguerreotype:
            // Daguerreotype (1839): silver-mercury image on a mirrored plate.
            // Blue-sensitive, contrasty, silver highlights; modelled in density.
            if let printed = densityPrint(image, process: .daguerreotype) {
                let v = CIFilter.vignette()
                v.inputImage = printed
                v.intensity = 1.6
                v.radius = 0.7
                return v.outputImage ?? printed
            }
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.25
            mono.brightness = -0.03
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = mono.outputImage
            matrix.rVector = CIVector(x: 0.96, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 0.97, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.03, y: 0.03, z: 1.05, w: 0)  // cold silver sheen
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let dagCurved = toneCurve(input: matrix.outputImage ?? image, shadows: -0.06, mid: 0.0, highlights: -0.02)
            let dagVig = CIFilter.vignette()
            dagVig.inputImage = dagCurved
            dagVig.intensity = 2.2
            dagVig.radius = 0.65
            return dagVig.outputImage ?? dagCurved

        case .styleAmber, .styleGold, .styleRoseGold, .styleNeutral, .styleCoolRose, .styleVibrant, .styleNatural, .styleLuminous, .styleDramatic, .styleQuiet, .styleCozy, .styleEthereal, .styleMutedBW, .styleStarkBW:
            return image   // styles are applied by StyleEngine after the sim pass

        case .tintype:
            // Wet-collodion tintype (1856): blue-only silver image on black
            // japanned iron. Strong falloff from the plate holder.
            if let p = densityPrint(image, process: .tintype) {
                let v = CIFilter.vignette(); v.inputImage = p; v.intensity = 2.0; v.radius = 0.75
                return v.outputImage ?? p
            }
            return image
        case .platinum:
            if let p = densityPrint(image, process: .platinum) { return p }
            return image
        case .vanDyke:
            if let p = densityPrint(image, process: .vanDyke) { return p }
            return image
        case .saltPrint:
            if let p = densityPrint(image, process: .saltPrint) { return p }
            return image

        case .duotone:
            // Duotone — indigo-purple shadows, warm amber/cream highlights.
            // Classic editorial duotone like magazine covers and art prints.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.08
            mono.brightness = 0.0
            // Map: L=0 → indigo (0.14, 0.10, 0.36), L=1 → cream (1.0, 0.92, 0.72)
            // output = matrix * [L, L, L] + bias
            // R = 0.86*L + 0.14  →  rVector.x = 0.86, bias.x = 0.14
            // G = 0.82*L + 0.10  →  gVector.y = 0.82, bias.y = 0.10
            // B = 0.36*L + 0.36  →  bVector.z = 0.36, bias.z = 0.36
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = mono.outputImage
            matrix.rVector = CIVector(x: 0.86, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 0.82, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.36, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.14, y: 0.10, z: 0.36, w: 0)
            return matrix.outputImage ?? image

        case .retroChrome:
            // Retro Chrome — oversaturated slide film a la early 1970s Ektachrome.
            // Punchy primaries, high contrast, vivid reds and teals.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.48
            cc.contrast = 1.14
            cc.brightness = -0.01
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5500, y: 6)  // warm-neutral
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.08, y: 0.0,  z: -0.04, w: 0)  // reds pop
            matrix.gVector = CIVector(x: 0.0,  y: 0.98, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: -0.04, y: 0.0, z: 1.06, w: 0)  // teals push
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.04, mid: 0.01, highlights: -0.03)

        case .neonNoir:
            // Neon Noir — dark cyberpunk city look. Deep shadows, electric magentas and
            // cyan-teals, high contrast, slightly blown artificial light sources.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.42
            cc.contrast = 1.16
            cc.brightness = -0.04
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 1.12, y: -0.05, z: 0.12, w: 0)
            matrix.gVector = CIVector(x: -0.04, y: 0.88, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.12, y: 0.0,  z: 1.16, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.0, y: 0.0, z: 0.02, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.08, mid: 0.0, highlights: -0.01)

        case .circuitBent:
            // Circuit-Bent — infrared/thermal false-color look. The grain
            // slider drives the speckle amount (0 when grain off → clean
            // gradient; up to full as the slider climbs).
            return circuitBend(image, heavy: false, speckleScale: speckle)

        case .circuitBentHeavy:
            // Circuit-Bent Heavy — same recipe, cranked. Grain slider drives
            // the speckle the same way.
            return circuitBend(image, heavy: true, speckleScale: speckle)

        // MARK: - Fujifilm additions

        case .fujiReala100:
            // Fuji Reala 100 — widely regarded as the most color-accurate neg film ever made.
            // Natural skin tones, cool-neutral WB, low saturation boost, very clean shadow detail.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.95
            cc.contrast = 1.0
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6600, y: 2)  // barely cool, nearly neutral
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.01, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.0,  w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.005, y: 0.005, z: 0.005, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.01, mid: 0.0, highlights: -0.01)

        case .fuji160NS:
            // Fuji 160NS (Natura S) — natural-light professional neg. Extremely soft contrast,
            // gently warm, shadow detail preserved, designed for indoor available light.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.90
            cc.contrast = 0.92
            cc.brightness = 0.02
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5900, y: 4)  // gently warm
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.01, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.98, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.01, z: 0.005, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.03, mid: 0.0, highlights: -0.02)

        case .fujiSensia:
            // Fuji Sensia 100 — consumer slide film. Vivid but smoother than Velvia,
            // accurate WB, slightly warm, punchy reds and greens without the harshness.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.15
            cc.contrast = 1.08
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6000, y: 4)
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.04, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.02, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.0,  w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.01, mid: 0.01, highlights: -0.02)

        // MARK: - Kodak additions

        case .kodakPortra160:
            // Kodak Portra 160 — finer grain and cooler/cleaner than 400. The go-to for
            // bright daylight portrait work. Very neutral WB, exceptional skin latitude.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.94
            cc.contrast = 0.97
            cc.brightness = 0.005
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6700, y: 2)  // slightly cooler than Portra 400
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.0,  y: 0.0,  z: 0.0, w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.01, z: 0.0, w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.0, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.008, y: 0.008, z: 0.006, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.015, mid: 0.0, highlights: -0.01)

        case .kodakProImage100:
            // Kodak Pro Image 100 — affordable professional neg, hugely popular in Asia
            // and Latin America. Warm, slightly pushed reds, good greens, slight tropical feel.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.04
            cc.contrast = 1.04
            cc.brightness = 0.01
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5800, y: 6)  // warm with slight green
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.04, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.03, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.96, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.01, z: 0.0, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.01, mid: 0.01, highlights: -0.02)

        case .kodakAdvantix:
            // Kodak Advantix / Nexia — consumer APS compact film. Lo-fi warm look,
            // slightly over-saturated in reds, soft shadow detail, budget point-and-shoot feel.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.08
            cc.contrast = 0.95
            cc.brightness = 0.03
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5500, y: 8)  // warm compact-camera WB
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.08, y: 0.02, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.92, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.015, y: 0.01, z: 0.0, w: 0)
            let advBlur = CIFilter.gaussianBlur()
            advBlur.inputImage = matrix.outputImage
            advBlur.radius = 0.5
            let advSoft = advBlur.outputImage?.cropped(to: image.extent) ?? (matrix.outputImage ?? image)
            return toneCurve(input: advSoft, shadows: 0.02, mid: 0.01, highlights: -0.01)

        // MARK: - Cinema additions

        case .kodak2383:
            // Kodak 2383 print film — the standard theatrical print stock used for projection.
            // Warm golden grade, lifted shadows, smooth S-curve, orange-amber tint in mids.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.06
            cc.contrast = 1.08
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5600, y: 6)  // warm theatrical WB
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.06, y: 0.02, z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.90, w: 0)  // blue pulled → amber
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.02, y: 0.015, z: 0.0, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.03, mid: 0.01, highlights: -0.03)

        case .fujiEternaVivid:
            // Fuji Eterna Vivid 250D — the punchier cinema daylight stock. More saturation
            // and contrast than Eterna 250D, still grade-friendly, cool-neutral base.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.98
            cc.contrast = 0.96
            cc.brightness = 0.01
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5700, y: -3)
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.0,  y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.04, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.98, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.012, z: 0.005, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.03, mid: 0.0, highlights: -0.03)

        // MARK: - Slide additions

        case .fujiProvia400X:
            // Fuji Provia 400X — faster slide film, slightly cooler and less saturated
            // than 100F. Fine grain for the speed. Good for mixed-light situations.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.10
            cc.contrast = 1.08
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6700, y: -2)  // slightly cool
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.0,  y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.02, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.01, mid: 0.0, highlights: -0.02)

        case .agfaRSX:
            // Agfa RSX 100 / CT Precisa — European slide film. Warm-neutral, slight magenta
            // bias in shadows, excellent skin, different character from Fuji or Kodak slides.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.06
            cc.contrast = 1.06
            cc.brightness = 0.0
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5900, y: 10)  // warm + slight magenta
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.04, y: 0.0,  z: 0.02, w: 0)  // slight magenta
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 1.0,  w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.01, mid: 0.01, highlights: -0.02)

        // MARK: - Instant additions

        case .fujiInstax:
            // Fuji Instax Mini — the world's most popular instant film. Slightly overexposed
            // feel, warm and cheerful, lifted shadows, soft pastel quality.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.05
            cc.contrast = 0.90
            cc.brightness = 0.06  // characteristic slight overexposure
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = cc.outputImage
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5800, y: 4)  // warm
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = temp.outputImage
            matrix.rVector = CIVector(x: 1.03, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.02, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.97, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.02, y: 0.02, z: 0.015, w: 0)  // pastel lift
            let instaxBlur = CIFilter.gaussianBlur()
            instaxBlur.inputImage = matrix.outputImage
            instaxBlur.radius = 0.4
            let instaxSoft = instaxBlur.outputImage?.cropped(to: image.extent) ?? (matrix.outputImage ?? image)
            return toneCurve(input: instaxSoft, shadows: 0.04, mid: 0.01, highlights: -0.01)

        // MARK: - B&W additions

        case .ilfordDelta3200:
            // Ilford Delta 3200 — very high speed, massively grainy, pushed look.
            // High contrast but with lifted shadows from the push processing.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.22
            mono.brightness = -0.01
            return toneCurve(input: mono.outputImage ?? image, shadows: -0.04, mid: 0.02, highlights: -0.06)

        case .ilfordDelta100:
            // Ilford Delta 100 — ultra fine grain, clinical precision. Textbook-clean B&W.
            // Smooth gradients, accurate mid tones, the "correct" B&W film.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.05
            mono.brightness = 0.0
            return toneCurve(input: mono.outputImage ?? image, shadows: -0.01, mid: 0.0, highlights: -0.02)

        case .ilfordXP2:
            // Ilford XP2 Super — C-41 (chromogenic) B&W. The silver grain is replaced
            // with dye clouds → very smooth, slightly warm tone, more like B&W portrait print.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.03
            mono.brightness = 0.0
            // Slight warm tone from the chromogenic dye clouds
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = mono.outputImage
            matrix.rVector = CIVector(x: 1.02, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 1.0,  z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.0,  y: 0.0,  z: 0.97, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.01, mid: 0.0, highlights: -0.02)

        case .kodakDoubleX:
            // Kodak Double-X 5222 — classic cinema B&W negative. Schindler's List, Raging
            // Bull, Manhattan. High contrast, rich deep blacks, slightly cool silver tone.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.28
            mono.brightness = -0.02
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = mono.outputImage
            matrix.rVector = CIVector(x: 0.97, y: 0.0,  z: 0.0,  w: 0)
            matrix.gVector = CIVector(x: 0.0,  y: 0.98, z: 0.0,  w: 0)
            matrix.bVector = CIVector(x: 0.02, y: 0.02, z: 1.02, w: 0)  // cool cinema silver
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.06, mid: 0.0, highlights: -0.03)

        case .kodakP3200:
            // Kodak T-MAX P3200 — pushed high-speed B&W. Very contrasty, gritty,
            // visible grain structure, street/night photography workhorse.
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0.0
            mono.contrast = 1.32
            mono.brightness = -0.02
            return toneCurve(input: mono.outputImage ?? image, shadows: -0.07, mid: 0.01, highlights: -0.05)

        // MARK: - Lomography additions

        case .lomochromeMetropolis:
            // Lomochrome Metropolis — desaturated urban palette. Greens shift toward brown/olive,
            // blues flatten, shadows go grey-green. Gritty city feel.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 0.62
            cc.contrast = 1.06
            cc.brightness = -0.01
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            matrix.rVector = CIVector(x: 0.95, y: 0.08, z: 0.0,  w: 0)   // slight brown pull
            matrix.gVector = CIVector(x: 0.04, y: 0.88, z: 0.04, w: 0)   // greens muted/olive
            matrix.bVector = CIVector(x: 0.0,  y: 0.06, z: 0.92, w: 0)   // blues flatten
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0.01, y: 0.015, z: 0.01, w: 0)
            return toneCurve(input: matrix.outputImage ?? image, shadows: -0.02, mid: 0.0, highlights: -0.02)

        case .lomochromeTurquoise:
            // Lomochrome Turquoise — extreme teal/turquoise color shift. Warm tones become
            // teal, sky goes green, skin turns aqua. Very distinctive and otherworldly.
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.saturation = 1.25
            cc.contrast = 1.05
            cc.brightness = 0.0
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = cc.outputImage
            // Pull red into teal: reduce R, boost G+B
            matrix.rVector = CIVector(x: 0.25, y: 0.35, z: 0.40, w: 0)   // reds → teal
            matrix.gVector = CIVector(x: 0.10, y: 0.75, z: 0.20, w: 0)   // greens stay with teal shift
            matrix.bVector = CIVector(x: 0.05, y: 0.20, z: 1.05, w: 0)   // blues/teals amplified
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return toneCurve(input: matrix.outputImage ?? image, shadows: 0.01, mid: 0.0, highlights: -0.02)
        }
    }

    // MARK: Custom Sim Processing

    /// A custom film = optional base film → your adjustments (or LUT) → lens.
    nonisolated func applyCustomSim(to image: CIImage, sim: CustomSimulation) -> CIImage {
        var img = image
        if sim.lutFilename == nil, let base = sim.baseSim, base != .none {
            img = applyFilmSim(to: img, sim: base, grainEnabled: false, grain: 0, digiCamQuality: cachedDigiCamQuality)
            if let k = base.styleKind {
                img = StyleEngine.apply(img, kind: k, tone: 0, color: 0, palette: 1, mask: nil)
            }
        }
        img = applyCustomParams(to: img, sim: sim)
        if sim.lensKind != .none { img = applyLens(img, sim.lensKind) }
        return img.cropped(to: image.extent)
    }

    // MARK: - Lens character

    nonisolated func applyLens(_ input: CIImage, _ lens: LensKind) -> CIImage {
        let extent = input.extent
        let size = max(extent.width, extent.height)
        let c = CIVector(x: extent.midX, y: extent.midY)
        func vignette(_ img: CIImage, _ intensity: Float, _ radius: Float) -> CIImage {
            let v = CIFilter.vignetteEffect()
            v.inputImage = img
            v.center = CGPoint(x: extent.midX, y: extent.midY)
            v.radius = Float(size) * radius
            v.intensity = intensity
            v.falloff = 0.6
            return v.outputImage ?? img
        }
        /// White at the edges, black in the middle — where lens faults show.
        func edgeMask(_ inner: CGFloat, _ outer: CGFloat) -> CIImage {
            CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": c, "inputRadius0": size * inner, "inputRadius1": size * outer,
                "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1),
            ])?.outputImage?.cropped(to: extent) ?? CIImage(color: .black).cropped(to: extent)
        }
        func rotated(_ img: CIImage, _ degrees: CGFloat) -> CIImage {
            let r = degrees * .pi / 180
            return img.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                    .concatenating(CGAffineTransform(rotationAngle: r))
                    .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY)))
                .cropped(to: extent)
        }
        func mix(_ a: CIImage, _ b: CIImage, _ t: Double) -> CIImage {
            CIFilter(name: "CIDissolveTransition", parameters: [
                kCIInputImageKey: a, kCIInputTargetImageKey: b, "inputTime": t,
            ])?.outputImage?.cropped(to: extent) ?? a
        }
        /// Smooth rotational blur: the mean of `steps` rotations spread over
        /// ±maxDeg (a handful of copies showed as ghosted double edges).
        func spun(_ img: CIImage, _ maxDeg: CGFloat, steps: Int = 9) -> CIImage {
            var acc = rotated(img, -maxDeg)
            for i in 1..<steps {
                let deg = -maxDeg + 2 * maxDeg * CGFloat(i) / CGFloat(steps - 1)
                acc = mix(acc, rotated(img, deg), 1 / Double(i + 1))      // running mean
            }
            return acc
        }
        func masked(_ fg: CIImage, over bg: CIImage, _ mask: CIImage) -> CIImage {
            let b = CIFilter.blendWithMask()
            b.inputImage = fg; b.backgroundImage = bg; b.maskImage = mask
            return b.outputImage?.cropped(to: extent) ?? bg
        }

        switch lens {
        case .none:
            return input
        case .swirl:
            // Rotational smear grows toward the edges (Helios-44 swirly bokeh).
            let swirl = spun(input, 1.8)
            return vignette(masked(swirl, over: input, edgeMask(0.22, 0.62)), 0.6, 0.75)
        case .glow:
            let bloom = CIFilter.bloom()
            bloom.inputImage = input
            bloom.radius = Float(size * 0.012)
            bloom.intensity = 0.55
            let soft = CIFilter.colorControls()
            soft.inputImage = bloom.outputImage?.cropped(to: extent) ?? input
            soft.contrast = 0.94
            return vignette(soft.outputImage ?? input, 0.4, 0.8)
        case .toy:
            // Radial chromatic aberration + soft corners + heavy vignette.
            func scaled(_ img: CIImage, _ k: CGFloat) -> CIImage {
                img.clampedToExtent()
                    .transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                        .concatenating(CGAffineTransform(scaleX: k, y: k))
                        .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY)))
                    .cropped(to: extent)
            }
            let r = isolateChannel(scaled(input, 1.007), channel: 0)
            let g = isolateChannel(input, channel: 1)
            let b = isolateChannel(scaled(input, 0.993), channel: 2)
            let m1 = CIFilter.maximumCompositing(); m1.inputImage = r; m1.backgroundImage = g
            let m2 = CIFilter.maximumCompositing(); m2.inputImage = m1.outputImage; m2.backgroundImage = b
            let fringed = m2.outputImage?.cropped(to: extent) ?? input
            let blurred = fringed.clampedToExtent().applyingGaussianBlur(sigma: Double(size) * 0.004).cropped(to: extent)
            return vignette(masked(blurred, over: fringed, edgeMask(0.25, 0.6)), 1.6, 0.6)
        case .anamorphic:
            let streaked = applyAnamorphicFlare(input: input)
            // Oval falloff: vignette on a horizontally squeezed frame.
            return vignette(streaked, 0.7, 0.85)
        case .pinhole:
            let soft = input.clampedToExtent().applyingGaussianBlur(sigma: Double(size) * 0.0018).cropped(to: extent)
            let d = CIFilter.colorControls()
            d.inputImage = soft; d.saturation = 0.9
            return vignette(d.outputImage ?? soft, 2.2, 0.55)

        case .takumar:
            // Thoriated elements yellow with age: the blue channel loses
            // most, single coating lowers saturation and lets a little glow in.
            let warm = CIFilter.colorMatrix()
            warm.inputImage = input
            warm.rVector = CIVector(x: 1.0, y: 0, z: 0, w: 0)
            warm.gVector = CIVector(x: 0, y: 0.97, z: 0, w: 0)
            warm.bVector = CIVector(x: 0, y: 0, z: 0.84, w: 0)
            warm.biasVector = CIVector(x: 0.01, y: 0.005, z: 0, w: 0)
            let bloom = CIFilter.bloom()
            bloom.inputImage = warm.outputImage?.cropped(to: extent) ?? input
            bloom.radius = Float(size * 0.008); bloom.intensity = 0.25
            let soft = CIFilter.colorControls()
            soft.inputImage = bloom.outputImage?.cropped(to: extent) ?? input
            soft.saturation = 0.9; soft.contrast = 0.96
            return vignette(soft.outputImage ?? input, 0.35, 0.85)

        case .petzval:
            // Sharp centre, strong field curvature: the swirl only starts
            // a third of the way out and is far stronger than a Helios.
            let swirl = spun(input, 3.2, steps: 11).clampedToExtent()
                .applyingGaussianBlur(sigma: Double(size) * 0.0015).cropped(to: extent)
            return vignette(masked(swirl, over: input, edgeMask(0.17, 0.5)), 1.1, 0.7)

        case .proMist:
            // Diffusion filter: bright areas spill a soft halo, blacks lift
            // a touch, highlight contrast eases.
            let bloom = CIFilter.bloom()
            bloom.inputImage = input
            bloom.radius = Float(size * 0.02); bloom.intensity = 0.5
            let lifted = CIFilter.toneCurve()
            lifted.inputImage = bloom.outputImage?.cropped(to: extent) ?? input
            lifted.point0 = CGPoint(x: 0, y: 0.025); lifted.point1 = CGPoint(x: 0.25, y: 0.26)
            lifted.point2 = CGPoint(x: 0.5, y: 0.5); lifted.point3 = CGPoint(x: 0.75, y: 0.73)
            lifted.point4 = CGPoint(x: 1, y: 0.97)
            return lifted.outputImage?.cropped(to: extent) ?? input

        case .sonnar:
            // Micro-contrast (texture and edges crisp) with a smooth roll-off
            // toward the corners: the subject "lifts" off the frame.
            let pop = CIFilter.unsharpMask()
            pop.inputImage = input
            pop.radius = Float(size * 0.0035); pop.intensity = 0.55
            let c2 = CIFilter.colorControls()
            c2.inputImage = pop.outputImage?.cropped(to: extent) ?? input
            c2.saturation = 1.03
            let falloff = input.clampedToExtent().applyingGaussianBlur(sigma: Double(size) * 0.002).cropped(to: extent)
            let popped = c2.outputImage ?? input
            return vignette(masked(falloff, over: popped, edgeMask(0.35, 0.75)), 0.45, 0.8)

        case .dream:
            // f/0.95 wide open: heavy spherical-aberration glow, low
            // contrast, soft corners with a gentle swirl.
            let bloom = CIFilter.bloom()
            bloom.inputImage = input
            bloom.radius = Float(size * 0.018); bloom.intensity = 0.7
            let low = CIFilter.colorControls()
            low.inputImage = bloom.outputImage?.cropped(to: extent) ?? input
            low.contrast = 0.88; low.saturation = 0.95
            let glowing = low.outputImage?.cropped(to: extent) ?? input
            let corners = spun(glowing, 0.8, steps: 5).clampedToExtent()
                .applyingGaussianBlur(sigma: Double(size) * 0.003).cropped(to: extent)
            return vignette(masked(corners, over: glowing, edgeMask(0.25, 0.6)), 0.8, 0.75)

        case .tiltShift:
            // Miniature: sharp band through the middle of the SCENE (across
            // the way the phone is held), blur growing toward both edges,
            // a little extra colour and contrast like a model railway.
            let vertical = abs(abs(Self.lookAngle) - 90) < 1     // held sideways: scene's horizontal = image's vertical axis
            let band = (vertical ? extent.width : extent.height) * 0.14
            let ramp = (vertical ? extent.width : extent.height) * 0.22
            let mid = vertical ? extent.midX : extent.midY
            func grad(_ from: CGFloat, _ to: CGFloat) -> CIImage {
                let p0 = vertical ? CIVector(x: from, y: 0) : CIVector(x: 0, y: from)
                let p1 = vertical ? CIVector(x: to, y: 0) : CIVector(x: 0, y: to)
                return CIFilter(name: "CISmoothLinearGradient", parameters: [
                    "inputPoint0": p0, "inputPoint1": p1,
                    "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1),
                ])?.outputImage?.cropped(to: extent) ?? CIImage(color: .black).cropped(to: extent)
            }
            let mask = grad(mid + band / 2, mid + band / 2 + ramp)
                .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: grad(mid - band / 2, mid - band / 2 - ramp)])
            let blurred = input.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
                "inputMask": mask, kCIInputRadiusKey: Double(size) * 0.012]).cropped(to: extent)
            let pop = CIFilter.colorControls()
            pop.inputImage = blurred; pop.saturation = 1.25; pop.contrast = 1.08
            return pop.outputImage?.cropped(to: extent) ?? blurred

        case .fisheye:
            // Barrel distortion: the centre bulges out, straight lines bow,
            // and the rim darkens like a 16 mm fisheye on a crop frame.
            let bump = CIFilter.bumpDistortion()
            bump.inputImage = input.clampedToExtent()
            bump.center = CGPoint(x: extent.midX, y: extent.midY)
            bump.radius = Float(size * 0.75)
            bump.scale = 0.55
            let bulged = bump.outputImage?.cropped(to: extent) ?? input
            return vignette(bulged, 1.3, 0.62)
        }
    }

    nonisolated func applyCustomParams(to image: CIImage, sim: CustomSimulation) -> CIImage {
        // LUT short-circuit: if this sim is backed by a .cube file, apply
        // the LUT and skip parameter-based grading. The LUT IS the look.
        // This branch runs from the live preview's nonisolated callback,
        // which is why LUTManager is non-isolated and thread-safe.
        if let lutFilename = sim.lutFilename {
            return LUTManager.shared.apply(filename: lutFilename, to: image)
        }

        var result = image

        // 1. Brightness / Contrast / Saturation
        let cc = CIFilter.colorControls()
        cc.inputImage = result
        cc.brightness = sim.brightness
        cc.contrast = sim.contrast
        cc.saturation = sim.saturation
        result = cc.outputImage ?? result

        // 2. Temperature & Tint
        let temp = CIFilter.temperatureAndTint()
        temp.inputImage = result
        temp.neutral = CIVector(x: 6500, y: 0)
        temp.targetNeutral = CIVector(x: CGFloat(sim.temperature), y: CGFloat(sim.tint))
        result = temp.outputImage ?? result

        // 3. Color matrix (channel multipliers + bias)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = result
        matrix.rVector = CIVector(x: CGFloat(sim.redMult), y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: CGFloat(sim.greenMult), z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(sim.blueMult), w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: CGFloat(sim.redBias), y: CGFloat(sim.greenBias), z: CGFloat(sim.blueBias), w: 0)
        result = matrix.outputImage ?? result

        // 4. Tone curve (shadow lift, mid shift, highlight rolloff)
        result = toneCurve(input: result, shadows: sim.shadowLift + sim.fadeAmount, mid: sim.midShift, highlights: sim.highlightRolloff)

        // 5. Fade (lift the black point)
        if sim.fadeAmount > 0 {
            let fade = CIFilter.colorMatrix()
            fade.inputImage = result
            fade.rVector = CIVector(x: CGFloat(1.0 - sim.fadeAmount), y: 0, z: 0, w: 0)
            fade.gVector = CIVector(x: 0, y: CGFloat(1.0 - sim.fadeAmount), z: 0, w: 0)
            fade.bVector = CIVector(x: 0, y: 0, z: CGFloat(1.0 - sim.fadeAmount), w: 0)
            fade.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            fade.biasVector = CIVector(x: CGFloat(sim.fadeAmount), y: CGFloat(sim.fadeAmount), z: CGFloat(sim.fadeAmount), w: 0)
            result = fade.outputImage ?? result
        }

        // 6. Bloom / halation
        if sim.bloomIntensity > 0 {
            let bloom = CIFilter.bloom()
            bloom.inputImage = result
            bloom.intensity = sim.bloomIntensity
            bloom.radius = sim.bloomRadius
            result = bloom.outputImage?.cropped(to: image.extent) ?? result
        }

        // 7. Haze — cool-white atmospheric veil cross-dissolved over the image
        if sim.hazeAmount > 0 {
            let mist = CIImage(color: CIColor(red: 0.96, green: 0.97, blue: 1.0))
                .cropped(to: image.extent)
            if let blend = CIFilter(name: "CIDissolveTransition") {
                blend.setValue(result, forKey: kCIInputImageKey)
                blend.setValue(mist,   forKey: kCIInputTargetImageKey)
                blend.setValue(NSNumber(value: sim.hazeAmount * 0.65), forKey: kCIInputTimeKey)
                result = blend.outputImage?.cropped(to: image.extent) ?? result
            }
        }

        // 8. Vignette
        if sim.vignetteIntensity > 0 {
            let vignette = CIFilter.vignette()
            vignette.inputImage = result
            vignette.intensity = sim.vignetteIntensity
            vignette.radius = 1.5
            result = vignette.outputImage ?? result
        }

        return result
    }

    // MARK: Push/Pull Processing

    nonisolated func applyPushPull(input: CIImage, stops: Float) -> CIImage {
        // Clamp to valid range
        let s = max(-2.0, min(3.0, stops))
        guard abs(s) > 0.05 else { return input }

        // Push: crush shadows, blow highlights, increase contrast
        // Pull: open shadows, protect highlights, lower contrast
        let shadowShift  = -s * 0.035   // push darkens shadows, pull lifts them
        let highlightShift = s * 0.04   // push clips highlights, pull brings them down
        let midShift     = s * 0.015

        let curve = CIFilter.toneCurve()
        curve.inputImage = input
        let s0 = CGFloat(max(0, min(1, 0.0 + shadowShift)))
        let s1 = CGFloat(max(0, min(1, 0.25 + shadowShift * 0.5)))
        let s2 = CGFloat(max(0, min(1, 0.5 + midShift)))
        let s3 = CGFloat(max(0, min(1, 0.75 + highlightShift * 0.5)))
        let s4 = CGFloat(max(0, min(1, 1.0 + highlightShift)))
        curve.point0 = CGPoint(x: 0,    y: s0)
        curve.point1 = CGPoint(x: 0.25, y: s1)
        curve.point2 = CGPoint(x: 0.5,  y: s2)
        curve.point3 = CGPoint(x: 0.75, y: s3)
        curve.point4 = CGPoint(x: 1,    y: s4)
        return curve.outputImage ?? input
    }

    // MARK: Anamorphic Flares

    nonisolated func applyAnamorphicFlare(input: CIImage) -> CIImage {
        let extent = input.extent

        // 1. Extract bright highlights via a luminance threshold
        let highlight = CIFilter.colorMatrix()
        highlight.inputImage = input
        // Keep only pixels above ~0.82 luminance by biasing heavily negative then clamping
        highlight.rVector = CIVector(x: 3, y: 0, z: 0, w: 0)
        highlight.gVector = CIVector(x: 0, y: 3, z: 0, w: 0)
        highlight.bVector = CIVector(x: 0, y: 0, z: 3, w: 0)
        highlight.biasVector = CIVector(x: -2.2, y: -2.2, z: -2.2, w: 0)
        // Clamp the VALUES to 0…1: everything below the threshold goes
        // negative, and negative light screen-blended back darkened the whole
        // frame and wiped out its blue. (.clamped(to:) only extends edges.)
        let bright = (highlight.outputImage ?? input)
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            .clamped(to: extent)

        // 2. Horizontal motion blur — wide streak
        let blur = CIFilter.motionBlur()
        blur.inputImage = bright
        blur.radius = 220
        blur.angle = 0  // horizontal
        let streaked = blur.outputImage?.clamped(to: extent) ?? bright

        // 3. Tint the streak blue/cyan
        let tint = CIFilter.colorMatrix()
        tint.inputImage = streaked
        tint.rVector = CIVector(x: 0.3, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: 0.6, z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: 1.4, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let tinted = (tint.outputImage ?? streaked)
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            .clamped(to: extent)

        // 4. Screen blend over original
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = tinted
        screen.backgroundImage = input
        return screen.outputImage?.cropped(to: extent) ?? input
    }

    // MARK: Film Randomization

    nonisolated func applyFilmRandomization(input: CIImage, seed: UInt64) -> CIImage {
        var rng = seed
        func nextFloat(min: Float, max: Float) -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let t = Float(rng >> 33) / Float(UInt32.max)
            return min + t * (max - min)
        }

        var image = input

        // Random temperature shift ±150K
        let tempShift = nextFloat(min: -150, max: 150)
        let temp = CIFilter.temperatureAndTint()
        temp.inputImage = image
        temp.neutral = CIVector(x: 6500, y: 0)
        temp.targetNeutral = CIVector(x: CGFloat(6500 + tempShift), y: CGFloat(nextFloat(min: -4, max: 4)))
        image = temp.outputImage ?? image

        // Random micro-vignette
        let vigStrength = nextFloat(min: 0, max: 0.25)
        let vignette = CIFilter.vignette()
        vignette.inputImage = image
        vignette.intensity = vigStrength
        vignette.radius = nextFloat(min: 1.2, max: 2.0)
        image = vignette.outputImage ?? image

        // Random subtle color bias (film batch variation)
        let rb = nextFloat(min: -0.012, max: 0.012)
        let gb = nextFloat(min: -0.008, max: 0.008)
        let bb = nextFloat(min: -0.012, max: 0.012)
        let bias = CIFilter.colorMatrix()
        bias.inputImage = image
        bias.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        bias.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        bias.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        bias.biasVector = CIVector(x: CGFloat(rb), y: CGFloat(gb), z: CGFloat(bb), w: 0)
        image = bias.outputImage ?? image

        return image
    }

    // MARK: Filter Building Blocks

    nonisolated func toneCurve(input: CIImage, shadows: Float, mid: Float, highlights: Float) -> CIImage {
        let curve = CIFilter.toneCurve()
        curve.inputImage = input
        curve.point0 = CGPoint(x: 0.0, y: max(0.0, min(1.0, 0.0 + CGFloat(shadows))))
        curve.point1 = CGPoint(x: 0.25, y: max(0.0, min(1.0, 0.25 + CGFloat(shadows * 0.5))))
        curve.point2 = CGPoint(x: 0.5, y: max(0.0, min(1.0, 0.5 + CGFloat(mid))))
        curve.point3 = CGPoint(x: 0.75, y: max(0.0, min(1.0, 0.75 + CGFloat(highlights * 0.5))))
        curve.point4 = CGPoint(x: 1.0, y: max(0.0, min(1.0, 1.0 + CGFloat(highlights))))
        return curve.outputImage ?? input
    }

    nonisolated func claritySharpen(input: CIImage) -> CIImage {
        let filter = CIFilter.unsharpMask()
        filter.inputImage = input
        filter.intensity = 0.6
        filter.radius = 1.5
        return filter.outputImage ?? input
    }

    /// Isolate one of R/G/B as its own grayscale-in-channel image. Used by
    /// circuitBend to separate planes before shifting them spatially.
    nonisolated private func isolateChannel(_ image: CIImage, channel: Int) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
        let rOn  = CIVector(x: 1, y: 0, z: 0, w: 0)
        let gOn  = CIVector(x: 0, y: 1, z: 0, w: 0)
        let bOn  = CIVector(x: 0, y: 0, z: 1, w: 0)
        m.rVector = channel == 0 ? rOn : zero
        m.gVector = channel == 1 ? gOn : zero
        m.bVector = channel == 2 ? bOn : zero
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage ?? image
    }

    /// Circuit-bent digicam look. Built from stock CIFilters so it works at
    /// live-preview rate. The signature elements:
    ///   • RGB plane separation (red shifts right, blue shifts left) — gives
    ///     the chromatic-fringe glitch reads as "wrong sensor readout"
    ///   • Posterize to a few levels per channel — fakes a broken DAC's stepped
    ///     output, the source of the banded color smears on real bent cams
    ///   • Saturation/contrast crank + magenta hue shift — pushes the palette
    ///     into the impossible-color zone these mods produce
    ///   • Crushed shadows + highlight clip — matches the under-bias that
    ///     bent sensors usually drift to
    ///   • `heavy: true` cranks all knobs and overlays hard scan lines for
    ///     a more outright-broken read.
    /// Single-pass Metal warp kernel for the ripple glitch. Loaded lazily from
    /// a PRECOMPILED metallib shipped as a bundle resource (source lives in
    /// shaders/Ripple.ci.metal; rebuild with scripts/build-shaders.sh). Device
    /// and simulator need different AIR targets, hence two files. Shipping the
    /// compiled kernel means normal builds never need the flaky Metal Toolchain.
    /// Double-optional: nil = not yet attempted, .some(nil) = attempted &
    /// unavailable (→ caller falls back to the composite ripple).
    nonisolated(unsafe) static var _rippleKernel: CIWarpKernel?? = nil
    nonisolated static func rippleKernel() -> CIWarpKernel? {
        if let attempted = _rippleKernel { return attempted }
        var loaded: CIWarpKernel? = nil
        #if targetEnvironment(simulator)
        let libName = "Ripple-sim"
        #else
        let libName = "Ripple-ios"
        #endif
        if let url = Bundle.main.url(forResource: libName, withExtension: "metallib"),
           let data = try? Data(contentsOf: url) {
            loaded = try? CIWarpKernel(functionName: "rippleWarp", fromMetalLibraryData: data)
        }
        _rippleKernel = .some(loaded)
        return loaded
    }

    // MARK: - Physically-modelled print processes (Metal)

    enum PrintProcess {
        case cyanotype, daguerreotype, tintype, platinum, vanDyke, saltPrint

        /// (spectral weights, exposure, contrast, dye at Dmax, paper, coating)
        /// Colours are LINEAR RGB.
        var params: (CIVector, Float, Float, CIVector, CIVector, Float) {
            switch self {
            case .cyanotype:
                // Blue/UV-sensitive; Prussian blue (sRGB ≈ 8,38,92) on cream
                // rag paper (≈ 242,238,226); long tonal scale; hand-coated.
                return (CIVector(x: 0.05, y: 0.30, z: 0.65), 0.0, 0.95,
                        CIVector(x: 0.0024, y: 0.019, z: 0.107),
                        CIVector(x: 0.888, y: 0.855, z: 0.760), 0.08)
            case .daguerreotype:
                // Strongly blue-sensitive; near-neutral silver-mercury image
                // (≈ 28,26,24) on a polished silver plate (≈ 222,226,232).
                return (CIVector(x: 0.02, y: 0.18, z: 0.80), 0.2, 1.35,
                        CIVector(x: 0.011, y: 0.010, z: 0.009),
                        CIVector(x: 0.730, y: 0.760, z: 0.810), 0.04)
            case .tintype:
                // Collodion sees blue only. The "paper" is the creamy silver
                // deposit (≈ 200,195,180); full density is the black-japanned
                // iron showing through (≈ 20,17,14). Poured by hand: uneven.
                return (CIVector(x: 0.0, y: 0.15, z: 0.85), 0.3, 1.25,
                        CIVector(x: 0.007, y: 0.0056, z: 0.0044),
                        CIVector(x: 0.578, y: 0.546, z: 0.457), 0.12)
            case .platinum:
                // Platinum/palladium: famously long, soft tonal scale; warm
                // neutral blacks (≈ 45,38,32) on warm white rag (≈ 240,232,215).
                return (CIVector(x: 0.10, y: 0.35, z: 0.55), 0.0, 0.80,
                        CIVector(x: 0.026, y: 0.019, z: 0.015),
                        CIVector(x: 0.871, y: 0.807, z: 0.680), 0.05)
            case .vanDyke:
                // Van Dyke brown (iron-silver): deep chocolate (≈ 52,30,18)
                // on cream paper (≈ 238,230,212).
                return (CIVector(x: 0.05, y: 0.30, z: 0.65), 0.0, 1.0,
                        CIVector(x: 0.034, y: 0.012, z: 0.006),
                        CIVector(x: 0.855, y: 0.791, z: 0.658), 0.09)
            case .saltPrint:
                // Salted paper (Talbot, 1840s): reddish-purple browns
                // (≈ 90,52,40), soft and matte, image sunk into the fibres.
                return (CIVector(x: 0.05, y: 0.30, z: 0.65), -0.2, 0.85,
                        CIVector(x: 0.102, y: 0.034, z: 0.021),
                        CIVector(x: 0.840, y: 0.770, z: 0.640), 0.10)
            }
        }
    }

    nonisolated(unsafe) static var _filmKernels: [String: CIColorKernel?] = [:]
    nonisolated static let filmKernelLock = NSLock()
    /// A colour kernel from FilmProcess.metallib (cached; nil if unavailable).
    nonisolated static func filmKernel(_ name: String) -> CIColorKernel? {
        filmKernelLock.lock(); defer { filmKernelLock.unlock() }
        if let cached = _filmKernels[name] { return cached }
        var loaded: CIColorKernel? = nil
        #if targetEnvironment(simulator)
        let libName = "FilmProcess-sim"
        #else
        let libName = "FilmProcess-ios"
        #endif
        if let url = Bundle.main.url(forResource: libName, withExtension: "metallib"),
           let data = try? Data(contentsOf: url) {
            loaded = try? CIColorKernel(functionName: name, fromMetalLibraryData: data)
        }
        _filmKernels[name] = .some(loaded)
        return loaded
    }
    nonisolated static func printKernel() -> CIColorKernel? { filmKernel("densityPrint") }

    /// Developer exhaustion / adjacency effects (see filmDevelop in
    /// FilmProcess.ci.metal). Diffusion distances scale with the frame, so the
    /// live preview and the full-res photo match.
    nonisolated func applyDevelopment(_ input: CIImage, strength: Float) -> CIImage {
        guard strength > 0, let k = CameraManager.filmKernel("filmDevelop") else { return input }
        let extent = input.extent
        let size = Double(max(extent.width, extent.height))
        let luma = input.applyingFilter("CISRGBToneCurveToLinear")
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            ])
            .clampedToExtent()
        let near = luma.applyingGaussianBlur(sigma: size * 0.006).cropped(to: extent)
        let far = luma.applyingGaussianBlur(sigma: size * 0.035).cropped(to: extent)
        return k.apply(extent: extent, arguments: [input, near, far, CGFloat(min(max(strength, 0), 1))]) ?? input
    }

    /// Isotropic grain noise for the film-grain kernel: white noise blurred
    /// into round clumps of `sigma` px, re-normalized to a fixed spread
    /// (std ≈ 0.144, i.e. half of uniform noise — fits 8-bit), centred on
    /// 0.5, independent per channel. (Enlarging a pixel-noise texture, as
    /// before, kept its square grid: blocky, artificial grain.)
    nonisolated static func noiseField(_ extent: CGRect, sigma: CGFloat) -> CIImage {
        let ox = CGFloat(Int.random(in: 0...8192)), oy = CGFloat(Int.random(in: 0...8192))
        guard var n = CIFilter.randomGenerator().outputImage else {
            return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        }
        n = n.transformed(by: CGAffineTransform(translationX: ox, y: oy))
        let q = (sigma * 4).rounded() / 4                     // cache key (¼ px steps)
        if q > 0.3 { n = n.applyingGaussianBlur(sigma: Double(q)) }
        // Measured, not derived: Core Image's blur doesn't follow the
        // textbook variance formula, and CIColorMatrix's bias didn't apply.
        let (mean, std) = noiseStats(q)
        guard let k = CameraManager.filmKernel("normalizeNoise") else { return n.cropped(to: extent) }
        let gain = 0.1443 / max(std, 1e-4)                    // half the raw spread (fits 8-bit)
        return (k.apply(extent: extent, arguments: [n.cropped(to: extent), CGFloat(mean), CGFloat(gain)]) ?? n)
            .cropped(to: extent)
    }

    private static let statsLock = NSLock()
    nonisolated(unsafe) private static var statsCache: [CGFloat: (Float, Float)] = [:]
    /// Mean and std of the blurred noise at this blur size (measured once on a patch).
    nonisolated static func noiseStats(_ sigma: CGFloat) -> (Float, Float) {
        statsLock.lock(); if let c = statsCache[sigma] { statsLock.unlock(); return c }; statsLock.unlock()
        var n = CIFilter.randomGenerator().outputImage ?? CIImage(color: .gray)
        if sigma > 0.3 { n = n.applyingGaussianBlur(sigma: Double(sigma)) }
        let side = 256
        var buf = [Float](repeating: 0, count: side * side * 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
        ctx.render(n, toBitmap: &buf, rowBytes: side * 16, bounds: CGRect(x: 0, y: 0, width: side, height: side),
                   format: .RGBAf, colorSpace: nil)
        var sum: Float = 0, sq: Float = 0, cnt: Float = 0
        for i in stride(from: 0, to: buf.count, by: 4) { for c in 0..<3 { sum += buf[i + c]; sq += buf[i + c] * buf[i + c]; cnt += 1 } }
        let mean = sum / cnt, std = max(sq / cnt - mean * mean, 0).squareRoot()
        statsLock.lock(); statsCache[sigma] = (mean, std); statsLock.unlock()
        return (mean, std)
    }

    /// Grain sizes (px) for an image: tuned on the ~2000 px preview and
    /// scaled with the frame, so a 48MP photo matches the preview.
    nonisolated static func grainSigmas(_ extent: CGRect, amount a: CGFloat, size k: CGFloat = 1) -> (fine: CGFloat, coarse: CGFloat, chroma: CGFloat) {
        let res = max(1, max(extent.width, extent.height) / 2000)
        let size = (1.0 + a * 2.0) * res * k        // grows with the amount and the stock's speed
        return (0.35 * size, 1.1 * size, 1.2 * size)       // fine grain; subtle clumps; soft dye clouds
    }

    /// Physically-modelled grain (see FilmProcess.ci.metal).
    nonisolated func physicalGrain(_ input: CIImage, amount a: CGFloat,
                                   fine: CIImage, coarse: CIImage, chroma: CIImage,
                                   character g: GrainCharacter = .standard) -> CIImage? {
        guard let k = CameraManager.filmKernel("filmGrain") else { return nil }
        let extent = input.extent
        return k.apply(extent: extent, arguments: [input, fine.cropped(to: extent), coarse.cropped(to: extent),
                                                   chroma.cropped(to: extent), a * 1.2 * g.strength, g.chroma, g.clump])
    }

    /// Context-aware grain: grain follows how much light there was, like
    /// film shot in dim light (underexposed / pushed, a thin negative). The
    /// capture ISO says it directly; frame brightness alone doesn't (auto
    /// exposure makes most frames similarly bright). ISO 50 ≈ 0.75×,
    /// 100 ≈ 0.85×, 800 ≈ 1.5×, 3200+ ≈ 1.8×; a little more in dark frames.
    nonisolated static func contextGrainScale(iso: Float?, luma: Float?) -> Float {
        guard let iso, iso > 0 else {
            // No ISO (older photos): fall back to frame brightness, gently.
            guard let l = luma else { return 1 }
            return max(0.7, min(1.6, 1.45 - l * 1.0))
        }
        // Gentle: the sensor's own noise is cleaned up before grain at high
        // ISO, so this only tilts the amount (it used to reach 1.8× on top of
        // digital noise — double noise exactly when it looks worst).
        var f = 0.92 + 0.08 * log2(max(iso, 25) / 100)
        if let l = luma, l < 0.18 { f *= 1.08 }
        return max(0.85, min(1.35, f))
    }

    /// At high ISO the frame already carries digital noise; smooth it a
    /// little before adding film grain so the grain replaces it instead of
    /// stacking on top (how a real film shot looks: grain, not speckle).
    nonisolated static func cleanSensorNoise(_ image: CIImage, iso: Float?) -> CIImage {
        guard let iso, iso >= 640 else { return image }
        let level = min(0.035, 0.008 * log2(iso / 320))
        return image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": level, "inputSharpness": 0.45])
            .cropped(to: image.extent)
    }

    /// Render `image` as a physical print process; nil if the kernel is missing.
    nonisolated func densityPrint(_ image: CIImage, process: PrintProcess) -> CIImage? {
        guard let kernel = CameraManager.printKernel() else { return nil }
        let extent = image.extent
        // Coating unevenness: soft, large-scale noise (fixed pattern).
        let sigma = Double(max(extent.width, extent.height)) * 0.02
        let noise = (CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)))
            .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: extent)
        let p = process.params
        return kernel.apply(extent: extent, arguments: [image, noise, p.0, p.1, p.2, p.3, p.4, p.5])
    }

    /// Build (and cache) the rainbow gradient LUT used by the circuit-bent
    /// thermal map. A 256×1 horizontal gradient sweeping the full spectrum;
    /// CIColorMap indexes pixel luminance into it. Cached because the
    /// CGContext draw is too expensive to repeat every frame.
    nonisolated func thermalGradient() -> CIImage {
        if let g = cachedThermalGradient { return g }
        let width = 256, height = 1
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CIImage.empty() }

        // INTERLEAVED circuit-bend palette — warm and cool colours alternate
        // so that even if the index concentrates in one region, it spans
        // contrasting hues instead of a single family. No colour dominates.
        // (A monotonic rainbow made whatever sat at mid-luminance take over —
        // magenta, then green; interleaving breaks that.)
        let stops: [(CGFloat, UIColor)] = [
            (0.00, UIColor(red: 0.03, green: 0.0,  blue: 0.08, alpha: 1)), // near-black
            (0.10, UIColor(red: 0.0,  green: 0.35, blue: 1.0,  alpha: 1)), // blue
            (0.20, UIColor(red: 1.0,  green: 0.55, blue: 0.0,  alpha: 1)), // orange
            (0.30, UIColor(red: 0.0,  green: 1.0,  blue: 0.55, alpha: 1)), // green
            (0.40, UIColor(red: 1.0,  green: 0.0,  blue: 0.7,  alpha: 1)), // magenta
            (0.50, UIColor(red: 0.0,  green: 0.85, blue: 1.0,  alpha: 1)), // cyan
            (0.60, UIColor(red: 1.0,  green: 0.85, blue: 0.0,  alpha: 1)), // yellow
            (0.70, UIColor(red: 0.45, green: 0.0,  blue: 1.0,  alpha: 1)), // violet
            (0.80, UIColor(red: 1.0,  green: 0.15, blue: 0.15, alpha: 1)), // red
            (0.90, UIColor(red: 0.1,  green: 0.7,  blue: 1.0,  alpha: 1)), // sky blue
            (1.00, UIColor(red: 1.0,  green: 1.0,  blue: 1.0,  alpha: 1)), // white hot
        ]
        let cgColors = stops.map { $0.1.cgColor } as CFArray
        let locations = stops.map { $0.0 }
        guard let grad = CGGradient(colorsSpace: cs, colors: cgColors, locations: locations) else {
            return CIImage.empty()
        }
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: width, y: 0),
                               options: [])
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        let ci = CIImage(cgImage: cg)
        cachedThermalGradient = ci
        return ci
    }

    /// - Parameter speckleScale: 0…1 grain amount from the slider. 0 = no
    ///   speckle (clean thermal gradient); 1 = full thermal-photo grain.
    nonisolated func circuitBend(_ image: CIImage, heavy: Bool = false, speckleScale: CGFloat = 1.0) -> CIImage {
        let extent = image.extent

        // Circuit-bend look: a CONTROLLED rainbow palette (so no single colour
        // dominates) driven by brightness, but scrambled by a low-frequency
        // CHAOS field so the colour mapping is non-uniform and broken across
        // the frame — not a clean linear sweep. Original luminance is blended
        // back so detail/structure always survives.
        let posterLevels: Int    = heavy ? 8 : 12       // colour bands
        let preContrast: Float   = heavy ? 1.35 : 1.20
        // Two chaos octaves so the frame is ALWAYS richly multi-coloured —
        // big blobs set broad colour regions, fine blobs break them up. This
        // is what stops a uniform scene from bathing in a single flat colour.
        // Higher chaos amplitude spreads the colour INDEX across the whole
        // gradient (instead of piling up at mid-luminance, which made one
        // colour family — magenta — dominate). The index is mostly chaos-
        // driven now, so colour varies by region rather than tracking the
        // scene's (usually mid) brightness.
        let chaosCoarse: CGFloat = heavy ? 1.30 : 1.10  // broad colour regions
        let chaosFine: CGFloat   = heavy ? 0.60 : 0.50  // finer break-up
        let sigmaCoarse: Double  = heavy ? 18 : 26
        let sigmaFine: Double    = heavy ? 5  : 8
        let postSat: Float       = heavy ? 1.45 : 1.25
        let speckleAmp: CGFloat  = (heavy ? 0.10 : 0.06) * max(0, speckleScale)
        let fringeShift: CGFloat = heavy ? 6 : 3

        // ── 1. Grayscale luminance (keep a clean copy for detail) ───────
        let gray = CIFilter.colorControls()
        gray.inputImage = image
        gray.saturation = 0.0
        gray.contrast = preContrast
        gray.brightness = -0.02
        let origLuma = (gray.outputImage ?? image).cropped(to: extent)
        var index = origLuma

        // ── 2. CHAOS: two octaves of blurred-noise offset to the INDEX ──
        // Each octave pushes regions to different gradient positions, so the
        // brightness→colour mapping is non-uniform across the frame and the
        // result is always full of varied colour — never one flat hue. THIS
        // is the look; it does NOT need the context-aware wild animator.
        func addChaosOctave(_ amp: CGFloat, _ sigma: Double, _ seedShift: CGFloat) {
            guard amp > 0, let rnd = CIFilter(name: "CIRandomGenerator"),
                  let raw = rnd.outputImage else { return }
            // seedShift samples a different region of the (infinite) noise so
            // the two octaves don't correlate.
            let blobs = raw.transformed(by: CGAffineTransform(translationX: seedShift, y: seedShift))
                .cropped(to: extent)
                .applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            let mono = CIFilter.colorControls()
            mono.inputImage = blobs
            mono.saturation = 0.0
            let scale = CIFilter.colorMatrix()
            scale.inputImage = mono.outputImage
            scale.rVector = CIVector(x: amp, y: 0, z: 0, w: 0)
            scale.gVector = CIVector(x: 0, y: amp, z: 0, w: 0)
            scale.bVector = CIVector(x: 0, y: 0, z: amp, w: 0)
            scale.biasVector = CIVector(x: -amp / 2, y: -amp / 2, z: -amp / 2, w: 0)
            let add = CIFilter.additionCompositing()
            add.inputImage = scale.outputImage
            add.backgroundImage = index
            index = (add.outputImage ?? index).cropped(to: extent)
        }
        addChaosOctave(chaosCoarse, sigmaCoarse, 0)
        addChaosOctave(chaosFine, sigmaFine, 1024)

        // ── 3. Speckle: fine noise into the index (grain slider) ────────
        if speckleAmp > 0, let rnd = CIFilter(name: "CIRandomGenerator"),
           let raw = rnd.outputImage {
            let mono = CIFilter.colorControls()
            mono.inputImage = raw.cropped(to: extent)
            mono.saturation = 0.0
            let scale = CIFilter.colorMatrix()
            scale.inputImage = mono.outputImage
            scale.rVector = CIVector(x: speckleAmp, y: 0, z: 0, w: 0)
            scale.gVector = CIVector(x: 0, y: speckleAmp, z: 0, w: 0)
            scale.bVector = CIVector(x: 0, y: 0, z: speckleAmp, w: 0)
            scale.biasVector = CIVector(x: -speckleAmp / 2, y: -speckleAmp / 2, z: -speckleAmp / 2, w: 0)
            let add = CIFilter.additionCompositing()
            add.inputImage = scale.outputImage
            add.backgroundImage = index
            index = (add.outputImage ?? index).cropped(to: extent)
        }

        // ── 4. Posterize the index into discrete bands ──────────────────
        if let poster = CIFilter(name: "CIColorPosterize") {
            poster.setValue(index, forKey: kCIInputImageKey)
            poster.setValue(posterLevels, forKey: "inputLevels")
            index = poster.outputImage ?? index
        }

        // ── 5. Index → colour via the balanced rainbow gradient LUT ─────
        var colorRGB = index
        if let map = CIFilter(name: "CIColorMap") {
            map.setValue(index, forKey: kCIInputImageKey)
            map.setValue(thermalGradient(), forKey: "inputGradientImage")
            colorRGB = map.outputImage ?? index
        }

        // ── 6. Restore ORIGINAL luminance for detail (colour blend) ─────
        // CIColorBlendMode = luminosity of backdrop + hue/sat of source.
        let cblend = CIFilter.colorBlendMode()
        cblend.inputImage = colorRGB           // wild colour
        cblend.backgroundImage = origLuma      // real detail/structure
        var result = (cblend.outputImage ?? colorRGB).cropped(to: extent)

        // ── 7. Polish: saturation ───────────────────────────────────────
        let polish = CIFilter.colorControls()
        polish.inputImage = result
        polish.saturation = postSat
        result = (polish.outputImage ?? result).cropped(to: extent)

        // ── D. Subtle channel offset for the glitchy chromatic fringe. ──
        // clampedToExtent() so the shifted channels smear their edge pixels
        // instead of leaving a transparent gap (which flattens to a black
        // line in the saved photo).
        let red  = isolateChannel(result, channel: 0).clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: fringeShift, y: 0))
        let grn  = isolateChannel(result, channel: 1)
        let blue = isolateChannel(result, channel: 2).clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -fringeShift, y: 0))
        // MAX, not add: each plane holds one channel, so max rebuilds the
        // colour while alpha stays 1. Adding summed alpha to 3, which broke
        // the live preview (Bent frames were dropped; the camera showed
        // through) and blanked Bent++ entirely.
        let a = CIFilter.maximumCompositing(); a.inputImage = red; a.backgroundImage = grn
        let b = CIFilter.maximumCompositing(); b.inputImage = a.outputImage ?? grn; b.backgroundImage = blue
        result = (b.outputImage ?? result).cropped(to: extent)

        // ── E. Heavy mode only: hard horizontal scan lines on top ───────
        if heavy {
            let stripPattern = horizontalLines(period: 3, dark: CIColor(red: 0.35, green: 0.35, blue: 0.4), extent: extent)
            let mult = CIFilter.multiplyCompositing()
            mult.inputImage = stripPattern
            mult.backgroundImage = result
            result = (mult.outputImage ?? result).cropped(to: extent)
        }

        return result.cropped(to: extent)
    }

    /// Horizontal interlacing scanlines — the old-camcorder / CCD-readout
    /// look. Static (not random): a fixed-period dark stripe pattern
    /// multiplied over the image. Used by DigiCam when its context-aware
    /// "lines" toggle is on. Deliberately subtle so it reads as a CRT/LCD
    /// artifact, not a glitch.
    /// Horizontal line pattern: `period` px white, `period` px `dark`.
    /// (The old trick — a checkerboard stretched 9999× wide — rendered as
    /// nothing, which blanked Bent++ and DigiCam's scanlines.)
    nonisolated func horizontalLines(period: CGFloat, dark: CIColor, extent: CGRect) -> CIImage {
        guard let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": dark,
            "inputWidth": period,
            "inputSharpness": 1,
            "inputCenter": CIVector(x: 0, y: 0),
        ])?.outputImage else { return CIImage(color: .white).cropped(to: extent) }
        // Stripes are vertical; turn them 90° to run across the frame.
        return stripes.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).cropped(to: extent)
    }

    nonisolated func applyScanlines(input: CIImage) -> CIImage {
        let extent = input.extent
        guard extent.height > 1 else { return input }
        // 2px-on / 2px-off dark lines — clearly visible interlacing.
        let pattern = horizontalLines(period: 2, dark: CIColor(red: 0.6, green: 0.6, blue: 0.66), extent: extent)
        let mult = CIFilter.multiplyCompositing()
        mult.inputImage = pattern
        mult.backgroundImage = input
        return (mult.outputImage ?? input).cropped(to: extent)
    }

    /// Per-frame random glitch overlay for the circuit-bent sims. Called only
    /// when grain is enabled. Each invocation rolls fresh randomness so the
    /// glitches flicker and jump frame-to-frame like a genuinely faulty board.
    ///   • `heavy`: bigger ceilings on displacement, harder dropouts
    ///   • `wild` (context-aware grain on): also randomize hue, exposure and
    ///     color cast each frame — the sensor "drifts" unpredictably
    ///   • `intensity` 0…1: the "weirdness" dial driven by the grain slider.
    ///     Scales band count, shift magnitude, glitch probability and the
    ///     wild-mode swing ranges. Near 0 = barely-there occasional twitch;
    ///     1 = full chaos.
    /// All built from stock CIFilters so it survives at live-preview rate.
    nonisolated func circuitBentGlitch(_ image: CIImage, heavy: Bool, wild: Bool, intensity: CGFloat = 1.0,
                                       flatten: Bool = true) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let t = max(0.0, min(1.0, intensity))            // clamp the dial
        let tF = Float(t)

        // FLATTEN the incoming image to pixels first. The base circuit-bend
        // sim is already a deep filter graph (two blurs, colour-map, blend);
        // stacking the glitch's many composite passes on top at full capture
        // resolution (48MP) overflowed Core Image and rendered BLACK. Baking
        // the base to a CGImage here gives the glitch a shallow, bounded graph
        // so it renders reliably at any resolution. The live preview passes
        // flatten:false — at half-res the graph is fine, and a synchronous
        // GPU→CPU readback every frame would tank the viewfinder framerate.
        var img: CIImage
        if flatten, let cg = photoContext.createCGImage(image, from: extent) {
            img = CIImage(cgImage: cg)
        } else {
            img = image
        }

        // ── 1. Signal RIPPLE: rows shifted by a smooth wave ─────────────
        // Real bent-camera/databending tearing = each row displaced by a
        // value that varies CONTINUOUSLY down the frame, so the image ripples
        // and tears organically. Two sine octaves + a little per-strip noise
        // give a wobble that reads as genuine signal corruption — not random
        // hard bands and never fake black lines. Strip count kept modest so
        // the composite graph stays shallow (no Metal kernel dependency).
        // Bent++ ripples much harder than Bent — bigger amplitude and more
        // wave cycles so the whole frame churns instead of gently wobbling.
        let rippleAmp: CGFloat = (heavy ? 130 : 28) * t
        if rippleAmp > 0.5 {
            let freq1 = heavy ? Float.random(in: 3...6)  : Float.random(in: 1.5...3.5)
            let freq2 = heavy ? Float.random(in: 9...18) : Float.random(in: 5...11)
            let phase = Float.random(in: 0...(2 * .pi))
            if let kernel = CameraManager.rippleKernel() {
                // Fast path: single-pass Metal warp — per-pixel smooth ripple.
                let maxShift = rippleAmp * 1.2 + 5
                if let warped = kernel.apply(
                    extent: extent,
                    roiCallback: { _, rect in rect.insetBy(dx: -maxShift, dy: 0) },
                    image: img.clampedToExtent(),
                    arguments: [Float(rippleAmp), freq1, freq2, phase, Float(extent.height)]
                ) {
                    img = warped.cropped(to: extent)
                }
            } else {
                // Fallback: composite strip ripple (no Metal kernel available).
                let cf1 = CGFloat(freq1), cf2 = CGFloat(freq2), cph = CGFloat(phase)
                let stripCount = heavy ? 22 : 16
                let stripH = max(1, extent.height / CGFloat(stripCount))
                for i in 0..<stripCount {
                    let y0 = extent.minY + CGFloat(i) * stripH
                    let f = CGFloat(i) / CGFloat(stripCount)
                    let wave = sin(f * cf1 * 2 * .pi + cph) * 0.7
                             + sin(f * cf2 * 2 * .pi + cph * 1.7) * 0.3
                    let shift = wave * rippleAmp + CGFloat.random(in: -rippleAmp * 0.1...rippleAmp * 0.1)
                    let rect = CGRect(x: extent.minX, y: y0 - 0.5, width: extent.width, height: stripH + 1)
                    let strip = img.clampedToExtent()
                        .transformed(by: CGAffineTransform(translationX: shift, y: 0))
                        .cropped(to: rect)
                    let over = CIFilter.sourceOverCompositing()
                    over.inputImage = strip
                    over.backgroundImage = img
                    img = (over.outputImage ?? img).cropped(to: extent)
                }
            }
        }

        // ── 2. Occasional big "data jump" tears on top of the ripple ────
        // A few rows yanked far sideways = the moment the signal glitches
        // hard. Sparse; scales with weirdness.
        let jumpBands = Int((CGFloat(heavy ? 5 : 3) * t).rounded())
        for _ in 0..<max(0, jumpBands) {
            let bandH = CGFloat.random(in: 4...(heavy ? 36 : 20))
            let bandY = CGFloat.random(in: extent.minY...max(extent.minY, extent.maxY - bandH))
            let shift = CGFloat.random(in: -1...1) * (heavy ? 150 : 80) * t
            let rect = CGRect(x: extent.minX, y: bandY, width: extent.width, height: bandH)
            let band = img.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: shift, y: 0))
                .cropped(to: rect)
            let over = CIFilter.sourceOverCompositing()
            over.inputImage = band
            over.backgroundImage = img
            img = (over.outputImage ?? img).cropped(to: extent)
        }

        // ── 3. Chromatic channel desync (looks like real signal bleed) ──
        if CGFloat.random(in: 0...1) < t * 0.9 {
            let jumpMax: CGFloat = (heavy ? 70 : 36) * t
            let jump = CGFloat.random(in: (jumpMax * 0.3)...max(jumpMax * 0.3 + 0.1, jumpMax))
            let red  = isolateChannel(img, channel: 0).clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: jump, y: 0))
            let gb   = isolateChannel(img, channel: 1)
            let blue = isolateChannel(img, channel: 2).clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -jump, y: 0))
            let a = CIFilter.maximumCompositing(); a.inputImage = red; a.backgroundImage = gb
            let b = CIFilter.maximumCompositing(); b.inputImage = a.outputImage ?? gb; b.backgroundImage = blue
            img = (b.outputImage ?? img).cropped(to: extent)
        }

        // ── 4. Wild mode: randomize light + color each frame ────────────
        // Swing ranges scale with weirdness so low t drifts gently.
        if wild {
            // Exposure swing — kept moderate so the frame doesn't blow out to
            // a flat color. Centered with a tighter range; the base sim is
            // already very bright/saturated so a little goes a long way.
            let exp = CIFilter.exposureAdjust()
            exp.inputImage = img
            exp.ev = Float.random(in: -0.9...0.9) * tF
            img = exp.outputImage ?? img

            // Hue can spin a full half-turn each frame at max — this is the
            // big chaos lever and it's safe (rotation never collapses values).
            let hue = CIFilter.hueAdjust()
            hue.inputImage = img
            hue.angle = Float.random(in: -3.14...3.14) * tF
            img = hue.outputImage ?? img

            // Color cast — moderate so it tints rather than floods.
            let castRange = 0.18 * t
            let m = CIFilter.colorMatrix()
            m.inputImage = img
            m.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
            m.biasVector = CIVector(x: CGFloat.random(in: -castRange...castRange),
                                    y: CGFloat.random(in: -castRange...castRange),
                                    z: CGFloat.random(in: -castRange...castRange),
                                    w: 0)
            img = m.outputImage ?? img

            // Saturation kick — never below 0.6 (so it doesn't gray out) and
            // capped so it doesn't push an already-saturated frame to a flat
            // primary.
            let cc = CIFilter.colorControls()
            cc.inputImage = img
            cc.saturation = 1.0 + (Float.random(in: -0.4...0.7)) * tF
            img = cc.outputImage ?? img
        }

        return img.cropped(to: extent)
    }

    /// Builds 8 fully-rasterised grain textures at `extent` on a background queue.
    /// Each texture is a CGImage-backed CIImage — zero filter graph evaluation when
    /// blended at preview time. Called lazily from the video-frame queue; skipped
    /// silently if a build is already in flight.
    nonisolated func buildGrainPreviewTextures(for extent: CGRect) {
        guard !grainPreviewBuilding, cachedGrainAmount > 0 else { return }
        grainPreviewBuilding = true
        DispatchQueue.global(qos: .utility).async { [self] in
            let a = CGFloat(max(0, min(0.35, cachedGrainAmount)))
            var textures: [CIImage] = []
            textures.reserveCapacity(8)
            // Same noise fields as the photo, baked once (no colour
            // management: these are data, not colours).
            let size = (cachedActiveCustomSim == nil ? cachedSim.grainCharacter : .standard).size
            let sg = Self.grainSigmas(extent, amount: a, size: size)
            let sigmas = [sg.fine, sg.fine, sg.fine, sg.fine, sg.coarse, sg.coarse, sg.chroma, sg.chroma]
            for sigma in sigmas {
                let field = Self.noiseField(extent, sigma: sigma)
                if let cg = photoContext.createCGImage(field, from: extent, format: .RGBA8, colorSpace: nil) {
                    textures.append(CIImage(cgImage: cg, options: [.colorSpace: NSNull()]))
                }
            }
            grainPreviewTextures = textures
            grainPreviewExtent   = extent
            grainPreviewSize     = size
            grainPreviewBuilding = false
        }
    }

    nonisolated func addGrain(input: CIImage, amount: Float, character gc: GrainCharacter = .standard) -> CIImage {
        guard amount > 0 else { return input }
        let a = CGFloat(max(0, min(0.35, amount)))
        let extent = input.extent

        // Random offset per call — CIRandomGenerator produces a fixed texture,
        // so we translate into a different region each time for true per-frame randomness
        let ox = CGFloat.random(in: 0...4096)
        let oy = CGFloat.random(in: 0...4096)
        guard let rawNoise = CIFilter.randomGenerator().outputImage else { return input }
        // Grain is sized to the FRAME, not to pixels: tuned on the ~2000 px
        // preview, so a 48MP photo gets ~4 px grains that look the same as
        // the preview. (Fixed 1–2 px grain at 48MP sat right on the finest
        // detail and read as digital noise: measured on the phone, grain 0.2
        // added noise ~1.1× the photo's own fine detail.)
        let res = max(1, max(extent.width, extent.height) / 2000)
        let noise = rawNoise
            .transformed(by: CGAffineTransform(translationX: ox, y: oy))
            .transformed(by: CGAffineTransform(scaleX: res, y: res))
            .cropped(to: extent)

        // Physical grain: round clumps sized to the frame (see grainSigmas).
        let sg = Self.grainSigmas(extent, amount: a, size: gc.size)
        if let g = physicalGrain(input, amount: a,
                                 fine: Self.noiseField(extent, sigma: sg.fine),
                                 coarse: Self.noiseField(extent, sigma: sg.coarse),
                                 chroma: Self.noiseField(extent, sigma: sg.chroma),
                                 character: gc) {
            return g.cropped(to: extent)
        }

        // Monochrome, centred at 0.5 so it both lightens and darkens
        let mono = CIFilter.colorControls()
        mono.inputImage = noise
        mono.saturation = 0.0
        mono.brightness = -0.5
        mono.contrast = Float(1.0 + a * 1.8)
        guard let monoNoise = mono.outputImage?.cropped(to: extent) else { return input }

        // Minimal blur — just enough to round pixel edges, not enough to cause blotchiness
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = monoNoise
        blur.radius = Float((0.4 + a * 0.6) * res)
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return input }

        // Soft light blend — more natural distribution than overlay, avoids clumping artifacts
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = blurred
        blend.backgroundImage = input
        guard let blended = blend.outputImage?.cropped(to: extent) else { return input }

        // Mix to control overall strength
        let strength = max(0.0, 1.0 - Double(a) * 1.5)
        let mix = CIFilter(name: "CIDissolveTransition", parameters: [
            kCIInputImageKey: blended,
            kCIInputTargetImageKey: input,
            "inputTime": NSNumber(value: strength)
        ])
        return mix?.outputImage?.cropped(to: extent) ?? blended
    }

    /// Sharp CCD-style digital noise — no blur, slight chroma component.
    /// Used by DigiCam instead of the film-grain pipeline.
    nonisolated func addDigitalNoise(input: CIImage, amount: Float) -> CIImage {
        guard amount > 0 else { return input }
        let a = max(0, min(0.5, amount))

        // 1. Raw random noise — keep it sharp (no blur = digital pixel noise)
        guard let noise = CIFilter.randomGenerator().outputImage?.cropped(to: input.extent) else { return input }

        // 2. Slight colour cast so it reads as CCD chroma noise (faint red/blue channels)
        let colorMatrix = CIFilter.colorMatrix()
        colorMatrix.inputImage = noise
        colorMatrix.rVector = CIVector(x: CGFloat(0.5 + a * 0.3), y: 0, z: 0, w: 0)
        colorMatrix.gVector = CIVector(x: 0, y: CGFloat(0.45), z: 0, w: 0)
        colorMatrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(0.5 + a * 0.3), w: 0)
        colorMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        colorMatrix.biasVector = CIVector(x: -0.25, y: -0.225, z: -0.25, w: 0)
        guard let colorNoise = colorMatrix.outputImage?.cropped(to: input.extent) else { return input }

        // 3. Screen blend (brightens selectively — looks like sensor hot pixels / amp noise)
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = colorNoise
        screen.backgroundImage = input
        guard let screened = screen.outputImage?.cropped(to: input.extent) else { return input }

        // 4. Mix: low amounts stay subtle, high amounts get gritty
        let mix = CIFilter(name: "CIDissolveTransition", parameters: [
            kCIInputImageKey: screened,
            kCIInputTargetImageKey: input,
            "inputTime": NSNumber(value: 1.0 - Double(a) * 1.8)
        ])
        return mix?.outputImage?.cropped(to: input.extent) ?? screened
    }

    /// Film light artifacts: light leaks, edge burns, and faint film scratches.
    /// Seeded so each capture gets a consistent but unique artifact pattern.
    nonisolated func applyLightArtifacts(input: CIImage, seed: UInt64) -> CIImage {
        let extent = input.extent
        var result = input

        // Simple LCG for repeatable per-shot randomness
        var s = seed &+ 0x9e3779b97f4a7c15
        func next() -> CGFloat {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(s >> 33) / 0x7fffffff
        }

        // ── Light leak ─────────────────────────────────────────────────────────
        // Warm/amber/pinkish gradient bleeding in from a random edge or corner
        let leakEdge = Int(next() * 4)   // 0=top 1=bottom 2=left 3=right
        let leakPos  = next()            // position along the edge
        let leakSpread = 0.25 + next() * 0.35
        let leakOpacity = 0.18 + next() * 0.28

        // Pick a leak color: amber, orange-red, or pink
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (1.0, 0.45, 0.05),   // amber-orange
            (1.0, 0.25, 0.10),   // orange-red
            (0.95, 0.15, 0.30),  // pink-red
            (1.0, 0.55, 0.0),    // golden yellow
        ]
        let col = palette[Int(next() * CGFloat(palette.count)) % palette.count]

        let w = extent.width, h = extent.height
        var p0: CIVector
        var p1: CIVector
        switch leakEdge {
        case 0:  // top
            p0 = CIVector(x: leakPos * w, y: h)
            p1 = CIVector(x: leakPos * w, y: h * (1 - leakSpread))
        case 1:  // bottom
            p0 = CIVector(x: leakPos * w, y: 0)
            p1 = CIVector(x: leakPos * w, y: h * leakSpread)
        case 2:  // left
            p0 = CIVector(x: 0, y: leakPos * h)
            p1 = CIVector(x: w * leakSpread, y: leakPos * h)
        default: // right
            p0 = CIVector(x: w, y: leakPos * h)
            p1 = CIVector(x: w * (1 - leakSpread), y: leakPos * h)
        }

        let leak = CIFilter.smoothLinearGradient()
        leak.point0 = CGPoint(x: p0.x, y: p0.y)
        leak.point1 = CGPoint(x: p1.x, y: p1.y)
        leak.color0 = CIColor(red: col.0, green: col.1, blue: col.2, alpha: leakOpacity)
        leak.color1 = CIColor(red: col.0, green: col.1, blue: col.2, alpha: 0)
        if let leakImg = leak.outputImage?.cropped(to: extent) {
            // Screen blend — light leak only brightens, never darkens
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = leakImg
            screen.backgroundImage = result
            result = screen.outputImage?.cropped(to: extent) ?? result
        }

        // ── Edge burn / secondary leak (50% chance) ────────────────────────────
        if next() > 0.5 {
            let burnEdge = (leakEdge + 1 + Int(next() * 3)) % 4
            let burnOpacity = 0.08 + next() * 0.14
            let burnSpread = 0.12 + next() * 0.15
            var b0, b1: CGPoint
            switch burnEdge {
            case 0:  b0 = CGPoint(x: w * 0.5, y: h);            b1 = CGPoint(x: w * 0.5, y: h * (1 - burnSpread))
            case 1:  b0 = CGPoint(x: w * 0.5, y: 0);            b1 = CGPoint(x: w * 0.5, y: h * burnSpread)
            case 2:  b0 = CGPoint(x: 0, y: h * 0.5);            b1 = CGPoint(x: w * burnSpread, y: h * 0.5)
            default: b0 = CGPoint(x: w, y: h * 0.5);            b1 = CGPoint(x: w * (1 - burnSpread), y: h * 0.5)
            }
            let burn = CIFilter.smoothLinearGradient()
            burn.point0 = b0; burn.point1 = b1
            // Burn is darker — multiply blend to darken edges slightly
            burn.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: burnOpacity)
            burn.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let burnImg = burn.outputImage?.cropped(to: extent) {
                let multiply = CIFilter.multiplyBlendMode()
                multiply.inputImage = burnImg
                multiply.backgroundImage = result
                // Use dissolve to mix burn in subtly
                if let darkened = multiply.outputImage?.cropped(to: extent) {
                    let mix = CIFilter(name: "CIDissolveTransition", parameters: [
                        kCIInputImageKey: darkened,
                        kCIInputTargetImageKey: result,
                        "inputTime": NSNumber(value: 0.6)
                    ])
                    result = mix?.outputImage?.cropped(to: extent) ?? result
                }
            }
        }

        return result
    }

    /// Applies faint vertical film scratches to the image.
    nonisolated func applyFilmScratches(input: CIImage, seed: UInt64) -> CIImage {
        let extent = input.extent
        let w = extent.width
        var result = input

        var rng = seed &+ 0xDEADBEEF_CAFEBABE
        func next() -> CGFloat {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(rng >> 33) / CGFloat(1 << 31)
        }

        // 1–3 scratches per frame
        let count = 1 + Int(next() * 2.99)
        for _ in 0..<count {
            let scratchX = next() * w + extent.origin.x
            let scratchWidth = 0.4 + next() * 1.2  // thin — 0.4 to 1.6pt
            let scratchOpacity = 0.06 + next() * 0.14
            let scratchRect = CGRect(x: scratchX, y: extent.origin.y, width: scratchWidth, height: extent.height)
            let scratchColor = CIColor(red: 1, green: 0.95, blue: 0.85, alpha: scratchOpacity)
            let scratchImg = CIImage(color: scratchColor).cropped(to: scratchRect)
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = scratchImg
            screen.backgroundImage = result
            result = screen.outputImage?.cropped(to: extent) ?? result
        }

        return result
    }

    nonisolated func applyColorCrosstalk(input: CIImage, amount: Float) -> CIImage {
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

    nonisolated func applyHalation(input: CIImage, amount: Float) -> CIImage {
        // Physical halation: only light above the highlight threshold, spread
        // at two radii, added back as red-orange light in linear space.
        if let ex = CameraManager.filmKernel("halationExtract"),
           let ap = CameraManager.filmKernel("halationApply") {
            let extent = input.extent
            let size = Double(max(extent.width, extent.height))
            if let energy = ex.apply(extent: extent, arguments: [input, 0.72]) {
                let e = energy.clampedToExtent()
                let near = e.applyingGaussianBlur(sigma: size * 0.004).cropped(to: extent)
                let far = e.applyingGaussianBlur(sigma: size * 0.03).cropped(to: extent)
                if let out = ap.apply(extent: extent, arguments: [input, energy, near, far, CGFloat(amount) * 2.2,
                                                                  CIVector(x: 1.0, y: 0.32, z: 0.08)]) {
                    return out
                }
            }
        }
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

    nonisolated func applyHighlightRolloff(input: CIImage, threshold: Float) -> CIImage {
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

    nonisolated func compositeDoubleExposure(base: CIImage, overlay: CIImage, opacity: Float, mask: UIImage? = nil) -> CIImage {
        // Scale base to match overlay extent if they differ
        var scaledBase = base
        let targetExtent = overlay.extent
        if base.extent.size != targetExtent.size {
            let sx = targetExtent.width / base.extent.width
            let sy = targetExtent.height / base.extent.height
            scaledBase = base.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        if let mask = mask, let cgMask = mask.cgImage {
            // Mask mode: use painted mask to control blend per-pixel.
            // The mask was painted in UIKit coordinates over the PREVIEW which uses
            // .resizeAspectFill (cropped to fit the screen). We aspect-fill scale
            // and center-crop the mask to match the preview's framing on the photo.
            // (No Y-flip needed — CIImage(cgImage:) maps CGImage row 0 to CIImage
            // top, so the mask is already in the right orientation for compositing.)
            var maskCI = CIImage(cgImage: cgMask)

            // Aspect-fill scale: pick the larger scale factor so the mask covers
            // the entire target, then center-crop the overflow.
            let maskW = maskCI.extent.width
            let maskH = maskCI.extent.height
            let sx = targetExtent.width  / maskW
            let sy = targetExtent.height / maskH
            let scale = max(sx, sy)
            maskCI = maskCI.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            // Center the scaled mask on the target extent
            let scaledW = maskCI.extent.width
            let scaledH = maskCI.extent.height
            let dx = (targetExtent.width  - scaledW) / 2.0 + targetExtent.origin.x
            let dy = (targetExtent.height - scaledH) / 2.0 + targetExtent.origin.y
            maskCI = maskCI.transformed(by: CGAffineTransform(translationX: dx, y: dy))
            maskCI = maskCI.cropped(to: targetExtent)

            // Apply global opacity on top of per-pixel mask: brush alpha × blend slider
            let opacityFilter = CIFilter.colorMatrix()
            opacityFilter.inputImage = maskCI
            opacityFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
            let scaledMask = opacityFilter.outputImage ?? maskCI

            // BlendWithMask: overlay shows through where mask is white, base shows where black
            let blendWithMask = CIFilter.blendWithMask()
            blendWithMask.inputImage = overlay         // foreground (second shot)
            blendWithMask.backgroundImage = scaledBase  // background (first shot)
            blendWithMask.maskImage = scaledMask
            return blendWithMask.outputImage?.cropped(to: targetExtent) ?? overlay
        }

        // No mask: uniform opacity screen blend
        let opacityFilter = CIFilter.colorMatrix()
        opacityFilter.inputImage = overlay
        opacityFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        let adjusted = opacityFilter.outputImage ?? overlay
        let blend = CIFilter.screenBlendMode()
        blend.inputImage = adjusted
        blend.backgroundImage = scaledBase
        return blend.outputImage?.cropped(to: targetExtent) ?? overlay
    }

}

// MARK: - Grain character per stock

/// How a stock's grain looks: size (relative), colour grain, and clumping.
/// Slow slide / fine colour stocks: small and tight; consumer 400: medium
/// with a hint of colour; fast and pushed stocks: bigger and clumpier.
/// Fujifilm's camera simulations get Fuji's in-camera Grain Effect:
/// luminance only, fine and even. (B&W stocks get no colour grain anyway —
/// the kernel only adds it where the image has colour.)
nonisolated struct GrainCharacter: Sendable, Equatable {
    var size: CGFloat
    var strength: CGFloat
    var chroma: CGFloat
    var clump: CGFloat
    static let fine      = GrainCharacter(size: 0.8, strength: 0.7, chroma: 0.12, clump: 0.22)
    static let standard  = GrainCharacter(size: 1.0, strength: 1.0, chroma: 0.2, clump: 0.3)
    static let fast      = GrainCharacter(size: 1.25, strength: 1.2, chroma: 0.25, clump: 0.42)
    static let fujiCamera = GrainCharacter(size: 0.9, strength: 0.85, chroma: 0, clump: 0.2)
}

extension FilmSimulation {
    nonisolated var grainCharacter: GrainCharacter {
        switch self {
        case .fujiVelvia, .fujiProvia, .ektachrome100, .kodachrome64, .kodakEktar, .kodakPortra160,
             .fujiReala100, .kodakVision3_50D, .cinestill50D, .kodakProImage100, .ilfordDelta100,
             .fuji160NS, .agfaRSX, .fujiProvia400X:
            return .fine
        case .kodakPortra800, .kodakPortra800Push1, .kodakPortra800Push2, .cinestill800T,
             .ilfordDelta3200, .kodakP3200, .ilfordHP5, .kodakTriX, .kodakDoubleX, .kodakTmax400:
            return .fast
        case .fujiClassicChrome, .fujiAstia, .fujiEterna, .fujiEternaVivid, .fujiAcros, .fujiSensia:
            return .fujiCamera
        default:
            return .standard
        }
    }
}
