//
//  CameraImport.swift
//  cam cam
//
//  Import over the cable: plug the camera (Sony a7R III or any PTP/MTP
//  camera) into the iPhone's USB-C port and develop everything on the card
//  with a film in one go.
//
//  ImageCaptureCore lists the card; each photo is downloaded, developed with
//  the chosen film (JPEGs as shot; RAW files — Sony ARW and others —
//  developed with Apple's RAW engine) and saved like every cam cam shot: the
//  camera's original as the photo, the film as a revertible, re-gradable
//  edit, in the cam cam album. Photos already imported are remembered and
//  skipped next time.
//
//  Sony: set Menu → Setup → USB Connection to "MTP" (or "Auto").
//

import ImageCaptureCore
import Photos
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class CameraImporter: NSObject {
    static let shared = CameraImporter()

    private(set) var status = "Plug your camera into the iPhone with a USB-C cable"
    private(set) var cameraName: String?
    /// Photos on the card (newest first), RAW+JPEG pairs listed once.
    private(set) var shots: [Shot] = []
    private(set) var thumbs: [String: UIImage] = [:]
    private(set) var running = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var failed = 0

    var onlyNew = true
    var preferRAW = UserDefaults.standard.object(forKey: "cc_importPreferRAW") as? Bool ?? false {
        didSet { UserDefaults.standard.set(preferRAW, forKey: "cc_importPreferRAW") }
    }

    struct Shot: Identifiable {
        let id: String              // base name + date
        var jpeg: ICCameraFile?
        var raw: ICCameraFile?
        var date: Date?
        var any: ICCameraFile { jpeg ?? raw! }
    }

    var newCount: Int { shots.filter { !imported.contains($0.id) }.count }

    @ObservationIgnored private let browser = ICDeviceBrowser()
    @ObservationIgnored private var camera: ICCameraDevice?
    @ObservationIgnored private var imported: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "cc_importedShots") ?? [])
    @ObservationIgnored private var browsing = false

    func isImported(_ s: Shot) -> Bool { imported.contains(s.id) }

    // MARK: Browsing

    func start() {
        guard !browsing else { return }
        browsing = true
        browser.delegate = self
        browser.requestContentsAuthorization { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                if st == .authorized { self.browser.start() }
                else { self.status = "Allow cam cam to read the camera's photos in Settings" }
            }
        }
    }

    func stop() {
        guard browsing, !running else { return }
        browsing = false
        browser.stop()
        camera?.requestCloseSession()
        camera = nil
    }

    fileprivate func catalogReady(_ cam: ICCameraDevice) {
        var byBase: [String: Shot] = [:]
        for case let f as ICCameraFile in cam.mediaFiles ?? [] {
            guard let name = f.name, let uti = f.uti.flatMap({ UTType($0) }), uti.conforms(to: .image) else { continue }
            let base = (name as NSString).deletingPathExtension
            let date = f.creationDate
            let key = "\(cam.name ?? "camera")|\(base)|\(Int(date?.timeIntervalSince1970 ?? 0))"
            var s = byBase[key] ?? Shot(id: key, date: date)
            if uti.conforms(to: .rawImage) { s.raw = f } else { s.jpeg = f }
            byBase[key] = s
        }
        shots = byBase.values.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        status = shots.isEmpty ? "No photos on the card" : "\(shots.count) photos · \(newCount) new"
        for s in shots.prefix(60) { loadThumb(s) }
    }

    private func loadThumb(_ s: Shot) {
        guard thumbs[s.id] == nil else { return }
        s.any.requestThumbnailData(options: nil) { [weak self] data, _ in
            guard let data, let img = UIImage(data: data) else { return }
            Task { @MainActor in self?.thumbs[s.id] = img }
        }
    }

    // MARK: Importing

    /// Develop the selected photos with `recipe` and save them.
    func importShots(recipe: ShotRecipe, camera cam: CameraManager) {
        guard !running else { return }
        let list = shots.filter { !onlyNew || !imported.contains($0.id) }
        guard !list.isEmpty else { status = "Nothing new to import"; return }
        running = true; done = 0; failed = 0; total = list.count
        status = "Developing \(total) photos…"
        for _ in list { DevelopActivity.shared.shotStarted(burst: true) }
        let preferRAW = preferRAW
        Task {
            for s in list {
                let file = preferRAW ? (s.raw ?? s.jpeg!) : (s.jpeg ?? s.raw!)
                let ok = await Self.importOne(file, recipe: recipe, camera: cam)
                DevelopActivity.shared.shotFinished()
                if ok { done += 1; imported.insert(s.id); UserDefaults.standard.set(Array(imported), forKey: "cc_importedShots") }
                else { failed += 1 }
                status = "Developed \(done) of \(total)" + (failed > 0 ? " · \(failed) failed" : "")
            }
            running = false
            status = "Imported \(done) photos" + (failed > 0 ? " · \(failed) failed" : "") + " into the cam cam album"
            UINotificationFeedbackGenerator().notificationOccurred(failed == 0 ? .success : .warning)
        }
    }

    /// Download one file, develop it with the film and save it. Off the main actor.
    nonisolated private static func importOne(_ file: ICCameraFile, recipe: ShotRecipe, camera cam: CameraManager) async -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("camera-import", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name: String? = await withCheckedContinuation { cont in
            _ = file.requestDownload(options: [.downloadsDirectoryURL: dir, .overwrite: true]) { saved, err in
                cont.resume(returning: err == nil ? saved : nil)
            }
        }
        guard let name else { return false }
        let url = dir.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url) else { return false }
        let uti = file.uti.flatMap { UTType($0) }
        let isRAW = uti?.conforms(to: .rawImage) ?? false

        struct Out: @unchecked Sendable { let jpeg: Data? }
        let out: Out? = await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                CameraManager.lookAngle = 0
                var img: CIImage?
                if isRAW {
                    img = CIRAWFilter(imageData: data, identifierHint: uti?.identifier)?.outputImage
                } else if let ci = CIImage(data: data) {
                    let o = (ci.properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
                    img = ci.oriented(forExifOrientation: o)
                }
                guard var image = img else { return nil }
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                let graded = recipe.isIdentity ? image : cam.renderLook(image, recipe: recipe, flatten: true).cropped(to: image.extent)
                guard let cg = cam.photoContext.createCGImage(graded, from: graded.extent) else { return nil }
                return Out(jpeg: MetadataTools.jpeg(from: cg, metadataFrom: data, location: nil))
            }
        }.value
        guard let out else { return false }
        do {
            _ = try await PhotoSaver.save(original: data, rendered: recipe.isIdentity ? nil : out.jpeg,
                                          recipe: recipe.isIdentity ? nil : recipe, location: nil,
                                          originalUTI: isRAW ? uti?.identifier : nil)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - ImageCaptureCore delegates

extension CameraImporter: ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        Task { @MainActor in
            self.camera = cam
            self.cameraName = cam.name
            self.status = "Connecting to \(cam.name ?? "the camera")…"
            cam.delegate = self
            cam.requestOpenSession()
        }
    }
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            guard device === self.camera else { return }
            self.camera = nil; self.cameraName = nil; self.shots = []
            self.status = self.running ? "Camera unplugged — import stopped" : "Plug your camera into the iPhone with a USB-C cable"
        }
    }
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        Task { @MainActor in
            if let error { self.status = "Couldn't open the camera: \(error.localizedDescription). On a Sony, set USB Connection to MTP." }
            else { self.status = "Reading the card…" }
        }
    }
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    nonisolated func didRemove(_ device: ICDevice) {}
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in self.catalogReady(device) }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor in if self.camera === camera, !self.running { self.catalogReady(camera) } }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

