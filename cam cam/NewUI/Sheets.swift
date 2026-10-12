//
//  Sheets.swift
//  cam cam
//
//  The three sheets of the new UI: the film library (opened from the centre
//  film on the arc), the film roll, and Settings (everything that isn't a
//  per-shot control).
//

import SwiftUI
import CoreImage
import ImageIO

// MARK: - Film library

struct FilmLibrarySheet: View {
    @Bindable var camera: CameraManager
    let customSimStore: CustomSimStore
    var onExportLUT: (FilmSimulation, CustomSimulation?, String) -> Void
    var onEditFilms: () -> Void
    var onImportLUT: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var favorites = FavoritesStore.shared
    @State private var tones = FilmToneStore.shared
    @State private var query = ""
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", pinned = "Pinned", builtIn = "Built-in", custom = "Custom", luts = "LUTs"
        var id: String { rawValue }
    }

    private var items: [ArcItem] {
        let built = FilmSimulation.allCases.map(ArcItem.builtIn)
        let customs = customSimStore.simulations.map(ArcItem.custom)
        let all: [ArcItem]
        switch filter {
        case .all: all = built + customs
        case .pinned: all = (built + customs).filter { favorites.isFavorite($0.key) }
        case .builtIn: all = built
        case .custom: all = customs.filter { $0.custom?.lutFilename == nil }
        case .luts: all = customs.filter { $0.custom?.lutFilename != nil }
        }
        guard !query.isEmpty else { return all }
        return all.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    private var selectedKey: String {
        if let c = camera.activeCustomSim { return FavoritesStore.key(c) }
        return FavoritesStore.key(camera.selectedSim)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Filter.allCases) { f in
                                Button { filter = f } label: {
                                    Text(f.rawValue).font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(filter == f ? .black : .white)
                                        .padding(.horizontal, 12).frame(height: 32)
                                        .background(Capsule().fill(filter == f ? Color.white : Color.white.opacity(0.12)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
                let pinned = items.filter { favorites.isFavorite($0.key) }
                if !pinned.isEmpty && filter != .pinned {
                    Section("Pinned") { ForEach(pinned) { row($0) } }
                }
                Section(filter == .pinned ? "Pinned" : "Films") {
                    ForEach(items.filter { filter == .pinned || !favorites.isFavorite($0.key) }) { row($0) }
                }
            }
            .searchable(text: $query, prompt: "Search films")
            .navigationTitle("Films")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Edit films") { dismiss(); onEditFilms() }
                    Spacer()
                    Button("Import LUT") { dismiss(); onImportLUT() }
                }
            }
            .task { tones.ensure(FilmSimulation.allCases.map(ArcItem.builtIn) + customSimStore.simulations.map(ArcItem.custom), camera: camera) }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ item: ArcItem) -> some View {
        let isSel = item.key == selectedKey
        let pinned = favorites.isFavorite(item.key)
        return HStack(spacing: 12) {
            Circle().fill(tones.tone(item.key)).frame(width: 22, height: 22)
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.body.weight(isSel ? .bold : .regular))
                    .foregroundStyle(isSel ? Color.yellow : .primary)
                Text(kind(item)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button { favorites.toggle(item.key) } label: {
                Image(systemName: pinned ? "star.fill" : "star")
                    .foregroundStyle(pinned ? Color.yellow : .secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pinned ? "Unpin \(item.label)" : "Pin \(item.label)")
        }
        .contentShape(Rectangle())
        .onTapGesture { choose(item); dismiss() }
        .contextMenu {
            Button { favorites.toggle(item.key) } label: {
                Label(pinned ? "Unpin" : "Pin to the dial", systemImage: pinned ? "star.slash" : "star")
            }
            if item.sim != FilmSimulation.none || item.custom != nil {
                Button {
                    onExportLUT(item.sim ?? .none, item.custom, item.label)
                } label: { Label("Export as LUT (.cube)", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private func kind(_ item: ArcItem) -> String {
        if let c = item.custom { return c.lutFilename == nil ? "Your film" : "LUT" }
        return "Built-in"
    }

    private func choose(_ item: ArcItem) {
        if let c = item.custom {
            customSimStore.activeCustomSimID = c.id
            camera.activeCustomSim = c
            camera.selectedSim = .none
        } else if let s = item.sim {
            camera.selectedSim = s
            customSimStore.activeCustomSimID = nil
            camera.activeCustomSim = nil
        }
    }
}

// MARK: - Film roll

struct RollSheet: View {
    let camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var roll = FilmRoll.shared
    @State private var confirmDiscard = false
    @State private var developedCount: Int?
    @State private var development: ContactSheet.Development = .normal
    @AppStorage("cc_rollContactSheet") private var contactSheet = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if let n = developedCount {
                    Spacer()
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 40, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 96, height: 96).background(Circle().fill(Color.yellow))
                            .symbolEffect(.bounce, value: n)
                        Text("\(n) frames developed").font(.title2.bold())
                        Text(contactSheet ? "They’re in the cam cam album, with a contact sheet."
                                          : "They’re in the cam cam album.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .sensoryFeedback(.success, trigger: n)
                    Spacer()
                } else if roll.isLoaded {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(roll.shotCount)").font(.system(size: 64, weight: .bold).monospacedDigit())
                        Text("of \(roll.capacity)").font(.title3).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(roll.shotCount), total: Double(max(roll.capacity, 1)))
                        .tint(.yellow)
                    Text("Frames stay hidden until you develop. Each keeps its film and location, and can be re-graded afterwards.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if roll.developing {
                        ProgressView("Developing \(roll.developProgress)…").tint(.yellow)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DEVELOPMENT").font(.system(size: 12, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(ContactSheet.Development.allCases) { d in
                                    Button { development = d } label: {
                                        Text(d.title).font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(development == d ? .black : .white)
                                            .padding(.horizontal, 14).frame(height: 36)
                                            .background(Capsule().fill(development == d ? Color.yellow : Color.white.opacity(0.12)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Text(development.detail).font(.footnote).foregroundStyle(.secondary)
                        Toggle("Make a contact sheet", isOn: $contactSheet).tint(.yellow)
                    }
                    Spacer()
                    Button {
                        let n = roll.shotCount
                        nonisolated(unsafe) let cam = camera
                        let render: (Data, ShotRecipe) -> Data? = { data, r in
                            guard let ci = CIImage(data: data) else { return nil }
                            let o = (ci.properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
                            let upright = ci.oriented(forExifOrientation: o)
                            let out = cam.renderLook(upright, recipe: r, flatten: true).cropped(to: upright.extent)
                            guard let cg = cam.ciContext.createCGImage(out, from: out.extent) else { return nil }
                            return MetadataTools.jpeg(from: cg, metadataFrom: data, location: nil)
                        }
                        Task {
                            await roll.develop(development: development, contactSheet: contactSheet, render: render)
                            if !roll.isLoaded { developedCount = n }
                        }
                    } label: {
                        Text("Develop \(roll.shotCount) frame\(roll.shotCount == 1 ? "" : "s")")
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 52)
                    }
                    .buttonStyle(.glassProminent).tint(.yellow).foregroundStyle(.black)
                    .disabled(roll.shotCount == 0 || roll.developing)
                    Button("Discard roll…", role: .destructive) { confirmDiscard = true }
                        .frame(maxWidth: .infinity)
                        .disabled(roll.developing)
                } else {
                    Text("Shoot without looking back. Frames are hidden until you develop the roll.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        loadButton(24)
                        loadButton(36)
                    }
                    Spacer()
                }
            }
            .padding(20)
            .navigationTitle("Film roll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Discard this roll?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard \(roll.shotCount) undeveloped frames", role: .destructive) { roll.discard() }
            } message: { Text("The frames haven’t been saved anywhere else.") }
        }
        .preferredColorScheme(.dark)
    }

    private func loadButton(_ n: Int) -> some View {
        Button { roll.load(capacity: n); developedCount = nil } label: {
            VStack(spacing: 4) {
                Text("\(n)").font(.system(size: 40, weight: .bold))
                Text("exposures").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 120)
        }
        .buttonStyle(.glass)
    }
}

// MARK: - Settings

struct CamSettingsSheet: View {
    @Bindable var camera: CameraManager
    var onRegrade: () -> Void
    var onRoll: () -> Void
    var onEditFilms: () -> Void
    var onImportLUT: () -> Void
    @Binding var cleanMode: Bool
    /// Separate: the DNG is its own picture. Combined: hidden inside the film
    /// photo as its RAW (Photos shows one picture; export "unmodified original").
    @AppStorage("cc_rawSeparate") private var rawSeparate = true

    @Environment(\.dismiss) private var dismiss
    @State private var geotag = LocationTagger.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Photos") {
                    Picker("Quality", selection: $camera.photoQuality) {
                        Text("Speed").tag(0); Text("Balanced").tag(1); Text("Max").tag(2); Text("Natural").tag(3)
                    }
                    .pickerStyle(.segmented)
                    if camera.photoQuality == 3 {
                        Text("48MP ProRAW developed in cam cam, without Apple's processing (no HDR tone mapping, light noise reduction): more natural texture under the film, a little more noise.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("RAW + film", isOn: $camera.rawEnabled)
                    if camera.rawEnabled {
                        Picker("RAW files", selection: $rawSeparate) {
                            Text("Separate").tag(true); Text("Combined").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    Picker("Aspect", selection: $camera.selectedAspectRatio) {
                        ForEach(AspectRatio.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Long exposure", isOn: $camera.isLongExposure)
                    if camera.isLongExposure {
                        Picker("Method", selection: $camera.longExposureMode) {
                            ForEach(LongExposureMode.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
                Section("Shooting") {
                    Toggle("Burst (hold shutter)", isOn: $camera.burstMode)
                    if camera.portraitModeAvailable {
                        Toggle("Portrait", isOn: $camera.portraitModeEnabled)
                            .disabled(!camera.currentDeviceSupportsDepth)
                    }
                    Toggle("Macro", isOn: $camera.macroModeEnabled)
                    Toggle("Double exposure", isOn: $camera.doubleExposureEnabled)
                    if camera.doubleExposureEnabled {
                        Toggle("Paint a mask", isOn: $camera.doubleExposureMaskEnabled)
                    }
                    Toggle("Manual focus", isOn: Binding(get: { camera.manualFocusEnabled },
                                                         set: { camera.setManualFocusEnabled($0) }))
                    Toggle("One lens (smooth zoom)", isOn: $camera.unifiedZoomMode)
                    Toggle("Push / pull", isOn: $camera.pushPullEnabled)
                    if camera.pushPullEnabled {
                        Stepper("\(camera.pushPullAmount >= 0 ? "+" : "")\(Int(camera.pushPullAmount)) stop",
                                value: $camera.pushPullAmount, in: -2...3, step: 1)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Development")
                        Picker("Development", selection: Binding(
                            get: { camera.development == 0 ? 0 : camera.development < 0.35 ? 1 : camera.development < 0.75 ? 2 : 3 },
                            set: { camera.development = [0, 0.3, 0.6, 1.0][$0] })) {
                            Text("Normal").tag(0); Text("Light").tag(1); Text("Semi-stand").tag(2); Text("Stand").tag(3)
                        }
                        .pickerStyle(.segmented)
                        Text("Developer exhaustion: highlights compress, edges gain film's natural pop.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Display") {
                    Toggle("Grid", isOn: $camera.showGrid)
                    Toggle("Level", isOn: $camera.showLevel)
                    Toggle("Focus peaking", isOn: $camera.showPeaking)
                    Toggle("Clean screen", isOn: $cleanMode)
                }
                Section("Controls") {
                    Toggle("Volume buttons take the photo", isOn: $camera.volumeShutterEnabled)
                    Toggle("Left-handed shutter", isOn: $camera.shutterOnLeft)
                }
                Section("Frame guide learning") {
                    let n = FrameLearning.sampleCount
                    LabeledContent("Framings logged", value: "\(n)")
                    if let sc = FrameLearning.scorer {
                        LabeledContent("Learned model", value: "\(sc.samples ?? 0) shots · \(Int((sc.accuracy ?? 0) * 100))%")
                    } else {
                        LabeledContent("Learned model", value: n < 30 ? "needs \(30 - n) more shots" : "plug into the Mac")
                    }
                    Text("Shots taken with Frame guide on teach it your framing. Training runs on the Mac whenever the phone is plugged in, never on the phone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Location") {
                    Toggle("Tag photos with location", isOn: $geotag.enabled)
                }
                Section("Films and photos") {
                    Button("Film roll") { dismiss(); onRoll() }
                    Button("Re-grade a photo") { dismiss(); onRegrade() }
                    Button("Edit films") { dismiss(); onEditFilms() }
                    Button("Import LUT") { dismiss(); onImportLUT() }
                }
                Section("Film data") {
                    // Required attribution (CC BY-SA 4.0) for the spectral stocks.
                    Text("Portra 160 / 400 / 800 (+1, +2), Ektar, Gold, Ultramax, Verita 200D, Pro 400H, Xtra 400, C200, Vision3 50D / 200T / 250D / 500T, Ektachrome, Kodachrome, Velvia and Provia are rendered from spektrafilm film and print profiles by Andrea Volpato, licensed CC BY-SA 4.0.")
                        .font(.footnote)
                    Link("github.com/andreavolpato/spektrafilm",
                         destination: URL(string: "https://github.com/andreavolpato/spektrafilm")!)
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
