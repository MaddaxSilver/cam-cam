//
//  PhotoSaver.swift
//  cam cam
//
//  One save pipeline for both cameras (iPhone + Sony):
//
//   1. The ORIGINAL becomes the photo's base resource, untouched (Sony bytes
//      are byte-identical apart from a lossless GPS insert).
//   2. If a look was applied, the rendered image is committed as a Photos
//      EDIT carrying the ShotRecipe as PHAdjustmentData. Photos shows "Revert";
//      cam cam can reopen the original later and re-grade it (RegradeView).
//   3. The phone's location is attached (Sony a7R III has no GPS).
//   4. Everything lands in a "cam cam" album.
//
//  Falls back to the old flat save (rendered image only) when the user granted
//  add-only Photos access, so a shot is never lost.
//

import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import CoreLocation

nonisolated enum PhotoSaver {

    static let albumTitle = "cam cam"

    struct Result: Sendable {
        let assetID: String?
        let nondestructive: Bool
        let message: String
    }

    enum SaveError: LocalizedError {
        case notAuthorized(String)
        var errorDescription: String? {
            switch self { case .notAuthorized(let s): return "Photos access: \(s) — enable in Settings" }
        }
    }

    // MARK: Public entry

    /// - original: camera output bytes (JPEG/HEIC). Becomes the base resource.
    /// - rendered: graded JPEG (orientation already baked, upright), or nil
    ///   when no look was applied (then only the original is saved).
    /// - recipe: the look that produced `rendered` (stored for re-grading).
    /// - location: phone GPS fix, or nil.
    static func save(original: Data, rendered: Data?, recipe: ShotRecipe?,
                     location: CLLocation?) async throws -> Result {
        let status = await authorize()
        switch status {
        case .authorized, .limited:
            break
        case .denied, .restricted, .notDetermined:
            // Maybe the user only allowed adding — try the flat fallback.
            return try await flatSave(data: rendered ?? original, location: location,
                                      reason: "add-only access")
        @unknown default:
            return try await flatSave(data: rendered ?? original, location: location,
                                      reason: "unknown access")
        }

        let base = location.flatMap { MetadataTools.addingGPS(to: original, location: $0) } ?? original
        let assetID = try await createAsset(data: base, location: location)

        guard let rendered, let recipe, let assetID else {
            return Result(assetID: assetID, nondestructive: true, message: "Saved original")
        }
        do {
            try await commitEdit(assetID: assetID, rendered: rendered, recipe: recipe)
            return Result(assetID: assetID, nondestructive: true,
                          message: "Saved · \(recipe.displayName) · revertible")
        } catch {
            // Never lose the look: add the rendered version as its own photo.
            _ = try? await createAsset(data: rendered, location: location)
            return Result(assetID: assetID, nondestructive: false,
                          message: "Saved (edit failed: \(error.localizedDescription))")
        }
    }

    /// Re-grade an existing cam cam photo with a new recipe. `render` turns the
    /// ORIGINAL (unedited) image into the new graded JPEG.
    static func regrade(assetID: String, recipe: ShotRecipe,
                        render: @Sendable (Data) -> Data?) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject,
              let input = await editingInput(for: asset),
              let url = input.fullSizeImageURL,
              let original = try? Data(contentsOf: url),
              let graded = render(original)
        else { throw NSError(domain: "PhotoSaver", code: 2,
                             userInfo: [NSLocalizedDescriptionKey: "Couldn't open the original"]) }
        try await commit(input: input, asset: asset, rendered: graded, recipe: recipe)
    }

    /// The recipe stored on a cam cam photo, if any.
    static func recipe(for asset: PHAsset) async -> ShotRecipe? {
        guard let input = await editingInput(for: asset),
              let adj = input.adjustmentData,
              adj.formatIdentifier == ShotRecipe.formatIdentifier
        else { return nil }
        return ShotRecipe.decode(adj.data)
    }

    // MARK: Internals

    static func authorize() async -> PHAuthorizationStatus {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard s == .notDetermined else { return s }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    private static func createAsset(data: Data, location: CLLocation?) async throws -> String? {
        var placeholder: String?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: data, options: nil)
            if let location { req.location = location }
            placeholder = req.placeholderForCreatedAsset?.localIdentifier
            if let album = albumIfExists(), let ph = req.placeholderForCreatedAsset {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([ph] as NSArray)
            }
        }
        // Create the album lazily the first time, then add the asset to it.
        if albumIfExists() == nil, let placeholder {
            try? await PHPhotoLibrary.shared().performChanges {
                let created = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: [placeholder], options: nil)
                created.addAssets(assets)
            }
        }
        return placeholder
    }

    static func albumIfExists() -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title == %@", albumTitle)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: opts).firstObject
    }

    private static func commitEdit(assetID: String, rendered: Data, recipe: ShotRecipe) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject,
              let input = await editingInput(for: asset)
        else { throw NSError(domain: "PhotoSaver", code: 1,
                             userInfo: [NSLocalizedDescriptionKey: "asset not found after save"]) }
        try await commit(input: input, asset: asset, rendered: rendered, recipe: recipe)
    }

    private static func commit(input: PHContentEditingInput, asset: PHAsset,
                               rendered: Data, recipe: ShotRecipe) async throws {
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: ShotRecipe.formatIdentifier,
            formatVersion: String(ShotRecipe.currentVersion),
            data: recipe.encoded() ?? Data())
        let url = try output.renderedContentURL(for: .jpeg)
        try rendered.write(to: url, options: .atomic)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
    }

    /// Editing input that hands us the UNEDITED original when the asset carries
    /// a cam cam recipe (canHandleAdjustmentData → true).
    static func editingInput(for asset: PHAsset) async -> PHContentEditingInput? {
        await withCheckedContinuation { cont in
            let opts = PHContentEditingInputRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.canHandleAdjustmentData = { $0.formatIdentifier == ShotRecipe.formatIdentifier }
            asset.requestContentEditingInput(with: opts) { input, _ in
                cont.resume(returning: input)
            }
        }
    }

    /// Old behaviour: one flat asset (used with add-only access).
    private static func flatSave(data: Data, location: CLLocation?, reason: String) async throws -> Result {
        let addStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            : PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard addStatus == .authorized || addStatus == .limited else {
            throw SaveError.notAuthorized("\(addStatus.rawValue)")
        }
        let tagged = location.flatMap { MetadataTools.addingGPS(to: data, location: $0) } ?? data
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: tagged, options: nil)
            if let location { req.location = location }
        }
        return Result(assetID: nil, nondestructive: false, message: "Saved (\(reason) — not revertible)")
    }
}

