//
//  GlassChrome.swift
//  cam cam
//
//  The new camera chrome, Camera-app style: the frame runs to a small
//  bottom row (last photo · shutter · flip) with the mode words above it,
//  a glass film arc rising out of that row, a lens pill, and three quiet
//  glass buttons on top. Everything else hides behind the chevron.
//
//  CameraContentView keeps owning the preview, gestures, volume buttons and
//  sheets; this view only draws controls and calls back.
//

import SwiftUI
import Photos

enum CaptureMode: String { case photo, video }

enum ControlKind: String, CaseIterable, Identifiable {
    case suggest, style, halation, exposure, effects, modes, view
    var id: String { rawValue }
    var title: String {
        switch self {
        case .suggest: "Suggest"
        case .style: "Style"
        case .halation: "Halation"
        case .exposure: "Exposure"
        case .effects: "Effects"
        case .modes: "Shooting modes"
        case .view: "View"
        }
    }
    var symbol: String {
        switch self {
        case .suggest: "wand.and.stars"
        case .style: "paintpalette"
        case .halation: "sun.max"
        case .exposure: "plusminus.circle"
        case .effects: "sparkles"
        case .modes: "camera.aperture"
        case .view: "viewfinder"
        }
    }
}

/// One switch in a tile grid (effects, modes, view).
struct Tile {
    let title: String
    let symbol: String
    let isOn: Binding<Bool>
    var enabled = true
}

struct GlassChrome<Shutter: View>: View {
    @Bindable var camera: CameraManager
    let customSimStore: CustomSimStore
    @Binding var mode: CaptureMode
    var onSony: () -> Void
    var onLibrary: () -> Void
    var onRoll: () -> Void
    var onSettings: () -> Void
    var onAlbum: () -> Void
    @ViewBuilder var shutter: () -> Shutter

