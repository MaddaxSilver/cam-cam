//
//  LUTManager.swift
//  cam cam
//
//  Imports user-supplied .cube LUT files from the Files app, stores them in
//  Documents/LUTs/, parses them into CIColorCube CIFilters, and caches the
//  parsed filters so per-frame application is fast.
//
//  .cube format reference: Adobe / Autodesk de-facto standard.
//      TITLE "name"
//      LUT_3D_SIZE 32
//      DOMAIN_MIN 0 0 0
//      DOMAIN_MAX 1 1 1
//      r g b
//      r g b
//      …  (N*N*N total samples in B-fastest, then G, then R order)
//

import Foundation
import CoreImage

/// Parsed 3D LUT: immutable, so it's safe to share across threads.
struct CubeLUT: Sendable {
    let size: Int
    let data: Data   // packed RGBA Float32, R-fastest (CIColorCube layout)
}

/// Not @MainActor because the per-frame `apply(filename:to:)` path runs from
/// CameraManager's nonisolated video-data callback AND from the capture
/// process queue — concurrently.
///
/// Thread safety: we cache the immutable parsed cube DATA (behind a lock) and
/// build a fresh filter per apply via `applyingFilter`. We deliberately do
/// NOT cache a CIFilter: CIFilters are mutable and not thread-safe, and the
/// old shared-filter design set `inputImage` from two threads at once — so a
/// saved photo could come out with a preview frame's pixels (or vice versa).
final class LUTManager: @unchecked Sendable {

    nonisolated static let shared = LUTManager()

    private let cacheLock = NSLock()
    nonisolated static let cubeColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    nonisolated(unsafe) private var lutCache: [String: CubeLUT] = [:]

    /// Directory where imported .cube files live: Documents/LUTs/
    nonisolated var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("LUTs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
        }
        return dir
    }

    /// All `.cube` files currently in the LUTs directory.
    var availableLUTs: [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names
            .filter { $0.lowercased().hasSuffix(".cube") }
            .sorted()
    }

    /// Copy a security-scoped source URL (from .fileImporter) into our LUTs
    /// directory. Returns the saved filename on success.
    func importLUT(from sourceURL: URL) throws -> String {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let filename = sourceURL.lastPathComponent
        let dest = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        // Validate by attempting a parse; clean up if invalid. Drop any stale
        // cache entry first in case this file replaced one with the same name.
        cacheLock.lock(); lutCache.removeValue(forKey: filename); cacheLock.unlock()
        if lut(for: filename) == nil {
            try? FileManager.default.removeItem(at: dest)
            throw NSError(domain: "LUTManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Not a valid .cube LUT file"
            ])
        }
        return filename
    }

    /// Delete a saved LUT.
    func deleteLUT(filename: String) {
        let url = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        cacheLock.lock(); lutCache.removeValue(forKey: filename); cacheLock.unlock()
    }

    /// Cached parsed LUT for `filename`, parsing on first use.
    /// Returns nil if the file is missing or not parseable.
    nonisolated func lut(for filename: String) -> CubeLUT? {
        cacheLock.lock()
        if let cached = lutCache[filename] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        // Parse outside the lock (can take a while for 64³ files); a racing
        // duplicate parse is harmless — both produce identical immutable data.
        guard let parsed = parseCubeFile(filename) else { return nil }
        cacheLock.lock(); lutCache[filename] = parsed; cacheLock.unlock()
        return parsed
    }

    /// Apply a stored LUT to a CIImage. Thread-safe: builds a fresh CIColorCube
    /// per call from the shared immutable cube data.
    nonisolated func apply(filename: String, to image: CIImage) -> CIImage {
        guard let lut = lut(for: filename) else { return image }
        // CIColorCubeWithColorSpace(sRGB): .cube LUTs are authored for gamma-
        // encoded Rec.709/sRGB values (how Lightroom/Resolve apply them). Plain
        // CIColorCube applies the table in the context's WORKING space — linear
        // by default — which shifted every imported LUT (badly on Sony, whose
        // context was linear; slightly on iPhone, whose working space is P3).
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": lut.size,
            "inputCubeData": lut.data,
            "inputColorSpace": LUTManager.cubeColorSpace,
        ])
    }

    // MARK: - .cube parsing

    nonisolated private func parseCubeFile(_ filename: String) -> CubeLUT? {
        let url = directory.appendingPathComponent(filename)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseCube(content)
    }

    /// Parse .cube text into packed cube data.
    /// Returns nil for malformed input or unsupported variants (1D LUTs).
    nonisolated private func parseCube(_ content: String) -> CubeLUT? {
        var size: Int = 0
        var domainMin: SIMD3<Float> = SIMD3(0, 0, 0)
        var domainMax: SIMD3<Float> = SIMD3(1, 1, 1)
        var samples: [Float] = []  // packed RGBA, A=1.0

        for rawLine in content.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip line comments
            if let hashIdx = line.firstIndex(of: "#") {
                line = String(line[..<hashIdx]).trimmingCharacters(in: .whitespaces)
            }
            if line.isEmpty { continue }

            let upper = line.uppercased()
            if upper.hasPrefix("TITLE") { continue }
            if upper.hasPrefix("LUT_1D_SIZE") { return nil }   // not supported
            if upper.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count >= 2, let n = Int(parts[1]) {
                    size = n
                    samples.reserveCapacity(n * n * n * 4)
                }
                continue
            }
            if upper.hasPrefix("DOMAIN_MIN") {
                let p = line.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
                if p.count >= 3 { domainMin = SIMD3(p[0], p[1], p[2]) }
                continue
            }
            if upper.hasPrefix("DOMAIN_MAX") {
                let p = line.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
                if p.count >= 3 { domainMax = SIMD3(p[0], p[1], p[2]) }
                continue
            }

            // Sample row: "r g b"
            let nums = line.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
            guard nums.count >= 3 else { continue }
            // Remap from [domainMin, domainMax] → [0,1] (most files use 0..1 already)
            let r = (nums[0] - domainMin.x) / max(domainMax.x - domainMin.x, .leastNonzeroMagnitude)
            let g = (nums[1] - domainMin.y) / max(domainMax.y - domainMin.y, .leastNonzeroMagnitude)
            let b = (nums[2] - domainMin.z) / max(domainMax.z - domainMin.z, .leastNonzeroMagnitude)
            samples.append(r); samples.append(g); samples.append(b); samples.append(1.0)
        }

        guard size > 0 else { return nil }
        let expected = size * size * size * 4
        guard samples.count == expected else {
            // Allow short LUTs only if exactly the right multiple of channels
            return nil
        }

        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(size: size, data: data)
    }
}
