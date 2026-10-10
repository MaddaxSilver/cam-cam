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
        let filtered = applyCustomSim?(scaled, sim) ?? scaled
        guard let cgImage = context.createCGImage(filtered, from: filtered.extent) else { return }
        DispatchQueue.main.async { self.previewImage = cgImage }
    }
}

struct CustomSimEditorView: View {
    var store: CustomSimStore
    var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var editing: CustomSimulation?
    @State private var showDeleteConfirm = false
    @State private var previewRenderer = FilteredPreviewRenderer()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if store.simulations.isEmpty && editing == nil {
                    emptyState
                } else if let sim = editing {
                    VStack(spacing: 0) {
                        // Live filtered preview
                        livePreview
                            .frame(height: 220)
                            .clipped()

                        SimParameterEditor(sim: Binding(
                            get: { sim },
                            set: {
                                editing = $0
                                previewRenderer.currentSim = $0
                            }
                        ))
                    }
                } else {
                    simList
                }
            }
            .navigationTitle(editing != nil ? "Edit Film" : "Custom Films")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if editing != nil {
                        Button("Back") {
                            if let e = editing {
                                store.update(e)
                            }
                            previewRenderer.stop()
                            editing = nil
                        }
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if editing != nil {
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                    } else {
                        Button {
                            let newSim = store.addNew()
                            editing = newSim
                            startPreview(for: newSim)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20))
                        }
                    }
                }
            }
            .alert("Delete this film?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let e = editing {
                        previewRenderer.stop()
                        store.delete(e)
                        editing = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onDisappear {
                previewRenderer.stop()
            }
        }
    }

    private var livePreview: some View {
        Group {
            if let image = previewRenderer.previewImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black.overlay {
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func startPreview(for sim: CustomSimulation) {
        previewRenderer.currentSim = sim
        previewRenderer.start(session: camera.session, camera: camera)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "paintpalette")
                .font(.system(size: 48))
                .foregroundStyle(.gray)
            Text("No custom films yet")
                .font(.title3)
                .foregroundStyle(.gray)
            Button {
                let newSim = store.addNew()
                editing = newSim
            } label: {
                Label("Create Film", systemImage: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(.yellow))
            }
        }
    }

    private var simList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.simulations) { sim in
                    Button {
                        editing = sim
                        startPreview(for: sim)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sim.name)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(simSummary(sim))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer()
                            if store.activeCustomSimID == sim.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.yellow)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }

    private func simSummary(_ sim: CustomSimulation) -> String {
        var parts: [String] = []
        if sim.temperature < 5500 { parts.append("warm") }
        else if sim.temperature > 7500 { parts.append("cool") }
        if sim.contrast > 1.15 { parts.append("high contrast") }
        if sim.saturation < 0.8 { parts.append("desaturated") }
        else if sim.saturation > 1.3 { parts.append("vivid") }
        if sim.vignetteIntensity > 0.5 { parts.append("vignette") }
        if sim.fadeAmount > 0.03 { parts.append("faded") }
        if sim.bloomIntensity > 0.1 { parts.append("bloom") }
        return parts.isEmpty ? "Neutral" : parts.joined(separator: " \u{00b7} ")
    }
}

// MARK: - Parameter Editor

private struct SimParameterEditor: View {
    @Binding var sim: CustomSimulation

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Name field
                HStack {
                    Text("NAME")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                TextField("Film name", text: $sim.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)

                // Sections
                paramSection("EXPOSURE") {
                    paramSlider("Brightness", value: $sim.brightness, range: -0.1...0.1)
                    paramSlider("Contrast", value: $sim.contrast, range: 0.7...1.5, neutral: 1.0)
                    paramSlider("Saturation", value: $sim.saturation, range: 0.0...2.0, neutral: 1.0)
                }

                paramSection("WHITE BALANCE") {
                    paramSlider("Temperature", value: $sim.temperature, range: 3000...10000, neutral: 6500)
                    paramSlider("Tint", value: $sim.tint, range: -50...50)
                }

                paramSection("TONE CURVE") {
                    paramSlider("Shadow Lift", value: $sim.shadowLift, range: 0...0.15)
                    paramSlider("Midtone", value: $sim.midShift, range: -0.1...0.1)
                    paramSlider("Highlight Roll", value: $sim.highlightRolloff, range: -0.1...0.0)
                    paramSlider("Fade", value: $sim.fadeAmount, range: 0...0.15)
                }

                paramSection("COLOR CHANNELS") {
                    paramSlider("Red", value: $sim.redMult, range: 0.7...1.3, neutral: 1.0, tint: .red)
                    paramSlider("Green", value: $sim.greenMult, range: 0.7...1.3, neutral: 1.0, tint: .green)
                    paramSlider("Blue", value: $sim.blueMult, range: 0.7...1.3, neutral: 1.0, tint: .blue)
                }

                paramSection("COLOR BIAS") {
                    paramSlider("Red Bias", value: $sim.redBias, range: -0.05...0.05, tint: .red)
                    paramSlider("Green Bias", value: $sim.greenBias, range: -0.05...0.05, tint: .green)
                    paramSlider("Blue Bias", value: $sim.blueBias, range: -0.05...0.05, tint: .blue)
                }

                paramSection("EFFECTS") {
                    paramSlider("Vignette", value: $sim.vignetteIntensity, range: 0...2.0)
                    paramSlider("Bloom", value: $sim.bloomIntensity, range: 0...0.5)
                    if sim.bloomIntensity > 0 {
                        paramSlider("Bloom Size", value: $sim.bloomRadius, range: 2...20)
                    }
                    paramSlider("Haze", value: $sim.hazeAmount, range: 0...1.0, tint: .cyan)
                    Divider().background(Color.white.opacity(0.1))
                    paramSlider("Red-Eye", value: $sim.redEyeStrength, range: 0...1.0, tint: .red)
                }

                // Quality picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("CAPTURE QUALITY")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                    HStack(spacing: 6) {
                        ForEach(Array(["Speed", "Balanced", "Max"].enumerated()), id: \.offset) { idx, label in
                            let sel = sim.quality == idx
                            Button {
                                sim.quality = idx
                            } label: {
                                Text(label)
                                    .font(.system(size: 13, weight: sel ? .bold : .regular))
                                    .foregroundStyle(sel ? .black : .white)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(Capsule().fill(sel ? Color.cyan : Color.white.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)

                    Text("Speed is fastest, Max uses Deep Fusion for best detail")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 4)
                }

                // Reset button
                Button {
                    let name = sim.name
                    let id = sim.id
                    sim = CustomSimulation()
                    sim.name = name
                    sim.id = id
                } label: {
                    Text("Reset to Default")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .padding(20)

                Spacer(minLength: 60)
            }
        }
    }

    @ViewBuilder
    private func paramSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.horizontal, 20)
                .padding(.top, 20)

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
            .padding(.horizontal, 16)
        }
    }

    private func paramSlider(
        _ label: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        neutral: Float = 0,
        tint: Color = .yellow
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(formatValue(value.wrappedValue, range: range))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint.opacity(0.8))
            }
            Slider(value: value, in: range)
                .tint(tint)
        }
        .padding(.vertical, 6)
    }

    private func formatValue(_ val: Float, range: ClosedRange<Float>) -> String {
        if range.upperBound > 100 {
            return String(format: "%.0f", val)
        } else if range.upperBound - range.lowerBound < 1 {
            return String(format: "%.3f", val)
        } else {
            return String(format: "%.2f", val)
        }
    }
}
