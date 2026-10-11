//
//  AppIntents.swift
//  cam cam
//
//  Shortcuts / Action Button entry points: "Open cam cam" straight into a
//  chosen film sim and/or Sony remote mode. Assign it via Settings → Action
//  Button → Shortcut → cam cam, or build a Shortcut around it.
//
//  Intents only record the request in `LaunchRouter`; the camera screen
//  observes the router and applies it (sim selection, Sony sheet).
//

import AppIntents
import Foundation

// MARK: - Router (intent → UI)

@MainActor @Observable
final class LaunchRouter {
    static let shared = LaunchRouter()

    struct Request: Equatable {
        var id = UUID()
        var sim: FilmSimulation?
        var customID: UUID?
        var mode: CamMode?
    }

    /// Latest unconsumed request; the camera screen sets it back to nil.
    var request: Request?
}

// MARK: - Mode

enum CamMode: String, AppEnum {
    case iphone, sony

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Camera"
    static let caseDisplayRepresentations: [CamMode: DisplayRepresentation] = [
        .iphone: DisplayRepresentation(title: "iPhone camera", image: .init(systemName: "iphone")),
        .sony: DisplayRepresentation(title: "Sony remote", image: .init(systemName: "camera")),
    ]
}

// MARK: - Film sim entity (built-ins + your custom sims)

struct FilmSimEntity: AppEntity {
    /// Same keys as FavoritesStore: "b:<raw>" built-in, "c:<uuid>" custom.
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Film Sim"
    static let defaultQuery = FilmSimQuery()

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    var builtIn: FilmSimulation? {
        id.hasPrefix("b:") ? FilmSimulation(rawValue: String(id.dropFirst(2))) : nil
    }
    var customID: UUID? {
        id.hasPrefix("c:") ? UUID(uuidString: String(id.dropFirst(2))) : nil
    }

    static func all() -> [FilmSimEntity] {
        let builtIns = FilmSimulation.allCases.map { FilmSimEntity(id: "b:\($0.rawValue)", name: $0.label) }
        var customs: [FilmSimEntity] = []
        if let data = UserDefaults.standard.data(forKey: "cam_cam_custom_sims"),
           let sims = try? JSONDecoder().decode([CustomSimulation].self, from: data) {
            customs = sims.map { FilmSimEntity(id: "c:\($0.id.uuidString)", name: $0.name) }
        }
        return builtIns + customs
    }
}

struct FilmSimQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [FilmSimEntity] {
        let all = FilmSimEntity.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }
    func entities(matching string: String) async throws -> [FilmSimEntity] {
        FilmSimEntity.all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [FilmSimEntity] { FilmSimEntity.all() }
}

// MARK: - Intent

struct OpenCamCamIntent: AppIntent {
    static let title: LocalizedStringResource = "Open cam cam"
    static let description = IntentDescription("Opens cam cam with a film sim and camera ready to shoot.")
    static let openAppWhenRun = true

    @Parameter(title: "Camera", default: .iphone)
    var mode: CamMode

    @Parameter(title: "Film Sim")
    var sim: FilmSimEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Open cam cam with \(\.$sim) on \(\.$mode)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRouter.shared.request = .init(sim: sim?.builtIn, customID: sim?.customID, mode: mode)
        return .result()
    }
}

struct CamCamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenCamCamIntent(),
                    phrases: ["Open \(.applicationName)",
                              "Shoot with \(.applicationName)",
                              "Open \(.applicationName) on \(\.$mode)"],
                    shortTitle: "Open cam cam",
                    systemImageName: "camera.filters")
    }
}
