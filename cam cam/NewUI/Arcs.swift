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
    static let height: CGFloat = 112        // visible cap (room for the lens pill under the labels)
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
    var onSwitchSet: () -> Void = {}

    @State private var tones = FilmToneStore.shared
    /// Where the dial is turned to (points along the arc). Animated as a
    /// value, so a long flick rolls smoothly through every film in between.
    @State private var offset: CGFloat = 0
    @State private var dragging = false
    @State private var dragBase: CGFloat = 0
    @State private var lastFilm = -1
    @State private var lastMinor = 0
    @State private var settleID = 0
    // Two feels: soft quick ticks between films, a firm detent on each film.
    @State private var tick = UIImpactFeedbackGenerator(style: .soft)
    @State private var detent = UIImpactFeedbackGenerator(style: .rigid)

    static let font = UIFont.systemFont(ofSize: 12, weight: .semibold)
    static let tracking: CGFloat = 0.7
    static let gap: CGFloat = 30
    static let minorStep: CGFloat = 11       // a small mark (and tick) every 11 pt

    private var centers: [CGFloat] {
        var out: [CGFloat] = []
        var x: CGFloat = 0
        var prevHalf: CGFloat = 0
        for (i, item) in items.enumerated() {
            let w = Self.width(item.label) + (item.isSetSwitch ? 22 : 0)
            if i > 0 { x += prevHalf + Self.gap + w / 2 }
            out.append(x)
            prevHalf = w / 2
        }
        return out
    }

    static func width(_ label: String) -> CGFloat {
        let t = label.uppercased() as NSString
        return max(ceil(t.size(withAttributes: [.font: font, .kern: tracking]).width), 30)
    }

    private var selectedIndex: Int? { items.firstIndex { $0.key == selectedKey } }
    /// Where the dial rests: the chosen film, or the first film in this set.
    private var restIndex: Int {
        selectedIndex ?? items.firstIndex { !$0.isSetSwitch } ?? 0
    }
    /// Landing on a set switch isn't a choice: settle on the film beside it.
    private func filmIndex(near i: Int) -> Int {
        guard items.indices.contains(i), items[i].isSetSwitch else { return i }
        if i == 0 { return items.count > 1 ? 1 : 0 }
        return max(i - 1, 0)
    }

    static func nearest(_ offset: CGFloat, in c: [CGFloat]) -> Int {
        guard !c.isEmpty else { return 0 }
        var best = 0
        for i in c.indices where abs(c[i] - offset) < abs(c[best] - offset) { best = i }
        return best
    }

    var body: some View {
        let c = centers
        ZStack {
            ArcGlass()
            if items.isEmpty {
                Text("No films here yet")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .offset(y: -6)
            }
            FilmDialFace(items: items, centers: c, offset: offset, tones: tones,
                         selectedIndex: selectedIndex,
                         onTapItem: { i in
                             if items[i].isSetSwitch { detent.impactOccurred(intensity: 0.85); onSwitchSet() }
                             else if i == selectedIndex { /* already chosen */ } else {
                                 detent.impactOccurred(intensity: 0.85)
                                 onSelect(items[i])
                             }
                         })
        }
        .frame(height: ArcGeo.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { v in
                    if !dragging {
                        dragging = true
                        settleID += 1
                        dragBase = offset
                        lastFilm = Self.nearest(offset, in: c)
                        lastMinor = Int((offset / Self.minorStep).rounded(.down))
                        tick.prepare(); detent.prepare()
                    }
                    let lo = (c.first ?? 0) - 36, hi = (c.last ?? 0) + 36
                    offset = min(max(dragBase - v.translation.width, lo), hi)
                    clicks(at: offset, centers: c)
                }
                .onEnded { v in
                    dragging = false
                    // Momentum: follow the flick, then settle on a film.
                    let projected = dragBase - v.predictedEndTranslation.width
                    let target = filmIndex(near: Self.nearest(projected, in: c))
                    guard c.indices.contains(target) else { return }
                    let from = offset, to = c[target]
                    let duration = min(0.75, 0.3 + Double(abs(to - from)) / 1600)
                    withAnimation(.timingCurve(0.15, 0.7, 0.25, 1, duration: duration)) { offset = to }
                    settleClicks(from: from, to: to, duration: duration, centers: c)
                    if target != selectedIndex { onSelect(items[target]) }
                }
        )
        .onAppear { offset = c.indices.contains(restIndex) ? c[restIndex] : 0 }
        .onChange(of: selectedKey) {
            guard !dragging, let i = selectedIndex, c.indices.contains(i), abs(offset - c[i]) > 0.5 else { return }
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { offset = c[i] }
        }
        .onChange(of: items.map(\.key)) {
            offset = c.indices.contains(restIndex) ? c[restIndex] : 0
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Film dial")
    }

    /// Clicks while the finger moves the dial.
    private func clicks(at o: CGFloat, centers c: [CGFloat]) {
        let film = Self.nearest(o, in: c)
        if film != lastFilm, abs(c[film] - o) < 8 {
            lastFilm = film
            detent.impactOccurred(intensity: 0.9)
            detent.prepare()
        }
        let minor = Int((o / Self.minorStep).rounded(.down))
        if minor != lastMinor {
            lastMinor = minor
            tick.impactOccurred(intensity: 0.35)
            tick.prepare()
        }
    }

    /// The same clicks, timed along the settle animation after a flick.
    private func settleClicks(from: CGFloat, to: CGFloat, duration: Double, centers c: [CGFloat]) {
        let id = settleID
        let dist = to - from
        guard abs(dist) > 1 else { detent.impactOccurred(intensity: 0.9); return }
        let steps = min(Int(abs(dist) / Self.minorStep), 60)
        // Ease-out: progress p happens at time ≈ duration * (1 - (1-p)^(1/2.2)).
        for k in 1...max(steps, 1) {
            let p = Double(k) / Double(max(steps, 1))
            let t = duration * (1 - pow(1 - p, 1 / 2.2)) * 0.9
            let pos = from + dist * CGFloat(p)
            let onFilm = c.contains { abs($0 - pos) < Self.minorStep / 2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                guard settleID == id else { return }
                if onFilm { detent.impactOccurred(intensity: k == steps ? 1 : 0.8) }
                else { tick.impactOccurred(intensity: 0.35) }
            }
        }
    }
}

