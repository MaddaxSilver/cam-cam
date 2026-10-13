//
//  RegradeView.swift
//  cam cam
//
//  Change a shot's film look AFTER taking it. Every cam cam photo is saved as
//  original + a Photos edit carrying its ShotRecipe (see PhotoSaver), so here
//  we reopen the untouched original, preview any film live on the same dial
//  as the camera, and commit a new edit — or go back to the original.
//  Effects/grain/seed from the shot's recipe are kept; only the film changes.
//

import SwiftUI
import Photos
import CoreImage

struct RegradeView: View {
    let camera: CameraManager
    let customSimStore: CustomSimStore
    @Environment(\.dismiss) private var dismiss
    @State private var assetIDs: [String] = []
    @State private var assets: [String: PHAsset] = [:]
    @State private var loaded = false
    @State private var open: String?            // editor
    @State private var viewing: Int?             // full-screen viewer (index into assetIDs)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let id = open {
                RegradeDetail(assetID: id, camera: camera, customSimStore: customSimStore,
                              onBack: { open = nil })
                    .transition(.move(edge: .bottom))
            } else if let i = viewing {
                PhotoViewer(ids: assetIDs, assets: assets, index: i,
                            onClose: { viewing = nil },
                            onEdit: { id in viewing = assetIDs.firstIndex(of: id); open = id },
                            onDeleted: { id in
                                assetIDs.removeAll { $0 == id }
                                if assetIDs.isEmpty { viewing = nil } else { viewing = min(i, assetIDs.count - 1) }
                            })
                    .transition(.opacity)
            } else {
                grid.transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.3), value: open)
        .animation(.easeOut(duration: 0.2), value: viewing)
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Back to camera")
                Spacer()
                VStack(spacing: 1) {
                    Text("cam cam").font(.system(size: 17, weight: .semibold))
                    Text("\(assetIDs.count) photos").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)

            if loaded && assetIDs.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack").font(.system(size: 44)).foregroundStyle(.white.opacity(0.5))
                    Text("No cam cam photos yet").font(.title3.weight(.semibold))
                    Text("Every shot keeps its original, so you can change its film here later.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(assetIDs, id: \.self) { id in
                            Button { viewing = assetIDs.firstIndex(of: id) } label: { AssetThumb(assetID: id, asset: assets[id]) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        _ = await PhotoSaver.authorize()
        defer { loaded = true }
        guard let album = PhotoSaver.albumIfExists() else { return }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let r = PHAsset.fetchAssets(in: album, options: opts)
        var list: [PHAsset] = []
        r.enumerateObjects { a, _, _ in list.append(a) }
        assets = Dictionary(uniqueKeysWithValues: list.map { ($0.localIdentifier, $0) })
        assetIDs = list.map(\.localIdentifier)
    }
}

// MARK: - Thumbnail (with the film it was shot on)

private struct AssetThumb: View {
    let assetID: String
    let asset: PHAsset?
    @State private var image: UIImage?
    @State private var film: String?
    @State private var request: PHImageRequestID?
    static let images = PHCachingImageManager()

    var body: some View {
        Color.white.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .overlay(alignment: .bottomLeading) {
                if let film {
                    Text(film.uppercased())
                        .font(.system(size: 9, weight: .bold)).tracking(0.5)
                        .lineLimit(1)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(5)
                }
            }
            .clipped()
            .task {
                guard let asset = asset ?? PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
                else { return }
                let opts = PHImageRequestOptions()
                opts.deliveryMode = .opportunistic
                opts.resizeMode = .fast
                opts.isNetworkAccessAllowed = true
                request = Self.images.requestImage(for: asset, targetSize: CGSize(width: 360, height: 360),
                                                   contentMode: .aspectFill, options: opts) { img, _ in
                    if let img { image = img }
                }
                // The film label: cached, or looked up in the background.
                if let n = PhotoSaver.cachedFilmName(assetID) { film = n.isEmpty ? nil : n }
                else {
                    let n = await PhotoSaver.FilmNameLoader.shared.name(for: asset)
                    film = n.isEmpty ? nil : n
                }
            }
            .onDisappear {
                if let r = request { Self.images.cancelImageRequest(r); request = nil }
            }
    }
}

// MARK: - Detail

private struct RegradeDetail: View {
    let assetID: String
    let camera: CameraManager
    let customSimStore: CustomSimStore
    var onBack: () -> Void

