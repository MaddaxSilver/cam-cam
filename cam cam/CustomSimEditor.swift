//
//  CustomSimEditor.swift
//  cam cam
//
//  Custom film-sim editor with live filtered preview.
//

import SwiftUI
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import Observation
import CoreMotion
import MediaPlayer
import MetalKit
import UniformTypeIdentifiers
import CoreLocation

// MARK: - Custom Sim Editor

// MARK: - Live Filtered Preview for Editor

@Observable final class FilteredPreviewRenderer: NSObject {
    var previewImage: CGImage?
    @ObservationIgnored nonisolated(unsafe) var currentSim: CustomSimulation = CustomSimulation()
    @ObservationIgnored nonisolated(unsafe) var applyCustomSim: ((CIImage, CustomSimulation) -> CIImage)?
    @ObservationIgnored nonisolated(unsafe) var lastFrameTime: CFAbsoluteTime = 0
    @ObservationIgnored nonisolated(unsafe) var sharedContext: CIContext?
    /// Hold-to-compare: show the scene without the film.
    @ObservationIgnored nonisolated(unsafe) var showOriginal = false
    private weak var camera: CameraManager?

    func start(session: AVCaptureSession, camera: CameraManager) {
        self.camera = camera
        self.sharedContext = camera.ciContext
        self.applyCustomSim = { [weak camera] image, sim in
            camera?.applyCustomSim(to: image, sim: sim) ?? image
        }
        // Ensure video data output is available, then register as receiver
        camera.addVideoDataOutputIfNeeded()
        camera.editorPreviewRenderer = self
    }

    func stop() {
        camera?.editorPreviewRenderer = nil
        camera = nil
    }

    /// Called from CameraManager.captureOutput on the video frame queue
    nonisolated func processFrame(pixelBuffer: CVPixelBuffer) {
        // Throttle to ~15fps for editor preview
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFrameTime > 0.066 else { return }
        lastFrameTime = now

        guard let context = sharedContext else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // Downsample for performance — quarter res for editor
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let sim = currentSim
        let filtered = showOriginal ? scaled : (applyCustomSim?(scaled, sim) ?? scaled)
        guard let cgImage = context.createCGImage(filtered, from: filtered.extent) else { return }
        DispatchQueue.main.async { self.previewImage = cgImage }
    }
}

// MARK: - Film editor (glass)

