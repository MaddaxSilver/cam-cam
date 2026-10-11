//
//  FilmRoll.swift
//  cam cam
//
//  Film roll mode: load a 24 or 36 exposure roll and shoot blind — frames are
//  held in app storage (Documents/Rolls/current) and nothing reaches Photos
//  until you "develop" the roll. Developing pushes every frame through the
//  normal PhotoSaver path, so developed shots are ordinary non-destructive
//  cam cam photos (original + recipe edit, re-gradable, in the album).
//
//  Shots survive app restarts (the manifest is rewritten after every frame).
//  Both iPhone and Sony captures are absorbed while a roll is loaded.
//

import Foundation
import CoreLocation
import CoreGraphics
import Observation

@MainActor @Observable
final class FilmRoll {

    static let shared = FilmRoll()

    struct Shot: Codable, Sendable {
        var original: String
        var rendered: String?
        var recipe: ShotRecipe?
        var latitude: Double?
        var longitude: Double?
        var altitude: Double?
        var accuracy: Double?
        var date: Date

        var location: CLLocation? {
            guard let latitude, let longitude else { return nil }
            return CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                              altitude: altitude ?? 0, horizontalAccuracy: accuracy ?? 0,
                              verticalAccuracy: -1, timestamp: date)
        }
    }

    struct Manifest: Codable, Sendable {
        var id = UUID()
        var capacity: Int
        var started = Date()
        var shots: [Shot] = []
    }

    // Observable mirror for the UI.
    private(set) var manifest: Manifest?
    private(set) var developing = false
    private(set) var developProgress = 0
    var message: String?

    var isLoaded: Bool { manifest != nil }
    var shotCount: Int { manifest?.shots.count ?? 0 }
    var capacity: Int { manifest?.capacity ?? 0 }
    var isFull: Bool { manifest.map { $0.shots.count >= $0.capacity } ?? false }
    var exposuresLeft: Int { max(0, capacity - shotCount) }

    // Authoritative copy, touched from capture/processing queues under `lock`.
    @ObservationIgnored nonisolated(unsafe) private var _store: Manifest?
    @ObservationIgnored nonisolated private let lock = NSLock()

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rolls/current", isDirectory: true)
    }
    nonisolated private static var manifestURL: URL { directory.appendingPathComponent("roll.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.manifestURL),
           let m = try? JSONDecoder().decode(Manifest.self, from: data) {
            _store = m
            manifest = m
        }
    }

    // MARK: Roll lifecycle

    func load(capacity: Int) {
        guard !isLoaded else { return }
        let m = Manifest(capacity: capacity)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        lock.lock(); _store = m; Self.persist(m); lock.unlock()
        manifest = m
        message = "Loaded \(capacity) exp — shots stay hidden until you develop"
    }

    /// Throw away an undeveloped roll (the UI confirms first).
    func discard() {
        lock.lock(); _store = nil; lock.unlock()
        try? FileManager.default.removeItem(at: Self.directory)
        manifest = nil
        message = "Roll discarded"
    }

    /// Save every frame to Photos (in shot order), then unload the roll.
    /// Frames are removed one by one as they land, so an interrupted develop
    /// can simply be resumed.
    /// Develop the roll: save every frame to Photos in shot order.
    /// - development: applied to every frame (re-rendered from its original
    ///   with `render`); `.normal` keeps each frame as shot.
    /// - contactSheet: also save one contact print of the whole roll.
    func develop(development: ContactSheet.Development = .normal, contactSheet: Bool = false,
                 render: ((Data, ShotRecipe) -> Data?)? = nil) async {
        guard !developing, let m = manifest, !m.shots.isEmpty else { return }
        developing = true; developProgress = 0
        defer { developing = false }
        let dir = Self.directory
        var remaining = m.shots
        var sheetFrames: [CGImage] = []
        var sheetFilm: String?
        while let shot = remaining.first {
            do {
                let original = try Data(contentsOf: dir.appendingPathComponent(shot.original))
                var rendered = shot.rendered.flatMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
                var recipe = rendered == nil ? nil : shot.recipe
                if development != .normal, let render {
                    let r = development.apply(to: shot.recipe ?? ShotRecipe())
                    if let out = await Task.detached(priority: .userInitiated, operation: { render(original, r) }).value {
                        rendered = out; recipe = r
                    }
                }
                if contactSheet {
                    if let t = ContactSheet.thumbnail(rendered ?? original) { sheetFrames.append(t) }
                    if sheetFilm == nil { sheetFilm = recipe?.displayName ?? shot.recipe?.displayName }
                }
                _ = try await PhotoSaver.save(original: original, rendered: rendered,
                                              recipe: rendered == nil ? nil : recipe,
                                              location: shot.location)
            } catch {
                message = "Developing stopped: \(error.localizedDescription) — \(remaining.count) frames kept"
                return
            }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(shot.original))
            if let r = shot.rendered { try? FileManager.default.removeItem(at: dir.appendingPathComponent(r)) }
            remaining.removeFirst()
            developProgress += 1
            lock.withLock {
                _store?.shots = remaining
                if let cur = _store { Self.persist(cur) }
            }
            manifest?.shots = remaining
        }
        let count = m.shots.count
        if contactSheet, let sheet = ContactSheet.render(frames: sheetFrames, film: sheetFilm ?? "cam cam",
                                                          date: m.started) {
            _ = try? await PhotoSaver.save(original: sheet, rendered: nil, recipe: nil, location: nil)
        }
        lock.withLock { _store = nil }
        try? FileManager.default.removeItem(at: dir)
        manifest = nil
        message = "Developed \(count) frames → cam cam album"
    }

    // MARK: Capture hook

    /// Called by every save path. Returns true if a roll is loaded and the
    /// frame was taken by it (the caller must then NOT save to Photos).
    nonisolated func absorb(original: Data, rendered: Data?, recipe: ShotRecipe?,
                            location: CLLocation?) -> Bool {
        lock.lock()
        guard var m = _store else { lock.unlock(); return false }
        guard m.shots.count < m.capacity else {
            lock.unlock()
            Task { @MainActor in FilmRoll.shared.message = "Roll is full — develop it to keep shooting" }
            return true
        }
        let n = m.shots.count + 1
        let base = String(format: "%03d", n)
        let dir = Self.directory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try original.write(to: dir.appendingPathComponent("\(base)-original"))
            var renderedName: String?
            if let rendered {
                renderedName = "\(base)-look.jpg"
                try rendered.write(to: dir.appendingPathComponent(renderedName!))
            }
            m.shots.append(Shot(original: "\(base)-original", rendered: renderedName, recipe: recipe,
                                latitude: location?.coordinate.latitude,
                                longitude: location?.coordinate.longitude,
                                altitude: location?.altitude,
                                accuracy: location?.horizontalAccuracy,
                                date: Date()))
            _store = m
            Self.persist(m)
        } catch {
            lock.unlock()
            // Couldn't write to the roll — let the caller save normally so
            // the frame isn't lost.
            return false
        }
        lock.unlock()
        let snapshot = m
        Task { @MainActor in FilmRoll.shared.manifest = snapshot }
        return true
    }

    nonisolated private static func persist(_ m: Manifest) {
        guard let data = try? JSONEncoder().encode(m) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}