    @State private var original: CIImage?          // downscaled, upright, for previews
    @State private var rendering = false
    @State private var renderAgain = false
    @State private var originalUI: UIImage?
    @State private var preview: UIImage?
    @State private var oldRecipe: ShotRecipe?
    @State private var recipe = ShotRecipe()
    @State private var busy = false
    @State private var message: String?
    @State private var comparing = false
    @State private var tones = FilmToneStore.shared

    private var items: [ArcItem] {
        FilmSimulation.allCases.map(ArcItem.builtIn) + customSimStore.simulations.map(ArcItem.custom)
    }
    private var selectedKey: String {
        if let c = recipe.custom { return FavoritesStore.key(c) }
        return FavoritesStore.key(recipe.sim)
    }

    var body: some View {
        ZStack {
            // Photo, full bleed; hold to see the original.
            Group {
                if let shown = comparing ? originalUI : preview {
                    Image(uiImage: shown).resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in comparing = true }
                .onEnded { _ in comparing = false })
            .accessibilityLabel("Photo. Hold to see the original.")

            VStack(spacing: 0) {
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Back to photos")
                    Spacer()
                    Text(statusText)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).frame(height: 32)
                        .glassEffect(.regular, in: Capsule())
                        .contentTransition(.opacity)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 16).padding(.top, 8)

                Spacer()

                if let message {
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).frame(minHeight: 34)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }

                FilmArc(items: items, selectedKey: selectedKey,
                        onSelect: { item in
                            if let c = item.custom { recipe.custom = c; recipe.sim = .none }
                            else if let sim = item.sim { recipe.sim = sim; recipe.custom = nil }
                        },
                        onOpenLibrary: {})

                HStack(spacing: 10) {
                    Button { Task { await revert() } } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white).frame(width: 50, height: 50)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .disabled(oldRecipe == nil)
                    .opacity(oldRecipe == nil ? 0.4 : 1)
                    .accessibilityLabel("Back to the original")

                    Button(action: onBack) {
                        Text("Cancel").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white).padding(.horizontal, 22).frame(height: 50)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())

                    Button { Task { await apply(); if message?.hasPrefix("Now") == true { onBack() } } } label: {
                        Label(recipe == oldRecipe ? "Saved" : "Save", systemImage: "checkmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(Capsule().fill(Color.yellow))
                    }
                    .buttonStyle(.plain)
                    .disabled(recipe == oldRecipe)
                    .opacity(recipe == oldRecipe ? 0.5 : 1)
                }
                .disabled(busy)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color.black.ignoresSafeArea(edges: .bottom))
            }

            if busy {
                ProgressView("Rendering full resolution…")
                    .padding(18)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .animation(.snappy(duration: 0.2), value: message)
        .task { await loadOriginal() }
        .task { tones.ensure(items, camera: camera) }
        .onChange(of: recipe) { renderPreview() }
    }

    private var statusText: String {
        if comparing { return "Original" }
        if recipe == oldRecipe { return oldRecipe.map { "Shot on \($0.displayName)" } ?? "No look yet" }
        return "Preview · \(recipe.displayName)"
    }

    // MARK: Actions

    private func loadOriginal() async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject,
              let input = await PhotoSaver.editingInput(for: asset),
              let url = input.fullSizeImageURL
        else { message = "Couldn't open this photo"; return }
        // Decode and downscale off the main thread (a 48MP decode froze the UI).
        nonisolated(unsafe) let cam = camera
        let loaded: (CIImage, UIImage)? = await Task.detached(priority: .userInitiated) {
            guard let ci = CIImage(contentsOf: url) else { return nil }
            let o = (ci.properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
            let upright = ci.oriented(forExifOrientation: o)
            // Screen resolution (1600 px was upscaled ~1.75× on a 2796 px screen: soft).
            let target = UIScreen.main.nativeBounds.height
            let scale = min(1, target / max(upright.extent.width, upright.extent.height))
            var small = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = cam.ciContext.createCGImage(small, from: small.extent) else { return nil }
            small = CIImage(cgImage: cg)              // previews re-render from pixels, not the 48MP file
            return (small, UIImage(cgImage: cg))
        }.value
        guard let (small, ui) = loaded else { message = "Couldn't open this photo"; return }
        original = small
        originalUI = ui
        if let adj = input.adjustmentData, adj.formatIdentifier == ShotRecipe.formatIdentifier {
            oldRecipe = ShotRecipe.decode(adj.data)
        } else {
            oldRecipe = nil
        }
        recipe = oldRecipe ?? ShotRecipe()
        renderPreview()
    }

    /// One render at a time; changes made meanwhile render once it's done
    /// (flicking through films used to queue a full render per change).
    private func renderPreview() {
        guard let original else { return }
        if rendering { renderAgain = true; return }
        rendering = true
        let r = recipe
        nonisolated(unsafe) let cam = camera
        Task.detached(priority: .userInitiated) {
            let out = cam.renderLook(original, recipe: r, flatten: false).cropped(to: original.extent)
            let cg = cam.ciContext.createCGImage(out, from: out.extent)
            await MainActor.run {
                if let cg, r == recipe { preview = UIImage(cgImage: cg) }
                rendering = false
                if renderAgain || r != recipe { renderAgain = false; renderPreview() }
            }
        }
    }

    private func apply() async {
        busy = true; defer { busy = false }
        let r = recipe
        nonisolated(unsafe) let cam = camera
        do {
            try await PhotoSaver.regrade(assetID: assetID, recipe: r) { data in
                guard let ci = CIImage(data: data) else { return nil }
                let o = (ci.properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
                let upright = ci.oriented(forExifOrientation: o)
                let out = cam.renderLook(upright, recipe: r, flatten: true).cropped(to: upright.extent)
                guard let cg = cam.ciContext.createCGImage(out, from: out.extent) else { return nil }
                return MetadataTools.jpeg(from: cg, metadataFrom: data, location: nil)
            }
            oldRecipe = r
            message = "Now \(r.displayName) — the original is kept"
        } catch {
            message = error.localizedDescription
        }
    }

    private func revert() async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }
        busy = true; defer { busy = false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
            }
            oldRecipe = nil
            recipe = ShotRecipe()
            PhotoSaver.rememberFilmName(nil, for: assetID)
            message = "Back to the original"
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Full-screen viewer