struct CustomSimEditorView: View {
    var store: CustomSimStore
    var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var editing: CustomSimulation?
    @State private var showDeleteConfirm = false
    @State private var previewRenderer = FilteredPreviewRenderer()
    @State private var tones = FilmToneStore.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let sim = editing {
                FilmEditDetail(sim: Binding(get: { sim }, set: { editing = $0; previewRenderer.currentSim = $0 }),
                               renderer: previewRenderer,
                               onBack: closeEditor,
                               onDelete: { showDeleteConfirm = true })
                    .transition(.move(edge: .trailing))
            } else {
                filmList.transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.3), value: editing == nil)
        .preferredColorScheme(.dark)
        .confirmationDialog("Delete this film?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete film", role: .destructive) {
                if let e = editing {
                    previewRenderer.stop()
                    store.delete(e)
                    editing = nil
                }
            }
        } message: { Text("Photos already taken with it keep their look.") }
        .onDisappear { previewRenderer.stop() }
    }

    private func open(_ sim: CustomSimulation) {
        editing = sim
        previewRenderer.currentSim = sim
        previewRenderer.start(session: camera.session, camera: camera)
    }

    private func closeEditor() {
        if let e = editing {
            store.update(e)
            tones.invalidate(FavoritesStore.key(e))
            if camera.activeCustomSim?.id == e.id { camera.activeCustomSim = e }
        }
        previewRenderer.stop()
        editing = nil
    }

    // MARK: List

    private var filmList: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Close")
                Spacer()
                Text("Your films").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { open(store.addNew()) } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.black).frame(width: 44, height: 44)
                        .background(Circle().fill(Color.yellow))
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("New film")
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)

            if store.simulations.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "paintpalette").font(.system(size: 44)).foregroundStyle(.white.opacity(0.5))
                    Text("Make your own film").font(.title3.weight(.semibold))
                    Text("Start from neutral and shape light, colour and tone with a live preview.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button { open(store.addNew()) } label: {
                        Text("New film").font(.headline).foregroundStyle(.black)
                            .padding(.horizontal, 28).frame(height: 50)
                            .background(Capsule().fill(Color.yellow))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(store.simulations) { sim in
                            Button { open(sim) } label: { card(sim) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                }
            }
        }
        .task { tones.ensure(store.simulations.map(ArcItem.custom), camera: camera) }
    }

    private func card(_ sim: CustomSimulation) -> some View {
        let active = store.activeCustomSimID == sim.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(tones.tone(FavoritesStore.key(sim))).frame(width: 28, height: 28)
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                Spacer()
                if sim.lutFilename != nil {
                    Text("LUT").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(Color.orange))
                }
                if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.yellow) }
            }
            Text(sim.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Text(summary(sim)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(active ? Color.yellow.opacity(0.7) : .clear, lineWidth: 1.5))
    }

    private func summary(_ sim: CustomSimulation) -> String {
        var parts: [String] = []
        if sim.temperature < 5500 { parts.append("Warm") } else if sim.temperature > 7500 { parts.append("Cool") }
        if sim.contrast > 1.15 { parts.append("contrasty") } else if sim.contrast < 0.9 { parts.append("soft") }
        if sim.saturation < 0.8 { parts.append("muted") } else if sim.saturation > 1.3 { parts.append("vivid") }
        if sim.fadeAmount > 0.03 { parts.append("faded") }
        if sim.bloomIntensity > 0.1 { parts.append("bloom") }
        if sim.vignetteIntensity > 0.5 { parts.append("vignette") }
        return parts.isEmpty ? "Neutral" : parts.joined(separator: " · ").capitalizedFirst
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Edit detail

private struct FilmEditDetail: View {
    @Binding var sim: CustomSimulation
    let renderer: FilteredPreviewRenderer
    var onBack: () -> Void
    var onDelete: () -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case light = "Light", colour = "Colour", tone = "Tone", channels = "Channels", effects = "Effects", more = "More"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .light
    @State private var comparing = false

    var body: some View {
        VStack(spacing: 0) {
            // Live preview, full width; hold to compare.
            ZStack(alignment: .top) {
                Group {
                    if let image = renderer.previewImage {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.05).overlay { ProgressView().tint(.white) }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 420)
                .clipped()
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !comparing { comparing = true; renderer.showOriginal = true } }
                    .onEnded { _ in comparing = false; renderer.showOriginal = false })
                .accessibilityLabel("Preview. Hold to see without the film.")

                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Save and go back")
                    Spacer()
                    TextField("Film name", text: $sim.name)
                        .font(.system(size: 15, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .frame(width: 170, height: 40)
                        .glassEffect(.regular, in: Capsule())
                    Spacer()
                    Button(action: onDelete) {
                        Image(systemName: "trash").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.red).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Delete film")
                }
                .padding(.horizontal, 16).padding(.top, 8)

                if comparing {
                    Text("ORIGINAL").font(.system(size: 11, weight: .bold)).tracking(1)
                        .padding(.horizontal, 10).frame(height: 24)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.top, 360)
                }
            }

            // Tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Tab.allCases) { t in
                        Button { tab = t } label: {
                            Text(t.rawValue).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(tab == t ? .black : .white)
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(Capsule().fill(tab == t ? Color.yellow : Color.white.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 10) { panel }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
            }
        }
        .animation(.snappy(duration: 0.2), value: tab)
    }

    @ViewBuilder private var panel: some View {
        switch tab {
        case .light:
            ruler("Brightness", $sim.brightness, -0.1...0.1)
            ruler("Contrast", $sim.contrast, 0.7...1.5, neutral: 1)
            resetButton { sim.brightness = 0; sim.contrast = 1 }
        case .colour:
            ruler("Saturation", $sim.saturation, 0...2, neutral: 1)
            ruler("Warmth", $sim.temperature, 3000...10000, neutral: 6500, kelvin: true)
            ruler("Tint", $sim.tint, -50...50)
            resetButton { sim.saturation = 1; sim.temperature = 6500; sim.tint = 0 }
        case .tone:
            ruler("Lift shadows", $sim.shadowLift, 0...0.15)
            ruler("Mid-tones", $sim.midShift, -0.1...0.1)
            ruler("Soften highlights", $sim.highlightRolloff, -0.1...0, neutral: 0)
            ruler("Fade", $sim.fadeAmount, 0...0.15)
            resetButton { sim.shadowLift = 0; sim.midShift = 0; sim.highlightRolloff = 0; sim.fadeAmount = 0 }
        case .channels:
            ruler("Red", $sim.redMult, 0.7...1.3, neutral: 1)
            ruler("Green", $sim.greenMult, 0.7...1.3, neutral: 1)
            ruler("Blue", $sim.blueMult, 0.7...1.3, neutral: 1)
            ruler("Red tint", $sim.redBias, -0.05...0.05)
            ruler("Green tint", $sim.greenBias, -0.05...0.05)
            ruler("Blue tint", $sim.blueBias, -0.05...0.05)
            resetButton {
                sim.redMult = 1; sim.greenMult = 1; sim.blueMult = 1
                sim.redBias = 0; sim.greenBias = 0; sim.blueBias = 0
            }
        case .effects:
            ruler("Vignette", $sim.vignetteIntensity, 0...2)
            ruler("Bloom", $sim.bloomIntensity, 0...0.5)
            if sim.bloomIntensity > 0 { ruler("Bloom size", $sim.bloomRadius, 2...20, neutral: 2) }
            ruler("Haze", $sim.hazeAmount, 0...1)
            ruler("Red-eye fix", $sim.redEyeStrength, 0...1)
        case .more:
            VStack(alignment: .leading, spacing: 10) {
                Text("CAPTURE QUALITY").font(.system(size: 12, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 6) {
                    ForEach(Array(["Speed", "Balanced", "Max"].enumerated()), id: \.offset) { i, label in
                        Button { sim.quality = i } label: {
                            Text(label).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(sim.quality == i ? .black : .white)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(Capsule().fill(sim.quality == i ? Color.yellow : Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Max uses Deep Fusion for the most detail; Speed shoots fastest.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            }
            .padding(14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Button(role: .destructive) {
                let name = sim.name, id = sim.id
                sim = CustomSimulation(); sim.name = name; sim.id = id
            } label: {
                Text("Reset whole film").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red).frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
    }

    /// Ruler showing a human value: kelvin for warmth, −100…+100 otherwise.
    private func ruler(_ title: String, _ v: Binding<Float>, _ range: ClosedRange<Float>,
                       neutral: Float = 0, kelvin: Bool = false) -> some View {
        let val = v.wrappedValue
        let text: String = {
            if kelvin { return "\(Int(val))K" }
            let span = max(range.upperBound - neutral, neutral - range.lowerBound, .ulpOfOne)
            return String(format: "%+.0f", (val - neutral) / span * 100)
        }()
        return GlassRuler(title: title, valueText: text,
                          value: Binding(get: { Double(v.wrappedValue) }, set: { v.wrappedValue = Float($0) }),
                          range: Double(range.lowerBound)...Double(range.upperBound))
    }

    private func resetButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Reset \(tab.rawValue.lowercased())", systemImage: "arrow.counterclockwise")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 36)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
