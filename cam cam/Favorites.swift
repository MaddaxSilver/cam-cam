//
//  Favorites.swift
//  cam cam
//
//  Pinned film sims, shown first in the sim strip (iPhone + Sony share them).
//  Built-ins are keyed by raw value, customs/LUTs by their stable UUID, so
//  renaming a custom sim keeps it pinned.
//

import Foundation
import Observation

@MainActor
@Observable
final class FavoritesStore {
    static let shared = FavoritesStore()

    /// Ordered (pin order) keys: "b:<FilmSimulation.rawValue>" or "c:<UUID>".
    private(set) var keys: [String] = UserDefaults.standard.stringArray(forKey: "cc_favoriteSims") ?? []

    static func key(_ sim: FilmSimulation) -> String { "b:\(sim.rawValue)" }
    static func key(_ custom: CustomSimulation) -> String { "c:\(custom.id.uuidString)" }

    func isFavorite(_ key: String) -> Bool { keys.contains(key) }

    func toggle(_ key: String) {
        if let i = keys.firstIndex(of: key) { keys.remove(at: i) } else { keys.append(key) }
        UserDefaults.standard.set(keys, forKey: "cc_favoriteSims")
    }

    /// Pinned built-ins, in pin order.
    var builtIns: [FilmSimulation] {
        keys.compactMap { $0.hasPrefix("b:") ? FilmSimulation(rawValue: String($0.dropFirst(2))) : nil }
    }

    /// Pinned customs/LUTs (resolved against the live store), in pin order.
    func customs(in all: [CustomSimulation]) -> [CustomSimulation] {
        keys.compactMap { k in
            guard k.hasPrefix("c:") else { return nil }
            return all.first { "c:\($0.id.uuidString)" == k }
        }
    }
}