private struct PhotoViewer: View {
    let ids: [String]
    let assets: [String: PHAsset]
    @State var index: Int
    var onClose: () -> Void
    var onEdit: (String) -> Void
    var onDeleted: (String) -> Void
    @State private var images: [String: UIImage] = [:]
    @State private var chrome = true
    @State private var comparing = false
    @State private var originals: [String: UIImage] = [:]
    @State private var split: CGFloat = 0.5

    private var currentID: String? { ids.indices.contains(index) ? ids[index] : nil }
    private var asset: PHAsset? { currentID.flatMap { assets[$0] } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                    ZStack {
                        if let img = images[id] { Image(uiImage: img).resizable().scaledToFit() }
                        else { ProgressView().tint(.white) }
                        // Before / after: the original on the left of the line.
                        if comparing, i == index, let orig = originals[id] {
                            GeometryReader { g in
                                Image(uiImage: orig).resizable().scaledToFit()
                                    .frame(width: g.size.width, height: g.size.height)
                                    .mask(alignment: .leading) {
                                        Rectangle().frame(width: g.size.width * split)
                                    }
                                Rectangle().fill(.white).frame(width: 2, height: g.size.height)
                                    .position(x: g.size.width * split, y: g.size.height / 2)
                                Circle().fill(.white).frame(width: 30, height: 30)
                                    .overlay(Image(systemName: "chevron.left.chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.black))
                                    .position(x: g.size.width * split, y: g.size.height / 2)
                                Text("ORIGINAL").font(.system(size: 10, weight: .bold)).tracking(0.8)
                                    .padding(.horizontal, 8).frame(height: 22)
                                    .background(Capsule().fill(.black.opacity(0.5)))
                                    .position(x: 52, y: g.size.height - 30)
                            }
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                                split = min(max(v.location.x / max(UIScreen.main.bounds.width, 1), 0), 1)
                            })
                        }
                    }
                    .tag(i)
                    .task { await load(id) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scrollDisabled(comparing)
            .ignoresSafeArea()
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { chrome.toggle() } }

            if chrome {
                VStack {
                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "chevron.left").font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .accessibilityLabel("Back to photos")
                        Spacer()
                        VStack(spacing: 1) {
                            Text(dateText).font(.system(size: 15, weight: .semibold))
                            if let film { Text(film.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6)
                                .foregroundStyle(.yellow) }
                        }
                        Spacer()
                        Button(role: .destructive) { Task { await delete() } } label: {
                            Image(systemName: "trash").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .accessibilityLabel("Delete photo")
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                    Spacer()
                    HStack(spacing: 14) {
                        if let id = currentID, let img = images[id] {
                            Menu {
                                Button { InstagramShare.shareSheet(img) } label: { Label("Share photo", systemImage: "square.and.arrow.up") }
                                Button { Task { await exportFramed(id) } } label: { Label("4:5 with border", systemImage: "rectangle.portrait") }
                            } label: {
                                Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white).frame(width: 52, height: 52)
                            }
                            .glassEffect(.regular.interactive(), in: Circle())
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) { comparing.toggle() }
                                if comparing { split = 0.5; Task { await loadOriginal(id) } }
                            } label: {
                                Image(systemName: comparing ? "square.split.2x1.fill" : "square.split.2x1")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(comparing ? .yellow : .white).frame(width: 52, height: 52)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: Circle())
                            .accessibilityLabel("Compare with the original")
                        }
                        if let id = currentID, let img = images[id] {
                            // One tap: Instagram's own share page (Feed / Story / Messages).
                            Button { if !InstagramShare.postToFeed(assetID: id) { InstagramShare.shareSheet(img) } } label: {
                                Image(systemName: "camera.circle").font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(.white).frame(width: 52, height: 52)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: Circle())
                            .accessibilityLabel("Share to Instagram")
                        }
                        Button { if let id = currentID { onEdit(id) } } label: {
                            Label("Edit", systemImage: "slider.horizontal.3")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 28).frame(height: 52)
                                .background(Capsule().fill(Color.white))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 24)
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var film: String? {
        guard let id = currentID, let n = PhotoSaver.cachedFilmName(id), !n.isEmpty else { return nil }
        return n
    }
    private var dateText: String {
        guard let d = asset?.creationDate else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMM d · h:mm a" : "MMM d, yyyy"
        return f.string(from: d)
    }

