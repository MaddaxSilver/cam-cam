//
//  FilmTone.swift
//  cam cam
//
//  Each film's label on the arc is tinted with that film's own colour tone.
//  The tone isn't hand-picked: a small swatch (skin, grey, foliage, sky) is
//  pushed through the real look pipeline and the average of what comes out
//  is the film's colour. Custom films and LUTs get a tone the same way.
//  The result is lifted to a light, readable tint so text stays legible on
//  glass over any scene; black-and-white films come out near white.
//

import SwiftUI
import CoreImage

@MainActor @Observable
final class FilmToneStore {
    static let shared = FilmToneStore()

    private(set) var tones: [String: Color] = [:]
    /// Measured look volume per film: [ΔE, mid-grey EV, saturation] (LookVolume).
    private(set) var volumes: [String: [Double]] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    /// Measured tones survive launches (hue, saturation, brightness per key),
    /// so the dial doesn't re-render every film (and re-parse every LUT) on
    /// each start. Keyed to the build, since looks can change between builds.
    @ObservationIgnored private var saved: [String: [Double]]
    nonisolated private static var cacheKey: String {
        "cc_filmTones_" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
    }

    init() {
        saved = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: [Double]] ?? [:]
        volumes = UserDefaults.standard.dictionary(forKey: Self.cacheKey + "_vol") as? [String: [Double]] ?? [:]
        for (k, v) in saved where v.count == 3 {
            tones[k] = Color(hue: v[0], saturation: v[1], brightness: v[2])
        }
    }

    func tone(_ key: String) -> Color { tones[key] ?? .white }

    /// "volume 12 · tone −0.2 EV · saturation +8%", once measured.
    func volumeText(_ key: String) -> String? {
        guard let v = volumes[key], v.count == 3 else { return nil }
        return String(format: "volume %.0f · %+.1f EV · saturation %+.0f%%", v[0], v[1], v[2] * 100)
    }

    /// Compute tones for any keys not yet known. Cheap: 4 tiny patches each.
    func ensure(_ items: [ArcItem], camera: CameraManager) {
        let todo = items.filter { (tones[$0.key] == nil || volumes[$0.key] == nil) && !pending.contains($0.key) }
        guard !todo.isEmpty else { return }
        todo.forEach { pending.insert($0.key) }
        let cam = camera
        let jobs = todo.map { ($0.key, $0.sim, $0.custom) }
        Task.detached(priority: .utility) {
            var out: [String: [Double]] = [:], vols: [String: [Double]] = [:]
            for (key, sim, custom) in jobs {
                out[key] = FilmToneStore.measure(sim: sim, custom: custom, camera: cam)
                var r = ShotRecipe(); r.sim = sim ?? .none; r.custom = custom
                if let v = LookVolume.measure({ cam.renderLook($0, recipe: r, flatten: false) }, context: cam.ciContext) {
                    vols[key] = [Double(v.deltaE), Double(v.midEV), Double(v.saturation)]
                }
            }
            let (outNow, volsNow) = (out, vols)
            await MainActor.run {
                let store = FilmToneStore.shared
                for (k, v) in outNow {
                    store.tones[k] = Color(hue: v[0], saturation: v[1], brightness: v[2])
                    store.pending.remove(k)
                    store.saved[k] = v
                }
                UserDefaults.standard.set(store.saved, forKey: FilmToneStore.cacheKey)
                for (k, v) in volsNow { store.volumes[k] = v }
                UserDefaults.standard.set(store.volumes, forKey: FilmToneStore.cacheKey + "_vol")
            }
        }
    }

    /// Forget a custom film's tone (after it's edited).
    func invalidate(_ key: String) {
        tones[key] = nil
        saved[key] = nil
        volumes[key] = nil
        UserDefaults.standard.set(saved, forKey: Self.cacheKey)
    }

    nonisolated private static let swatch: CIImage = {
        let patches: [(CGFloat, CGFloat, CGFloat)] = [
            (0.80, 0.62, 0.52),   // skin
            (0.50, 0.50, 0.50),   // grey
            (0.36, 0.48, 0.30),   // foliage
            (0.56, 0.70, 0.86),   // sky
        ]
        var img = CIImage.empty()
        for (i, p) in patches.enumerated() {
            let patch = CIImage(color: CIColor(red: p.0, green: p.1, blue: p.2))
                .cropped(to: CGRect(x: CGFloat(i) * 32, y: 0, width: 32, height: 32))
            img = patch.composited(over: img)
        }
        return img
    }()

    /// The film's label tint as [hue, saturation, brightness].
    nonisolated static func measure(sim: FilmSimulation?, custom: CustomSimulation?, camera: CameraManager) -> [Double] {
        var r = ShotRecipe()
        r.sim = sim ?? .none
        r.custom = custom
        guard !r.isIdentity else { return [0, 0, 1] }
        let input = swatch
        let graded = camera.renderLook(input, recipe: r, flatten: false).cropped(to: input.extent)
        let avg = graded.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: input.extent)])
        var px = [Float](repeating: 0, count: 4)
        camera.ciContext.render(avg, toBitmap: &px, rowBytes: 16,
                                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
        let ui = UIColor(red: CGFloat(px[0]), green: CGFloat(px[1]), blue: CGFloat(px[2]), alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Exaggerate the cast a little so it reads, but keep text light.
        let sat = min(max(s * 1.8, 0), 0.55)
        return [Double(h), Double(sat), 0.97]
    }
}

/// One stop on the film arc: a built-in film or a custom film / LUT.
nonisolated struct ArcItem: Identifiable, Equatable {
    let key: String
    let label: String
    let sim: FilmSimulation?
    let custom: CustomSimulation?
    var id: String { key }

    static func builtIn(_ s: FilmSimulation) -> ArcItem {
        ArcItem(key: FavoritesStore.key(s), label: s.label, sim: s, custom: nil)
    }
    static func custom(_ c: CustomSimulation) -> ArcItem {
        ArcItem(key: FavoritesStore.key(c), label: c.name, sim: nil, custom: c)
    }
    /// A film-set switch that sits at each end of the dial.
    static func setSwitch(_ end: String, title: String) -> ArcItem {
        ArcItem(key: "__set_\(end)", label: title, sim: nil, custom: nil)
    }
    var isSetSwitch: Bool { key.hasPrefix("__set_") }
}
