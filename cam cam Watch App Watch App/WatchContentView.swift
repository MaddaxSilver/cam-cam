//
//  WatchContentView.swift
//  cam cam Watch App
//
//  Polished UI: shutter (primary action / double-tap), record, flash,
//  RAW, live EV reading, and Digital Crown scrolling through film sims
//  with auto-select.
//

import SwiftUI

enum CrownMode {
    case film
    case zoom
}

struct WatchContentView: View {
    @EnvironmentObject var connector: WatchPhoneConnector

    /// Continuous Double the Digital Crown writes into. We round it to the
    /// nearest index in whichever list (films or zoom presets) is currently
    /// being controlled and auto-apply the selection on change.
    @State private var crownValue: Double = 0
    @State private var crownInited: Bool = false
    @State private var lastSentIdx: Int = -1
    @State private var crownMode: CrownMode = .film
    @FocusState private var crownFocused: Bool

    var body: some View {
        GeometryReader { geo in
            // Scale all key sizes off screen width so it fits 41/45/49mm.
            // Reference width ~176pt (41mm). Ultra is ~205pt → ~1.16× bigger.
            let s = max(1.0, geo.size.width / 176.0)
            VStack(spacing: 6 * s) {
                statusRow(scale: s)
                shutterRow(scale: s)
                controlRow(scale: s)
                filmRow(scale: s)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .focusable(true)
        .focused($crownFocused)
        .digitalCrownRotation(
            $crownValue,
            from: 0,
            through: Double(max(0, crownItemCount - 1)),
            by: 1.0,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onAppear { crownFocused = true; syncCrownFromState() }
        .onChange(of: connector.sims.count) { syncCrownFromState() }
        .onChange(of: connector.selectedSim) { syncCrownFromState() }
        .onChange(of: connector.presetMMs.count) { syncCrownFromState() }
        .onChange(of: connector.selectedFocalIdx) { syncCrownFromState() }
        .onChange(of: crownMode) { syncCrownFromState() }
        .onChange(of: crownValue) { _, newVal in
            guard crownInited else { return }
            let count = crownItemCount
            guard count > 0 else { return }
            let idx = max(0, min(count - 1, Int(newVal.rounded())))
            guard idx != lastSentIdx else { return }
            lastSentIdx = idx
            switch crownMode {
            case .film:
                guard idx < connector.sims.count else { return }
                connector.sendSetSim(connector.sims[idx].raw)
            case .zoom:
                connector.sendSetFocalPreset(idx)
            }
        }
    }

    // MARK: - Sections

    private func statusRow(scale s: CGFloat) -> some View {
        HStack(spacing: 6 * s) {
            Circle()
                .fill(connector.isReachable ? Color.green : Color.gray)
                .frame(width: 7 * s, height: 7 * s)
            // mm pill — tap to switch crown to zoom mode. Also force the iPhone into
            // unified-zoom (1-Lens) mode so each crown tick just adjusts videoZoomFactor
            // on the virtual triple instead of triggering preset-tap lens swaps.
            Button {
                crownMode = .zoom
                connector.sendSetUnifiedZoom(true)
            } label: {
                Text("\(connector.currentMM)mm")
                    .font(.system(size: 12 * s, weight: .semibold, design: .monospaced))
                    .foregroundStyle(crownMode == .zoom ? .black : .white)
                    .padding(.horizontal, 7 * s).padding(.vertical, 2 * s)
                    .background(Capsule().fill(crownMode == .zoom ? Color.yellow : Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            Spacer()
            Text(String(format: "EV %+.1f", connector.evReading))
                .font(.system(size: 11 * s, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 4 * s)
    }

    private func shutterRow(scale s: CGFloat) -> some View {
        Button {
            if connector.burstMode {
                if connector.isBursting { connector.sendBurstStop() }
                else { connector.sendBurstStart() }
            } else {
                connector.sendShutter()
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.85), lineWidth: 3 * s)
                    .frame(width: 90 * s, height: 90 * s)
                Circle()
                    .fill(shutterColor)
                    .frame(width: 76 * s, height: 76 * s)
                    .scaleEffect(connector.isCapturing || connector.isBursting ? 0.85 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: connector.isCapturing)
                    .animation(.easeOut(duration: 0.12), value: connector.isBursting)
            }
        }
        .buttonStyle(.plain)
        .modifier(PrimaryActionModifier())
    }

    private func controlRow(scale s: CGFloat) -> some View {
        HStack(spacing: 14 * s) {
            // Flash
            Button {
                connector.sendToggleFlash()
            } label: {
                Image(systemName: connector.flashOn ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 15 * s, weight: .semibold))
                    .foregroundStyle(connector.flashOn ? .yellow : .white.opacity(0.7))
                    .frame(width: 40 * s, height: 30 * s)
                    .background(Capsule().fill(Color.white.opacity(connector.flashOn ? 0.18 : 0.10)))
            }
            .buttonStyle(.plain)

            // RAW
            Button {
                connector.sendToggleRaw()
            } label: {
                Text("RAW")
                    .font(.system(size: 12 * s, weight: .bold, design: .monospaced))
                    .foregroundStyle(connector.rawEnabled ? .black : .white.opacity(0.7))
                    .frame(width: 48 * s, height: 30 * s)
                    .background(Capsule().fill(connector.rawEnabled ? Color.yellow : Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)

            // Record
            Button {
                connector.sendRecordToggle()
            } label: {
                Image(systemName: connector.isRecording ? "stop.fill" : "video.fill")
                    .font(.system(size: 15 * s, weight: .semibold))
                    .foregroundStyle(connector.isRecording ? .red : .white.opacity(0.7))
                    .frame(width: 40 * s, height: 30 * s)
                    .background(Capsule().fill(Color.white.opacity(connector.isRecording ? 0.22 : 0.10)))
            }
            .buttonStyle(.plain)
        }
    }

    private func filmRow(scale s: CGFloat) -> some View {
        // Compact film-sim strip: shows the current selection bold + tinted by mode,
        // prev/next dimmed. Tapping it switches the crown back to film mode.
        // The Digital Crown scrolls through whichever list crownMode is set to.
        let isActive = crownMode == .film
        let activeColor: Color = isActive ? .yellow : .white.opacity(0.85)
        return Button {
            crownMode = .film
            // Turn off iPhone's 1-Lens (unified zoom) mode so the user gets back
            // their explicit lens control after the crown is no longer driving zoom.
            connector.sendSetUnifiedZoom(false)
        } label: {
            HStack(spacing: 6 * s) {
                if connector.sims.isEmpty {
                    Text("…").foregroundStyle(.white.opacity(0.4))
                } else {
                    let idx = filmIdx()
                    if isActive, idx > 0 {
                        Text(connector.sims[idx - 1].label)
                            .font(.system(size: 11 * s))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                    Text(connector.sims[idx].label)
                        .font(.system(size: 13 * s, weight: .bold))
                        .foregroundStyle(activeColor)
                        .padding(.horizontal, 9 * s).padding(.vertical, 4 * s)
                        .background(Capsule().fill(activeColor.opacity(0.15)))
                        .lineLimit(1)
                    if isActive, idx < connector.sims.count - 1 {
                        Text(connector.sims[idx + 1].label)
                            .font(.system(size: 11 * s))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.top, 2 * s)
    }

    // MARK: - Helpers

    private var shutterColor: Color {
        if connector.isBursting { return .yellow }
        if connector.isRecording { return .red }
        return .white
    }

    /// Number of items the crown can scroll through in the current mode.
    private var crownItemCount: Int {
        switch crownMode {
        case .film: return connector.sims.count
        case .zoom: return connector.presetMMs.count
        }
    }

    /// Display index for the film row — uses the crown value when in film mode,
    /// the iPhone's reported selection when in zoom mode.
    private func filmIdx() -> Int {
        if crownMode == .film {
            let i = Int(crownValue.rounded())
            return max(0, min(connector.sims.count - 1, i))
        }
        if let i = connector.sims.firstIndex(where: { $0.raw == connector.selectedSim }) {
            return i
        }
        return 0
    }

    private func syncCrownFromState() {
        let count = crownItemCount
        guard count > 0 else { return }
        let target: Int
        switch crownMode {
        case .film:
            target = connector.sims.firstIndex(where: { $0.raw == connector.selectedSim }) ?? 0
        case .zoom:
            target = max(0, min(count - 1, connector.selectedFocalIdx >= 0 ? connector.selectedFocalIdx : 0))
        }
        crownValue = Double(target)
        lastSentIdx = target
        crownInited = true
    }
}

/// Marks the shutter as the watch's primary action so the system "double tap"
/// gesture (Series 9 / Ultra 2+, watchOS 11+) triggers it. On older versions
/// this modifier is a no-op.
private struct PrimaryActionModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.handGestureShortcut(.primaryAction)
        } else {
            content
        }
    }
}