/// The dial's face: marks and film names. Animatable on `offset`, so SwiftUI
/// redraws every frame of a turn instead of sliding labels between two states.
private struct FilmDialFace: View, Animatable {
    let items: [ArcItem]
    let centers: [CGFloat]
    var offset: CGFloat
    let tones: FilmToneStore
    let selectedIndex: Int?
    var onTapItem: (Int) -> Void

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let focus = FilmArc.nearest(offset, in: centers)
            let rl = ArcGeo.labelRadius
            let first = (centers.first ?? 0) - 36, last = (centers.last ?? 0) + 36
            // Minor marks every few points; film marks above each name.
            let lo = max(first, offset - 340), hi = min(last, offset + 340)
            let startK = Int((lo / FilmArc.minorStep).rounded(.up))
            let endK = Int((hi / FilmArc.minorStep).rounded(.down))
            ZStack {
                if endK >= startK {
                    ForEach(startK...endK, id: \.self) { k in
                        let pos = CGFloat(k) * FilmArc.minorStep
                        mark(at: pos, w: w, height: 4, opacity: 0.35)
                    }
                }
                ForEach(centers.indices, id: \.self) { i in
                    let a = Double((centers[i] - offset) / rl) * 180 / .pi
                    if abs(a) < 48 {
                        mark(at: centers[i], w: w, height: 8, opacity: (i == focus || items[i].isSetSwitch) ? 0 : 0.85)
                        let isSel = i == focus
                        label(for: items[i])
                            .opacity(isSel || items[i].isSetSwitch ? 1 : 0.8)
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                            .onTapGesture { onTapItem(i) }
                            .rotationEffect(.degrees(a))
                            .position(x: w / 2 + CGFloat(Double(rl) * sin(a * .pi / 180)),
                                      y: ArcGeo.radius - CGFloat(Double(rl) * cos(a * .pi / 180)))
                            .accessibilityLabel(items[i].label)
                            .accessibilityAddTraits(i == selectedIndex ? .isSelected : [])
                    }
                }
                Capsule().fill(Color.yellow)
                    .frame(width: 2.5, height: 11)
                    .position(x: w / 2, y: 10.5)
            }
        }
    }

    @ViewBuilder private func label(for item: ArcItem) -> some View {
        if item.isSetSwitch {
            HStack(spacing: 5) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(item.label.uppercased())
                    .font(Font(FilmArc.font)).tracking(FilmArc.tracking)
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Switch films: \(item.label)")
        } else {
            Text(item.label.uppercased())
                .font(Font(FilmArc.font))
                .tracking(FilmArc.tracking)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(tones.tone(item.key))
        }
    }

    private func mark(at pos: CGFloat, w: CGFloat, height: CGFloat, opacity: Double) -> some View {
        let a = Double((pos - offset) / ArcGeo.labelRadius) * 180 / .pi
        let rad = a * .pi / 180
        let r = Double(ArcGeo.radius - 5 - height / 2)
        return Capsule()
            .fill(.white.opacity(opacity))
            .frame(width: 1.5, height: height)
            .rotationEffect(.degrees(a))
            .position(x: w / 2 + CGFloat(r * sin(rad)), y: ArcGeo.radius - CGFloat(r * cos(rad)))
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
        HStack(spacing: 0) {
            if scrubbing {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(liveMM)").font(.system(size: 18, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.yellow)
                        .contentTransition(.numericText())
                    Text("mm").font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 16)
                .frame(height: 28)
            } else {
                ForEach(Array(focalPresets.enumerated()), id: \.offset) { i, p in
                    let on = i == selectedIndex
                    // Off-preset (pinch): show the live length in the nearest slot.
                    let label = (selectedIndex < 0 && i == nearestIndex) ? "\(liveMM)" : "\(p.mm)"
                    let hot = on || (selectedIndex < 0 && i == nearestIndex)
                    Button { onTap(i) } label: {
                        Text(label)
                            .font(.system(size: hot ? 12 : 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(hot ? Color.yellow : .white)
                            .frame(width: 30, height: 28)
                            .background(Capsule().fill(hot ? Color.black.opacity(0.45) : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(p.mm) millimetre")
                }
            }
        }
        .padding(2)
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
