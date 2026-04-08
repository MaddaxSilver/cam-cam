//
//  ContentView.swift
//  cam cam
//
//  Created by maddax silver on 2026-04-07.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            cameraLayer
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if showSettings {
                    SettingsPanel(settings: $camera.settings)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                filmBar
            }
            .animation(.spring(duration: 0.3), value: showSettings)
        }
        .preferredColorScheme(.dark)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: - Camera layer

    @ViewBuilder
    private var cameraLayer: some View {
        if let frame = camera.filteredFrame {
            Image(decorative: frame, scale: 1.0)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            Color.black
                .overlay { cameraPlaceholder }
        }
    }

    @ViewBuilder
    private var cameraPlaceholder: some View {
        if camera.isDenied {
            VStack(spacing: 10) {
                Image(systemName: "camera.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Camera access denied")
                    .foregroundStyle(.secondary)
                Text("Enable it in Settings > cam cam")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text("Starting camera…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bottom bar

    private var filmBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilmSim.allCases) { sim in
                        SimChip(sim: sim, isSelected: camera.selectedSim == sim) {
                            camera.selectedSim = sim
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: showSettings ? "xmark.circle.fill" : "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 44)
            }
            .padding(.trailing, 4)
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - Film sim chip

private struct SimChip: View {
    let sim: FilmSim
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(sim.rawValue)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Color.white : Color.white.opacity(0.18))
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Settings panel

private struct SettingsPanel: View {
    @Binding var settings: CameraSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ToggleRow(label: "Highlight Rolloff", isOn: $settings.isHighlightRolloffEnabled)
            if settings.isHighlightRolloffEnabled {
                SliderRow(label: "Threshold", value: $settings.rolloffThreshold, range: 0.5...0.98)
            }

            ToggleRow(label: "Color Crosstalk", isOn: $settings.isColorCrosstalkEnabled)
            if settings.isColorCrosstalkEnabled {
                SliderRow(label: "Amount", value: $settings.crossTalkAmount, range: 0...0.2)
            }

            ToggleRow(label: "Halation", isOn: $settings.isHalationEnabled)
            if settings.isHalationEnabled {
                SliderRow(label: "Amount", value: $settings.halationAmount, range: 0...0.5)
            }

            ToggleRow(label: "Auto Grain", isOn: $settings.isAutoGrainEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
        .tint(.white)
    }
}

private struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        LabeledContent(label) {
            Slider(value: $value, in: range)
                .tint(.white)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
    }
}

#Preview {
    ContentView()
}
