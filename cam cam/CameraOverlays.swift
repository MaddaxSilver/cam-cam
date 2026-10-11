//
//  CameraOverlays.swift
//  cam cam
//
//  Viewfinder overlays and dials: exposure meter, grid, level, aspect mask, double-exposure mask, focus/face indicators, peaking.
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

// MARK: - ExposureMeterBar

struct ExposureMeterBar: View {
    let evValue: Float
    let bias: Float

    private let range: Float = 3.0
    private let dialSize: CGFloat = 64

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.5))
                .frame(width: dialSize, height: dialSize)

            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 1.5)
                .frame(width: dialSize, height: dialSize)

            // Coloured arc
            Circle()
                .trim(from: 0.5 - arcFraction(for: evValue) / 2,
                      to:   0.5 + arcFraction(for: evValue) / 2)
                .stroke(meterColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: dialSize - 8, height: dialSize - 8)
                .rotationEffect(.degrees(90))
                .animation(.easeOut(duration: 0.12), value: evValue)

            // Bias marker dot
            Circle()
                .fill(Color.yellow)
                .frame(width: 5, height: 5)
                .offset(y: -(dialSize / 2 - 4))
                .rotationEffect(.degrees(Double(bias / range) * 90))

            // Centre label
            VStack(spacing: 0) {
                Image(systemName: "sun.max")
                    .font(.system(size: 8))
                    .foregroundStyle(meterColor)
                Text(evLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }

            // Scale ticks
            ForEach([-3, -1, 0, 1, 3], id: \.self) { stop in
                Rectangle()
                    .fill(Color.white.opacity(stop == 0 ? 0.8 : 0.3))
                    .frame(width: 1, height: stop == 0 ? 6 : 4)
                    .offset(y: -(dialSize / 2 - 2))
                    .rotationEffect(.degrees(Double(stop) / Double(range) * 90))
            }
        }
        .frame(width: dialSize, height: dialSize)
    }

    private func arcFraction(for value: Float) -> CGFloat {
        let clamped = Swift.max(-range, Swift.min(value, range))
        return CGFloat(abs(clamped) / range) * 0.5
    }

    private var evLabel: String {
        String(format: "%+.1f", evValue + bias)
    }

    private var meterColor: Color {
        let total = abs(evValue)
        if total < 0.5 { return .green }
        if total < 1.5 { return .yellow }
        return .red
    }
}