// MARK: - Metadata helpers

nonisolated enum MetadataTools {

    /// Insert GPS into JPEG/HEIC bytes WITHOUT recompressing the pixels
    /// (CGImageDestinationCopyImageSource rewrites metadata only).
    static func addingGPS(to data: Data, location: CLLocation) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src) else { return nil }
        let meta = CGImageMetadataCreateMutable()
        for (k, v) in gpsDictionary(for: location) {
            _ = CGImageMetadataSetValueMatchingImageProperty(
                meta, kCGImagePropertyGPSDictionary, k, v as CFTypeRef)
        }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out as CFMutableData, type, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationMetadata: meta,
                                     kCGImageDestinationMergeMetadata: true]
        guard CGImageDestinationCopyImageSource(dst, src, opts as CFDictionary, nil) else { return nil }
        return out as Data
    }

    /// EXIF GPS dictionary for a fix (for re-encodes that write full properties).
    static func gpsDictionary(for loc: CLLocation) -> [CFString: Any] {
        let c = loc.coordinate
        let utc = TimeZone(identifier: "UTC")!
        let df = DateFormatter(); df.timeZone = utc; df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy:MM:dd"; let date = df.string(from: loc.timestamp)
        df.dateFormat = "HH:mm:ss.SS"; let time = df.string(from: loc.timestamp)
        var d: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(c.latitude),
            kCGImagePropertyGPSLatitudeRef: c.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(c.longitude),
            kCGImagePropertyGPSLongitudeRef: c.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSDateStamp: date,
            kCGImagePropertyGPSTimeStamp: time,
        ]
        if loc.horizontalAccuracy >= 0 { d[kCGImagePropertyGPSHPositioningError] = loc.horizontalAccuracy }
        if loc.verticalAccuracy >= 0 {
            d[kCGImagePropertyGPSAltitude] = abs(loc.altitude)
            d[kCGImagePropertyGPSAltitudeRef] = loc.altitude < 0 ? 1 : 0
        }
        return d
    }

    /// Re-encode `image` as JPEG keeping the source's EXIF/TIFF/maker metadata,
    /// with orientation reset (pixels are already upright) and optional GPS.
    static func jpeg(from image: CGImage, metadataFrom original: Data?,
                     location: CLLocation?, quality: CGFloat = 1.0) -> Data? {
        var props: [CFString: Any] = [:]
        if let original, let src = CGImageSourceCreateWithData(original as CFData, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            props = p
        }
        props[kCGImageDestinationLossyCompressionQuality] = quality
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let location { props[kCGImagePropertyGPSDictionary] = gpsDictionary(for: location) }
        // Pixel dims change after crops — let ImageIO write the real ones.
        props.removeValue(forKey: kCGImagePropertyPixelWidth)
        props.removeValue(forKey: kCGImagePropertyPixelHeight)
        let buf = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(buf as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dst, image, props as CFDictionary)
        return CGImageDestinationFinalize(dst) ? buf as Data : nil
    }
}
