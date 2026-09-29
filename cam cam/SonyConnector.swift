//
//  SonyConnector.swift
//  cam cam
//
//  Sony Camera Remote API (JSON-RPC over WiFi) connector.
//  Connects to a Sony a7R III (or any Sony body supporting the documented
//  Camera Remote API), shoots remotely, downloads the postview JPEG, applies
//  the active film simulation via the shared CIFilter pipeline, and saves
//  to Photos.
//
//  Scope: this connector implements ONLY the documented Camera Remote API.
//  We previously explored the DLNA/UPnP/SOAP push subsystem (XPushList,
//  X_TransferStart, ContentDirectory, NWListener for NOTIFY callbacks,
//  Bonjour, mode-switching) in an attempt to auto-receive physical-shutter
//  shots in Ctrl-w/Smartphone mode. After thorough testing we proved the
//  a7R III firmware v3.10 does NOT serve those endpoints in this mode —
//  every SOAP action returns 404, eventing returns 404, mode switching
//  returns 40401. That capability lives only on a9-firmware-4+, a7R IV+,
//  etc. Physical-shutter auto-transfer on a7R III genuinely isn't possible
//  through the documented API surface, so we no longer attempt it.
//

import Foundation
import UIKit
import Photos
import Combine
import Darwin   // getifaddrs, inet_ntop
import ImageIO
import UniformTypeIdentifiers

// MARK: - Sony Device Discovery

/// Discovers Sony cameras on the local WiFi network.
@MainActor
final class SonyDiscovery: NSObject {

    var onDeviceFound: ((SonyDevice) -> Void)?
    var onLog: ((String) -> Void)?
    var manualBaseURL: String? = nil

    private var running = false
    private var probeTask: Task<Void, Never>?

    func start() {
        guard !running else { return }
        running = true
        probeTask = Task { [weak self] in await self?.probeDirect() }
    }

    func stop() {
        running = false
        probeTask?.cancel()
        probeTask = nil
    }

    /// Read iPhone's WiFi IP and return the /24 prefix so we can try .1 first.
    private func detectWiFiSubnetPrefix() -> String? {
        let preferred = ["en0", "en1", "en2", "bridge100"]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let ifaStart = ifap else { return nil }
        defer { freeifaddrs(ifaStart) }

        for name in preferred {
            var ptr: UnsafeMutablePointer<ifaddrs>? = ifaStart
            while let ifa = ptr {
                defer { ptr = ifa.pointee.ifa_next }
                guard let ifaName = ifa.pointee.ifa_name,
                      String(cString: ifaName) == name,
                      let addr = ifa.pointee.ifa_addr,
                      addr.pointee.sa_family == UInt8(AF_INET)
                else { continue }

                let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var inAddr = sin.sin_addr
                guard inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
                let ipStr = String(cString: buf)
                let parts = ipStr.split(separator: ".")
                guard parts.count == 4 else { continue }
                return "\(parts[0]).\(parts[1]).\(parts[2])"
            }
        }
        return nil
    }

    private func probeDirect() async {
        var candidates = [
            "http://192.168.122.1:10000",
            "http://192.168.122.1:8080",
            "http://10.0.0.1:8080",
            "http://10.0.0.1:10000",
            "http://192.168.0.1:8080",
            "http://192.168.0.1:10000",
        ]

        if let prefix = detectWiFiSubnetPrefix() {
            log("📡 WiFi subnet detected: \(prefix).x — trying \(prefix).1 first")
            candidates.insert("http://\(prefix).1:8080",  at: 0)
            candidates.insert("http://\(prefix).1:10000", at: 0)
        } else {
            log("⚠️ Could not read WiFi IP — trying known Sony subnets")
        }

        if let manual = manualBaseURL, !manual.isEmpty {
            candidates.insert(manual, at: 0)
        }

        for pass in 1...2 {
            for base in candidates {
                guard running, !Task.isCancelled else { return }
                log(pass == 1 ? "Trying \(base)…" : "Retry \(base)…")
                let (device, error) = await SonyDevice.probeWithError(baseURL: base)
                if let device {
                    log("✓ Found \(device.model) at \(base)")
                    onDeviceFound?(device)
                    return
                }
                log("✗ \(error ?? "no response")")
            }
            if pass == 1 {
                log("Pass 1 done — retrying in 2 s…")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        log("All candidates exhausted.")
    }

    private func log(_ msg: String) { onLog?(msg) }
}

// MARK: - Sony Device

struct SonyDevice: Sendable {
    let baseURL: String
    let model: String
    let services: [String: String]

    var cameraServiceURL: String? { services["camera"] }
    var avContentServiceURL: String? { services["avContent"] }

    static func probe(baseURL: String) async -> SonyDevice? {
        await probeWithError(baseURL: baseURL).0
    }

    static func probeWithError(baseURL: String) async -> (SonyDevice?, String?) {
        let url = "\(baseURL)/sony/camera"
        var lastError: String = "no response"

        do {
            let result = try await SonyAPIClient.call(
                endpoint: url, method: "getApplicationInfo", params: []
            )
            let model = extractModel(from: result, method: "getApplicationInfo")
            return (SonyDevice(baseURL: baseURL, model: model, services: [
                "camera":    "\(baseURL)/sony/camera",
                "avContent": "\(baseURL)/sony/avContent"
            ]), nil)
        } catch SonyAPIError.apiError(let code, let msg) {
            lastError = "API error \(code): \(msg)"
        } catch {
            lastError = error.localizedDescription
        }

        for method in ["getVersions", "getAvailableApiList"] {
            do {
                _ = try await SonyAPIClient.call(endpoint: url, method: method, params: [])
                return (SonyDevice(baseURL: baseURL, model: "Sony Camera", services: [
                    "camera":    "\(baseURL)/sony/camera",
                    "avContent": "\(baseURL)/sony/avContent"
                ]), nil)
            } catch SonyAPIError.apiError(let code, let msg) {
                lastError = "API error \(code): \(msg)"
            } catch {
                lastError = error.localizedDescription
            }
        }
        return (nil, lastError)
    }

    /// Pull a human-readable model from the API response.
    private static func extractModel(from result: [String: Any], method: String) -> String {
        if method == "getApplicationInfo",
           let arr = result["result"] as? [Any],
           let name = arr.first as? String, !name.isEmpty {
            return name
        }
        return "Sony Camera"
    }
}

// MARK: - Sony API Client

enum SonyAPIError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case badResponse
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:                  return "Invalid URL"
        case .networkError(let e):         return "Network error: \(e.localizedDescription)"
        case .badResponse:                 return "Bad response from camera"
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        }
    }
}

struct SonyAPIClient {

    @discardableResult
    static func call(endpoint: String,
                     method: String,
                     params: [Any],
                     id: Int = 1,
                     version: String = "1.0",
                     timeout: TimeInterval = 3) async throws -> [String: Any] {
        guard let url = URL(string: endpoint) else { throw SonyAPIError.invalidURL }

        let body: [String: Any] = [
            "method":  method,
            "params":  params,
            "id":      id,
            "version": version
        ]
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw SonyAPIError.badResponse }

        // Sony wraps errors in {"error":[code,"message"]}.
        if let err = json["error"] as? [Any] {
            let code: Int
            if let c = err.first as? Int          { code = c }
            else if let n = err.first as? NSNumber { code = n.intValue }
            else { code = -1 }
            let msg = (err.dropFirst().first as? String) ?? ""
            throw SonyAPIError.apiError(code, msg)
        }
        return json
    }

    static func get(urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw SonyAPIError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}