// MARK: - Triangle Shape

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - GridOverlay

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { path in
                // Vertical thirds
                path.move(to: CGPoint(x: w / 3, y: 0))
                path.addLine(to: CGPoint(x: w / 3, y: h))
                path.move(to: CGPoint(x: 2 * w / 3, y: 0))
                path.addLine(to: CGPoint(x: 2 * w / 3, y: h))
                // Horizontal thirds
                path.move(to: CGPoint(x: 0, y: h / 3))
                path.addLine(to: CGPoint(x: w, y: h / 3))
                path.move(to: CGPoint(x: 0, y: 2 * h / 3))
                path.addLine(to: CGPoint(x: w, y: 2 * h / 3))
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - LevelOverlay

struct LevelOverlay: View {
    let roll: Double // degrees

    var body: some View {
        GeometryReader { geo in
            let centerX = geo.size.width / 2
            let centerY = geo.size.height / 2
            let lineLength: CGFloat = 80
            let isLevel = abs(roll) < 1.0

            ZStack {
                // Center dot
                Circle()
                    .fill(isLevel ? Color.green : Color.white)
                    .frame(width: 6, height: 6)
                    .position(x: centerX, y: centerY)

                // Horizon line
                Path { path in
                    path.move(to: CGPoint(x: centerX - lineLength, y: centerY))
                    path.addLine(to: CGPoint(x: centerX + lineLength, y: centerY))
                }
                .stroke(isLevel ? Color.green : Color.white.opacity(0.5), lineWidth: 1)
                .rotationEffect(.degrees(-roll), anchor: UnitPoint(x: 0.5, y: centerY / geo.size.height))

                // Reference line (always horizontal)
                Path { path in
                    path.move(to: CGPoint(x: centerX - lineLength * 0.4, y: centerY))
                    path.addLine(to: CGPoint(x: centerX + lineLength * 0.4, y: centerY))
                }
                .stroke(Color.yellow.opacity(0.5), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - AspectRatioOverlay

struct AspectRatioOverlay: View {
    let aspectRatio: AspectRatio
    let geoSize: CGSize
    var isLandscape: Bool = false

    var body: some View {
        if let baseRatio = aspectRatio.ratio {
            // Orientation-aware: rotate the frame with the device so it always
            // looks like the labeled ratio from the USER's viewpoint.
            //   Portrait viewing: on-screen ratio = baseRatio (e.g. 16:9 wide slit)
            //   Landscape viewing: on-screen ratio = 1/baseRatio (tall narrow on
            //     portrait-locked screen, which when rotated 90° in user's view
            //     appears as 16:9 wide.)
            let ratio: CGFloat = isLandscape ? (1.0 / baseRatio) : baseRatio
            let fullW = geoSize.width
            let fullH = geoSize.height
            let fullRatio = fullW / fullH

            if ratio > fullRatio {
                // Wider than viewport: crop top and bottom
                let visibleH = fullW / ratio
                let barH = (fullH - visibleH) / 2
                VStack(spacing: 0) {
                    Rectangle().fill(Color.black.opacity(0.6)).frame(height: barH)
                    Spacer()
                    Rectangle().fill(Color.black.opacity(0.6)).frame(height: barH)
                }
            } else {
                // Taller: crop left and right
                let visibleW = fullH * ratio
                let barW = (fullW - visibleW) / 2
                HStack(spacing: 0) {
                    Rectangle().fill(Color.black.opacity(0.6)).frame(width: barW)
                    Spacer()
                    Rectangle().fill(Color.black.opacity(0.6)).frame(width: barW)
                }
            }
        }
    }
}

// MARK: - Double Exposure Mask Painter

struct MaskPainterView: UIViewRepresentable {
    @Binding var mask: UIImage?
    @Binding var brushTipPosition: CGPoint?     // live position for the on-screen brush ring
    var brushSize: CGFloat
    var brushOpacity: Double  // 1 = paint (expose), 0 = erase
    var viewSize: CGSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: CGRect(origin: .zero, size: viewSize))
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    class Coordinator: NSObject {
        var parent: MaskPainterView
        var lastPoint: CGPoint?

        init(_ parent: MaskPainterView) { self.parent = parent }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let pt = gesture.location(in: gesture.view)
            DispatchQueue.main.async { self.parent.brushTipPosition = pt }
            draw(from: pt, to: pt)
            // Hide the indicator shortly after a tap
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.parent.brushTipPosition = nil
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let pt = gesture.location(in: gesture.view)
            switch gesture.state {
            case .began:
                lastPoint = pt
                DispatchQueue.main.async { self.parent.brushTipPosition = pt }
                draw(from: pt, to: pt)
            case .changed:
                DispatchQueue.main.async { self.parent.brushTipPosition = pt }
                draw(from: lastPoint ?? pt, to: pt)
                lastPoint = pt
            default:
                lastPoint = nil
                DispatchQueue.main.async { self.parent.brushTipPosition = nil }
            }
        }

        func draw(from: CGPoint, to: CGPoint) {
            let size = parent.viewSize
            guard size.width > 0, size.height > 0 else { return }

            // Create or reuse mask canvas
            let current = parent.mask ?? UIImage.solidColor(.black, size: size)
            UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
            defer { UIGraphicsEndImageContext() }
            current.draw(at: .zero)

            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(parent.brushSize)

            if parent.brushOpacity > 0.5 {
                // Paint white = expose second image in this area
                ctx.setStrokeColor(UIColor.white.withAlphaComponent(CGFloat(parent.brushOpacity)).cgColor)
                ctx.setBlendMode(.normal)
            } else {
                // Erase = reveal first image (paint black)
                ctx.setStrokeColor(UIColor.black.cgColor)
                ctx.setBlendMode(.normal)
            }

            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()

            parent.mask = UIGraphicsGetImageFromCurrentImageContext()
        }
    }
}

struct MaskOverlayView: View {
    @Bindable var camera: CameraManager
    let geoSize: CGSize
    @State private var brushTip: CGPoint? = nil

    var body: some View {
        ZStack {
            // Show current mask as semi-transparent overlay
            if let mask = camera.doubleExposureMask, let cgImage = mask.cgImage {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .blendMode(.screen)
                    .opacity(0.35)
                    .allowsHitTesting(false)
            }

            // Painting canvas
            MaskPainterView(
                mask: $camera.doubleExposureMask,
                brushTipPosition: $brushTip,
                brushSize: camera.maskBrushSize,
                brushOpacity: camera.maskBrushOpacity,
                viewSize: geoSize
            )

            // Live brush-tip indicator — shows the user where they're painting and the
            // size of the brush. Filled tint reflects paint vs erase mode.
            if let pt = brushTip {
                let isErase = camera.maskBrushOpacity < 0.5
                Circle()
                    .stroke(isErase ? Color.red : Color.yellow, lineWidth: 1.5)
                    .background(
                        Circle().fill((isErase ? Color.red : Color.yellow).opacity(0.18))
                    )
                    .frame(width: camera.maskBrushSize, height: camera.maskBrushSize)
                    .position(pt)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.08), value: pt)
            }
        }
    }
}

extension UIImage {
    static func solidColor(_ color: UIColor, size: CGSize) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        color.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }
}

// MARK: - FocusIndicator

struct FocusIndicator: View {
    let position: CGPoint
    /// Stays on screen (AE/AF lock) instead of fading out.
    var persistent = false
    @State private var scale: CGFloat = 1.5
    @State private var opacity: Double = 1.0

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 70, height: 70)
            .scaleEffect(scale)
            .opacity(opacity)
            .position(position)
            .onAppear {
                withAnimation(.easeOut(duration: 0.3)) {
                    scale = 1.0
                }
                if !persistent {
                    withAnimation(.easeOut(duration: 1.5).delay(0.5)) {
                        opacity = 0.0
                    }
                }
            }
    }
}

