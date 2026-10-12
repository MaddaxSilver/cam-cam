//
//  CameraPreview.swift
//  cam cam
//
//  Viewfinder views: AVCapture preview layer and the Metal filtered preview.
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

// MARK: - PreviewUIView

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }

    private var observation: NSKeyValueObservation?
    private var sessionStartObserver: Any?
    private var snapshotView: UIView?

    func configure(session: AVCaptureSession) {
        guard let previewLayer else { return }
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        applyRotation()

        // Re-apply rotation whenever inputs change (lens swap) or session starts running
        observation = session.observe(\.inputs, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyRotation() }
        }
        // Store observer token so deinit can unregister it (otherwise leaks)
        sessionStartObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification,
            object: session, queue: .main
        ) { [weak self] _ in
            self?.applyRotation()
        }
    }

    func applyRotation() {
        guard let conn = previewLayer?.connection,
              conn.isVideoRotationAngleSupported(90) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        conn.videoRotationAngle = 90
        CATransaction.commit()
    }

    /// Capture a snapshot of the current preview and overlay it, then crossfade out
    func freezeAndCrossfade(duration: TimeInterval = 0.4) {
        // Snapshot the current preview layer into an image view
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let snapshot = renderer.image { ctx in
            layer.render(in: ctx.cgContext)
        }
        let imageView = UIImageView(image: snapshot)
        imageView.frame = bounds
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        snapshotView = imageView

        // Fade out after the new lens starts producing frames
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            UIView.animate(withDuration: duration, delay: 0, options: .curveEaseInOut) {
                imageView.alpha = 0
            } completion: { _ in
                imageView.removeFromSuperview()
                self.snapshotView = nil
            }
        }
    }

    deinit {
        observation?.invalidate()
        if let obs = sessionStartObserver { NotificationCenter.default.removeObserver(obs) }
    }
}

// MARK: - CameraPreviewView

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var camera: CameraManager? = nil

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.configure(session: session)
        camera?.previewLayer = view.previewLayer
        camera?.previewUIView = view
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.applyRotation()
    }
}

// MARK: - Metal Filtered Preview

/// Renders filtered CIImages directly on the GPU via Metal — no CGImage round-trip
final class MetalFilteredPreviewView: MTKView, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue?
    nonisolated(unsafe) var sharedCIContext: CIContext?
    private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    nonisolated(unsafe) var currentImage: CIImage?

    func setup(sharedContext: CIContext? = nil) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.device = device
        commandQueue = device.makeCommandQueue()
        sharedCIContext = sharedContext
        delegate = self
        framebufferOnly = false
        // On-demand rendering: only draw when setNeedsDisplay() is called
        isPaused = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 60
        backgroundColor = .clear
        isOpaque = false
    }

    /// Drawable size, mirrored for the camera queue (UIKit owns the real one).
    nonisolated(unsafe) private var renderSize: CGSize = .zero
    /// The drawable's size in pixels (read from the camera queue).
    nonisolated var drawSize: CGSize { renderSize }
    nonisolated(unsafe) private var renderQueue: MTLCommandQueue?
    nonisolated(unsafe) private var metalLayer: CAMetalLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        renderSize = drawableSize
        renderQueue = commandQueue
        metalLayer = layer as? CAMetalLayer
    }

    /// Render a frame straight from the camera queue. Drawing used to hop to
    /// the main thread every frame (setNeedsDisplay → draw(in:)), where
    /// building and submitting the Core Image graph competed with touches,
    /// the film dial and pinch. CAMetalLayer hands out drawables on any thread.
    nonisolated func render(_ image: CIImage) {
        // Never block the camera queue waiting for the GPU: if two frames are
        // still in flight (the GPU is busy, e.g. rendering a photo), skip this
        // one. nextDrawable() would otherwise wait up to a second per frame,
        // stalling Frame guide, AE and every later frame with it.
        inFlightLock.lock()
        guard inFlight < 2 else { inFlightLock.unlock(); return }
        inFlight += 1
        inFlightLock.unlock()
        guard let layer = metalLayer,
              renderSize.width > 0,
              let context = sharedCIContext,
              let commandBuffer = renderQueue?.makeCommandBuffer(),
              let drawable = layer.nextDrawable() else { finished(); return }
        commandBuffer.addCompletedHandler { [weak self] _ in self?.finished() }
        encode(image, size: renderSize, context: context, drawable: drawable, commandBuffer: commandBuffer)
    }

    nonisolated(unsafe) private var inFlight = 0
    private let inFlightLock = NSLock()
    nonisolated private func finished() {
        inFlightLock.lock(); inFlight = max(0, inFlight - 1); inFlightLock.unlock()
    }

    func draw(in view: MTKView) {
        guard let image = currentImage,
              let context = sharedCIContext,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        encode(image, size: drawableSize, context: context, drawable: drawable, commandBuffer: commandBuffer)
    }

    nonisolated private func encode(_ image: CIImage, size dSize: CGSize, context: CIContext,
                                    drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
        // Aspect-fill so the preview fills the whole screen.
        let scaleX = dSize.width / image.extent.width
        let scaleY = dSize.height / image.extent.height
        let scale = max(scaleX, scaleY)
        // Combine scale + translation into a single transform
        let scaledW = image.extent.width * scale
        let scaledH = image.extent.height * scale
        let offsetX = (dSize.width - scaledW) / 2 - image.extent.origin.x * scale
        let offsetY = (dSize.height - scaledH) / 2 - image.extent.origin.y * scale
        let centered = image.transformed(by: CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offsetX, ty: offsetY))

        let destination = CIRenderDestination(
            width: Int(dSize.width),
            height: Int(dSize.height),
            pixelFormat: drawable.texture.pixelFormat,
            commandBuffer: commandBuffer,
            mtlTextureProvider: { drawable.texture }
        )
        _ = try? context.startTask(toRender: centered, to: destination)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { renderSize = size }
}

struct MetalFilteredPreview: UIViewRepresentable {
    let camera: CameraManager

    func makeUIView(context: Context) -> MetalFilteredPreviewView {
        let view = MetalFilteredPreviewView()
        view.setup(sharedContext: camera.ciContext)
        camera.metalPreviewView = view
        return view
    }

    func updateUIView(_ uiView: MetalFilteredPreviewView, context: Context) {}
}