    @State private var showControls = false
    @State private var active: ControlKind = .exposure
    @State private var showGrain = false
    @State private var scrubStartMM: Double?
    @State private var scrubMM: Double = 35
    @State private var lastPresetCrossed: Int?
    @State private var favorites = FavoritesStore.shared
    @State private var roll = FilmRoll.shared
    @State private var tones = FilmToneStore.shared
    @State private var thumbToken = 0
    @State private var smartAE = SmartExposure.shared
    @State private var styleSettings = StyleSettings.shared
    @State private var showSetPicker = false
    @AppStorage("cc_arcSet") private var arcSetRaw = ArcSet.all.rawValue
    private var arcSet: ArcSet { ArcSet(rawValue: arcSetRaw) ?? .all }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, 58)
                .padding(.horizontal, 16)
            Spacer(minLength: 0)
            contextRulers
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            if showGrain && !showControls {
                grainPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showControls {
                controlPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                controlsRow
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                // The lens pill sits in the dial, under the film names: the
                // dial turns behind it, the pill stays put (and takes its own
                // taps and scrubs, since it's on top).
                ZStack(alignment: .bottom) {
                    Group {
                        if scrubStartMM != nil {
                            ZoomArc(mm: scrubMM)
                        } else {
                            FilmArc(items: shownItems, selectedKey: selectedKey,
                                    onSelect: select, onOpenLibrary: onLibrary,
                                    onSwitchSet: { showSetPicker = true })
                        }
                    }
                    .transition(.opacity)
                    LensPill(selectedIndex: scrubStartMM == nil ? camera.selectedFocalIndex : -1,
                             liveMM: scrubStartMM == nil ? camera.currentMM : Int(scrubMM.rounded()),
                             scrubbing: scrubStartMM != nil,
                             onTap: { i in camera.selectFocalPreset(i) },
                             onScrub: scrub,
                             onScrubEnd: endScrub)
                        .padding(.bottom, 8)
                }
            }
            bottomRows
        }
        .background {
            // While controls are open, a tap anywhere on the picture closes them.
            if showControls || showGrain {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { showControls = false; showGrain = false }
                    .accessibilityHidden(true)
            }
        }
        .confirmationDialog("Show on the dial", isPresented: $showSetPicker, titleVisibility: .visible) {
            ForEach(ArcSet.allCases) { set in
                Button(set == arcSet ? "\(set.title) ✓" : set.title) { arcSetRaw = set.rawValue }
            }
            Button("Browse all films…") { onLibrary() }
            Button("Cancel", role: .cancel) {}
        }
        .animation(.snappy(duration: 0.3), value: showControls)
        .animation(.snappy(duration: 0.3), value: showGrain)
        .onChange(of: showControls) { _, on in if on { showGrain = false } }
        .onChange(of: styleOn) { _, on in if !on && active == .style { active = .exposure } }
        .animation(.snappy(duration: 0.2), value: scrubStartMM == nil)
        .task(id: arcItems.count) { tones.ensure(arcItems, camera: camera) }
        .onChange(of: camera.isCapturing) { _, capturing in
            guard !capturing else { return }
            Task { try? await Task.sleep(for: .seconds(1.5)); thumbToken += 1 }
        }
        .onChange(of: camera.activeCustomSim) { _, c in
            // An edited custom film needs its tone measured again.
            if let c { tones.invalidate(FavoritesStore.key(c)); tones.ensure(arcItems, camera: camera) }
        }
    }

    // MARK: Top

    private var topBar: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(alignment: .top) {
                // Left: flash, then status icons beside it — same size.
                HStack(spacing: 8) {
                    Button { camera.toggleFlash() } label: {
                        Image(systemName: flashSymbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(camera.flashMode == .off ? .white : .yellow)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Flash \(camera.flashLabel)")

                    statusCircles
                }

                Spacer()

                // Right: the exposure scale, viewfinder style. Tap for exposure.
                Button {
                    if showControls && active == .exposure { showControls = false }
                    else { active = .exposure; showControls = true }
                } label: {
                    GlassEVMeter(bias: camera.exposureBias, correction: smartAE.correction,
                                 smart: smartAE.enabled)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .accessibilityLabel("Exposure \(String(format: "%+.1f", camera.exposureBias))\(smartAE.enabled ? ", smart exposure on" : "")")
            }
            .overlay(alignment: .top) {
                Group {

                if camera.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(.white).frame(width: 7, height: 7)
                        Text(timeString(camera.recordingDuration))
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(Color.red))
                } else {
                    Button { showControls.toggle() } label: {
                        Image(systemName: showControls ? "chevron.down" : "chevron.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(showControls ? .black : .white)
                            .frame(width: 64, height: 32)
                            .background(Capsule().fill(showControls ? Color.yellow : .clear))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .accessibilityLabel(showControls ? "Hide controls" : "Show controls")
                }

                }
            }
        }
    }

    struct StatusIcon: Identifiable {
        let id: String
        let symbol: String
        var text: String? = nil
        var tint: Color = .yellow
        var pulse = false
    }

    /// What's on that changes the shot: roll, modes, heat, focus/face.
    private var statusIcons: [StatusIcon] {
        var out: [StatusIcon] = []
        if roll.isLoaded {
            out.append(.init(id: "roll", symbol: "film", text: roll.isFull ? "Dev" : "\(roll.exposuresLeft)",
                             tint: roll.isFull ? .yellow : .white))
        }
        if camera.doubleExposureEnabled {
            out.append(.init(id: "dx", symbol: "circle.lefthalf.filled", text: camera.firstExposurePreview == nil ? "1" : "2"))
        }
        if camera.isLongExposure {
            out.append(.init(id: "lx", symbol: "timer", text: String(format: "%gs", camera.longExposureDuration)))
        }
        if camera.burstMode { out.append(.init(id: "burst", symbol: "square.stack.3d.down.right")) }
        if camera.macroModeEnabled { out.append(.init(id: "macro", symbol: "camera.macro")) }
        if camera.pushPullEnabled && camera.pushPullAmount != 0 {
            out.append(.init(id: "pp", symbol: "plusminus", text: String(format: "%+d", Int(camera.pushPullAmount))))
        }
        if camera.rawEnabled { out.append(.init(id: "raw", symbol: "r.square")) }
        if camera.thermalWarning != nil { out.append(.init(id: "heat", symbol: "thermometer.medium", tint: .orange)) }
        if camera.isFocusing { out.append(.init(id: "focus", symbol: "scope", pulse: true)) }
        else if camera.faceDetected && !camera.manualFocusEnabled { out.append(.init(id: "face", symbol: "face.dashed")) }
        return out
    }

    /// Up to two full-size glass circles beside the flash; a third slot
    /// becomes "+N". Tapping opens the roll (for the roll icon) or Modes.
    @ViewBuilder private var statusCircles: some View {
        let icons = statusIcons
        let shown = icons.count > 2 ? Array(icons.prefix(1)) : icons
        ForEach(shown) { icon in
            Button {
                if icon.id == "roll" { onRoll() } else { active = .modes; showControls = true }
            } label: { statusLabel(icon) }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel(icon.id)
        }
        if icons.count > 2 {
            Button { active = .modes; showControls = true } label: {
                Text("+\(icons.count - 1)")
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(.yellow)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("\(icons.count - 1) more active modes")
        }
    }

    private func statusLabel(_ icon: StatusIcon) -> some View {
        VStack(spacing: 0) {
            Image(systemName: icon.symbol)
                .font(.system(size: icon.text == nil ? 16 : 13, weight: .semibold))
                .symbolEffect(.pulse, isActive: icon.pulse)
            if let t = icon.text {
                Text(t).font(.system(size: 9, weight: .bold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(icon.tint)
        .frame(width: 44, height: 44)
    }

    private var flashSymbol: String {
        switch camera.flashMode {
        case .off: "bolt.slash.fill"
        case .on: "bolt.fill"
        default: "bolt.badge.automatic.fill"
        }
    }

    // MARK: Context rulers (only for modes that need a live value)

    @ViewBuilder private var contextRulers: some View {
        VStack(spacing: 8) {
            if camera.portraitModeEnabled {
                GlassRuler(title: "Aperture", valueText: String(format: "ƒ%.1f", camera.portraitFStop),
                           value: Binding(get: { Double(camera.portraitFStop) },
                                          set: { camera.portraitFStop = Float($0); camera.pendingPortraitFStop = Float($0) }),
                           range: 1.4...16)
            }
            if camera.manualFocusEnabled {
                GlassRuler(title: "Focus", valueText: camera.manualFocusValue < 0.5 ? "Near" : "Far",
                           value: Binding(get: { Double(camera.manualFocusValue) }, set: { camera.setManualFocus(Float($0)) }),
                           range: 0...1)
            }
            if camera.isLongExposure {
                GlassRuler(title: "Long exposure", valueText: String(format: "%.1f s", camera.longExposureDuration),
                           value: Binding(get: { camera.longExposureDuration }, set: { camera.longExposureDuration = ($0 * 2).rounded() / 2 }),
                           range: 1...30)
            }
            if camera.doubleExposureEnabled && camera.firstExposurePreview != nil {
                Button { camera.firstExposurePreview = nil } label: {
                    Label("Retake first exposure", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 36)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            if camera.doubleExposureEnabled {
                GlassRuler(title: "Blend", valueText: "\(Int(camera.doubleExposureOpacity * 100))%",
                           value: $camera.doubleExposureOpacity, range: 0...1)
            }
        }
    }

    // MARK: Controls

    private var controlsRow: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(visibleKinds) { k in
                    let on = k == active
                    Button { active = k } label: {
                        Image(systemName: k.symbol).font(.system(size: 17, weight: .medium))
                        .foregroundStyle(on ? .black : .white)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(on ? Color.yellow : .clear))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel(k.title)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Button(action: onSettings) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("More settings")
            }
        }
    }

    private var styleOn: Bool { camera.activeCustomSim == nil && camera.selectedSim.styleKind != nil }
    private var visibleKinds: [ControlKind] { ControlKind.allCases.filter { $0 != .style || styleOn } }

    @ViewBuilder private var controlPanel: some View {
        switch active {
        case .suggest:
            suggestPanel
        case .style:
            VStack(spacing: 10) {
                StylePad(settings: styleSettings, name: camera.selectedSim.label)
                GlassRuler(title: "Palette", valueText: "\(Int(styleSettings.palette * 100))%",
                           value: Binding(get: { Double(styleSettings.palette) }, set: { styleSettings.palette = Float($0) }),
                           range: 0...1)
            }
        case .halation:
            GlassRuler(title: "Halation", valueText: camera.halationEnabled ? "\(Int(camera.halationAmount * 100))" : "Off",
                       isOn: $camera.halationEnabled,
                       value: Binding(get: { Double(camera.halationAmount) }, set: { camera.halationAmount = Float($0) }),
                       range: 0...1)
        case .exposure:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button { smartAE.enabled.toggle() } label: {
                        Label(smartAE.enabled ? "Smart" : "Apple auto", systemImage: smartAE.enabled ? "sparkles" : "a.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(smartAE.enabled ? .black : .white)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Capsule().fill(smartAE.enabled ? Color.yellow : Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Switches between smart exposure and Apple's standard auto exposure")
                    if smartAE.enabled {
                        Text(smartAE.status.isEmpty ? "Balanced" : smartAE.status)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .contentTransition(.opacity)
                    }
                }
                GlassRuler(title: smartAE.enabled ? "Your offset" : "Exposure",
                           valueText: String(format: "%+.1f", camera.exposureBias),
                           value: Binding(get: { Double(camera.exposureBias) },
                                          set: { camera.setExposureBias(Float(($0 * 3).rounded() / 3)) }),
                           range: -3...3)
            }
        case .effects:
            tilePanel(title: "Effects", tiles: [
                Tile(title: "Crosstalk", symbol: "circle.hexagongrid", isOn: $camera.crosstalkEnabled),
                Tile(title: "Rolloff", symbol: "circle.lefthalf.striped.horizontal", isOn: $camera.rolloffEnabled),
                Tile(title: "Flares", symbol: "rays", isOn: $camera.anamorphicFlareEnabled),
                Tile(title: "Light leaks", symbol: "light.max", isOn: $camera.lightArtifactsEnabled),
                Tile(title: "Scratches", symbol: "scribble", isOn: $camera.filmScratchesEnabled),
                Tile(title: "Randomise", symbol: "dice", isOn: $camera.filmRandomizationEnabled),
            ])
        case .modes:
            VStack(spacing: 10) {
                tilePanel(title: "Shooting modes", tiles: [
                    Tile(title: "Burst", symbol: "square.stack.3d.down.right", isOn: $camera.burstMode),
                    Tile(title: "Macro", symbol: "camera.macro", isOn: $camera.macroModeEnabled),
                    Tile(title: "Long exp.", symbol: "timer", isOn: $camera.isLongExposure),
                    Tile(title: "Double exp.", symbol: "circle.lefthalf.filled", isOn: $camera.doubleExposureEnabled),
                    Tile(title: "Push / pull", symbol: "plusminus", isOn: $camera.pushPullEnabled),
                    Tile(title: "RAW+", symbol: "r.square", isOn: $camera.rawEnabled),
                    Tile(title: "Portrait", symbol: "person.crop.circle", isOn: $camera.portraitModeEnabled,
                         enabled: camera.portraitModeAvailable && CameraManager.hasDepthCamera
                            && focalPresets.indices.contains(camera.selectedFocalIndex)
                            && focalPresets[camera.selectedFocalIndex].deviceType != .builtInUltraWideCamera),
                    Tile(title: "Manual focus", symbol: "scope",
                         isOn: Binding(get: { camera.manualFocusEnabled }, set: { camera.setManualFocusEnabled($0) })),
                    Tile(title: "One lens", symbol: "arrow.left.and.right.circle", isOn: $camera.unifiedZoomMode),
                ])
                if camera.pushPullEnabled {
                    segmentRow(title: "Push / pull",
                               options: [(-2, "−2"), (-1, "−1"), (0, "0"), (1, "+1"), (2, "+2"), (3, "+3")],
                               selected: Int(camera.pushPullAmount)) { camera.pushPullAmount = Float($0) }
                }
                if camera.isLongExposure {
                    segmentRow(title: "Long exposure",
                               options: LongExposureMode.allCases.enumerated().map { ($0.offset, $0.element.label) },
                               selected: LongExposureMode.allCases.firstIndex(of: camera.longExposureMode) ?? 0) {
                        camera.longExposureMode = LongExposureMode.allCases[$0]
                    }
                }
            }
        case .view:
            VStack(spacing: 10) {
                tilePanel(title: "View", tiles: [
                    Tile(title: "Grid", symbol: "grid", isOn: $camera.showGrid),
                    Tile(title: "Level", symbol: "level", isOn: $camera.showLevel),
                    Tile(title: "Peaking", symbol: "scope", isOn: $camera.showPeaking),
                    Tile(title: "Zebras", symbol: "line.diagonal", isOn: $camera.showZebras),
                ])
                segmentRow(title: "Aspect",
                           options: AspectRatio.allCases.enumerated().map { ($0.offset, $0.element.label) },
                           selected: AspectRatio.allCases.firstIndex(of: camera.selectedAspectRatio) ?? 0) {
                    camera.selectedAspectRatio = AspectRatio.allCases[$0]
                }
            }
        }
    }

    // MARK: Film suggestions

    private var suggestPanel: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let reading = FilmSuggest.read(device: camera.currentDevice, ev: camera.evReading,
                                           faces: camera.faceDetected)
            VStack(alignment: .leading, spacing: 10) {
                if let reading {
                    let s = FilmSuggest.suggest(reading)
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.reason).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("\(Int(reading.kelvin.rounded() / 100) * 100)K · EV \(Int(reading.ev.rounded()))")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    HStack(spacing: 8) {
                        ForEach(s.films) { f in
                            let on = camera.activeCustomSim == nil && camera.selectedSim == f
                            Button {
                                camera.selectedSim = f
                                customSimStore.activeCustomSimID = nil
                                camera.activeCustomSim = nil
                            } label: {
                                VStack(spacing: 6) {
                                    Circle().fill(tones.tone(FavoritesStore.key(f))).frame(width: 14, height: 14)
                                    Text(f.label).font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1).minimumScaleFactor(0.75)
                                }
                                .foregroundStyle(on ? .black : .white)
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(on ? Color.yellow : Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text("Reading the light…").font(.system(size: 14, weight: .semibold))
                }
            }
            .padding(14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    /// A grid of icon tiles, three across, with even text.
    private func tilePanel(title: String, tiles: [Tile]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased()).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("\(tiles.filter { $0.isOn.wrappedValue }.count) on").foregroundStyle(.yellow)
            }
            .font(.system(size: 12, weight: .semibold)).tracking(0.8)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(tiles.indices, id: \.self) { i in
                    let t = tiles[i]
                    let on = t.isOn.wrappedValue
                    Button { t.isOn.wrappedValue.toggle() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: t.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 18)
                            Text(t.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(on ? .black : .white)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(on ? Color.yellow : Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!t.enabled)
                    .opacity(t.enabled ? 1 : 0.4)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func segmentRow(title: String, options: [(Int, String)], selected: Int,
                            set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
            HStack(spacing: 4) {
                ForEach(options, id: \.0) { opt in
                    let on = opt.0 == selected
                    Button { set(opt.0) } label: {
                        Text(opt.1).font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(on ? .black : .white)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(Capsule().fill(on ? Color.yellow : Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: Grain (beside the shutter)

    private var grainKind: (label: String, symbol: String) {
        if camera.activeCustomSim == nil {
            if camera.selectedSim == .digiCam { return ("Lines", "line.3.horizontal") }
            if camera.selectedSim == .circuitBent || camera.selectedSim == .circuitBentHeavy { return ("Wild", "waveform.path") }
        }
        return ("Context", "waveform.badge.magnifyingglass")
    }

    private var grainPanel: some View {
        VStack(spacing: 8) {
            GlassRuler(title: "Grain", valueText: camera.grainEnabled ? "\(Int(camera.grainAmount * 200))" : "Off",
                       isOn: $camera.grainEnabled,
                       value: Binding(get: { Double(camera.grainAmount) }, set: { camera.grainAmount = Float($0) }),
                       range: 0...0.5)
            Button {
                camera.contextAwareGrainEnabled.toggle()
                if camera.contextAwareGrainEnabled { camera.grainEnabled = true }
            } label: {
                Label(grainKind.label, systemImage: grainKind.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(camera.contextAwareGrainEnabled ? .black : .white)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(Capsule().fill(camera.contextAwareGrainEnabled ? Color.yellow : .clear))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityHint(grainKind.label == "Context"
                               ? "More grain in dark areas, less in bright ones, like real film"
                               : "Changes how this film's texture behaves")
        }
    }

    private var grainButton: some View {
        Button { showGrain.toggle(); if showGrain { showControls = false } } label: {
            Image(systemName: camera.grainEnabled ? "circle.grid.3x3.fill" : "circle.grid.3x3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(showGrain ? .black : (camera.grainEnabled ? .yellow : .white))
                .frame(width: 40, height: 40)
                .background(Circle().fill(showGrain ? Color.yellow : .clear))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(camera.grainEnabled ? "Grain on" : "Grain off")
    }

    // MARK: Bottom

    private var bottomRows: some View {
        VStack(spacing: 6) {
            HStack(spacing: 30) {
                modeButton("VIDEO", on: mode == .video) { mode = .video }
                modeButton("PHOTO", on: mode == .photo) { mode = .photo }
                modeButton("SONY", on: false, action: onSony)
            }
            .padding(.top, 6)
            Group {
                if camera.shutterOnLeft {
                    // Left-handed: shutter under the left thumb, grain beside it.
                    HStack(spacing: 18) {
                        shutterForMode
                        grainButton
                        Spacer()
                        thumbButton
                        flipButton
                    }
                } else {
                    // Shutter dead centre, like the Camera app.
                    ZStack {
                        HStack {
                            thumbButton
                            Spacer()
                            flipButton
                        }
                        shutterForMode
                        // Grain sits just right of the shutter.
                        // Grain hugs the shutter as its accessory (10 pt gap).
                        grainButton.offset(x: 42 + 10 + 20)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .background(Color.black.ignoresSafeArea(edges: .bottom))
    }

    private var flipButton: some View {
        Button { camera.flipCamera() } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(camera.isFrontCamera ? "Switch to back camera" : "Switch to front camera")
    }

    private var thumbButton: some View {
        Button(action: onAlbum) {
            LastShotThumb(token: thumbToken, hidden: roll.isLoaded, preview: camera.lastShotPreview)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Last photo")
    }

    @ViewBuilder private var shutterForMode: some View {
        if mode == .video { videoShutter } else { shutter() }
    }

    private func modeButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold)).tracking(1.2)
                .foregroundStyle(on ? Color.yellow : .white.opacity(0.8))
                .frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
    }

    private var videoShutter: some View {
        Button {
            if camera.isRecording { camera.stopRecording() } else { camera.startRecording() }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: camera.isRecording ? 7 : 31, style: .continuous)
                    .fill(Color.red)
                    .frame(width: camera.isRecording ? 30 : 62, height: camera.isRecording ? 30 : 62)
            }
            .animation(.spring(duration: 0.3, bounce: 0.2), value: camera.isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(camera.isRecording ? "Stop recording" : "Start recording")
    }

    // MARK: Film arc data

    /// The films on the dial, after the All / Pinned / Built-in / Custom / LUTs choice.
    private var shownItems: [ArcItem] {
        let films = filteredItems
        return [.setSwitch("lead", title: arcSet.title)] + films + [.setSwitch("trail", title: arcSet.title)]
    }

    private var filteredItems: [ArcItem] {
        switch arcSet {
        case .all: return arcItems
        case .pinned: return arcItems.filter { favorites.isFavorite($0.key) }
        case .builtIn: return arcItems.filter { $0.sim != nil && $0.sim?.styleKind == nil }
        case .styles: return arcItems.filter { $0.sim?.styleKind != nil }
        case .custom: return arcItems.filter { $0.custom != nil && $0.custom?.lutFilename == nil }
        case .luts: return arcItems.filter { $0.custom?.lutFilename != nil }
        }
    }

    private var arcItems: [ArcItem] {
        let pinnedBuilt = favorites.builtIns
        let pinnedCustom = favorites.customs(in: customSimStore.simulations)
        var seen = Set<String>()
        var out: [ArcItem] = []
        func add(_ i: ArcItem) { if seen.insert(i.key).inserted { out.append(i) } }
        add(.builtIn(.none))
        pinnedBuilt.forEach { add(.builtIn($0)) }
        pinnedCustom.forEach { add(.custom($0)) }
        FilmSimulation.allCases.forEach { add(.builtIn($0)) }
        customSimStore.simulations.forEach { add(.custom($0)) }
        return out
    }

    private var selectedKey: String {
        if let c = camera.activeCustomSim { return FavoritesStore.key(c) }
        return FavoritesStore.key(camera.selectedSim)
    }

    private func select(_ item: ArcItem) {
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

    // MARK: Zoom scrub (press and drag on the lens pill)

    private func scrub(_ dx: CGFloat) {
        if scrubStartMM == nil {
            scrubStartMM = Double(max(camera.currentMM, 13))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        guard let start = scrubStartMM else { return }
        let deg = Double(dx) * 180 / (Double.pi * 414)
        let maxMM = 26 * camera.maxManualZoom
        let mm = min(max(start * exp(-deg / ZoomArc.degPerLn), 13), maxMM)
        // A soft click as the dial passes a preset.
        let crossed = focalPresets.firstIndex { abs(Double($0.mm) - mm) < 0.6 }
        if let crossed, crossed != lastPresetCrossed { UISelectionFeedbackGenerator().selectionChanged() }
        lastPresetCrossed = crossed
        scrubMM = mm
        camera.setZoom(CGFloat(mm / 26))
    }

    private func endScrub() {
        guard scrubStartMM != nil else { return }
        camera.zoom = scrubMM / 26
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { camera.syncZoomState() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { scrubStartMM = nil; lastPresetCrossed = nil }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Glass ruler

/// A tick ruler with a yellow marker; drag anywhere on it to set the value.
struct GlassRuler: View {
    let title: String
    let valueText: String
    var isOn: Binding<Bool>? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(title.uppercased()).foregroundStyle(.white.opacity(0.85))
                Text(valueText).foregroundStyle(.yellow).monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold)).tracking(1)
            HStack(spacing: 12) {
                if let isOn {
                    Toggle("", isOn: isOn).labelsHidden().tint(.yellow).scaleEffect(0.8)
                        .frame(width: 44)
                        .accessibilityLabel("\(title) on")
                }
                GeometryReader { geo in
                    let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                    ZStack(alignment: .leading) {
                        HStack(spacing: 0) {
                            ForEach(0..<31, id: \.self) { i in
                                Capsule().fill(.white.opacity(0.7))
                                    .frame(width: 1.5, height: i % 5 == 0 ? 18 : 9)
                                if i < 30 { Spacer(minLength: 0) }
                            }
                        }
                        Capsule().fill(Color.yellow)
                            .frame(width: 3, height: 30)
                            .offset(x: CGFloat(min(max(frac, 0), 1)) * (geo.size.width - 3))
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        let f = min(max(g.location.x / geo.size.width, 0), 1)
                        value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                    })
                }
                .frame(height: 32)
                .opacity(isOn?.wrappedValue == false ? 0.4 : 1)
                .accessibilityElement()
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
                .accessibilityAdjustableAction { dir in
                    let stepV = (range.upperBound - range.lowerBound) / 20
                    value = min(max(value + (dir == .increment ? stepV : -stepV), range.lowerBound), range.upperBound)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - Last-shot thumbnail

struct LastShotThumb: View {
    let token: Int
    let hidden: Bool          // film roll loaded: no peeking
    var preview: UIImage? = nil   // the shot just taken, before it reaches Photos
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.12))
            if hidden {
                Image(systemName: "film").font(.system(size: 18)).foregroundStyle(.white.opacity(0.8))
            } else if let image = preview ?? image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .task(id: token) { await load() }
    }

    private func load() async {
        guard !hidden,
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
              let album = PhotoSaver.albumIfExists() else { return }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(in: album, options: opts).firstObject else { return }
        let req = PHImageRequestOptions()
        req.deliveryMode = .opportunistic
        req.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 150, height: 150),
                                              contentMode: .aspectFill, options: req) { img, _ in
            if let img { image = img }
        }
    }
}


// MARK: - Dial set

enum ArcSet: String, CaseIterable, Identifiable {
    case all, pinned, builtIn, styles, custom, luts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All films"
        case .pinned: "Pinned"
        case .builtIn: "Built-in"
        case .styles: "Styles"
        case .custom: "Your films"
        case .luts: "LUTs"
        }
    }
    var symbol: String {
        switch self {
        case .all: "film.stack"
        case .pinned: "star.fill"
        case .builtIn: "film"
        case .styles: "paintpalette.fill"
        case .custom: "paintbrush.fill"
        case .luts: "cube.fill"
        }
    }
}

// MARK: - Exposure meter (glass)

/// A viewfinder-style exposure scale: −2 … +2 in thirds. The yellow caret is
/// your offset; when smart exposure is on, a small white dot shows where it
/// is steering on top of that.
struct GlassEVMeter: View {
    let bias: Float
    let correction: Float
    let smart: Bool

    private let span: CGFloat = 78          // width of the scale
    private func x(_ ev: Float) -> CGFloat { CGFloat(max(-2, min(2, ev)) / 2) * span / 2 }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                // ticks: thirds, with taller ones on whole stops
                ForEach(-6...6, id: \.self) { k in
                    Capsule()
                        .fill(.white.opacity(k == 0 ? 0.95 : (k % 3 == 0 ? 0.75 : 0.4)))
                        .frame(width: k == 0 ? 1.5 : 1, height: k == 0 ? 10 : (k % 3 == 0 ? 7 : 4))
                        .offset(x: CGFloat(k) / 6 * span / 2, y: 3)
                }
                // your offset
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.yellow)
                    .offset(x: x(bias), y: -6)
                // smart exposure's steering
                if smart {
                    Circle().fill(.white)
                        .frame(width: 4, height: 4)
                        .offset(x: x(bias + correction), y: 11)
                }
            }
            .frame(width: span + 4, height: 30)
            .animation(.snappy(duration: 0.25), value: bias)
            .animation(.smooth(duration: 0.4), value: correction)

            VStack(alignment: .trailing, spacing: 0) {
                Text(String(format: "%+.1f", bias))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(smart ? "SMART" : "AUTO")
                    .font(.system(size: 8, weight: .bold)).tracking(0.8)
                    .foregroundStyle(smart ? .yellow : .white.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

/// Pulsing ring while the camera hunts for focus.
struct FocusPulse: View {
    @State private var on = false
    var body: some View {
        Circle()
            .stroke(Color.yellow.opacity(on ? 0.9 : 0.35), lineWidth: 1.5)
            .frame(width: 14, height: 14)
            .scaleEffect(on ? 1.15 : 0.9)
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityLabel("Focusing")
    }
}


// MARK: - Style pad

/// Apple-style 2D pad: drag up/down for Tone, left/right for Colour.
struct StylePad: View {
    @Bindable var settings: StyleSettings
    let name: String

    var body: some View {
        HStack(spacing: 14) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.white.opacity(0.08))
                    // grid
                    Path { p in
                        for i in 1..<4 {
                            let x = w * CGFloat(i) / 4, y = h * CGFloat(i) / 4
                            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                        }
                    }
                    .stroke(.white.opacity(0.15), lineWidth: 1)
                    Circle().fill(Color.yellow)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .position(x: CGFloat(settings.color + 1) / 2 * w,
                                  y: CGFloat(1 - settings.tone) / 2 * h)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    settings.color = Float(min(max(g.location.x / w, 0), 1) * 2 - 1)
                    settings.tone = Float(1 - min(max(g.location.y / h, 0), 1) * 2)
                })
                .onTapGesture(count: 2) { settings.tone = 0; settings.color = 0 }
            }
            .frame(width: 112, height: 112)
            .accessibilityElement()
            .accessibilityLabel("Style pad")
            .accessibilityValue(String(format: "Tone %+.0f, Colour %+.0f", settings.tone * 100, settings.color * 100))

            VStack(alignment: .leading, spacing: 8) {
                Text(name.uppercased())
                    .font(.system(size: 13, weight: .bold)).tracking(0.8)
                    .foregroundStyle(.yellow)
                row("Tone", settings.tone)
                row("Colour", settings.color)
                Text("Drag the pad. Double-tap to reset.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func row(_ title: String, _ v: Float) -> some View {
        HStack {
            Text(title).foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(String(format: "%+.0f", v * 100)).foregroundStyle(.white).monospacedDigit()
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 120)
    }
}
