//
//  MonoDepth.swift
//  cam cam
//
//  Depth from a single photo with Depth Anything V2 Small (Apache-2.0,
//  Apple's Core ML conversion; fetched by scripts/fetch-models.sh and
//  optional — without it portraits use the camera's depth stream only).
//
//  Why: the camera's live depth map is ~320×240 and only comes with the 12MP
//  depth format of the multi-lens camera. The network gives sharper,
//  scene-wide depth from any frame, so Portrait works at 48MP on the main
//  lens. When the camera's depth is there too, the network's depth is fitted
//  to it (the network's depth is relative), keeping the camera's scale and
//  the network's edges.
//

import CoreImage
import CoreML
import Vision

nonisolated enum MonoDepth {
    nonisolated(unsafe) private static var model: VNCoreMLModel?
    nonisolated(unsafe) private static var tried = false
    private static let lock = NSLock()

    private static func load() -> VNCoreMLModel? {
        lock.lock(); defer { lock.unlock() }
        if tried { return model }
        tried = true
        guard let url = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        do { model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: cfg)) }
        catch { print("MonoDepth: load failed: \(error)") }
        return model
    }

    /// Load (and compile for the Neural Engine) ahead of time: the first load
    /// takes ~7.5 s per launch, a depth map ~0.7 s after that.
    static func prewarm() {
        guard available else { return }
        DispatchQueue.global(qos: .utility).async { _ = load() }
    }

    /// The model is bundled (doesn't load it).
    static let available: Bool = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") != nil

    /// Relative disparity (bright = near, 0…1) at `image`'s extent.
    static func disparity(of image: CIImage) -> CIImage? {
        guard let m = load() else { return nil }
        let e = image.extent
        // The network is 518×392 (landscape): feed portrait frames turned.
        let portrait = e.height > e.width
        var input = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        if portrait { input = input.oriented(.right); input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY)) }
        let s = 1036 / max(input.extent.width, input.extent.height)
        input = input.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let req = VNCoreMLRequest(model: m)
        req.imageCropAndScaleOption = .scaleFill
        do { try VNImageRequestHandler(ciImage: input).perform([req]) }
        catch { print("MonoDepth: request failed: \(error)"); return nil }
        guard let obs = req.results?.first as? VNPixelBufferObservation else { print("MonoDepth: no result"); return nil }
        var d = CIImage(cvPixelBuffer: obs.pixelBuffer)
        if portrait { d = d.oriented(.left) }
        d = d.transformed(by: CGAffineTransform(translationX: -d.extent.minX, y: -d.extent.minY))
        let sx = e.width / d.extent.width, sy = e.height / d.extent.height
        return d.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .cropped(to: e)
    }

    /// Fit the network's relative depth to the camera's disparity
    /// (`camera = a·mono + b`, least squares on a coarse grid), or, without
    /// the camera's, map it to a plausible 0.1…2 /m range.
    static func calibrated(_ mono: CIImage, to camera: CIImage?, context: CIContext) -> CIImage {
        func scaled(_ a: CGFloat, _ b: CGFloat) -> CIImage {
            mono.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: a, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0)])
                .cropped(to: mono.extent)
        }
        guard let camera else { return scaled(1.9, 0.1) }
        let e = mono.extent, gw = 32, gh = 24
        func grid(_ img: CIImage) -> [Float] {
            let g = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(gw) / e.width, y: CGFloat(gh) / e.height))
            var buf = [Float](repeating: 0, count: gw * gh * 4)
            context.render(g, toBitmap: &buf, rowBytes: gw * 16, bounds: CGRect(x: 0, y: 0, width: gw, height: gh),
                           format: .RGBAf, colorSpace: nil)
            return (0..<(gw * gh)).map { buf[$0 * 4] }
        }
        let x = grid(mono), y = grid(camera.cropped(to: e))
        let n = Float(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy: Float = 0, sxx: Float = 0
        for i in x.indices { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) * (x[i] - mx) }
        guard sxx > 1e-6, sxy > 0, mx.isFinite, my.isFinite else { return scaled(1.9, 0.1) }
        let a = sxy / sxx, b = my - a * mx
        return scaled(CGFloat(a), CGFloat(b))
    }
}
