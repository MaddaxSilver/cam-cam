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
    @ObservationIgnored private var pending: Set<String> = []

    func tone(_ key: String) -> Color { tones[key] ?? .white }

    /// Compute tones for any keys not yet known. Cheap: 4 tiny patches each.
    func ensure(_ items: [ArcItem], camera: CameraManager) {
        let todo = items.filter { tones[$0.key] == nil && !pending.contains($0.key) }
        guard !todo.isEmpty else { return }
        todo.forEach { pending.insert($0.key) }
        nonisolated(unsafe) let cam = camera
        let jobs = todo.map { ($0.key, $0.sim, $0.custom) }
        Task.detached(priority: .utility) {
            var out: [String: Color] = [:]
            for (key, sim, custom) in jobs {
                out[key] = FilmToneStore.measure(sim: sim, custom: custom, camera: cam)
            }
            await MainActor.run {
                for (k, v) in out { FilmToneStore.shared.tones[k] = v; FilmToneStore.shared.pending.remove(k) }
            }
        }
    }

    /// Forget a custom film's tone (after it's edited).
    func invalidate(_ key: String) { tones[key] = nil }

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

    nonisolated static func measure(sim: FilmSimulation?, custom: CustomSimulation?, camera: CameraManager) -> Color {
        var r = ShotRecipe()
        r.sim = sim ?? .none
        r.custom = custom
        guard !r.isIdentity else { return .white }
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
        return Color(hue: Double(h), saturation: Double(sat), brightness: 0.97)
    }
}

/// One stop on the film arc: a built-in film or a custom film / LUT.
struct ArcItem: Identifiable, Equatable {
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
}