    private func load(_ id: String) async {
        guard images[id] == nil, let a = assets[id] ?? PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return }
        // Full detail at screen resolution: "exact" sizing (the default fast
        // mode can return a smaller image), and a quick low-res placeholder
        // never replaces the sharp one.
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic; opts.resizeMode = .exact; opts.isNetworkAccessAllowed = true
        let side = UIScreen.main.bounds.height * UIScreen.main.scale
        AssetThumbImages.manager.requestImage(for: a, targetSize: CGSize(width: side, height: side),
                                              contentMode: .aspectFit, options: opts) { img, info in
            guard let img else { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !degraded || images[id] == nil { images[id] = img }
        }
    }

    /// The unedited original (for before / after), at screen size.
    private func loadOriginal(_ id: String) async {
        guard originals[id] == nil, let a = assets[id] ?? PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let input = await PhotoSaver.editingInput(for: a), let url = input.fullSizeImageURL else { return }
        let side = UIScreen.main.nativeBounds.height
        let img: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let img { originals[id] = img }
    }

    /// Instagram-ready: the photo on a 4:5 white card with the film's name.
    private func exportFramed(_ id: String) async {
        guard let a = assets[id] ?? PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
        let photo: UIImage? = await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat; o.resizeMode = .exact; o.isNetworkAccessAllowed = true
            AssetThumbImages.manager.requestImage(for: a, targetSize: CGSize(width: 2160, height: 2160),
                                                  contentMode: .aspectFit, options: o) { img, _ in cont.resume(returning: img) }
        }
        guard let photo else { return }
        let caption = [PhotoSaver.cachedFilmName(id).flatMap { $0.isEmpty ? nil : $0.uppercased() }, "CAM CAM"]
            .compactMap { $0 }.joined(separator: "  ·  ")
        let W: CGFloat = 2160, H: CGFloat = 2700, margin: CGFloat = 120, capH: CGFloat = 150
        let box = CGRect(x: margin, y: margin, width: W - 2 * margin, height: H - 2 * margin - capH)
        let s = min(box.width / photo.size.width, box.height / photo.size.height)
        let r = CGRect(x: box.midX - photo.size.width * s / 2, y: box.midY - photo.size.height * s / 2,
                       width: photo.size.width * s, height: photo.size.height * s)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let card = UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: fmt).image { _ in
            UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: W, height: H))
            photo.draw(in: r)
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40, weight: .semibold), .kern: 6,
                .foregroundColor: UIColor(white: 0.25, alpha: 1), .paragraphStyle: para]
            (caption as NSString).draw(in: CGRect(x: 0, y: r.maxY + 50, width: W, height: 60), withAttributes: attrs)
        }
        InstagramShare.shareSheet(card)
    }

    private func delete() async {
        guard let id = currentID, let a = asset else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([a] as NSArray)    // iOS asks to confirm
            }
            onDeleted(id)
        } catch {}
    }
}

private enum AssetThumbImages { static let manager = PHCachingImageManager() }