// MARK: - Focus Hunting Indicator

/// Small pulsing ring shown while the camera is actively searching for focus.
struct FocusHuntingIndicator: View {
    @State private var pulse: Bool = false

    var body: some View {
        Circle()
            .stroke(Color.yellow.opacity(pulse ? 0.9 : 0.35), lineWidth: 1.5)
            .frame(width: 18, height: 18)
            .scaleEffect(pulse ? 1.15 : 0.9)
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 12)
            .padding(.top, 56)
    }
}

// MARK: - Face Detected Badge

/// Tiny face icon that appears when the camera's face detection has a lock.
struct FaceDetectedBadge: View {
    @State private var visible: Bool = false

    var body: some View {
        Image(systemName: "face.dashed")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.yellow.opacity(0.85))
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeIn(duration: 0.2)) { visible = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 36)
            .padding(.top, 59)
    }
}

// MARK: - ExposureDial

struct ExposureDial: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    // Capture the value at the moment the drag begins so we can apply the
    // TOTAL translation rather than accumulating incremental deltas, which
    // would cause the dial to drift/over-respond across frames.
    @State private var valueAtDragStart: Float = 0
    @State private var isDragging: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.55))
                .frame(width: 72, height: 72)

            // Tick marks
            ForEach(0..<24, id: \.self) { i in
                Circle()
                    .fill(Color.gray.opacity(0.35))
                    .frame(width: 2, height: 2)
                    .offset(y: -31)
                    .rotationEffect(.degrees(Double(i) * 15))
            }

            VStack(spacing: 1) {
                Image(systemName: "sun.min.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text(String(format: "%+.1f", value))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 8)   // raised from 1 so taps aren't swallowed
                .onChanged { gesture in
                    if !isDragging {
                        isDragging = true
                        valueAtDragStart = value
                    }
                    let delta = Float(-gesture.translation.height / 200.0)
                    value = max(range.lowerBound, min(range.upperBound, valueAtDragStart + delta))
                }
                .onEnded { _ in isDragging = false }
        )
    }
}

// MARK: - OpacityDial

struct OpacityDial: View {
    @Binding var value: Double
    let label: String

    @State private var valueAtDragStart: Double = 0
    @State private var isDragging: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.55))
                .frame(width: 60, height: 60)

            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.gray)
                Text("\(Int(value * 100))%")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { gesture in
                    if !isDragging {
                        isDragging = true
                        valueAtDragStart = value
                    }
                    let delta = -gesture.translation.height / 200.0
                    value = max(0, min(1, valueAtDragStart + delta))
                }
                .onEnded { _ in isDragging = false }
        )
    }
}

// MARK: - Focus Peaking

struct FocusPeakingView: UIViewRepresentable {
    let camera: CameraManager

    func makeUIView(context: Context) -> PeakingUIView {
        let view = PeakingUIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.sharedContext = camera.ciContext
        camera.peakingView = view
        return view
    }

    func updateUIView(_ uiView: PeakingUIView, context: Context) {}

    static func dismantleUIView(_ uiView: PeakingUIView, coordinator: ()) {
        // Will be cleared when camera.showPeaking toggled off
    }
}

class PeakingUIView: UIView {
    nonisolated(unsafe) var sharedContext: CIContext?
    private var overlayLayer = CALayer()
    nonisolated(unsafe) var lastPeakingTime: CFTimeInterval = 0
    // Reuse filter instances
    nonisolated(unsafe) var edgesFilter = CIFilter.edges()
    nonisolated(unsafe) var colorMatrixFilter = CIFilter.colorMatrix()

    override init(frame: CGRect) {
        super.init(frame: frame)
        overlayLayer.contentsGravity = .resizeAspectFill
        layer.addSublayer(overlayLayer)
        // Pre-configure static filter params
        edgesFilter.intensity = 5.0
        colorMatrixFilter.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        colorMatrixFilter.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        colorMatrixFilter.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        colorMatrixFilter.aVector = CIVector(x: 1, y: 0, z: 0, w: 0)
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlayLayer.frame = bounds
    }

    nonisolated func processFrame(pixelBuffer: CVPixelBuffer) {
        // Throttle to ~15fps
        let now = CACurrentMediaTime()
        guard now - lastPeakingTime > 0.066 else { return }
        lastPeakingTime = now

        guard let context = sharedContext else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // Downscale for peaking — edges are visible at quarter res
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))

        edgesFilter.inputImage = scaled
        guard let edgeImage = edgesFilter.outputImage else { return }

        colorMatrixFilter.inputImage = edgeImage

        guard let colored = colorMatrixFilter.outputImage,
              let cgImage = context.createCGImage(colored, from: scaled.extent) else { return }

        DispatchQueue.main.async {
            self.overlayLayer.contents = cgImage
        }
    }
}
