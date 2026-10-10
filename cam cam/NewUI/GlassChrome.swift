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
    case grain, halation, exposure, effects, aspect
    var id: String { rawValue }
    var title: String {
        switch self {
        case .grain: "Grain"
        case .halation: "Halation"
        case .exposure: "Exposure"
        case .effects: "Effects"
        case .aspect: "Aspect"
        }
    }
    var symbol: String {
        switch self {
        case .grain: "circle.grid.3x3.fill"
        case .halation: "sun.max"
        case .exposure: "plusminus.circle"
        case .effects: "sparkles"
        case .aspect: "aspectratio"
        }
    }
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
    @State private var active: ControlKind = .grain
    @State private var scrubStartMM: Double?
    @State private var scrubMM: Double = 35
    @State private var lastPresetCrossed: Int?
    @State private var favorites = FavoritesStore.shared
    @State private var roll = FilmRoll.shared
    @State private var tones = FilmToneStore.shared
    @State private var thumbToken = 0
    @State private var smartAE = SmartExposure.shared
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
            if showControls {
                controlPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                controlsRow
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                LensPill(selectedIndex: scrubStartMM == nil ? camera.selectedFocalIndex : -1,
                         liveMM: scrubStartMM == nil ? camera.currentMM : Int(scrubMM.rounded()),
                         scrubbing: scrubStartMM != nil,
                         onTap: { i in camera.selectFocalPreset(i) },
                         onScrub: scrub,
                         onScrubEnd: endScrub)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
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
            }
            bottomRows
        }
        .background {
            // While controls are open, a tap anywhere on the picture closes them.
            if showControls {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { showControls = false }
                    .accessibilityHidden(true)
            }
        }
        .confirmationDialog("Show on the dial", isPresented: $showSetPicker, titleVisibility: .visible) {
            ForEach(ArcSet.allCases) { set in
                Button(set == arcSet ? "\(set.title) ✓" : set.title) { arcSetRaw = set.rawValue }
            }
            Button("Cancel", role: .cancel) {}
        }
        .animation(.snappy(duration: 0.3), value: showControls)
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
                // Left: flash, then status chips (roll, focus, face).
                VStack(alignment: .leading, spacing: 10) {
                    Button { camera.toggleFlash() } label: {
                        Image(systemName: flashSymbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(camera.flashMode == .off ? .white : .yellow)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Flash \(camera.flashLabel)")

                    if roll.isLoaded {
                        Button(action: onRoll) {
                            HStack(spacing: 5) {
                                Image(systemName: "film").font(.system(size: 11, weight: .semibold))
                                Text(roll.isFull ? "Develop" : "\(roll.exposuresLeft)")
                                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            }
                            .foregroundStyle(roll.isFull ? .yellow : .white)
                            .padding(.horizontal, 11).frame(height: 30)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .accessibilityLabel("\(roll.exposuresLeft) frames left on the roll")
                    }

                    if camera.isFocusing || (camera.faceDetected && !camera.manualFocusEnabled) {
                        HStack(spacing: 6) {
                            if camera.isFocusing { FocusPulse() }
                            if camera.faceDetected && !camera.manualFocusEnabled {
                                Image(systemName: "face.dashed").font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .padding(.horizontal, 10).frame(height: 28)
                        .glassEffect(.regular, in: Capsule())
                        .transition(.opacity)
                    }
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
                ForEach(ControlKind.allCases) { k in
                    let on = k == active
                    Button { active = k } label: {
                        Group {
                            if k == .aspect {
                                Text(camera.selectedAspectRatio.label)
                                    .font(.system(size: 11, weight: .bold))
                            } else {
                                Image(systemName: k.symbol).font(.system(size: 17, weight: .medium))
                            }
                        }
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

    @ViewBuilder private var controlPanel: some View {
        switch active {
        case .grain:
            GlassRuler(title: "Grain", valueText: camera.grainEnabled ? "\(Int(camera.grainAmount * 200))" : "Off",
                       isOn: $camera.grainEnabled,
                       value: Binding(get: { Double(camera.grainAmount) }, set: { camera.grainAmount = Float($0) }),
                       range: 0...0.5)
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
            chipPanel(title: "Effects", chips: [
                ("Crosstalk", $camera.crosstalkEnabled), ("Rolloff", $camera.rolloffEnabled),
                ("Flares", $camera.anamorphicFlareEnabled), ("Leaks", $camera.lightArtifactsEnabled),
                ("Scratches", $camera.filmScratchesEnabled), ("Random", $camera.filmRandomizationEnabled),
            ])
        case .aspect:
            VStack(spacing: 8) {
                Text("ASPECT").font(.system(size: 12, weight: .semibold)).tracking(1)
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 6) {
                    ForEach(AspectRatio.allCases) { a in
                        let on = a == camera.selectedAspectRatio
                        Button { camera.selectedAspectRatio = a } label: {
                            Text(a.label).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(on ? .black : .white)
                                .padding(.horizontal, 10).frame(height: 32)
                                .background(Capsule().fill(on ? Color.yellow : Color.white.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func chipPanel(title: String, chips: [(String, Binding<Bool>)]) -> some View {
        VStack(spacing: 8) {
            Text("\(title.uppercased())  \(chips.filter { $0.1.wrappedValue }.count) ON")
                .font(.system(size: 12, weight: .semibold)).tracking(1)
                .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 6) {
                ForEach(chips.indices, id: \.self) { i in
                    let on = chips[i].1.wrappedValue
                    Button { chips[i].1.wrappedValue.toggle() } label: {
                        Text(chips[i].0).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? .black : .white)
                            .padding(.horizontal, 8).frame(height: 32)
                            .background(Capsule().fill(on ? Color.yellow : Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
            HStack(spacing: 18) {
                if camera.shutterOnLeft {
                    // Left-handed: shutter under the left thumb.
                    shutterForMode
                    Spacer()
                    thumbButton
                } else {
                    thumbButton
                    Spacer()
                    shutterForMode
                    Spacer()
                }
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
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .background(Color.black.ignoresSafeArea(edges: .bottom))
    }

    private var thumbButton: some View {
        Button(action: onAlbum) {
            LastShotThumb(token: thumbToken, hidden: roll.isLoaded)
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
        case .builtIn: return arcItems.filter { $0.sim != nil }
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
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.12))
            if hidden {
                Image(systemName: "film").font(.system(size: 18)).foregroundStyle(.white.opacity(0.8))
            } else if let image {
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
    case all, pinned, builtIn, custom, luts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All films"
        case .pinned: "Pinned"
        case .builtIn: "Built-in"
        case .custom: "Your films"
        case .luts: "LUTs"
        }
    }
    var symbol: String {
        switch self {
        case .all: "film.stack"
        case .pinned: "star.fill"
        case .builtIn: "film"
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
