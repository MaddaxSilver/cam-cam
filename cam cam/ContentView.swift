//
//  ContentView.swift
//  cam cam
//
//  Created by maddax silver on 2026-04-07.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var selectedFocalLength = 28
    @State private var exposureValue: Double = -0.1

    private let focalLengths = [24, 28, 35, 70, 120]

    var body: some View {
        ZStack {
            cameraLayer
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.top, 4)
                Spacer()
                bottomSection
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: - Camera

    @ViewBuilder
    private var cameraLayer: some View {
        if let frame = camera.filteredFrame {
            Image(decorative: frame, scale: 1.0)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            Color.black.overlay {
                if camera.isDenied {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Camera access denied")
                            .foregroundStyle(.secondary)
                        Text("Enable in Settings \u{203A} cam cam")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(alignment: .top) {
            // Exposure dial
            ZStack {
                Circle()
                    .fill(.black.opacity(0.55))
                    .frame(width: 72, height: 72)

                ForEach(0..<24, id: \.self) { i in
                    Circle()
                        .fill(.gray.opacity(0.35))
                        .frame(width: 2, height: 2)
                        .offset(y: -31)
                        .rotationEffect(.degrees(Double(i) * 15))
                }

                VStack(spacing: 1) {
                    Image(systemName: "sun.min.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text(String(format: "%.1f", exposureValue))
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    TopPill(icon: "square.stack", text: "2X")
                    TopPill(text: "JPEG")
                    TopPill(icon: "timer", text: "BULB")
                    TopPill(icon: "viewfinder", text: "AF")
                }
                TopPill(icon: "rectangle.split.2x1", text: "4:3", showChevron: true)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(spacing: 14) {
            // MF badge
            Text("MF")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.gray.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Focal lengths
            HStack(spacing: 14) {
                ForEach(focalLengths, id: \.self) { fl in
                    Button { selectedFocalLength = fl } label: {
                        VStack(spacing: 1) {
                            Text("\(fl)")
                                .font(.system(size: 20, weight: .semibold))
                            Text("mm")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(selectedFocalLength == fl ? Color.yellow : .white)
                        .frame(width: 54, height: 54)
                        .overlay(
                            Circle().stroke(
                                selectedFocalLength == fl ? Color.yellow : .gray.opacity(0.5),
                                lineWidth: selectedFocalLength == fl ? 2 : 1
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Film sims
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilmSim.allCases) { sim in
                        Button { camera.selectedSim = sim } label: {
                            Text(sim.chipLabel)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(camera.selectedSim == sim ? Color.yellow : .gray.opacity(0.35))
                                .foregroundStyle(camera.selectedSim == sim ? .black : .white)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            // Shutter row
            HStack {
                HStack(spacing: 14) {
                    // EV button
                    ZStack(alignment: .top) {
                        Circle()
                            .stroke(.gray.opacity(0.5), lineWidth: 1)
                            .frame(width: 50, height: 50)
                        VStack(spacing: -1) {
                            Image(systemName: "plusminus")
                                .font(.system(size: 7))
                            Text("0.0")
                                .font(.system(size: 18, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        Circle()
                            .fill(.white)
                            .frame(width: 5, height: 5)
                            .offset(y: -2)
                    }

                    // Flash button
                    ZStack {
                        Circle()
                            .stroke(.gray.opacity(0.5), lineWidth: 1)
                            .frame(width: 50, height: 50)
                        VStack(spacing: -2) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 14))
                            Text("AUTO")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)

                // Shutter
                Button {} label: {
                    ZStack {
                        Circle()
                            .stroke(.gray.opacity(0.35), lineWidth: 3)
                            .frame(width: 76, height: 76)
                        Circle()
                            .fill(.white)
                            .frame(width: 66, height: 66)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Color.clear
                    .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Top Pill

private struct TopPill: View {
    var icon: String? = nil
    var text: String
    var showChevron: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
            }
            Text(text)
                .font(.system(size: 13, weight: .semibold))
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.5))
        .clipShape(Capsule())
    }
}

#Preview {
    ContentView()
}