// MARK: - Sheet

struct CameraImportSheet: View {
    let camera: CameraManager
    @State private var importer = CameraImporter.shared
    @Environment(\.dismiss) private var dismiss

    private var recipe: ShotRecipe { camera.liveRecipe(sim: camera.selectedSim, custom: camera.activeCustomSim) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Image(systemName: importer.cameraName == nil ? "cable.connector" : "camera.fill")
                        .font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(importer.cameraName ?? "No camera").font(.headline)
                    Text(importer.status).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                if importer.running {
                    ProgressView(value: Double(importer.done + importer.failed), total: Double(max(importer.total, 1)))
                        .tint(.yellow).padding(.horizontal)
                }

                if !importer.shots.isEmpty {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2) {
                            ForEach(importer.shots.prefix(60)) { s in
                                ZStack(alignment: .topTrailing) {
                                    Color.white.opacity(0.06).aspectRatio(1, contentMode: .fit)
                                        .overlay { if let t = importer.thumbs[s.id] { Image(uiImage: t).resizable().scaledToFill() } }
                                        .clipped()
                                    if importer.isImported(s) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.yellow).padding(4)
                                    } else if s.raw != nil {
                                        Text("RAW").font(.system(size: 9, weight: .bold)).padding(3)
                                            .background(.black.opacity(0.6), in: Capsule()).padding(4)
                                    }
                                }
                            }
                        }
                    }
                    Form {
                        LabeledContent("Film", value: recipe.displayName)
                        Toggle("Only photos not imported yet", isOn: $importer.onlyNew)
                        Toggle("Use RAW when there's RAW + JPEG", isOn: $importer.preferRAW)
                    }
                    .frame(height: 170)
                    .scrollDisabled(true)
                    Button {
                        importer.importShots(recipe: recipe, camera: camera)
                    } label: {
                        Text(importer.running ? "Developing…" : "Import \(importer.onlyNew ? importer.newCount : importer.shots.count) with \(recipe.displayName)")
                            .font(.headline).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(Capsule().fill(Color.yellow))
                    }
                    .buttonStyle(.plain)
                    .disabled(importer.running || (importer.onlyNew && importer.newCount == 0))
                    .padding(.horizontal).padding(.bottom, 8)
                } else {
                    Spacer()
                    Text("Sony: Menu → Setup → USB Connection → MTP.\nThe film is the one on your dial.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }
            }
            .navigationTitle("Import from camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear { importer.start() }
        .onDisappear { importer.stop() }
    }
}