// MARK: - Live View Snapshot
//
// Reference type the live-view parser can read from off the main actor without
// a per-frame MainActor.run hop. Writes happen on main via didSet; reads
// happen on the parser task. Stale reads are acceptable (one frame with
// previous sim setting).

final class SonyLiveSimSnapshot: @unchecked Sendable {
    nonisolated(unsafe) var sim: FilmSimulation = .none
    nonisolated(unsafe) var custom: CustomSimulation? = nil
    nonisolated(unsafe) var applyClosure: ((CIImage, FilmSimulation, CustomSimulation?) -> CIImage)? = nil
}

// MARK: - Sony Connector

@MainActor
@Observable
final class SonyConnector {

    enum State: Equatable {
        case disconnected
        case searching
        case connected(model: String)
        case error(String)
    }

    var state: State = .disconnected
    var isPolling = false
    var lastPhotoURL: String? = nil

    /// Recently-seen postview URLs for dedupe across getEvent ticks. Burst
    /// shooting fires the same takePicture slot repeatedly until the body
    /// rotates it out; without per-URL tracking we'd re-enqueue the same
    /// frame on every poll. Capped to last 64 to bound memory.
    @ObservationIgnored private var recentPhotoURLs: [String] = []
    private func isNewPhotoURL(_ url: String) -> Bool {
        if recentPhotoURLs.contains(url) { return false }
        recentPhotoURLs.append(url)
        if recentPhotoURLs.count > 64 { recentPhotoURLs.removeFirst() }
        return true
    }
    var processedCount: Int = 0
    var lastProcessedThumb: UIImage? = nil

    /// When true, every processed photo is automatically saved to the Camera Roll.
    var autoSave: Bool = true

    /// The film sim to apply to incoming Sony shots.
    var selectedSim: FilmSimulation = .none {
        didSet { liveSimSnapshot.sim = selectedSim }
    }
    var activeCustomSim: CustomSimulation? = nil {
        didSet { liveSimSnapshot.custom = activeCustomSim }
    }

    /// Called with the processed UIImage — caller (SonyView) updates UI.
    var onPhotoProcessed: ((UIImage) -> Void)?

    private var device: SonyDevice?
    private var discovery = SonyDiscovery()

    // Tracked tasks — all cancelled in disconnect()
    private var pollTask:       Task<Void, Never>?
    private var liveViewTask:   Task<Void, Never>?
    private var shutterTask:    Task<Void, Never>?
    private var timeoutTask:    Task<Void, Never>?
    private var watchdogTask:   Task<Void, Never>?
    private var setupTask:      Task<Void, Never>?
    private var heartbeatTask:  Task<Void, Never>?

    /// Set true while a shot is in flight — guards against double-taps.
    private var isShooting: Bool = false

    /// Number of postview downloads currently in flight. While >0 the
    /// watchdog stops counting frame gaps — a 24MP postview pull saturates
    /// the camera's WiFi for several seconds and live-view frames legitimately
    /// pause, which is not the same as a dead stream.
    @ObservationIgnored private var activeDownloads: Int = 0

    /// Serial queue of pending postview URLs. Even on burst shooting we only
    /// pull one image at a time so we never double up on the WiFi link.
    /// IEM does the same — confirmed via packet capture: postview GETs are
    /// always sequential, never overlapping.
    /// A queued postview download remembers the sim selection at the
    /// moment of capture. That way if the user changes sims mid-burst (or
    /// while the queue drains), each photo still gets processed with the
    /// look it was *taken* with — like a non-destructive RAW pipeline.
    private struct PendingDownload {
        let url: String
        let sim: FilmSimulation
        let custom: CustomSimulation?
    }
    @ObservationIgnored private var pendingDownloads: [PendingDownload] = []
    @ObservationIgnored private var downloadDrainTask: Task<Void, Never>? = nil

    /// Observable mirror of `pendingDownloads.count + activeDownloads` for UI.
    /// SwiftUI views read this to show a "📥 N queued" badge after a burst.
    var downloadQueueDepth: Int = 0

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Inject the film-sim apply function from CameraManager.
    var applySimClosure: ((CIImage, FilmSimulation, CustomSimulation?) -> CIImage)? {
        didSet { liveSimSnapshot.applyClosure = applySimClosure }
    }

    struct LogEntry: Identifiable, Hashable {
        let id = UUID()
        let text: String
    }
    var diagnosticLog: [LogEntry] = []

    /// Last shutter action status — shown in the connected-view UI.
    var shutterStatus: String = ""

    // Live camera status (polled via getEvent)
    var sonyShutterSpeed: String = ""
    var sonyISO: String = ""
    var sonyAperture: String = ""
    var sonyEVComp: Float = 0.0

    // Available values reported by the camera — used to populate adjustment pickers.
    var shutterSpeedCandidates: [String] = []
    var isoCandidates: [String] = []
    var apertureCandidates: [String] = []
    var evMin: Int = -9
    var evMax: Int = 9
    var evStep: Int = 1
    var evRawValue: Int = 0

    /// Optional manual IP override.
    var manualIP: String = ""

    /// Live view frame — updated at ~15 fps while connected.
    var liveViewImage: UIImage? = nil
    var liveViewStatus: String = ""

    /// APIs reported by getAvailableApiList — used for capability gating.
    var availableAPIs: [String] = []

    /// getEvent version. We use 1.8 to match Imaging Edge Mobile.
    /// Confirmed via packet capture: IEM polls `getEvent v1.8` with long-poll,
    /// and v1.8 returns a `type:"takePicture"` slot containing the postview URL
    /// for EVERY shutter (physical or API) — that's how IEM catches body
    /// shutter shots. v1.3 doesn't expose that slot.
    private var eventVersion: String = "1.8"

    /// Lock-free snapshot of sim settings used by the live-view parser.
    private let liveSimSnapshot = SonyLiveSimSnapshot()

    /// Wall-clock time of the most recent live-view frame.
    private var lastFrameTime: Date = .distantPast

    /// Single-slot frame mailbox flag — if true, parser drops new frames
    /// until main has finished assigning the previous one. Prevents queue
    /// buildup that causes growing latency in long sessions.
    /// nonisolated(unsafe): cross-actor reads/writes; benign races just
    /// mean an extra frame is dropped.
    @ObservationIgnored nonisolated(unsafe) private var liveFrameQueued: Bool = false

    /// Wall time of the last frame we actually rendered. Used by the parser
    /// to throttle when a film sim is active (its filter chain takes
    /// 30-50 ms/frame and we can't sustain stream rate). When no sim is
    /// active, this throttle is bypassed — we render every frame and rely
    /// on the mailbox flag alone for backpressure.
    @ObservationIgnored nonisolated(unsafe) private var lastRenderStart: CFTimeInterval = 0

    /// URLSession for the live-view stream. Inter-byte timeout 30s so a
    /// stalled WiFi link is detected promptly (instead of waiting 60min).
    private let streamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    private func log(_ msg: String) {
        diagnosticLog.append(LogEntry(text: msg))
        if diagnosticLog.count > 500 {
            diagnosticLog.removeFirst(diagnosticLog.count - 500)
        }
    }

    // MARK: - Connect / Disconnect

