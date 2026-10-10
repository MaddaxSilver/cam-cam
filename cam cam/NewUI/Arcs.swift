//
//  Arcs.swift
//  cam cam
//
//  The film arc (a glass dial rising out of the bottom row; swipe to turn,
//  tap a neighbour to step, tap the centre film for the library), the zoom
//  arc that replaces it while you scrub the lens pill, and the lens pill.
//

import SwiftUI

private enum ArcGeo {
    static let radius: CGFloat = 450        // glass disc radius
    static let labelInset: CGFloat = 36     // labels sit this far inside the rim
    static let height: CGFloat = 92         // visible cap
    static var labelRadius: CGFloat { radius - labelInset }
    static func degPerPoint() -> Double { 180 / (Double.pi * Double(labelRadius)) }
}

/// The glass cap the arcs sit on.
private struct ArcGlass: View {
    var body: some View {
        GeometryReader { geo in
            Circle()
                .fill(.clear)
                .frame(width: ArcGeo.radius * 2, height: ArcGeo.radius * 2)
                .glassEffect(.regular, in: Circle())
                .position(x: geo.size.width / 2, y: ArcGeo.radius)
        }
        .frame(height: ArcGeo.height)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// Places a view on the arc at `angle` degrees from the top.
private struct OnArc: ViewModifier {
    let angle: Double
    let width: CGFloat
    func body(content: Content) -> some View {
        let r = Double(ArcGeo.labelRadius)
        let rad = angle * .pi / 180
        content
            .rotationEffect(.degrees(angle))
            .position(x: width / 2 + CGFloat(r * sin(rad)),
                      y: ArcGeo.radius - CGFloat(r * cos(rad)))
    }
}

// MARK: - Film arc

struct FilmArc: View {
    let items: [ArcItem]
    let selectedKey: String?
    var onSelect: (ArcItem) -> Void
    var onOpenLibrary: () -> Void

    @State private var tones = FilmToneStore.shared
    @State private var dragDeg: Double = 0
    @State private var lastStep = 0
    private let step: Double = 17

    private var selectedIndex: Int { items.firstIndex { $0.key == selectedKey } ?? 0 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ArcGlass()
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    let a = Double(i - selectedIndex) * step + dragDeg
                    if abs(a) < 44 {
                        let isSel = i == selectedIndex && dragDeg == 0
                        Text(item.label.uppercased())
                            .font(.system(size: isSel ? 13 : 12, weight: isSel ? .bold : .semibold))
                            .tracking(0.7)
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(tones.tone(item.key))
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if i == selectedIndex { onOpenLibrary() } else { onSelect(item) }
                            }
                            .modifier(OnArc(angle: a, width: geo.size.width))
                            .accessibilityLabel(item.label)
                            .accessibilityAddTraits(isSel ? .isSelected : [])
                    }
                }
                // index mark: which film is chosen
                Capsule().fill(Color.yellow)
                    .frame(width: 18, height: 3)
                    .position(x: geo.size.width / 2, y: 6)
            }
        }
        .frame(height: ArcGeo.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { v in
                    dragDeg = Double(v.translation.width) * ArcGeo.degPerPoint()
                    let s = Int((dragDeg / step).rounded())
                    if s != lastStep {
                        lastStep = s
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
                .onEnded { _ in
                    let target = min(max(selectedIndex - lastStep, 0), max(items.count - 1, 0))
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) { dragDeg = 0 }
                    lastStep = 0
                    if items.indices.contains(target), target != selectedIndex { onSelect(items[target]) }
                }
        )
        .animation(.spring(duration: 0.35, bounce: 0.15), value: selectedKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Film dial")
    }
}

// MARK: - Zoom arc (shown while scrubbing the lens pill)

struct ZoomArc: View {
    let mm: Double
    static let degPerLn: Double = 80

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ArcGlass()
                let presets = focalPresets.map(\.mm)
                ForEach(tickValues, id: \.self) { m in
                    let a = (log(Double(m)) - log(mm)) * Self.degPerLn
                    if abs(a) < 46 {
                        let major = presets.contains(m)
                        Capsule()
                            .fill(.white.opacity(major ? 0.95 : 0.5))
                            .frame(width: 1.5, height: major ? 14 : 7)
                            .rotationEffect(.degrees(a))
                            .position(x: geo.size.width / 2 + CGFloat(Double(ArcGeo.radius - 6) * sin(a * .pi / 180)),
                                      y: ArcGeo.radius - CGFloat(Double(ArcGeo.radius - 6) * cos(a * .pi / 180)) + (major ? 7 : 3.5))
                    }
                }
                ForEach(presets, id: \.self) { m in
                    let a = (log(Double(m)) - log(mm)) * Self.degPerLn
                    if abs(a) < 44 {
                        Text("\(m)")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .modifier(OnArc(angle: a, width: geo.size.width))
                    }
                }
                Capsule().fill(Color.yellow)
                    .frame(width: 2.5, height: 22)
                    .position(x: geo.size.width / 2, y: 11)
            }
        }
        .frame(height: ArcGeo.height)
        .clipped()
        .allowsHitTesting(false)
    }

    private var tickValues: [Int] {
        var v: [Int] = []
        var m = 13
        while m <= 240 { v.append(m); m += m < 40 ? 1 : m < 80 ? 2 : m < 160 ? 4 : 8 }
        return v
    }
}

// MARK: - Lens pill

struct LensPill: View {
    let selectedIndex: Int
    let liveMM: Int
    let scrubbing: Bool
    var onTap: (Int) -> Void
    var onScrub: (CGFloat) -> Void      // horizontal translation since press
    var onScrubEnd: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            if scrubbing {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(liveMM)").font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.yellow)
                        .contentTransition(.numericText())
                    Text("mm").font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 18)
                .frame(height: 34)
            } else {
                ForEach(Array(focalPresets.enumerated()), id: \.offset) { i, p in
                    let on = i == selectedIndex
                    // Off-preset (pinch): show the live length in the nearest slot.
                    let label = (selectedIndex < 0 && i == nearestIndex) ? "\(liveMM)" : "\(p.mm)"
                    let hot = on || (selectedIndex < 0 && i == nearestIndex)
                    Button { onTap(i) } label: {
                        Text(label)
                            .font(.system(size: hot ? 13 : 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(hot ? Color.yellow : .white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(hot ? Color.black.opacity(0.45) : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(p.mm) millimetre")
                }
            }
        }
        .padding(3)
        .glassEffect(.regular.interactive(), in: Capsule())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.25)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { v in
                    if case .second(true, let drag) = v { onScrub(drag?.translation.width ?? 0) }
                }
                .onEnded { _ in onScrubEnd() }
        )
        .animation(.snappy(duration: 0.25), value: scrubbing)
    }

    private var nearestIndex: Int {
        let mms = focalPresets.map { abs(log(Double($0.mm)) - log(Double(max(liveMM, 1)))) }
        return mms.firstIndex(of: mms.min() ?? 0) ?? 0
    }
}
