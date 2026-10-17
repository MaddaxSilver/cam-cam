//
//  SonyGlassChrome.swift
//  cam cam
//
//  The Sony remote in the same glass language as the iPhone camera:
//  connection pill + chevron + histogram on top, a settings pill whose
//  choice turns the dial into Film / ISO / Shutter / Aperture / EV, and the
//  Camera-style bottom row (last download · shutter · back to iPhone).
//

import SwiftUI

struct SonyGlassChrome: View {
    @Bindable var sony: SonyConnector
    @Bindable var camera: CameraManager
    let customSimStore: CustomSimStore
    @Binding var showGrid: Bool
    @Binding var rotationLocked: Bool
    @Binding var showDebugLog: Bool
    var onClose: () -> Void
    var onOpenLast: () -> Void
    var onImportLUT: () -> Void

    enum Dial: String, CaseIterable, Identifiable { case film, iso, shutter, aperture, ev; var id: String { rawValue } }
    @State private var dial: Dial = .film
    @State private var showPanel = false
    @State private var favorites = FavoritesStore.shared
    @State private var tones = FilmToneStore.shared
    @State private var statusVisible = false

    var body: some View {
        VStack(spacing: 0) {
            topBar.padding(.horizontal, 16).padding(.top, 58)
            if statusVisible, !sony.shutterStatus.isEmpty {
                Text(sony.shutterStatus)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 10).padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Spacer(minLength: 0)
            if showPanel {
                panel.padding(.horizontal, 16).padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            settingsPill.padding(.bottom, 12)
            dialView
            bottomRows
        }
        .background {
            if showPanel {
                Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { showPanel = false }
            }
        }
        .animation(.snappy(duration: 0.3), value: showPanel)
        .animation(.snappy(duration: 0.25), value: statusVisible)
        .animation(.snappy(duration: 0.25), value: dial)
        .onChange(of: sony.shutterStatus) { _, s in
            guard !s.isEmpty else { return }
            statusVisible = true
            Task {
                try? await Task.sleep(for: .seconds(3))
                if sony.shutterStatus == s { statusVisible = false }
            }
        }
        .task { tones.ensure(filmItems, camera: camera) }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .top) {
            Button { showDebugLog.toggle() } label: {
                HStack(spacing: 7) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text(modelName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if sony.downloadQueueDepth > 0 {
                        Text("↓\(sony.downloadQueueDepth)").font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundStyle(.yellow)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityLabel("Connected to \(modelName). Show connection log")

            Spacer()

            if sony.showHistogram, !sony.liveHistogram.isEmpty {
                HistogramView(bins: sony.liveHistogram)
                    .frame(width: 96, height: 44)
            }
        }
        .overlay(alignment: .top) {
            Button { showPanel.toggle() } label: {
                Image(systemName: showPanel ? "chevron.down" : "chevron.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(showPanel ? .black : .white)
                    .frame(width: 64, height: 32)
                    .background(Capsule().fill(showPanel ? Color.yellow : .clear))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .padding(.top, 6)
            .accessibilityLabel(showPanel ? "Hide options" : "Show options")
        }
    }

    private var modelName: String {
        if case .connected(let m) = sony.state { return m }
        return "Sony"
    }

    // MARK: Settings pill (picks what the dial controls)

    private var settingsPill: some View {
        HStack(spacing: 1) {
            ForEach(Dial.allCases) { d in
                let on = d == dial
                Button { dial = d } label: {
                    Text(label(for: d))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .foregroundStyle(on ? Color.yellow : .white)
                        .padding(.horizontal, 9).frame(height: 34)
                        .background(Capsule().fill(on ? Color.black.opacity(0.45) : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func label(for d: Dial) -> String {
        switch d {
        case .film: return "Film"
        case .iso: return sony.sonyISO.isEmpty ? "ISO" : "ISO \(sony.sonyISO)"
        case .shutter: return sony.sonyShutterSpeed.isEmpty ? "Shutter" : sony.sonyShutterSpeed
        case .aperture: return sony.sonyAperture.isEmpty ? "ƒ" : "ƒ\(sony.sonyAperture)"
        case .ev: return String(format: "%+.1f", sony.sonyEVComp)
        }
    }

    // MARK: Dial

    @ViewBuilder private var dialView: some View {
        switch dial {
        case .film:
            FilmArc(items: filmItems, selectedKey: selectedFilmKey, onSelect: selectFilm, onOpenLibrary: {})
        case .iso:
            valueArc(sony.isoCandidates, current: sony.sonyISO, display: { $0.replacingOccurrences(of: "ISO ", with: "") }) {
                sony.setIso($0)
            }
        case .shutter:
            valueArc(sony.shutterSpeedCandidates, current: sony.sonyShutterSpeed, display: { $0 }) {
                sony.setShutterSpeed($0)
            }
        case .aperture:
            valueArc(sony.apertureCandidates, current: sony.sonyAperture, display: { "ƒ" + $0 }) {
                sony.setAperture($0)
            }
        case .ev:
            let steps = Array(stride(from: sony.evMin, through: sony.evMax, by: 1))
            let div: Float = sony.evStep == 2 ? 2 : 3
            valueArc(steps.map(String.init), current: String(sony.evRawValue),
                     display: { String(format: "%+.1f", (Float($0) ?? 0) / div) }) {
                if let v = Int($0) { sony.setExposureComp(v) }
            }
        }
    }

    /// A dial over the camera's own list of allowed values.
    private func valueArc(_ values: [String], current: String, display: @escaping (String) -> String,
                          set: @escaping (String) -> Void) -> some View {
        let items = values.map { ArcItem(key: "v:\($0)", label: display($0), sim: nil, custom: nil) }
        let cur = values.first { $0 == current || display($0) == current || $0.replacingOccurrences(of: "ISO ", with: "") == current }
        return Group {
            if items.isEmpty {
                Text("The camera hasn't reported values yet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(height: 92)
            } else {
                FilmArc(items: items, selectedKey: cur.map { "v:\($0)" },
                        onSelect: { item in set(String(item.key.dropFirst(2))) }, onOpenLibrary: {})
            }
        }
    }

    private var filmItems: [ArcItem] {
        var seen = Set<String>()
        var out: [ArcItem] = []
        func add(_ i: ArcItem) { if seen.insert(i.key).inserted { out.append(i) } }
        add(.builtIn(.none))
        favorites.builtIns.forEach { add(.builtIn($0)) }
        favorites.customs(in: customSimStore.simulations).forEach { add(.custom($0)) }
        FilmSimulation.allCases.forEach { add(.builtIn($0)) }
        customSimStore.simulations.forEach { add(.custom($0)) }
        return out
    }

    private var selectedFilmKey: String {
        if let c = sony.activeCustomSim { return FavoritesStore.key(c) }
        return FavoritesStore.key(sony.selectedSim)
    }

    private func selectFilm(_ item: ArcItem) {
        if let c = item.custom {
            customSimStore.activeCustomSimID = c.id
            camera.activeCustomSim = c; camera.selectedSim = .none
            sony.activeCustomSim = c;   sony.selectedSim = .none
        } else if let s = item.sim {
            customSimStore.activeCustomSimID = nil
            camera.selectedSim = s; camera.activeCustomSim = nil
            sony.selectedSim = s;   sony.activeCustomSim = nil
        }
    }

    // MARK: Options panel

    @State private var guides = SonyGuides.shared
    @State private var poseGuide = PoseGuide.shared

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SONY").font(.system(size: 12, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.white.opacity(0.85))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                tile("Histogram", "chart.bar.fill", $sony.showHistogram)
                tile("Zebras", "line.diagonal", $sony.showZebras)
                tile("Grid", "grid", $showGrid)
                tile("Lock turn", "lock.rotation", $rotationLocked)
                tile("Auto-save", "square.and.arrow.down", $sony.autoSave)
                tile("Log", "text.alignleft", $showDebugLog)
                tile("Frame guide", "viewfinder.rectangular", $guides.frameOn)
                tile("Pose guide", "figure.stand", $poseGuide.enabled)
                tile("Auto shoot", "camera.shutter.button", $guides.autoShoot)
                tile("Sharp live view", "4k.tv", $sony.sharpLiveView)
            }
            Button(action: onImportLUT) {
                Label("Import LUT", systemImage: "cube")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func tile(_ title: String, _ symbol: String, _ isOn: Binding<Bool>) -> some View {
        let on = isOn.wrappedValue
        return Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 18)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? .black : .white)
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(on ? Color.yellow : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Bottom

    private var bottomRows: some View {
        VStack(spacing: 6) {
            HStack(spacing: 30) {
                Button(action: onClose) {
                    Text("PHOTO").font(.system(size: 12.5, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(.white.opacity(0.8)).frame(minHeight: 28)
                }
                .buttonStyle(.plain)
                Text("SONY").font(.system(size: 12.5, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(.yellow).frame(minHeight: 28)
            }
            .padding(.top, 6)
            ZStack {
                HStack {
                    Button(action: onOpenLast) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.12))
                            if let t = sony.lastProcessedThumb {
                                Image(uiImage: t).resizable().scaledToFill()
                            }
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Last Sony photo")
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "iphone").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white).frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Back to the iPhone camera")
                }
                Button { sony.triggerShutter() } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                        Circle().fill(.white).frame(width: 64, height: 64)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Take a photo on the Sony")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .background(Color.black.ignoresSafeArea(edges: .bottom))
    }
}