    func connect() {
        guard state == .disconnected || {
            if case .error = state { return true }; return false
        }() else { return }
        state = .searching
        diagnosticLog = []
        discovery.manualBaseURL = manualIP.isEmpty ? nil : manualIP
        discovery.onLog = { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.diagnosticLog.append(LogEntry(text: msg))
            }
        }
        discovery.onDeviceFound = { [weak self] dev in
            Task { @MainActor [weak self] in self?.handleDeviceFound(dev) }
        }
        discovery.start()

        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if case .searching = self.state {
                self.state = .error("Camera not found.\n\nTips:\n• Camera WiFi connected in iPhone Settings?\n• On camera: Menu → Network → Ctrl w/ Smartphone → Connect\n• Allow Local Network in Settings → Privacy → Local Network → cam cam\n• Enter the camera IP manually above and retry")
                self.discovery.stop()
            }
        }
    }

    func disconnect() {
        timeoutTask?.cancel();   timeoutTask = nil
        setupTask?.cancel();     setupTask = nil
        pollTask?.cancel();      pollTask = nil
        liveViewTask?.cancel();  liveViewTask = nil
        shutterTask?.cancel();   shutterTask = nil
        watchdogTask?.cancel();  watchdogTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        downloadDrainTask?.cancel(); downloadDrainTask = nil
        pendingDownloads.removeAll()
        recentPhotoURLs.removeAll()
        activeDownloads = 0
        downloadQueueDepth = 0
        discovery.stop()
        device = nil
        isPolling = false
        isShooting = false
        liveViewImage = nil
        liveViewStatus = ""
        lastFrameTime = .distantPast
        liveFrameQueued = false
        state = .disconnected
    }

    // MARK: - Post-connect setup

    private func handleDeviceFound(_ dev: SonyDevice) {
        device = dev
        state = .connected(model: dev.model)
        discovery.stop()
        timeoutTask?.cancel(); timeoutTask = nil

        setupTask?.cancel()
        setupTask = Task { [weak self] in
            guard let self else { return }
            guard let camURL = dev.cameraServiceURL else { return }

            // 1. Probe APIs and version
            await self.probeCapabilities(camURL: camURL)

            // 2. Older bodies require startRecMode before any other method
            if self.availableAPIs.contains("startRecMode") {
                self.log("📷 startRecMode…")
                _ = try? await SonyAPIClient.call(
                    endpoint: camURL, method: "startRecMode", params: [], timeout: 10
                )
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            // 3. Force still-photo shoot mode — prevents errors 1/5/40400
            if self.availableAPIs.isEmpty || self.availableAPIs.contains("setShootMode") {
                _ = try? await SonyAPIClient.call(
                    endpoint: camURL, method: "setShootMode", params: ["still"], timeout: 5
                )
                self.log("📷 setShootMode(still) on connect")
            }

            // 4. Disable self-timer (some bodies 40400 when timer is set)
            if self.availableAPIs.contains("setSelfTimer") {
                _ = try? await SonyAPIClient.call(
                    endpoint: camURL, method: "setSelfTimer", params: [0], timeout: 3
                )
                self.log("📷 setSelfTimer(0) on connect")
            }

            // 5. Ensure postview transfer is on
            if self.availableAPIs.contains("setPostviewImageSize") {
                _ = try? await SonyAPIClient.call(
                    endpoint: camURL, method: "setPostviewImageSize",
                    params: ["Original"], timeout: 3
                )
                self.log("📷 setPostviewImageSize(Original) on connect")
            }

            // 6. Begin polling + live view
            self.startEventPolling()
            await self.startLiveView()
        }
    }

    /// Probe getAvailableApiList and getVersions.
    private func probeCapabilities(camURL: String) async {
        if let result = try? await SonyAPIClient.call(
            endpoint: camURL, method: "getAvailableApiList", params: [], timeout: 5
        ),
           let arr = result["result"] as? [[String]],
           let methods = arr.first {
            availableAPIs = methods
            log("📋 \(methods.count) APIs available")
        }

        // getVersions returns {"result":[["1.0","1.1",…,"1.8"]]}.
        // We hardcode eventVersion to "1.8" because that's the version
        // Imaging Edge Mobile uses on a7R III (confirmed via packet capture)
        // and it's required to receive the takePicture slot for physical
        // shutter shots. Log what the camera advertises so future-us knows
        // if a newer body exposes a higher version.
        if let result = try? await SonyAPIClient.call(
            endpoint: camURL, method: "getVersions", params: [], timeout: 5
        ),
           let arr = result["result"] as? [[String]],
           let versions = arr.first {
            log("📋 getVersions advertises: \(versions.joined(separator: ", "))")
            // Keep eventVersion at 1.8. Don't auto-upgrade higher unless we
            // confirm new slots exist; don't downgrade below 1.8 either.
        }
    }

    // MARK: - Event Polling

    private func startEventPolling() {
        guard let device, let camURL = device.cameraServiceURL else { return }
        isPolling = true
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // First call uses short-poll to establish baseline state quickly.
            // Subsequent calls use long-poll (params:[true]) so the camera
            // blocks on the response until something changes — including
            // the `type:"takePicture"` slot firing on a physical-shutter shot.
            // This matches Imaging Edge Mobile's behavior exactly (confirmed
            // via packet capture).
            var first = true
            while !Task.isCancelled {
                await self?.pollEvent(camURL: camURL, longPoll: !first)
                first = false
                // No fixed sleep — long-poll itself blocks on the server.
                // Tiny pause to avoid tight error loops if the call errors fast.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// getEvent — long-poll (true) blocks server-side until state changes;
    /// short-poll (false) returns the full current state immediately.
    private func pollEvent(camURL: String, longPoll: Bool) async {
        let result: [String: Any]
        do {
            result = try await SonyAPIClient.call(
                endpoint: camURL,
                method: "getEvent",
                params: [longPoll],
                version: eventVersion,
                // Long-poll: camera holds the response up to ~30 s. Short-
                // poll returns ~50 ms. Use 35 s when long-polling.
                timeout: longPoll ? 35 : 5
            )
        } catch {
            return
        }

        guard let results = result["result"] as? [Any] else { return }

        // Camera status, settings + candidates
        for slot in results {
            guard let dict = slot as? [String: Any],
                  let type_ = dict["type"] as? String else { continue }
            switch type_ {
            case "shutterSpeed":
                if let v = stringValue(dict["currentShutterSpeed"]), !v.isEmpty {
                    sonyShutterSpeed = v
                }
                if let arr = dict["shutterSpeedCandidates"] as? [Any] {
                    shutterSpeedCandidates = arr.compactMap(stringValue)
                }
            case "isoSpeedRate":
                if let v = stringValue(dict["currentIsoSpeedRate"]), !v.isEmpty {
                    sonyISO = v.replacingOccurrences(of: "ISO ", with: "")
                }
                if let arr = dict["isoSpeedRateCandidates"] as? [Any] {
                    isoCandidates = arr.compactMap(stringValue)
                }
            case "fNumber":
                if let v = stringValue(dict["currentFNumber"]), !v.isEmpty {
                    sonyAperture = v
                }
                if let arr = dict["fNumberCandidates"] as? [Any] {
                    apertureCandidates = arr.compactMap(stringValue)
                }
            case "exposureCompensation":
                if let v = dict["currentExposureCompensation"] as? Int {
                    sonyEVComp = Float(v) / 3.0
                    evRawValue = v
                } else if let n = dict["currentExposureCompensation"] as? NSNumber {
                    sonyEVComp = n.floatValue / 3.0
                    evRawValue = n.intValue
                }
                if let mx = dict["maxExposureCompensation"] as? Int { evMax = mx }
                if let mn = dict["minExposureCompensation"] as? Int { evMin = mn }
                if let st = dict["stepIndexOfExposureCompensation"] as? Int { evStep = st }
            default: break
            }
        }

        // Scan for photo URLs in photo-related slots.
        //
        // The big one is `type:"takePicture"` (slot index 5 in getEvent v1.8).
        // It fires for EVERY shutter — physical body button OR our own
        // actTakePicture. The URL is in `takePictureUrl[]`. This is the
        // single mechanism Imaging Edge Mobile uses for both flows;
        // packet-confirmed.
        //
        // Older slot types (`shootedImages`, `postViewUrl`, etc.) are kept
        // as fallbacks for compatibility with firmware that exposes them.
        for slot in results {
            // Handle slot-array elements that are themselves arrays of dicts
            // (some firmware nests the takePicture dict inside [])
            if let arr = slot as? [Any] {
                for inner in arr {
                    if let dict = inner as? [String: Any],
                       (dict["type"] as? String) == "takePicture",
                       let urls = dict["takePictureUrl"] as? [String] {
                        // Burst mode: takePictureUrl[] can hold multiple
                        // postview URLs in a single slot. Enqueue every
                        // new one so cont-shooting bursts all land.
                        var enqueuedAny = false
                        for url in urls where isImageURL(url) && isNewPhotoURL(url) {
                            log("📷 takePicture slot URL: \(url.suffix(60))")
                            lastPhotoURL = url
                            enqueueDownload(url: url)
                            enqueuedAny = true
                        }
                        if enqueuedAny { return }
                    }
                }
                continue
            }
            // Direct dict slot (older firmware path)
            if let url = slot as? String, isImageURL(url), isNewPhotoURL(url) {
                log("📷 New photo (direct URL)")
                lastPhotoURL = url
                enqueueDownload(url: url)
                return
            }
            guard let dict = slot as? [String: Any] else { continue }
            let type_ = dict["type"] as? String ?? ""

            // Top-level takePicture slot (shouldn't normally appear here but
            // catch it just in case)
            if type_ == "takePicture",
               let urls = dict["takePictureUrl"] as? [String] {
                var enqueuedAny = false
                for url in urls where isImageURL(url) && isNewPhotoURL(url) {
                    log("📷 takePicture slot URL: \(url.suffix(60))")
                    lastPhotoURL = url
                    enqueueDownload(url: url)
                    enqueuedAny = true
                }
                if enqueuedAny { return }
            }

            let isPhotoSlot = type_ == "shootedImages"
                           || type_ == "postViewUrl"
                           || dict["postViewImageUrl"] != nil
                           || dict["shootedImages"]    != nil
            guard isPhotoSlot else { continue }
            let url: String?
            if let direct = dict["postViewImageUrl"] as? String, isImageURL(direct) {
                url = direct
            } else {
                url = firstImageURL(in: dict as Any)
            }
            if let url, isNewPhotoURL(url) {
                lastPhotoURL = url
                enqueueDownload(url: url)
                return
            }
        }
    }

    /// Best-effort string extraction from JSON values (String / NSNumber / Int / Double).
    private func stringValue(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        if let i = any as? Int      { return String(i) }
        if let d = any as? Double   { return String(d) }
        return nil
    }

    /// Permissive image-URL recognizer — handles Sony's `.JPG?<query>` form.
    private func isImageURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        let pathOnly = lower.split(separator: "?").first.map(String.init) ?? lower
        return pathOnly.hasSuffix(".jpg")
            || pathOnly.hasSuffix(".jpeg")
            || lower.contains(".jpg")
            || lower.contains(".jpeg")
            || lower.contains("postview")
            || lower.contains("postviewimage")
            || lower.contains("/pict")
    }

    /// Recursively walks any JSON value and returns the first JPEG URL.
    private func firstImageURL(in value: Any) -> String? {
        if let str = value as? String, isImageURL(str) { return str }
        if let arr = value as? [Any] {
            for item in arr { if let url = firstImageURL(in: item) { return url } }
        }
        if let dict = value as? [String: Any] {
            for (_, v) in dict { if let url = firstImageURL(in: v) { return url } }
        }
        return nil
    }

    // MARK: - Download + Process

    /// Enqueue a postview URL for serial download. Safe to call from any
    /// event-source path (event poll, direct takePicture response, etc).
    /// Dedupes against the queue + currently-downloading URL.
    private func enqueueDownload(url: String) {
        if pendingDownloads.contains(where: { $0.url == url }) { return }
        // Snapshot the sim at capture time so changing sims mid-queue
        // doesn't retroactively reprocess earlier shots with the wrong look.
        pendingDownloads.append(
            PendingDownload(url: url,
                            sim: selectedSim,
                            custom: activeCustomSim)
        )
        downloadQueueDepth = pendingDownloads.count + activeDownloads
        if downloadDrainTask == nil {
            downloadDrainTask = Task { [weak self] in
                await self?.drainDownloadQueue()
            }
        }
    }

    /// Drain pending postview URLs one at a time. Sets activeDownloads so
    /// the watchdog backs off — a 24MP pull genuinely stalls live view for
    /// a few seconds and that's not a stream death.
    private func drainDownloadQueue() async {
        while !pendingDownloads.isEmpty {
            let item = pendingDownloads.removeFirst()
            activeDownloads += 1
            downloadQueueDepth = pendingDownloads.count + activeDownloads
            // Reset the watchdog clock so the gap caused by the download
            // doesn't trip the 5s threshold the moment the download ends.
            lastFrameTime = Date()
            await downloadAndProcess(url: item.url,
                                     simOverride: item.sim,
                                     customOverride: item.custom)
            activeDownloads -= 1
            downloadQueueDepth = pendingDownloads.count + activeDownloads
            // Nudge the watchdog forward again so it gives the stream a
            // grace period to catch up after the bandwidth crunch.
            lastFrameTime = Date()
        }
        downloadDrainTask = nil
    }

    /// `simOverride` / `customOverride` let the drain queue use the sim
    /// that was active *when the shutter fired*, not whatever's selected
    /// now. Pass `nil` overrides only when called from a context where the
    /// current selection is what you want (none currently).
    private func downloadAndProcess(url: String,
                                    simOverride: FilmSimulation? = nil,
                                    customOverride: CustomSimulation? = nil) async {
        log("⬇️ Downloading: \(url)")
        guard let data = try? await SonyAPIClient.get(urlString: url) else {
            log("❌ Download failed: \(url)")
            return
        }
        log("⬇️ Downloaded \(data.count / 1024) KB")
        guard let ciImage = CIImage(data: data) else {
            log("❌ Not a valid image (\(data.count) bytes)")
            return
        }

        // EXIF orientation: CIImage stores it as NSNumber.
        let orientationVal: Int32 = {
            if let n = ciImage.properties[kCGImagePropertyOrientation as String] as? NSNumber {
                return n.int32Value
            }
            if let i = ciImage.properties[kCGImagePropertyOrientation as String] as? Int {
                return Int32(i)
            }
            return 1
        }()
        let oriented = ciImage.oriented(forExifOrientation: orientationVal)

        // Render on main actor — applySimClosure ultimately calls @MainActor
        // CameraManager code, so off-actor rendering would silently fail.
        // Use the snapshotted sim (capture-time) if provided, falling back
        // to the live selection.
        let simToUse    = simOverride    ?? selectedSim
        let customToUse = customOverride ?? activeCustomSim
        let hasSim = applySimClosure != nil && (simToUse != .none || customToUse != nil)
        let processed = hasSim ? applySimClosure!(oriented, simToUse, customToUse) : oriented
        guard let cg = ciContext.createCGImage(processed, from: processed.extent) else {
            log("❌ Render failed (createCGImage)")
            return
        }
        let output = UIImage(cgImage: cg)
        let thumb = output.preparingThumbnail(of: CGSize(width: 200, height: 200)) ?? output

        processedCount += 1
        lastProcessedThumb = thumb
        log("✅ Photo processed (#\(processedCount))")

        // Save: original Sony JPEG bytes (lossless) when no sim, otherwise
        // re-encode at q=1.0 *with the original EXIF spliced back in* so
        // Photos still shows camera model, lens, aperture/shutter/ISO,
        // capture time, GPS, etc. on sim-rendered shots.
        if autoSave {
            if hasSim {
                let bytes = reencodeJPEGPreservingMetadata(
                    processed: cg, originalJPEG: data, quality: 1.0
                )
                await saveToPhotos(output,
                                   fallbackData: bytes,
                                   label: bytes != nil ? "sim-rendered (EXIF kept)" : "sim-rendered")
            } else {
                await saveToPhotos(output, fallbackData: data, label: "original Sony bytes")
            }
        }

        onPhotoProcessed?(output)
    }

    /// Re-encode a processed CGImage as JPEG, splicing the EXIF / TIFF /
    /// GPS / Maker dictionaries from the original camera JPEG. Returns
    /// nil on any failure so the caller can fall back to plain encoding.
    ///
    /// Why: `UIImage.jpegData(compressionQuality:)` does NOT carry over
    /// metadata. Without this splice, sim-rendered photos land in Photos
    /// with no camera/lens/exposure info, no original capture date, and
    /// no GPS — which makes them harder to organize and breaks "Taken in
    /// this app on this date" search behavior. We pull every property
    /// block from the source JPEG and write them straight back out.
    private func reencodeJPEGPreservingMetadata(processed: CGImage,
                                                originalJPEG: Data,
                                                quality: CGFloat) -> Data? {
        guard let src = CGImageSourceCreateWithData(originalJPEG as CFData, nil),
              let srcProps = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }

        // Merge source metadata with our compression-quality option.
        var props = srcProps
        props[kCGImageDestinationLossyCompressionQuality] = quality
        // Drop the cached orientation — we already applied it to the
        // CIImage via .oriented(forExifOrientation:), so the pixels are
        // upright. Leaving the original orientation tag in would cause
        // Photos to re-rotate and end up sideways.
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }

        let buf = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(
            buf as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dst, processed, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return buf as Data
    }

    /// Save to Photos with maximum quality.
    private func saveToPhotos(_ image: UIImage,
                              fallbackData: Data?,
                              label: String) async {
        log("📸 saveToPhotos start (\(label))")

        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            log("📸 Requesting Photos permission…")
            shutterStatus = "📸 Asking Photos permission…"
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        let authName: String = {
            switch status {
            case .notDetermined: return "notDetermined"
            case .restricted:    return "restricted"
            case .denied:        return "denied"
            case .authorized:    return "authorized"
            case .limited:       return "limited"
            @unknown default:    return "unknown(\(status.rawValue))"
            }
        }()
        log("📸 Photos auth: \(authName)")

        guard status == .authorized || status == .limited else {
            shutterStatus = "⚠️ Photos: \(authName) — enable in Settings"
            log("⚠️ Photos permission denied")
            return
        }

        let dataToSave: Data
        if let raw = fallbackData {
            dataToSave = raw
            log("📸 Saving raw camera JPEG (\(raw.count / 1024) KB)")
        } else if let encoded = image.jpegData(compressionQuality: 1.0) {
            dataToSave = encoded
            log("📸 Encoded JPEG q=1.0 (\(encoded.count / 1024) KB)")
        } else {
            shutterStatus = "❌ JPEG encode failed"
            log("❌ JPEG encode failed")
            return
        }
        let kb = dataToSave.count / 1024
        shutterStatus = "💾 Saving (\(kb) KB)…"

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: dataToSave, options: nil)
            }
            shutterStatus = "✅ Saved (\(kb) KB, \(label))"
            log("💾 Saved to Photos (\(dataToSave.count) bytes, \(label))")
        } catch {
            shutterStatus = "❌ Save failed: \(error.localizedDescription)"
            log("❌ Photos save error: \(error.localizedDescription)")
        }
    }

    // MARK: - Camera State Helpers

    /// Snapshot cameraStatus + shootMode from a single getEvent call.
    private func snapshotCameraState(camURL: String) async -> (status: String, shootMode: String) {
        guard let ev = try? await SonyAPIClient.call(
            endpoint: camURL, method: "getEvent",
            params: [false], version: eventVersion, timeout: 3
        ), let slots = ev["result"] as? [Any] else {
            return ("unknown", "unknown")
        }
        var status = "unknown"
        var shootMode = "unknown"
        for slot in slots {
            guard let dict = slot as? [String: Any], let type_ = dict["type"] as? String
            else { continue }
            if type_ == "cameraStatus", let s = dict["cameraStatus"] as? String { status = s }
            if type_ == "shootMode", let m = dict["currentShootMode"] as? String { shootMode = m }
        }
        log("🩺 cameraStatus=\(status), shootMode=\(shootMode)")
        return (status, shootMode)
    }

    /// Poll until cameraStatus = "IDLE" or timeout. If shootMode is wrong,
    /// force it back to "still" en route. Returns true if IDLE reached.
    @discardableResult
    private func waitForCameraIdle(camURL: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            let snap = await snapshotCameraState(camURL: camURL)
            if snap.shootMode != "still" && snap.shootMode != "unknown" {
                log("🔧 Forcing setShootMode(still) — current was \(snap.shootMode)")
                _ = try? await SonyAPIClient.call(
                    endpoint: camURL, method: "setShootMode",
                    params: ["still"], timeout: 5
                )
                try? await Task.sleep(nanoseconds: 800_000_000)
                continue
            }
            if snap.status == "IDLE" {
                log("✓ cameraStatus = IDLE")
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("⚠️ cameraStatus never reached IDLE within \(Int(timeout))s — proceeding anyway")
        return false
    }

    // MARK: - Camera Setting Setters (tap-to-adjust)

    func setShutterSpeed(_ value: String) {
        guard let camURL = device?.cameraServiceURL else { return }
        Task { [weak self] in
            do {
                _ = try await SonyAPIClient.call(
                    endpoint: camURL, method: "setShutterSpeed",
                    params: [value], timeout: 5
                )
                await MainActor.run { [weak self] in
                    self?.sonyShutterSpeed = value
                    self?.log("✓ setShutterSpeed(\(value))")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.log("❌ setShutterSpeed: \(error.localizedDescription)")
                }
            }
        }
    }

    func setIso(_ value: String) {
        guard let camURL = device?.cameraServiceURL else { return }
        Task { [weak self] in
            do {
                _ = try await SonyAPIClient.call(
                    endpoint: camURL, method: "setIsoSpeedRate",
                    params: [value], timeout: 5
                )
                await MainActor.run { [weak self] in
                    self?.sonyISO = value.replacingOccurrences(of: "ISO ", with: "")
                    self?.log("✓ setIsoSpeedRate(\(value))")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.log("❌ setIsoSpeedRate: \(error.localizedDescription)")
                }
            }
        }
    }

    func setAperture(_ value: String) {
        guard let camURL = device?.cameraServiceURL else { return }
        Task { [weak self] in
            do {
                _ = try await SonyAPIClient.call(
                    endpoint: camURL, method: "setFNumber",
                    params: [value], timeout: 5
                )
                await MainActor.run { [weak self] in
                    self?.sonyAperture = value
                    self?.log("✓ setFNumber(\(value))")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.log("❌ setFNumber: \(error.localizedDescription)")
                }
            }
        }
    }

    func setExposureComp(_ rawSteps: Int) {
        guard let camURL = device?.cameraServiceURL else { return }
        Task { [weak self] in
            do {
                _ = try await SonyAPIClient.call(
                    endpoint: camURL, method: "setExposureCompensation",
                    params: [rawSteps], timeout: 5
                )
                await MainActor.run { [weak self] in
                    self?.evRawValue = rawSteps
                    self?.sonyEVComp = Float(rawSteps) / 3.0
                    self?.log("✓ setExposureCompensation(\(rawSteps))")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.log("❌ setExposureCompensation: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Shutter Trigger

    func triggerShutter() {
        if isShooting {
            log("⚠️ Shutter already busy — ignoring tap")
            return
        }
        guard let camURL = device?.cameraServiceURL else {
            shutterStatus = "❌ No camera URL"
            log("❌ triggerShutter: no camera service URL")
            return
        }

        isShooting = true
        shutterStatus = "Shooting…"
        shutterTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isShooting = false }

            // ── Take the picture, with multi-attempt recovery ─────────────
            // FAST PATH: first attempt fires actTakePicture immediately.
            // Sony bodies return 1/5/40400 when:
            //   • Camera still initializing right after connect
            //   • Wrong shoot mode (movie/intervalstill)
            //   • Lingering half-press / AF in progress
            //   • cameraStatus != IDLE
            //   • Camera menu open or playback mode active
            var shotResult: [String: Any]? = nil
            var lastError: String = ""
            let maxAttempts = 4
            var stoppedLiveviewDuringRecovery = false

            for attempt in 1...maxAttempts {
                if Task.isCancelled { return }
                do {
                    shotResult = try await SonyAPIClient.call(
                        endpoint: camURL, method: "actTakePicture",
                        params: [], timeout: 20
                    )
                    break
                } catch SonyAPIError.apiError(let code, let msg)
                        where code == 1 || code == 5 || code == 40400 {
                    lastError = "API error \(code): \(msg)"
                    self.log("⚠️ \(lastError) — attempt \(attempt)/\(maxAttempts)")
                    self.shutterStatus = "⚠️ Not ready (\(attempt)/\(maxAttempts))…"

                    if attempt == maxAttempts {
                        let final = await self.snapshotCameraState(camURL: camURL)
                        self.shutterStatus = "❌ \(lastError) — status:\(final.status) mode:\(final.shootMode)"
                        self.log("❌ Gave up after \(maxAttempts) attempts. Final state: cameraStatus=\(final.status) shootMode=\(final.shootMode)")
                        self.log("   Fix on camera: dial to P/A/S/M, close menu, exit playback")
                        // Restart live view if we stopped it during recovery
                        if stoppedLiveviewDuringRecovery {
                            await self.startLiveView()
                        }
                        return
                    }
                    // Recovery sequence
                    _ = try? await SonyAPIClient.call(
                        endpoint: camURL, method: "cancelHalfPressShutter",
                        params: [], timeout: 3
                    )
                    _ = try? await SonyAPIClient.call(
                        endpoint: camURL, method: "setShootMode",
                        params: ["still"], timeout: 5
                    )
                    if attempt == 2 {
                        self.log("🛠 Half-press to engage AF")
                        _ = try? await SonyAPIClient.call(
                            endpoint: camURL, method: "actHalfPressShutter",
                            params: [], timeout: 5
                        )
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                    }
                    if attempt >= 3 {
                        self.log("🛠 Stopping liveview before retry (some bodies require this)")
                        _ = try? await SonyAPIClient.call(
                            endpoint: camURL, method: "stopLiveview",
                            params: [], timeout: 5
                        )
                        self.liveViewTask?.cancel()
                        stoppedLiveviewDuringRecovery = true
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                    }
                    await self.waitForCameraIdle(camURL: camURL, timeout: 5)
                } catch {
                    self.shutterStatus = "❌ \(error.localizedDescription)"
                    self.log("❌ actTakePicture: \(error.localizedDescription)")
                    if stoppedLiveviewDuringRecovery {
                        await self.startLiveView()
                    }
                    return
                }
            }
            guard let result = shotResult else { return }

            // Restart live view if recovery stopped it. Awaiting inline
            // (no untracked Task) so cancellation propagates correctly.
            if stoppedLiveviewDuringRecovery {
                await self.startLiveView()
            }

            // ── Step 2: inline photo URL ───────────────────────────────────
            // CRITICAL: result["result"] is Any? — must use `if let` to unwrap.
            // Writing `as Any` boxes the Optional itself and every cast fails.
            self.log("🔍 actTakePicture result: \(result)")
            if let resultValue = result["result"],
               let photoURL = self.firstImageURL(in: resultValue),
               photoURL != self.lastPhotoURL {
                self.log("📸 Inline photo URL: \(photoURL)")
                self.shutterStatus = "⬇️ Downloading…"
                self.lastPhotoURL = photoURL
                self.enqueueDownload(url: photoURL)
                // Final status set by saveToPhotos
                return
            }

            // ── Step 3: poll getEvent for up to 30 s ──────────────────────
            self.shutterStatus = "⏳ Waiting for photo URL…"
            self.log("⚠️ No inline URL from actTakePicture — polling getEvent (up to 30 s)")
            for attempt in 1...30 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                guard let ev = try? await SonyAPIClient.call(
                    endpoint: camURL, method: "getEvent",
                    params: [false], version: self.eventVersion
                ), let slots = ev["result"] as? [Any] else { continue }

                for slot in slots {
                    guard let dict = slot as? [String: Any] else { continue }
                    let type_ = dict["type"] as? String ?? ""
                    let isPhoto = type_ == "shootedImages" || type_ == "postViewUrl"
                               || dict["postViewImageUrl"] != nil
                               || dict["shootedImages"]    != nil
                    guard isPhoto else { continue }
                    self.log("📡 Poll \(attempt): slot type=\"\(type_)\"")
                    if let url = self.firstImageURL(in: dict as Any),
                       url != self.lastPhotoURL {
                        self.log("📸 Photo URL (event poll): \(url)")
                        self.shutterStatus = "⬇️ Downloading…"
                        self.lastPhotoURL = url
                        self.enqueueDownload(url: url)
                        return
                    }
                }
                self.shutterStatus = "⏳ Waiting (\(attempt)/30)…"
            }
            self.shutterStatus = "❌ Photo URL not found after 30 s"
            self.log("❌ Gave up waiting for photo URL")
        }
    }

    // MARK: - Live View

    private func startLiveView() async {
        guard let camURL = device?.cameraServiceURL else {
            liveViewStatus = "❌ No camera service URL"
            return
        }

        // Pick the right startLiveview variant. startLiveviewWithSize("L")
        // gives a higher-resolution stream (~1024×680 vs. default ~640×424)
        // for noticeably better quality. Some bodies only support the plain
        // version; we detect that via availableAPIs and fall back.
        let supportsSized = availableAPIs.contains("startLiveviewWithSize")
        let method = supportsSized ? "startLiveviewWithSize" : "startLiveview"
        let params: [Any] = supportsSized ? ["L"] : []
        if supportsSized {
            log("📹 Using startLiveviewWithSize(\"L\") for higher quality stream")
        }

        liveViewStatus = "Waiting for camera ready…"
        for attempt in 1...15 {
            if Task.isCancelled { return }
            log("📹 \(method) attempt \(attempt)/15…")
            do {
                let result = try await SonyAPIClient.call(
                    endpoint: camURL, method: method, params: params
                )
                var liveURL: String? = nil
                if let arr = result["result"] as? [Any] {
                    if let str = arr.first as? String { liveURL = str }
                    else if let inner = arr.first as? [Any], let str = inner.first as? String { liveURL = str }
                }
                guard let urlStr = liveURL, let url = URL(string: urlStr) else {
                    log("❌ startLiveview: no URL in result: \(result)")
                    liveViewStatus = "❌ No stream URL"
                    return
                }
                liveViewStatus = "Connecting to stream…"
                log("📹 Stream URL: \(urlStr)")
                lastFrameTime = .distantPast
                liveFrameQueued = false
                liveViewTask?.cancel()
                liveViewTask = Task { [weak self] in
                    await self?.parseLiveViewStream(from: url)
                }
                startLiveViewWatchdog()
                startLiveViewHeartbeat(camURL: camURL, method: method, params: params)
                return

            } catch SonyAPIError.apiError(1, _) {
                liveViewStatus = "Camera warming up… (\(attempt)/15)"
                try? await Task.sleep(nanoseconds: 2_000_000_000)

            } catch {
                log("❌ startLiveview: \(error.localizedDescription)")
                liveViewStatus = "❌ \(error.localizedDescription)"
                return
            }
        }
        liveViewStatus = "❌ Camera not ready after 30 s — check mode on camera"
    }

    /// Periodically re-call startLiveview as a keep-alive ping.  Imaging Edge
    /// Mobile does this every ~1.7 s during streaming (confirmed via packet
    /// capture: 21 calls in a 35 s session). The camera returns the same
    /// stream URL each time; we ignore the response — the call itself
    /// appears to be what the camera's firmware uses to confirm the client
    /// is still healthy. Without it, some bodies may drop the stream after
    /// a few seconds of presumed idleness.
    private func startLiveViewHeartbeat(camURL: String, method: String, params: [Any]) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_700_000_000)
                guard !Task.isCancelled else { break }
                _ = try? await SonyAPIClient.call(
                    endpoint: camURL, method: method, params: params, timeout: 3
                )
                // Don't log every ping — would flood the diagnostic log.
                // If the call errors, we just retry on the next tick;
                // the watchdog handles real stream death.
                _ = self    // capture-keep
            }
        }
    }

    /// Stream watchdog. Two failure conditions both trigger a restart:
    ///   (a) frames were flowing but stopped for ≥5 s
    ///   (b) we just tried a restart but no frame has arrived after ≥8 s
    /// (b) is critical: without it, a failed startLiveView leaves
    /// lastFrameTime at .distantPast and the watchdog skips forever
    /// because there's no "elapsed since last frame" to measure.
    ///
    /// After 4 consecutive failed local restarts (~30 s of trying), escalate
    /// to a full session reset — re-runs SSDP discovery in case the camera
    /// pulled a new DHCP lease or fully reset its WiFi side.
    private func startLiveViewWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            var reconnectAttempt = 0
            var lastRestartAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                // A 24MP postview download saturates the camera's WiFi for
                // several seconds — live-view frames legitimately pause
                // during it. Don't count that gap against the stream.
                if self.activeDownloads > 0 { continue }

                let now = Date()
                let gotFramesEver = self.lastFrameTime != .distantPast
                let frameGap = gotFramesEver
                    ? now.timeIntervalSince(self.lastFrameTime)
                    : .infinity
                let timeSinceRestart = now.timeIntervalSince(lastRestartAt)

                // Reset failure counter if frames are flowing fine again.
                if gotFramesEver && frameGap < 1.5 && reconnectAttempt > 0 {
                    self.log("🐶 Watchdog: stream recovered after \(reconnectAttempt) attempts")
                    reconnectAttempt = 0
                }

                // Decide whether to restart:
                //  • frame gap exceeded threshold, OR
                //  • we restarted but no frames came back within 8 s
                let needRestart =
                    (gotFramesEver && frameGap > 5) ||
                    (!gotFramesEver && reconnectAttempt > 0 && timeSinceRestart > 8) ||
                    (!gotFramesEver && reconnectAttempt == 0 && timeSinceRestart > 15)

                if !needRestart { continue }

                reconnectAttempt += 1
                if gotFramesEver {
                    self.log("🐶 Watchdog: no frame in \(Int(frameGap)) s — restart attempt \(reconnectAttempt)")
                } else {
                    self.log("🐶 Watchdog: restart \(reconnectAttempt-1) produced no frames in \(Int(timeSinceRestart)) s — retry")
                }

                // Escalate to full session reset after enough local failures.
                if reconnectAttempt >= 4 {
                    self.log("🐶 Watchdog: \(reconnectAttempt) failed restarts — full session reset")
                    self.liveViewStatus = "Re-establishing camera session…"
                    await self.hardResetSession()
                    return
                }

                self.liveViewTask?.cancel()
                self.heartbeatTask?.cancel()
                self.liveViewImage = nil
                self.liveViewStatus = reconnectAttempt == 1
                    ? "Reconnecting stream…"
                    : "Reconnecting stream… (\(reconnectAttempt))"
                self.lastFrameTime = .distantPast
                lastRestartAt = Date()
                await self.startLiveView()
                // If startLiveView succeeded it spawned a fresh watchdog
                // (cancelling us); the cancellation check exits us cleanly.
                if Task.isCancelled { return }
                // Small back-off so we don't hammer a sleeping body.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Last-resort recovery: nuke the live-view session, drop the cached
    /// device, and re-run SSDP discovery. The camera may have pulled a new
    /// DHCP lease while its WiFi was asleep, or reset its HTTP service —
    /// either way, a fresh discovery + setup is the only thing that gets
    /// us back. Stays in `.connected` long enough to flip to `.searching`
    /// so the UI shows "Searching…" instead of the disconnected screen
    /// (less jarring mid-shoot).
    private func hardResetSession() async {
        // Cancel everything live-view related, but keep the diagnostic log
        // and manual IP intact.
        liveViewTask?.cancel();      liveViewTask = nil
        heartbeatTask?.cancel();     heartbeatTask = nil
        pollTask?.cancel();          pollTask = nil
        setupTask?.cancel();         setupTask = nil
        // NOT cancelling watchdogTask — that's us; we exit on return.
        liveViewImage = nil
        lastFrameTime = .distantPast
        liveFrameQueued = false
        isPolling = false

        // Try a polite stopLiveview first so the body releases its side
        // of the stream; ignore failure, the body might already be gone.
        if let camURL = device?.cameraServiceURL {
            _ = try? await SonyAPIClient.call(
                endpoint: camURL, method: "stopLiveview",
                params: [], version: eventVersion, timeout: 3
            )
        }

        device = nil
        state = .searching
        liveViewStatus = "Searching for camera…"
        log("🔄 hardResetSession: re-running discovery")

        discovery.stop()
        discovery.manualBaseURL = manualIP.isEmpty ? nil : manualIP
        // Re-bind handlers defensively in case SonyDiscovery cleared them.
        discovery.onLog = { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.diagnosticLog.append(LogEntry(text: msg))
            }
        }
        discovery.onDeviceFound = { [weak self] dev in
            Task { @MainActor [weak self] in self?.handleDeviceFound(dev) }
        }
        discovery.start()

        // Re-arm the 60 s search timeout so we don't search forever.
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if case .searching = self.state {
                self.state = .error("Lost camera and couldn't reconnect.\n\n• Check WiFi is still associated with the camera\n• Re-tap 'Connect' on the camera (Menu → Network → Ctrl w/ Smartphone)\n• Then tap Reconnect here")
                self.discovery.stop()
            }
        }
    }

    /// Sony live-view binary frame format (Camera Remote API spec v2.40):
    ///
    ///   Common header  [8 bytes]
    ///     buf[0]      = 0xFF
    ///     buf[1]      = payload type (0x01 = JPEG, 0x02 = frame info)
    ///   Payload header [128 bytes]
    ///     buf[8..11]  = start code 0x24356879
    ///     buf[12..14] = payload size (3 bytes big-endian)
    ///     buf[15]     = padding size
    ///   Payload data  [payloadSize bytes of JPEG]
    ///   Padding data  [paddingSize bytes]
    private func parseLiveViewStream(from url: URL) async {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        guard let (byteStream, _) = try? await streamSession.bytes(for: request) else {
            liveViewStatus = "❌ Stream connection failed"
            log("❌ Stream: could not open \(url)")
            return
        }

        liveViewStatus = "Streaming…"
        log("📡 Stream open at \(url)")

        let ctx = self.ciContext
        let snapshot = self.liveSimSnapshot

        // Detached so the byte-loop runs OFF the main actor. A regular
        // `Task { … }` inside this @MainActor method would inherit MainActor
        // isolation and pin the byte loop onto main, which made the live
        // view feel laggy because every byte iteration starved the UI.
        //
        // We re-attach cancellation via withTaskCancellationHandler so when
        // the surrounding liveViewTask is cancelled (on disconnect or
        // watchdog restart), the detached parser also gets cancelled.
        let parserTask = Task.detached(priority: .userInitiated) { [weak self] in
            var buf = [UInt8]()
            buf.reserveCapacity(1_048_576)
            var pendingType: UInt8 = 0
            var pendingSize: Int   = 0
            var paddingSize: Int   = 0
            var hasHeader          = false
            var frameCount         = 0
            var loggedFirstBytes   = false

            do {
                for try await byte in byteStream {
                    if Task.isCancelled { break }
                    buf.append(byte)

                    if !hasHeader {
                        guard buf.count >= 136 else { continue }

                        if !loggedFirstBytes {
                            loggedFirstBytes = true
                            let hex = buf.prefix(20)
                                        .map { String(format: "%02X", $0) }
                                        .joined(separator: " ")
                            Task { @MainActor [weak self] in
                                self?.log("📡 Stream bytes[0..19]: \(hex)")
                            }
                        }

                        // Resync: jump to next 0xFF instead of byte-by-byte slide
                        if buf[0] != 0xFF {
                            if let idx = buf.firstIndex(of: 0xFF), idx > 0 {
                                buf.removeFirst(idx)
                            } else if buf.first != 0xFF {
                                buf.removeAll(keepingCapacity: true)
                            }
                            continue
                        }

                        guard buf[8]  == 0x24, buf[9]  == 0x35,
                              buf[10] == 0x68, buf[11] == 0x79 else {
                            buf.removeFirst()
                            continue
                        }

                        let pType = buf[1]
                        let pSize = (Int(buf[12]) << 16) | (Int(buf[13]) << 8) | Int(buf[14])
                        let padSz = Int(buf[15])

                        guard pSize > 0, pSize < 4_000_000 else {
                            buf.removeFirst()
                            continue
                        }

                        pendingType = pType
                        pendingSize = pSize
                        paddingSize = padSz
                        hasHeader   = true
                    }

                    guard buf.count >= 136 + pendingSize + paddingSize else { continue }

                    if pendingType == 0x01 {
                        // Read sim state once — used for both throttle
                        // decision and rendering.
                        let closure = snapshot.applyClosure
                        let sim = snapshot.sim
                        let custom = snapshot.custom
                        let hasSim = closure != nil && (sim != .none || custom != nil)

                        // BACKPRESSURE: drop if main is still showing the
                        // previous frame.
                        if let strong = self, strong.liveFrameQueued {
                            buf.removeSubrange(0 ..< (136 + pendingSize + paddingSize))
                            hasHeader = false
                            continue
                        }
                        // TIME THROTTLE: only when a sim is active. Without
                        // a sim, decode + createCGImage are fast enough to
                        // sustain the camera's native ~15 fps. With a sim,
                        // the CIFilter chain adds 30-50 ms per frame, so we
                        // cap to ~14 fps (70 ms) for headroom.
                        if hasSim {
                            let now = CACurrentMediaTime()
                            if now - (self?.lastRenderStart ?? 0) < 0.070 {
                                buf.removeSubrange(0 ..< (136 + pendingSize + paddingSize))
                                hasHeader = false
                                continue
                            }
                            self?.lastRenderStart = now
                        }

                        let jpeg = Data(buf[136 ..< (136 + pendingSize)])

                        if let ciImage = CIImage(data: jpeg) {
                            // DO NOT apply EXIF for live view — Sony streams
                            // a fixed-size landscape JPEG; EXIF reflects camera
                            // tilt and reshapes the displayed frame.
                            let oriented = ciImage
                            let simmed: CIImage
                            if let fn = closure, sim != .none || custom != nil {
                                simmed = fn(oriented, sim, custom)
                            } else {
                                simmed = oriented
                            }
                            // Lift exposure for display only — Sony's live-view
                            // stream is encoded ~half a stop dark vs the actual
                            // metered exposure. Applied AFTER the sim filter
                            // so the sim sees an unmodified input; only the
                            // user's preview is brightened.  Saved photos
                            // (which come from `actTakePicture`'s postview
                            // URL, a separate code path) are unaffected.
                            let out: CIImage = {
                                guard let f = CIFilter(name: "CIExposureAdjust") else { return simmed }
                                f.setValue(simmed, forKey: kCIInputImageKey)
                                f.setValue(0.7, forKey: "inputEV")  // +0.7 stops
                                return f.outputImage ?? simmed
                            }()
                            // Already throttled above; just render + hand to main.
                            if let cg = ctx.createCGImage(out, from: out.extent) {
                                let uiImg = UIImage(cgImage: cg)
                                let isFirst = frameCount == 0
                                self?.liveFrameQueued = true
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    self.liveViewImage = uiImg
                                    self.lastFrameTime = Date()
                                    if isFirst {
                                        self.liveViewStatus = "Live"
                                        self.log("🎬 First live view frame!")
                                    }
                                    self.liveFrameQueued = false
                                }
                                frameCount += 1
                            }
                        }
                    }

                    buf.removeSubrange(0 ..< (136 + pendingSize + paddingSize))
                    hasHeader = false
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.liveViewStatus = "❌ Stream error: \(error.localizedDescription)"
                    self?.log("❌ Stream: \(error)")
                }
            }
        }
        // Bridge cancellation: if the outer liveViewTask is cancelled,
        // forward it to the detached parser. This is what makes disconnect
        // and watchdog-restart actually stop the byte loop cleanly.
        await withTaskCancellationHandler {
            await parserTask.value
        } onCancel: {
            parserTask.cancel()
        }
    }
}
