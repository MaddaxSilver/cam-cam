//
//  ShotRecipe.swift
//  cam cam
//
//  Everything needed to (re)render a shot's look, as one immutable value.
//
//  Why this exists:
//  • The render pipeline used to read ~25 shared mutable `pending*` globals.
//    The live preview, the Sony live view (off-main) and Sony photo
//    processing (on main) all temporarily SWAPPED those globals and restored
//    them — so overlapping renders could leave them corrupted and give a shot
//    the wrong look. Passing a value removes that whole class of race.
//  • It's Codable, so it's stored with every photo (Photos adjustment data):
//    the original stays untouched and the shot can be re-graded later.
//

import Foundation

nonisolated struct ShotRecipe: Codable, Sendable, Equatable {
    /// Bump when the meaning of a field changes (old recipes stay decodable
    /// because every field below has a default).
    static let currentVersion = 1
    static let formatIdentifier = "com.camcam.recipe"

    var version: Int = ShotRecipe.currentVersion

    // Look
    var sim: FilmSimulation = .none
    var custom: CustomSimulation? = nil          // param sim or LUT reference

    // Grain (doubles as "weirdness" for Bent, "noise" for DigiCam)
    var grainEnabled = false
    var grain: Float = 0
    var contextAwareGrain = false                 // DigiCam "lines", Bent "wild"
    var digiCamQuality: Float = 12

    // Film effects
    var crosstalkEnabled = false;  var crosstalk: Float = 0.1
    var halationEnabled = false;   var halation: Float = 0.2
    var rolloffEnabled = false;    var rolloff: Float = 0.9
    var pushPullEnabled = false;   var pushPull: Float = 0
    var anamorphicFlare = false
    var lightArtifacts = false
    var filmScratches = false
    var randomization = false

    /// Per-shot seed so leaks/scratches/randomization re-render identically.
    var randomSeed: UInt64 = 0

    /// A recipe that changes nothing (no sim, no effects).
    var isIdentity: Bool {
        sim == .none && custom == nil && !grainEnabled && !crosstalkEnabled
            && !halationEnabled && !rolloffEnabled && !pushPullEnabled
            && !anamorphicFlare && !lightArtifacts && !filmScratches && !randomization
    }

    /// Short human label, e.g. "Portra" or "Teal & Orange (LUT)".
    var displayName: String {
        if let custom { return custom.lutFilename != nil ? "\(custom.name) (LUT)" : custom.name }
        return sim.label
    }

    // Tolerant decoding: any missing key falls back to its default, so
    // recipes written by older/newer app versions still load.
    enum CodingKeys: String, CodingKey {
        case version, sim, custom, grainEnabled, grain, contextAwareGrain, digiCamQuality
        case crosstalkEnabled, crosstalk, halationEnabled, halation, rolloffEnabled, rolloff
        case pushPullEnabled, pushPull, anamorphicFlare, lightArtifacts, filmScratches
        case randomization, randomSeed
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T {
            if let x = try? c.decodeIfPresent(T.self, forKey: k) { return x }
            return d
        }
        version          = v(.version, ShotRecipe.currentVersion)
        sim              = v(.sim, FilmSimulation.none)
        custom           = (try? c.decodeIfPresent(CustomSimulation.self, forKey: .custom)) ?? nil
        grainEnabled     = v(.grainEnabled, false)
        grain            = v(.grain, Float(0))
        contextAwareGrain = v(.contextAwareGrain, false)
        digiCamQuality   = v(.digiCamQuality, Float(12))
        crosstalkEnabled = v(.crosstalkEnabled, false); crosstalk = v(.crosstalk, Float(0.1))
        halationEnabled  = v(.halationEnabled, false);  halation  = v(.halation, Float(0.2))
        rolloffEnabled   = v(.rolloffEnabled, false);   rolloff   = v(.rolloff, Float(0.9))
        pushPullEnabled  = v(.pushPullEnabled, false);  pushPull  = v(.pushPull, Float(0))
        anamorphicFlare  = v(.anamorphicFlare, false)
        lightArtifacts   = v(.lightArtifacts, false)
        filmScratches    = v(.filmScratches, false)
        randomization    = v(.randomization, false)
        randomSeed       = v(.randomSeed, UInt64(0))
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data) -> ShotRecipe? { try? JSONDecoder().decode(ShotRecipe.self, from: data) }
}
