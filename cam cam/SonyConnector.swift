//
//  SonyConnector.swift
//  cam cam
//
//  Sony Camera Remote API (REST/JSON over WiFi) connector.
//  Connects to a Sony a7R III (or any Sony camera supporting the API),
//  monitors for new photos, downloads them, and applies a chosen film
//  simulation via the same CIFilter pipeline used for the phone camera.
//

import Foundation
import UIKit
import Photos
import Combine
import Darwin   // getifaddrs, inet_ntop
import Network  // NWListener for UPnP NOTIFY HTTP server

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

    /// Read the iPhone's current WiFi IPv4 address and return the /24 gateway
    /// prefix (e.g. "192.168.122") so we can try .1 first. Probes en0 first,
    /// then a few common alternates (bridge, USB-Ethernet) for iPad edge cases.
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

    private func log(_ msg: String) {
        onLog?(msg)
    }
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

    /// Returns (device, errorDescription). One will be non-nil.
    static func probeWithError(baseURL: String) async -> (SonyDevice?, String?) {
        let url = "\(baseURL)/sony/camera"
        var lastError: String = "no response"

        // Try getApplicationInfo first — it returns the real model name.
        // If that fails, fall back to getVersions / getAvailableApiList just to
        // confirm reachability and use a generic label.
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
    /// `getApplicationInfo` → `result: [appName, version]` (flat).
    private static func extractModel(from result: [String: Any], method: String) -> String {
        if method == "getApplicationInfo" {
            if let arr = result["result"] as? [Any],
               let name = arr.first as? String, !name.isEmpty {
                return name
            }
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
        case .invalidURL:            return "Invalid URL"
        case .networkError(let e):   return "Network error: \(e.localizedDescription)"
        case .badResponse:           return "Bad response from camera"
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
        // Code may bridge as Int or NSNumber depending on JSONSerialization mood.
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

// MARK: - Bonjour publish-result logger

/// Tiny NetServiceDelegate that forwards publish status to a log closure.
final class BonjourLogger: NSObject, NetServiceDelegate {
    private let logFn: (String) -> Void
    init(log: @escaping (String) -> Void) { self.logFn = log }
    func netServiceDidPublish(_ sender: NetService) {
        logFn("✅ Bonjour up: \(sender.name) (\(sender.type)) :\(sender.port)")
    }
    func netService(_ sender: NetService,
                    didNotPublish errorDict: [String : NSNumber]) {
        logFn("⚠️ Bonjour FAILED: \(sender.name) (\(sender.type)) — \(errorDict)")
    }
}

// MARK: - Live View Snapshot
//
// Holds the current film-sim selection in a reference type the live-view
// parser can read off-actor without a per-frame MainActor.run hop.
// Writes happen on the main actor (via didSet on SonyConnector properties);
// reads happen on the detached parser task.  Stale reads are acceptable
// (worst case: one frame uses the previous sim setting).

final class SonyLiveSimSnapshot: @unchecked Sendable {
    // nonisolated(unsafe): we intentionally accept stale reads across actors.
    // Reference-type writes are atomic in Swift's ARC; a stale value means
    // one frame renders with the previous sim setting, which is fine.
    nonisolated(unsafe) var sim: FilmSimulation = .none
    nonisolated(unsafe) var custom: CustomSimulation? = nil
    nonisolated(unsafe) var applyClosure: ((CIImage, FilmSimulation, CustomSimulation?) -> CIImage)? = nil
}

// MARK: - Sony Connector (main state machine)

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

    /// Called with the processed UIImage — caller saves to Photos.
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
    private var avContentTask:  Task<Void, Never>?

    /// Discovered storage source URI (e.g. "storage:memoryCard1") — set by
    /// avContent discovery (only works while in Contents Transfer mode).
    private var avContentSourceURI: String?
    /// The most recent photo URL we've seen on the camera's SD card.
    /// Used to detect new files written by physical-shutter presses.
    private var lastAvContentURL: String?
    /// Last reported number-of-recordable-images value from storageInformation.
    /// When this drops, a new shot has been written to the card.
    private var lastRecordableImages: Int? = nil
    /// Last reported cameraStatus — used to detect the StillCapturing/Saving
    /// → IDLE transition that marks a completed shot (the strongest signal
    /// we get for physical-shutter shots in Smart Remote Control mode).
    private var lastCameraStatus: String = "unknown"
    /// Set to non-nil while a Contents-Transfer mode-switch sync is in flight.
    /// Used to debounce multiple rapid physical-shutter presses.
    private var modeSwitchTask: Task<Void, Never>?
    /// Background task that periodically forces a sync as a safety net for
    /// physical shutter shots the cameraStatus heuristic might miss.
    private var bgFetchTask: Task<Void, Never>?
    /// User toggle for periodic background sync. Default true.
    var autoBackgroundFetch: Bool = true

    /// Set true while a shot is in flight — guards against double-taps.
    private var isShooting: Bool = false

    /// HTTP listener for UPnP NOTIFY callbacks. Camera sends NOTIFY POSTs to
    /// this listener whenever a subscribed service's state changes — including
    /// new media being added. This is the standard UPnP event delivery
    /// mechanism that we were faking with a dummy callback before.
    private var notifyListener: NWListener?
    private var notifyListenPort: UInt16 = 0
    /// Subscription IDs (SID) returned by SUBSCRIBE responses, keyed by service.
    /// Needed for unsubscribe and renew (not strictly required for short tests).
    private var subscriptionSIDs: [String: String] = [:]
    /// Bonjour / mDNS advertisements for our HTTP listener. Sony's camera may
    /// require seeing a specific service type before it pushes photos.
    /// We publish under several candidate types since the exact one IEM uses
    /// is undocumented.
    private var bonjourServices: [NetService] = []

    /// One-shot flag — we log the slot types from the first non-empty
    /// getEvent response so we can verify our type matching is correct.
    private var loggedSlotTypesOnce: Bool = false
    /// Set of slot type names we've already logged. New types get logged once
    /// so we can spot anything we should be handling but aren't.
    private var seenSlotTypes: Set<String> = []

    /// Set true the instant a new live-view frame is handed off to the main
    /// actor for display; cleared when the main actor finishes assigning it.
    /// Acts as a single-slot mailbox so we never queue frames — if main is
    /// busy, the next frame from the parser is dropped (you always see the
    /// latest, never a backlog). nonisolated(unsafe) because the parser
    /// reads/writes this from a detached Task; minor races just mean an
    /// extra frame is dropped, which is fine.
    nonisolated(unsafe) private var liveFrameQueued: Bool = false

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Inject the film-sim apply function from CameraManager.
    /// Setter also mirrors into the lock-free live-view snapshot.
    var applySimClosure: ((CIImage, FilmSimulation, CustomSimulation?) -> CIImage)? {
        didSet { liveSimSnapshot.applyClosure = applySimClosure }
    }

    /// Live diagnostic log lines shown in the UI during search.
    /// Each entry has a stable id so SwiftUI ForEach doesn't dedupe duplicates.
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

    // Available values reported by the camera — used to populate the picker
    // when the user taps an info cell to adjust a setting.
    var shutterSpeedCandidates: [String] = []
    var isoCandidates: [String] = []
    var apertureCandidates: [String] = []
    /// EV is an integer in 1/3 stop steps; min/max bracket the slider.
    var evMin: Int = -9
    var evMax: Int = 9
    var evStep: Int = 1  // 1 = 1/3 EV, 2 = 1/2 EV
    var evRawValue: Int = 0  // current camera value in 1/3 stop steps

    /// Optional manual IP override.
    var manualIP: String = ""

    /// Live view frame — updated at ~15 fps while connected.
    var liveViewImage: UIImage? = nil

    /// Human-readable status for the live view stream.
    var liveViewStatus: String = ""

    /// APIs reported by getAvailableApiList — used for capability gating.
    var availableAPIs: [String] = []

    /// getEvent version. Default 1.3 (what every modern Sony body supports —
    /// older firmware that only supports 1.0/1.1 still accepts 1.3 requests
    /// gracefully). probeCapabilities may upgrade to 1.4 if available, but
    /// never downgrades below 1.3.
    private var eventVersion: String = "1.3"

    /// Lock-free snapshot of sim settings used by the live-view parser.
    private let liveSimSnapshot = SonyLiveSimSnapshot()

    /// Wall-clock time of the most recent live-view frame.
    /// Read by the watchdog to detect frozen streams.
    private var lastFrameTime: Date = .distantPast

    /// URLSession configured for streaming.
    /// `timeoutIntervalForRequest` is the *inter-byte* timeout — 30 s means
    /// a stalled WiFi link is detected within 30 s instead of 60 minutes.
    private let streamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    private func log(_ msg: String) {
        diagnosticLog.append(LogEntry(text: msg))
        // Cap log growth — keep the most recent 500 lines
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

        // Tracked timeout — cancelled on successful connect or manual disconnect
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
        avContentTask?.cancel(); avContentTask = nil
        modeSwitchTask?.cancel(); modeSwitchTask = nil
        contentDirPollTask?.cancel(); contentDirPollTask = nil
        notifyListener?.cancel(); notifyListener = nil
        notifyListenPort = 0
        subscriptionSIDs.removeAll()
        stopBonjourAdvertising()
        pushRootInitialized = false
        pushServices.removeAll()
        xPushListUsable = true
        xPushFailureStreak = 0
        avContentSourceURI = nil
        lastAvContentURL = nil
        lastRecordableImages = nil
        lastCameraStatus = "unknown"
        loggedSlotTypesOnce = false
        seenSlotTypes.removeAll()
        bgFetchTask?.cancel(); bgFetchTask = nil
        discovery.stop()
        device = nil
        isPolling = false
        isShooting = false
        liveViewImage = nil
        liveViewStatus = ""
        lastFrameTime = .distantPast
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

            // 1. Probe APIs and version so we know what's safe to call
            await self.probeCapabilities(camURL: camURL)

            // 2. Older bodies require startRecMode before any other camera method
            if self.availableAPIs.contains("startRecMode") {
                self.log("📷 startRecMode…")
                _ = try? await SonyAPIClient.call(
                    endpoint: camURL, method: "startRecMode", params: [], timeout: 10
                )
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            // 3. Force still-photo shoot mode — prevents errors 1 / 5 / 40400
            if self.availableAPIs.isEmpty || self.availableAPIs.contains("setShootMode") {
                _ = try? await SonyAPIClient.call(
                    endpoint: camURL, method: "setShootMode", params: ["still"], timeout: 5
                )
                self.log("📷 setShootMode(still) on connect")
            }
            // 3a. Disable self-timer — some bodies return 40400 if timer is set,
            //    because they treat each tap as "queue the timer" and the API
            //    sees the camera as "busy waiting for timer".
            if self.availableAPIs.contains("setSelfTimer") {
                _ = try? await SonyAPIClient.call(
                    endpoint: camURL, method: "setSelfTimer", params: [0], timeout: 3
                )
                self.log("📷 setSelfTimer(0) on connect")
            }
            // 3b. Make sure post-view (the JPEG transferred to phone) is enabled.
            //    Without this, actTakePicture may succeed at the camera but not
            //    return a URL for us to download.
            if self.availableAPIs.contains("setPostviewImageSize") {
                _ = try? await SonyAPIClient.call(
                    endpoint: camURL, method: "setPostviewImageSize",
                    params: ["Original"], timeout: 3
                )
                self.log("📷 setPostviewImageSize(Original) on connect")
            }

            // 4. Begin polling and live view.
            self.startEventPolling()

            // 5. Start the local HTTP NOTIFY listener BEFORE we subscribe.
            //    Sony cameras verify the callback URL during SUBSCRIBE — if
            //    our listener isn't reachable, the subscription is rejected.
            self.startNotifyListener()
            // Give the listener a beat to come up
            try? await Task.sleep(nanoseconds: 300_000_000)
            // 5a. Advertise ourselves via Bonjour / mDNS on several candidate
            //     service types. The camera may only push to clients it can
            //     discover via mDNS lookup.
            self.startBonjourAdvertising()

            // 6. Probe for the "Send to Smartphone" SOAP push service
            //    (DLNA/UPnP on port 64321) and discover its services.
            await self.probePushService(baseHost: dev.baseURL)
            // 6b. Probe the photo server (port 60152) and other plausible
            //     paths to see if anything's exposed besides the postview
            //     URLs.  Some Sony bodies have undocumented index endpoints.
            await self.probeAuxiliaryEndpoints(baseHost: dev.baseURL)

            // 7. If push service is available, run diagnostic probe + start
            //    the SOAP drain task + subscribe to UPnP events.
            if !self.pushServices.isEmpty {
                // Probe every safe action on every service — if even one
                // returns 200 we know the SOAP stack is alive.
                await self.probeAllSafeActions()
                self.startContentDirectoryPolling()
                for svc in self.pushServices {
                    await self.subscribeToEvents(service: svc)
                }
            }

            await self.startLiveView()
        }
    }

    // MARK: - Sony Push Service (DLNA/UPnP over port 64321)
    //
    // Reverse-engineered by ImagingEdge4Linux. Sony cameras expose themselves
    // as a DLNA MediaServer:1 device on port 64321 with Sony-specific X_ SOAP
    // actions in the "av" namespace. This service is what Imaging Edge uses
    // to receive photos pushed from the camera (including physical-shutter
    // shots in Send to Smartphone mode — but it's also reachable during
    // Ctrl w/ Smartphone mode!).
    //
    // Architecture:
    //   1. GET /DmsDescPush.xml — root device descriptor (services list)
    //   2. GET each service's SCPDURL — list of actions per service
    //   3. POST control URL with SOAP envelope to invoke actions
    //   4. SUBSCRIBE to event URL to get push notifications

    /// Cached service info extracted from the device descriptor.
    struct PushService {
        let serviceType: String      // e.g. "urn:schemas-upnp-org:service:ContentDirectory:1"
        let controlURL: String       // absolute URL for POSTing SOAP actions
        let eventSubURL: String      // absolute URL for SUBSCRIBE
        let scpdURL: String          // absolute URL for service description
    }
    private var pushServices: [PushService] = []
    /// Base host (no path) for the push service, used to absolute-ify URLs.
    private var pushBaseURL: String = ""

    /// Probe and discover Sony push services. Two-phase:
    ///   1. Fetch root descriptor at /DmsDescPush.xml
    ///   2. Parse out each service's URLs, fetch SCPD, log available actions
    private func probePushService(baseURL: String) async {
        guard let url = URL(string: baseURL), let host = url.host else { return }
        let descURL = "http://\(host):64321/DmsDescPush.xml"
        pushBaseURL = "http://\(host):64321"
        log("🔍 Probing push service at \(descURL)…")

        guard let probeURL = URL(string: descURL) else { return }
        var req = URLRequest(url: probeURL)
        req.timeoutInterval = 4
        req.httpMethod = "GET"

        let data: Data
        do {
            let (responseData, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                log("✗ Push service returned non-200")
                return
            }
            data = responseData
        } catch {
            log("✗ Push service unreachable: \(error.localizedDescription)")
            return
        }

        guard let xml = String(data: data, encoding: .utf8) else {
            log("✗ DmsDescPush.xml: bad encoding")
            return
        }
        log("✓ Push service available — \(data.count) bytes")

        // Parse services from XML
        pushServices = extractServices(from: xml)
        log("📋 Found \(pushServices.count) UPnP services:")
        for svc in pushServices {
            // Trim the schema URI to just the local type for readable logging
            let shortType = svc.serviceType.split(separator: ":").suffix(2).joined(separator: ":")
            log("  • \(shortType)")
            log("      control:  \(svc.controlURL.suffix(70))")
            log("      event:    \(svc.eventSubURL.suffix(70))")
        }

        // For each service, fetch its SCPD descriptor to list available actions.
        for svc in pushServices {
            await fetchAndLogActions(scpdURL: svc.scpdURL, serviceType: svc.serviceType)
        }
    }

    /// Convenience entry point used by handleDeviceFound.
    private func probePushService(baseHost: String) async {
        await probePushService(baseURL: baseHost)
    }

    /// Probe miscellaneous Sony endpoints. We don't know what's there but
    /// if anything responds with useful data, we know where to look further.
    /// All probes are quick (1s timeout) and silently no-op on failure.
    private func probeAuxiliaryEndpoints(baseHost: String) async {
        guard let url = URL(string: baseHost), let host = url.host else { return }
        // Port 60152 hosts the postview/photo files. Camera serves them via
        // a tiny HTTP server. Maybe there's a directory listing or index.
        // Port 64321 hosts UPnP. Try a few non-descriptor paths.
        // Port 8080/10000 is the JSON-RPC server. Try undocumented service paths.
        let probes: [String] = [
            "http://\(host):60152/",
            "http://\(host):60152/index.html",
            "http://\(host):60152/list",
            "http://\(host):60152/postview/",
            "http://\(host):64321/",
            "http://\(host):64321/upnp/",
            "http://\(host):64321/DmsDescPush.xml",   // confirmed working — reference
            "http://\(host):8080/sony/system",
            "http://\(host):8080/sony/guide",
            "http://\(host):8080/sony/accessControl",
        ]
        log("🔎 Auxiliary endpoint sweep…")
        for endpoint in probes {
            guard let u = URL(string: endpoint) else { continue }
            var req = URLRequest(url: u, timeoutInterval: 1.5)
            req.httpMethod = "GET"
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse {
                    // Suffix for readable logging
                    let path = u.path.isEmpty ? "/" : u.path
                    let label = "\(u.host ?? "?"):\(u.port ?? 0)\(path)"
                    if http.statusCode == 200 {
                        let preview = String(data: data.prefix(150), encoding: .utf8)?
                            .replacingOccurrences(of: "\n", with: " ") ?? ""
                        log("   ✓ \(label) → 200, \(data.count)B: \(preview.prefix(120))")
                    } else if http.statusCode != 404 {
                        // 404s are noise (most paths don't exist); only log non-404 misses
                        log("   ◇ \(label) → \(http.statusCode)")
                    }
                }
            } catch {
                // network error — endpoint dead or filtered, skip
            }
        }
    }

    /// Pull `<service>…</service>` blocks out of the UPnP device descriptor
    /// and extract each one's URLs. Tag-soup style parsing — UPnP XML is
    /// extremely regular so we don't need a full XML parser for this.
    private func extractServices(from xml: String) -> [PushService] {
        var results: [PushService] = []
        let serviceBlocks = xml.components(separatedBy: "<service>").dropFirst()
        for block in serviceBlocks {
            guard let endRange = block.range(of: "</service>") else { continue }
            let body = String(block[..<endRange.lowerBound])
            let type = extractTag(body, tag: "serviceType")
            let ctrl = absoluteURL(extractTag(body, tag: "controlURL"))
            let evt  = absoluteURL(extractTag(body, tag: "eventSubURL"))
            let scpd = absoluteURL(extractTag(body, tag: "SCPDURL"))
            guard !type.isEmpty, !ctrl.isEmpty else { continue }
            results.append(PushService(serviceType: type, controlURL: ctrl,
                                       eventSubURL: evt, scpdURL: scpd))
        }
        return results
    }

    /// Extract the text content of <tag>…</tag> (first occurrence).
    /// Trims whitespace; returns "" if not found.
    private func extractTag(_ xml: String, tag: String) -> String {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let start = xml.range(of: open),
              let end = xml.range(of: close, range: start.upperBound..<xml.endIndex)
        else { return "" }
        return String(xml[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve a possibly-relative URL against pushBaseURL.
    private func absoluteURL(_ s: String) -> String {
        if s.isEmpty { return "" }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        if s.hasPrefix("/") { return pushBaseURL + s }
        return pushBaseURL + "/" + s
    }

    /// Fetch a service's SCPD and log every action name it advertises.
    private func fetchAndLogActions(scpdURL: String, serviceType: String) async {
        let shortType = serviceType.split(separator: ":").suffix(2).joined(separator: ":")
        guard !scpdURL.isEmpty, let url = URL(string: scpdURL) else {
            log("⚡ \(shortType) actions: (no SCPD URL)")
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                log("⚡ \(shortType) SCPD HTTP \(http.statusCode) — can't list actions")
                return
            }
            guard let xml = String(data: data, encoding: .utf8) else {
                log("⚡ \(shortType) SCPD bad encoding")
                return
            }
            let actionBlocks = xml.components(separatedBy: "<action>").dropFirst()
            var actions: [String] = []
            for block in actionBlocks {
                guard let end = block.range(of: "</action>") else { continue }
                let body = String(block[..<end.lowerBound])
                let name = extractTag(body, tag: "name")
                if !name.isEmpty { actions.append(name) }
            }
            if actions.isEmpty {
                log("⚡ \(shortType) actions: NONE (SCPD returned \(data.count)B but no <action> blocks)")
            } else {
                log("⚡ \(shortType) actions: \(actions.joined(separator: ", "))")
            }
        } catch {
            log("⚡ \(shortType) SCPD fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - SOAP / UPnP photo-push client
    //
    // Strategy: poll ContentDirectory.Browse every few seconds, look at the
    // most recent item, compare to last-seen. If new, extract its <res> URL
    // and download it through the standard downloadAndProcess pipeline.
    //
    // ContentDirectory is the standard UPnP MediaServer service for browsing
    // media. Browse() with ObjectID="0" (root) returns the top-level
    // hierarchy; the Sony Imaging Device puts new shots under root.

    /// Background task that drains the XPushList queue periodically.
    private var contentDirPollTask: Task<Void, Never>?
    /// Set false after XPushList has returned 404 twice in a row — we stop
    /// hammering the endpoint to avoid stream-lagging after every shutter
    /// press. Re-enabled on disconnect/reconnect.
    private var xPushListUsable: Bool = true
    /// Counts consecutive failed X_TransferStart calls.
    private var xPushFailureStreak: Int = 0

    /// Start polling Sony's X_TransferStart / X_TransferEnd protocol.
    /// This is the same protocol Imaging Edge uses to receive photos.
    /// Sequence per file:
    ///   1. POST X_TransferStart (no args) → camera returns DIDL with URL
    ///   2. HTTP GET the URL → download bytes
    ///   3. POST X_TransferEnd with ErrCode=0 → camera marks transfer done
    /// Camera keeps an internal queue of new photos — calling X_TransferStart
    /// drains one at a time until queue is empty.
    private func startContentDirectoryPolling() {
        contentDirPollTask?.cancel()
        guard let xp = pushServices.first(where: {
            $0.serviceType.contains("XPushList")
        }) else {
            log("⚠️ No XPushList service — physical-shutter shots can't auto-transfer")
            return
        }
        log("📂 Starting XPushList drain on \(xp.controlURL)")

        contentDirPollTask = Task { [weak self] in
            guard let self else { return }
            // Initial drain at connect — empties whatever's already in the
            // queue from before we started listening.
            await self.drainXPushList(service: xp)
            // Then poll periodically (3s) as a safety net. Most new shots
            // are also signaled via cameraStatus transitions, which trigger
            // a drain immediately — this loop just catches anything missed.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                await self.drainXPushList(service: xp)
            }
        }
    }

    /// Public entry point invoked on cameraStatus shot-complete transition.
    /// Drains the XPushList queue right after a shot finishes for fast pickup.
    private func drainXPushListNow() {
        guard xPushListUsable else { return }    // disabled after repeated 404s
        guard let xp = pushServices.first(where: {
            $0.serviceType.contains("XPushList")
        }) else { return }
        Task { [weak self] in
            await self?.drainXPushList(service: xp)
        }
    }

    /// Probe every safe action on every discovered UPnP service. If any
    /// returns HTTP 200, we know the SOAP stack is alive — just specific
    /// actions are gated. Logs the response status + body preview for each.
    /// This is a diagnostic run, called once on connect.
    private func probeAllSafeActions() async {
        log("🧪 ━━━ Probing safe actions ━━━")
        var successCount = 0
        var failCount = 0
        for svc in pushServices {
            let svcShort = svc.serviceType.split(separator: ":").suffix(2).joined(separator: ":")
            // No-argument actions that are harmless across UPnP services
            let testActions: [String]
            if svc.serviceType.contains("ContentDirectory") {
                testActions = ["GetSystemUpdateID", "GetSortCapabilities", "GetSearchCapabilities"]
            } else if svc.serviceType.contains("ConnectionManager") {
                testActions = ["GetProtocolInfo", "GetCurrentConnectionIDs"]
            } else if svc.serviceType.contains("XPushList") {
                testActions = ["X_GetPushRoot", "X_TransferProgress"]
            } else if svc.serviceType.contains("DigitalImaging") {
                // We don't know the exact action names — try plausible ones
                testActions = ["X_GetDeviceInfo", "X_GetCapabilities",
                               "GetDeviceCapabilities", "X_GetStillFormat",
                               "X_GetExtDevInfo"]
            } else {
                testActions = []
            }
            for action in testActions {
                if let resp = await soapCall(service: svc, action: action, arguments: []) {
                    log("✅ \(svcShort)/\(action) WORKS — \(resp.count) bytes")
                    log("   resp: \(resp.prefix(300).replacingOccurrences(of: "\n", with: " "))")
                    successCount += 1
                } else {
                    failCount += 1
                }
            }
        }
        if successCount == 0 {
            log("🧪 ━━━ Probe DONE: 0 actions worked, \(failCount) failed ━━━")
            log("🛑 SOAP stack is fully dead in current camera mode")
        } else {
            log("🧪 ━━━ Probe DONE: \(successCount) ✅, \(failCount) ✗ ━━━")
        }
    }

    /// Has X_GetPushRoot been called for this session? Once called, the
    /// camera "registers" the client for push and X_TransferStart starts
    /// returning real data. Without this, X_TransferStart 404s — that's
    /// what's been happening to us all this time.
    private var pushRootInitialized: Bool = false

    /// Call X_GetPushRoot to register this client with the camera's push
    /// subsystem. Sony's protocol requires this BEFORE X_TransferStart will
    /// return anything — without it the action 404s.  Idempotent.
    private func ensurePushRoot(service: PushService) async {
        guard !pushRootInitialized else { return }
        log("🔑 Calling X_GetPushRoot to initialize push subsystem…")
        if let resp = await soapCall(service: service,
                                     action: "X_GetPushRoot",
                                     arguments: []) {
            // Log the response so we can see what the root ID etc. looks like
            log("✓ X_GetPushRoot OK — \(resp.count) bytes")
            log("   resp: \(resp.prefix(300).replacingOccurrences(of: "\n", with: " "))")
            pushRootInitialized = true
            // Reset the failure counter now that we may have unlocked things
            xPushFailureStreak = 0
            xPushListUsable = true
        } else {
            log("⚠️ X_GetPushRoot failed — push subsystem may not activate")
        }
    }

    /// Call X_TransferStart repeatedly until the queue is empty. For each
    /// non-empty response: extract URL, download via standard pipeline, send
    /// X_TransferEnd. Safety capped at 20 iterations.
    private func drainXPushList(service: PushService) async {
        // STEP 0: ensure we've registered with the camera's push subsystem.
        // This was the missing piece — X_TransferStart 404s without it.
        await ensurePushRoot(service: service)
        for _ in 0..<20 {
            guard let response = await soapCall(
                service: service, action: "X_TransferStart", arguments: []
            ) else {
                // soapCall returned nil — either network error or non-200
                // (404 from this camera). Track consecutive failures and
                // disable the polling after 2 strikes so we don't lag the
                // live stream with useless requests on every shutter press.
                xPushFailureStreak += 1
                if xPushFailureStreak >= 2 {
                    if xPushListUsable {
                        log("🛑 XPushList disabled after \(xPushFailureStreak) failures — protocol not active in this camera mode")
                    }
                    xPushListUsable = false
                    contentDirPollTask?.cancel()
                    contentDirPollTask = nil
                }
                return
            }
            // A successful response — reset failure streak
            xPushFailureStreak = 0

            // Parse out the file URL — pick the largest <res> for max quality
            guard let url = extractPushURL(from: response) else {
                // Empty response means queue is drained
                return
            }
            log("📷 XPushList yielded: \(url.suffix(60))")

            // Process through the standard pipeline (download + sim + save)
            if url != lastPhotoURL {
                lastPhotoURL = url
                await downloadAndProcess(url: url)
            }

            // Tell the camera we successfully received it (ErrCode=0).
            _ = await soapCall(service: service, action: "X_TransferEnd", arguments: [
                ("ErrCode", "0")
            ])
        }
    }

    /// Extract the highest-quality <res> URL from a SOAP X_TransferStart
    /// response. The response embeds DIDL-Lite XML in <Result>, which
    /// contains one or more <res size="N">URL</res> elements. We pick the
    /// largest size for full-quality JPEG.
    private func extractPushURL(from soapResponse: String) -> String? {
        let didl = decodeDIDL(from: soapResponse)
        guard !didl.isEmpty else { return nil }

        var bestSize: Int64 = 0
        var bestURL: String?
        // Split on the opening "<res "; first chunk is preamble we discard.
        let blocks = didl.components(separatedBy: "<res ").dropFirst()
        for block in blocks {
            guard let close = block.range(of: "</res>") else { continue }
            let chunk = String(block[..<close.lowerBound])
            // Get size attribute (may be absent on some firmware)
            let sizeStr = extractAttr(chunk, attr: "size")
            let size = Int64(sizeStr) ?? 0
            // Find the URL: it's between the first ">" (end of open tag) and the end of chunk
            guard let gt = chunk.firstIndex(of: ">") else { continue }
            let url = String(chunk[chunk.index(after: gt)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty, size >= bestSize {
                bestSize = size
                bestURL = url
            }
        }
        return bestURL
    }

    /// Generic UPnP SOAP call. Returns the raw response XML.
    /// Envelope is byte-identical to ImagingEdge4Linux (which is known to
    /// work on Sony cameras): encoding= "UTF-8" (space + uppercase), no
    /// pretty-print, single line via backslash continuation. Some Sony
    /// firmware parsers are picky about exact framing.
    private func soapCall(service: PushService,
                          action: String,
                          arguments: [(String, String)]) async -> String? {
        guard let url = URL(string: service.controlURL) else { return nil }
        // Short timeout (2s) so failed calls don't hog WiFi bandwidth — the
        // live view stream shares the link and feels laggy if we wait 6s+
        // on each shutter press for a SOAP request that's just going to 404.
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        // SOAPACTION (uppercase) — matches ImagingEdge4Linux. HTTP headers
        // are case-insensitive per spec but Sony firmware may be strict.
        req.setValue("\"\(service.serviceType)#\(action)\"",
                     forHTTPHeaderField: "SOAPACTION")
        // User-Agent mimicking Imaging Edge Mobile. Some Sony firmware
        // gates SOAP endpoints by UA — replying only to the official app.
        req.setValue("Imaging Edge Mobile/7.5 (iOS)", forHTTPHeaderField: "User-Agent")

        var args = ""
        for (k, v) in arguments {
            args += "<\(k)>\(soapEscape(v))</\(k)>"
        }
        let envelope = "<?xml version=\"1.0\" encoding= \"UTF-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body>"
            + "<u:\(action) xmlns:u=\"\(service.serviceType)\">"
            + args
            + "</u:\(action)>"
            + "</s:Body>"
            + "</s:Envelope>"
        req.httpBody = envelope.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<empty>"
                let svcShort = service.serviceType.split(separator: ":").suffix(2).joined(separator: ":")
                log("⚠️ SOAP \(svcShort)/\(action) → HTTP \(http.statusCode)")
                log("   URL: \(service.controlURL)")
                log("   body(\(data.count)B): \(preview.replacingOccurrences(of: "\n", with: " "))")
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            log("⚠️ SOAP \(action) network error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - UPnP eventing: real HTTP NOTIFY listener
    //
    // UPnP devices push state changes to subscribers via HTTP NOTIFY POSTs.
    // To receive them we need to actually run a TCP HTTP server on the phone
    // and provide its address as the CALLBACK URL in our SUBSCRIBE request.
    // Without a working callback, Sony rejects/ignores the subscription —
    // which is exactly what happened before.

    /// Start an HTTP listener on a random local port to receive NOTIFY POSTs.
    /// Stores the port in notifyListenPort.
    private func startNotifyListener() {
        log("🔧 startNotifyListener: creating NWListener…")
        notifyListener?.cancel()
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            notifyListener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue {
                            self?.notifyListenPort = port
                            self?.log("📡 NOTIFY listener ready on port \(port)")
                        } else {
                            self?.log("⚠️ NOTIFY listener ready but no port?")
                        }
                    case .failed(let err):
                        self?.log("❌ NOTIFY listener failed: \(err)")
                    case .cancelled:
                        self?.notifyListenPort = 0
                        self?.log("📡 NOTIFY listener cancelled")
                    case .waiting(let err):
                        self?.log("⏳ NOTIFY listener waiting: \(err)")
                    case .setup:
                        self?.log("⚙️ NOTIFY listener in setup")
                    @unknown default:
                        self?.log("? NOTIFY listener state \(state)")
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.log("📥 NOTIFY: incoming connection")
                }
                connection.start(queue: .global(qos: .userInitiated))
                self?.handleNotifyConnection(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            log("🔧 startNotifyListener: listener.start() called")
        } catch {
            log("❌ Couldn't start NOTIFY listener: \(error.localizedDescription)")
        }
    }

    /// Handle an incoming NOTIFY connection. Reads HTTP request, parses body,
    /// logs key data, then responds 200 OK and closes.
    private nonisolated func handleNotifyConnection(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            if let data, let raw = String(data: data, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    self?.handleNotifyMessage(raw)
                }
            }
            // Send 200 OK
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
            _ = isComplete
        }
    }

    /// Parse a NOTIFY HTTP message; if it contains any signal of new media,
    /// drain XPushList immediately.
    private func handleNotifyMessage(_ raw: String) {
        // Log a digest so we can see what events fire on the camera
        let firstLine = raw.split(separator: "\n", maxSplits: 0).first.map(String.init) ?? ""
        log("📬 NOTIFY received (\(raw.count)B): \(firstLine.prefix(80))")
        // Body is after the blank line
        if let bodyStart = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n") {
            let body = String(raw[bodyStart.upperBound...])
            // Log just first 200 chars of body to keep log readable
            if !body.isEmpty {
                log("   body: \(body.prefix(200).replacingOccurrences(of: "\n", with: " "))")
            }
        }
        // Heuristics: any of these strings suggests something changed that
        // we should investigate — drain XPushList to check.
        let triggers = ["SystemUpdateID", "X_Push", "X_Transfer", "ObjectAdded",
                        "ContentDirectory", "ImageURL", "TransferStart"]
        if triggers.contains(where: { raw.contains($0) }) {
            log("📷 NOTIFY hints at new content — draining XPushList")
            drainXPushListNow()
        }
    }

    /// Publish our HTTP listener via Bonjour under multiple service types.
    /// IEM almost certainly advertises itself somehow — Sony's camera might
    /// look for clients by mDNS service type before initiating push transfer.
    /// We try several candidate types in parallel since the exact one Sony's
    /// firmware looks for isn't documented anywhere.
    private func startBonjourAdvertising() {
        guard notifyListenPort != 0 else {
            log("⚠️ Bonjour: can't advertise — no listener port yet")
            return
        }
        let port = Int32(notifyListenPort)
        // Service types worth trying:
        //   _http._tcp                       — generic HTTP server
        //   _dlna-pushcontroller._tcp        — DLNA push-controller (standard)
        //   _dlna-playcontainer._tcp         — DLNA play-container
        //   _imagingedge._tcp                — Sony app guess
        //   _sony-camera._tcp                — Sony guess
        //   _photo-push._tcp                 — generic photo push guess
        let candidates: [(String, String)] = [
            ("cam cam",        "_http._tcp"),
            ("cam cam push",   "_dlna-pushcontroller._tcp"),
            ("cam cam play",   "_dlna-playsingle._tcp"),
            ("cam cam ie",     "_imagingedge._tcp"),
            ("cam cam sony",   "_sony._tcp"),
            ("cam cam photo",  "_photo-push._tcp"),
        ]
        for (name, type) in candidates {
            let svc = NetService(domain: "local.", type: type, name: name, port: port)
            svc.delegate = bonjourDelegate
            svc.publish()
            bonjourServices.append(svc)
            log("📢 Bonjour publish: \(name) @ \(type):\(port)")
        }
    }

    /// Delegate that logs successful publication / errors for each service.
    /// @ObservationIgnored because @Observable doesn't allow lazy properties.
    @ObservationIgnored private var _bonjourDelegate: BonjourLogger?
    private var bonjourDelegate: BonjourLogger {
        if let d = _bonjourDelegate { return d }
        let d = BonjourLogger { [weak self] msg in
            Task { @MainActor [weak self] in self?.log(msg) }
        }
        _bonjourDelegate = d
        return d
    }

    /// Tear down Bonjour services on disconnect.
    private func stopBonjourAdvertising() {
        for svc in bonjourServices { svc.stop() }
        bonjourServices.removeAll()
    }

    /// Read our IP address that's REACHABLE from the camera.
    /// Uses each interface's ACTUAL subnet mask (not assuming /24).
    /// Sony Wi-Fi Direct hands out /16 masks, so iPhone at 192.168.0.2 and
    /// camera at 192.168.122.1 are on the SAME network — the old /24 logic
    /// missed this. Now we apply the real mask to both IPs and check.
    private func getLocalIPReachableFromCamera() -> String? {
        let cameraHost: String? = {
            guard let baseURL = device?.baseURL,
                  let url = URL(string: baseURL) else { return nil }
            return url.host
        }()
        guard let cameraIPStr = cameraHost else { return getLocalIP_en0() }
        let cameraIP = ipToUInt32(cameraIPStr)
        guard cameraIP != 0 else { return getLocalIP_en0() }

        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let ifaStart = ifap else { return nil }
        defer { freeifaddrs(ifaStart) }

        var seen: [(String, String, String)] = []  // (iface, ip, mask)
        var ptr: UnsafeMutablePointer<ifaddrs>? = ifaStart
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            guard let ifaName = ifa.pointee.ifa_name,
                  let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let name = String(cString: ifaName)
            if name.hasPrefix("lo") { continue }

            // Read IP
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = sin.sin_addr
            guard inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: buf)

            // Read actual subnet mask for this interface
            var maskStr = "?"
            var maskU32: UInt32 = 0
            if let maskAddr = ifa.pointee.ifa_netmask {
                let maskSin = maskAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var maskBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var maskIn = maskSin.sin_addr
                if inet_ntop(AF_INET, &maskIn, &maskBuf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    maskStr = String(cString: maskBuf)
                    maskU32 = ipToUInt32(maskStr)
                }
            }
            seen.append((name, ip, maskStr))

            // Apply mask to both IPs: same network if (cam & mask) == (us & mask)
            let myIP = ipToUInt32(ip)
            if maskU32 != 0 && myIP != 0 {
                if (cameraIP & maskU32) == (myIP & maskU32) {
                    log("✓ Reachable IP \(ip)/\(maskStr) on \(name) — same network as camera \(cameraIPStr)")
                    return ip
                }
            }
        }

        log("⚠️ No interface on same network as \(cameraIPStr). Interfaces seen:")
        for (name, ip, mask) in seen {
            log("   • \(name) = \(ip) / \(mask)")
        }
        return getLocalIP_en0()
    }

    /// Parse dotted-quad into a UInt32 in network byte order (big-endian).
    private func ipToUInt32(_ s: String) -> UInt32 {
        let parts = s.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    /// Just read en0's IP — old behavior, kept as fallback.
    private func getLocalIP_en0() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let ifaStart = ifap else { return nil }
        defer { freeifaddrs(ifaStart) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = ifaStart
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            guard let ifaName = ifa.pointee.ifa_name,
                  String(cString: ifaName) == "en0",
                  let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = sin.sin_addr
            guard inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            return String(cString: buf)
        }
        return nil
    }

    /// Convenience name kept for older call sites.
    private func getLocalIP() -> String? { getLocalIPReachableFromCamera() }

    /// UPnP event SUBSCRIBE — with a REAL callback URL pointing at our local
    /// HTTP listener. Sony cameras verify the callback by sending a NOTIFY
    /// before accepting; a bogus callback causes the subscription to fail.
    private func subscribeToEvents(service: PushService) async {
        guard let url = URL(string: service.eventSubURL) else {
            log("⚠️ SUBSCRIBE: bad event URL: \(service.eventSubURL)")
            return
        }
        let localIP = getLocalIP()
        log("🔧 SUBSCRIBE: localIP=\(localIP ?? "nil"), port=\(notifyListenPort)")
        guard notifyListenPort != 0, let ip = localIP else {
            log("⚠️ Can't SUBSCRIBE — listener not ready or no local IP")
            return
        }
        let callback = "<http://\(ip):\(notifyListenPort)/notify>"
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "SUBSCRIBE"
        req.setValue(callback,        forHTTPHeaderField: "CALLBACK")
        req.setValue("upnp:event",    forHTTPHeaderField: "NT")
        req.setValue("Second-1800",   forHTTPHeaderField: "TIMEOUT")

        let svcShort = service.serviceType.split(separator: ":").suffix(2).joined(separator: ":")
        log("📡 SUBSCRIBE \(svcShort) → \(url.absoluteString) cb=\(callback)")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                let sid = (http.allHeaderFields["SID"] as? String) ?? ""
                let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
                log("📡 SUBSCRIBE \(svcShort) ← HTTP \(http.statusCode) SID=\(sid.prefix(40))")
                if !body.isEmpty, http.statusCode != 200 {
                    log("   body: \(body)")
                }
                if !sid.isEmpty {
                    subscriptionSIDs[service.serviceType] = sid
                }
            }
        } catch {
            log("⚠️ SUBSCRIBE \(svcShort) error: \(error.localizedDescription)")
        }
    }

    /// Specialization of soapCall for ContentDirectory.Browse.
    private func soapBrowse(service: PushService,
                            objectID: String,
                            browseFlag: String,
                            count: Int,
                            sort: String) async -> String? {
        return await soapCall(service: service, action: "Browse", arguments: [
            ("ObjectID",       objectID),
            ("BrowseFlag",     browseFlag),
            ("Filter",         "*"),
            ("StartingIndex",  "0"),
            ("RequestedCount", "\(count)"),
            ("SortCriteria",   sort)
        ])
    }

    /// Decode the &lt;Result&gt;...&lt;/Result&gt; CDATA from a Browse response.
    /// The DIDL-Lite is XML-escaped inside the outer SOAP response.
    private func decodeDIDL(from soapXML: String) -> String {
        let resultBody = extractTag(soapXML, tag: "Result")
        guard !resultBody.isEmpty else { return "" }
        return resultBody
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;",  with: "&")
    }

    /// Pull attr="value" from an opening-tag fragment.
    private func extractAttr(_ s: String, attr: String) -> String {
        let needle = "\(attr)=\""
        guard let start = s.range(of: needle) else { return "" }
        let rest = s[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return "" }
        return String(rest[..<end])
    }

    /// XML-escape a string value for SOAP arguments.
    private func soapEscape(_ s: String) -> String {
        return s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Probe `getAvailableApiList` and `getVersions` so we know which methods
    /// the camera supports and which `getEvent` version is highest.
    private func probeCapabilities(camURL: String) async {
        if let result = try? await SonyAPIClient.call(
            endpoint: camURL, method: "getAvailableApiList", params: [], timeout: 5
        ),
           let arr = result["result"] as? [[String]],
           let methods = arr.first {
            availableAPIs = methods
            log("📋 \(methods.count) APIs available")
        }

        // getVersions returns {"result":[["1.0","1.1","1.2","1.3","1.4"]]}.
        // Default is "1.3"; only upgrade — never downgrade to 1.0/1.1 because
        // those versions don't include shutterSpeed/isoSpeedRate event slots.
        if let result = try? await SonyAPIClient.call(
            endpoint: camURL, method: "getVersions", params: [], timeout: 5
        ),
           let arr = result["result"] as? [[String]],
           let versions = arr.first {
            let highest = versions.compactMap(Double.init)
                                  .filter { $0 <= 1.4 }
                                  .max()
            if let v = highest, v > 1.3 {
                eventVersion = String(format: "%.1f", v)
                log("📋 getEvent version upgraded: \(eventVersion)")
            } else {
                log("📋 getEvent version: \(eventVersion) (default)")
            }
        }
    }

    // MARK: - Event Polling (long-poll)

    // MARK: - Physical-shutter sync via mode switch

    /// Triggered when the cameraStatus slot value changes. The transition
    /// StillCapturing or StillSaving → IDLE means a shot just completed.
    /// At that moment, fire a sync to grab the new file off the SD card.
    private func handleCameraStatusTransition(prev: String, new: String) {
        // Only act on the trailing edge of a shot
        let shotEnding = (prev == "StillCapturing" || prev == "StillSaving") && new == "IDLE"
        guard shotEnding else { return }
        // Skip if the API shot path is mid-flight — it will fetch the inline
        // postview URL anyway and trigger downloadAndProcess on its own.
        if isShooting { return }
        log("📸 cameraStatus \(prev)→\(new) — draining XPushList")
        // Drain the Sony X_TransferStart queue (same protocol Imaging Edge
        // uses for physical-shutter shots). NO mode switch needed.
        drainXPushListNow()
    }

    /// Parse the storageInformation event slot. When numberOfRecordableImages
    /// drops, that means the camera just wrote a new file to the SD card —
    /// trigger a mode-switch sync to fetch it.
    private func handleStorageInformation(_ dict: [String: Any]) {
        guard let arr = dict["storageInformation"] as? [[String: Any]],
              let first = arr.first else { return }

        // Field can come back as Int or NSNumber
        let recordable: Int? = {
            if let i = first["numberOfRecordableImages"] as? Int { return i }
            if let n = first["numberOfRecordableImages"] as? NSNumber { return n.intValue }
            return nil
        }()
        guard let rec = recordable else { return }

        // First reading just sets the baseline
        if lastRecordableImages == nil {
            lastRecordableImages = rec
            log("📁 Baseline recordable images: \(rec)")
            return
        }

        if let last = lastRecordableImages, rec < last, modeSwitchTask == nil {
            let delta = last - rec
            log("📷 Physical-shutter shot detected (\(last) → \(rec), \(delta) new). Syncing…")
            triggerContentSync()
        }
        lastRecordableImages = rec
    }

    /// Public entry point for the user-triggered "sync from camera" button.
    /// Same code path as the automatic storage-change trigger.
    func manualSync() {
        guard modeSwitchTask == nil else {
            log("⚠️ Sync already in progress")
            return
        }
        log("👆 Manual sync requested")
        triggerContentSync()
    }

    /// Kicks off the brief mode-switch sequence that grabs new shots off the
    /// SD card. Debounced — a second call while one is in flight is a no-op.
    private func triggerContentSync() {
        guard modeSwitchTask == nil else { return }
        modeSwitchTask = Task { [weak self] in
            await self?.contentSyncSequence()
            await MainActor.run { [weak self] in
                self?.modeSwitchTask = nil
            }
        }
    }

    /// Try to fetch the newest file from the SD card. Tries strategies from
    /// least to most disruptive:
    ///   1. Direct avContent.getContentList (no mode switch) — works on some
    ///      firmware versions even during Remote Shooting.
    ///   2. Mode-switch dance — only if direct call fails.
    /// Always restores Remote Shooting + live view at the end, even on error.
    private func contentSyncSequence() async {
        guard let camURL = device?.cameraServiceURL,
              let avURL = device?.avContentServiceURL else { return }

        // ── Strategy 1: try direct avContent during Remote Shooting ────────
        if let url = await tryDirectAvContentFetch(avURL: avURL) {
            await handleFetchedURL(url, source: "direct avContent")
            return  // success — no live view interruption needed
        }

        // ── Strategy 2: mode-switch dance ──────────────────────────────────
        log("🔄 Direct fetch failed — trying mode-switch")
        liveViewTask?.cancel()
        watchdogTask?.cancel()
        liveFrameQueued = false
        liveViewStatus = "Syncing…"

        var modeSwitched = false
        do {
            _ = try await SonyAPIClient.call(
                endpoint: camURL, method: "setCameraFunction",
                params: ["Contents Transfer"], timeout: 4
            )
            modeSwitched = true
            try? await Task.sleep(nanoseconds: 600_000_000)
        } catch SonyAPIError.apiError(let code, _) {
            log("❌ Sync: setCameraFunction failed with code \(code) — body may not support mode switching during Smart Remote Control")
        } catch {
            log("❌ Sync: setCameraFunction error: \(error.localizedDescription)")
        }

        // Discover and fetch — only if mode switch succeeded
        if modeSwitched {
            if avContentSourceURI == nil {
                avContentSourceURI = await discoverStorageSource(avURL: avURL)
            }
            if let source = avContentSourceURI,
               let url = await fetchLatestStillURL(avURL: avURL, source: source) {
                await handleFetchedURL(url, source: "mode-switch avContent")
            }
            // Switch back regardless
            _ = try? await SonyAPIClient.call(
                endpoint: camURL, method: "setCameraFunction",
                params: ["Remote Shooting"], timeout: 4
            )
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        // ALWAYS restart live view (regardless of how we got here)
        await startLiveView()
    }

    /// Try the avContent API directly without setCameraFunction. Some Sony
    /// bodies (and firmware versions) allow this; others 40401.
    private func tryDirectAvContentFetch(avURL: String) async -> String? {
        let uris = ["storage:memoryCard1", "storage:memoryCard2"]
        // Try without "type" filter first — some firmware rejects the filter
        let paramVariants: [[String: Any]] = [
            ["stIdx": 0, "cnt": 1, "view": "flat", "sort": "descending"],
            ["stIdx": 0, "cnt": 1, "view": "flat", "sort": "descending", "type": ["still"]]
        ]
        for uri in uris {
            for var params in paramVariants {
                params["uri"] = uri
                do {
                    let result = try await SonyAPIClient.call(
                        endpoint: avURL, method: "getContentList",
                        params: [params], version: "1.3", timeout: 3
                    )
                    if let resultValue = result["result"],
                       let url = firstImageURL(in: resultValue) {
                        return url
                    }
                } catch {
                    // Just keep trying the next combination — only log once
                }
            }
        }
        return nil
    }

    /// Process a URL returned by either fetch path: check it's actually new,
    /// then download it through the standard pipeline.
    private func handleFetchedURL(_ url: String, source: String) async {
        let basis = url.split(separator: "?").first.map(String.init) ?? url
        let lastBasis = lastAvContentURL?.split(separator: "?").first.map(String.init)
        guard basis != lastBasis else {
            log("ℹ️ \(source): already have latest")
            return
        }
        lastAvContentURL = url
        guard url != lastPhotoURL else { return }
        log("📷 \(source): \(url.suffix(60))")
        lastPhotoURL = url
        await downloadAndProcess(url: url)
    }

    // MARK: - avContent Polling (catches physical-shutter shots)
    //
    // The Sony Camera Remote API exposes a second service called avContent for
    // browsing files written to the SD card. Many bodies (including a7R III)
    // DON'T emit `postViewImageUrl` events in getEvent when the user fires
    // the camera's physical shutter button — the photo is just written to the
    // card silently. To catch those shots and bring them to the phone, we
    // poll avContent.getContentList every few seconds and download any new
    // photo URL we haven't seen yet.
    //
    // Note: avContent during Smart Remote Control mode is firmware-dependent.
    // If the camera refuses these calls, the log shows the error once and
    // polling stops gracefully — no harm done.

    private func startAvContentPolling() {
        guard let avURL = device?.avContentServiceURL else {
            log("⚠️ No avContent URL — physical-shutter shots can't be auto-detected")
            return
        }
        avContentTask?.cancel()
        avContentTask = Task { [weak self] in
            guard let self else { return }

            // 1. Discover storage source URI (e.g. "storage:memoryCard1")
            guard let source = await self.discoverStorageSource(avURL: avURL) else {
                self.log("⚠️ avContent discovery failed — physical-shutter detection disabled")
                return
            }
            self.avContentSourceURI = source
            self.log("📁 avContent source: \(source)")

            // 2. Record the current latest file so we don't re-download
            //    everything that was already on the card.
            self.lastAvContentURL = await self.fetchLatestStillURL(avURL: avURL, source: source)
            if let u = self.lastAvContentURL {
                self.log("📁 avContent baseline (last file): \(u.suffix(60))")
            }

            // 3. Poll every 3s looking for new files
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                await self.checkAvContentForNewPhoto(avURL: avURL, source: source)
            }
        }
    }

    /// One-shot: discover the camera's storage source URI.
    /// Returns nil if avContent is unavailable on this camera/mode.
    private func discoverStorageSource(avURL: String) async -> String? {
        do {
            let result = try await SonyAPIClient.call(
                endpoint: avURL, method: "getSourceList",
                params: [["scheme": "storage"]],
                version: "1.0", timeout: 5
            )
            // Result shape: {"result": [[{"source": "storage:memoryCard1"}]]}
            if let outer = result["result"] as? [Any],
               let inner = outer.first as? [Any] {
                for item in inner {
                    if let d = item as? [String: Any],
                       let s = d["source"] as? String {
                        return s
                    }
                }
            }
            log("⚠️ avContent getSourceList returned unexpected shape: \(result)")
        } catch SonyAPIError.apiError(let code, let msg) {
            log("⚠️ avContent getSourceList: API error \(code): \(msg)")
        } catch {
            log("⚠️ avContent getSourceList: \(error.localizedDescription)")
        }
        return nil
    }

    /// Fetch the URL of the most recent still photo on the camera's storage,
    /// or nil if the call fails / there are no photos.
    private func fetchLatestStillURL(avURL: String, source: String) async -> String? {
        do {
            // Get newest 1 still photo, descending by date.
            let result = try await SonyAPIClient.call(
                endpoint: avURL, method: "getContentList",
                params: [[
                    "uri":   source,
                    "stIdx": 0,
                    "cnt":   1,
                    "view":  "flat",
                    "sort":  "descending",
                    "type":  ["still"]
                ]],
                version: "1.3", timeout: 8
            )
            // Walk the response for any JPEG URL.  Response shape varies but
            // typically contains content.original[].url somewhere.
            if let resultValue = result["result"],
               let url = firstImageURL(in: resultValue) {
                return url
            }
        } catch SonyAPIError.apiError(let code, let msg) {
            // Only log first time per session — otherwise it spams every 3 s
            log("⚠️ avContent getContentList: \(code) \(msg)")
        } catch {
            // network blip — ignore quietly
        }
        return nil
    }

    /// Compare the newest file URL to what we saw last time; download if new.
    private func checkAvContentForNewPhoto(avURL: String, source: String) async {
        guard let latest = await fetchLatestStillURL(avURL: avURL, source: source) else {
            return
        }
        // Strip any volatile query params off the URL for comparison; Sony
        // sometimes attaches an auth token that changes per request.
        let basis = latest.split(separator: "?").first.map(String.init) ?? latest
        let lastBasis = lastAvContentURL?.split(separator: "?").first.map(String.init)

        if basis != lastBasis {
            log("📷 New file on card: \(basis.suffix(60))")
            lastAvContentURL = latest
            // Reuse the same download/process/save pipeline. If this URL is
            // ALSO the postview from a just-fired API shot, the lastPhotoURL
            // guard inside downloadAndProcess prevents double-processing.
            if latest != lastPhotoURL {
                lastPhotoURL = latest
                await downloadAndProcess(url: latest)
            }
        }
    }

    private func startEventPolling() {
        guard let device, let camURL = device.cameraServiceURL else { return }
        isPolling = true
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // Short-poll at 1 Hz. We tried long-poll for efficiency, but the
            // a7R III doesn't reliably push storageInformation updates on
            // physical-shutter shots — the slot just doesn't appear unless
            // we ask. Short-poll always returns the FULL current state, so
            // every relevant slot is parsed every second.
            while !Task.isCancelled {
                await self?.pollEvent(camURL: camURL)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func pollEvent(camURL: String) async {
        let result: [String: Any]
        do {
            result = try await SonyAPIClient.call(
                endpoint: camURL,
                method: "getEvent",
                params: [false],          // short-poll: full state, returns immediately
                version: eventVersion,
                timeout: 5
            )
        } catch {
            return  // transient — the loop will retry
        }

        guard let results = result["result"] as? [Any] else { return }

        // Extract camera status from dict-type event slots.
        // CRITICAL: Sony's actual type name is "exposureCompensation", not
        // "expComp". The old code used the wrong name and EV always read 0.
        // Values can arrive as String or NSNumber depending on firmware —
        // accept both via stringValue() helper.
        for slot in results {
            guard let dict = slot as? [String: Any],
                  let type_ = dict["type"] as? String else { continue }
            switch type_ {
            case "cameraStatus":
                // Detect shot completion (StillCapturing/Saving → IDLE).
                // This is our strongest signal that the user just fired the
                // shutter (API or physical). Triggers a background sync
                // to grab the file off the SD card.
                if let s = dict["cameraStatus"] as? String {
                    handleCameraStatusTransition(prev: lastCameraStatus, new: s)
                    lastCameraStatus = s
                }
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
                // Sony reports EV in 1/3 EV steps (stepIndexOfExposureCompensation)
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
            case "storageInformation":
                // Detect physical-shutter shots by watching numberOfRecordableImages.
                // Each new photo decreases this by 1. When we see a drop, we know a
                // shot was written to the SD card and we should sync.
                handleStorageInformation(dict)
            default: break
            }
        }

        // Diagnostic: log any slot type we haven't seen before, with its keys.
        // Helps us spot slots we should be parsing but aren't (e.g. if storage
        // info comes through under a different type name).
        for slot in results {
            guard let dict = slot as? [String: Any],
                  let type_ = dict["type"] as? String else { continue }
            if seenSlotTypes.insert(type_).inserted {
                let pairs = dict.map { k, v -> String in
                    let s = String(describing: v)
                    let trimmed = s.count > 40 ? String(s.prefix(40)) + "…" : s
                    return "\(k)=\(trimmed)"
                }.sorted()
                log("🩺 new slot type: \(type_) — \(pairs.joined(separator: ", "))")
            }
        }

        // Scan for new-photo notifications across firmware variants
        for slot in results {
            if let url = slot as? String, isImageURL(url), url != lastPhotoURL {
                log("📷 New photo (direct URL)")
                lastPhotoURL = url
                await downloadAndProcess(url: url)
                return
            }

            guard let dict = slot as? [String: Any] else { continue }
            let type_ = dict["type"] as? String ?? ""

            // Walk EVERY slot recursively — Sony bodies emit photos in many
            // forms when the physical shutter is pressed. We use firstImageURL
            // (recursive) on every dict so any URL string anywhere is caught.
            // Without this, manual-shutter shots from the body are missed
            // because they're not always tagged as "shootedImages".
            if let url = firstImageURL(in: dict as Any), url != lastPhotoURL {
                log("📷 Photo detected (slot type=\(type_), URL=\(url))")
                lastPhotoURL = url
                await downloadAndProcess(url: url)
                return
            }
        }
    }

    /// Best-effort string extraction for JSON values that might arrive as
    /// String, NSNumber, or numeric primitives — Sony JSONSerialization
    /// behavior varies. Returns nil only if the value is truly unrepresentable.
    private func stringValue(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        if let i = any as? Int      { return String(i) }
        if let d = any as? Double   { return String(d) }
        return nil
    }

    /// Permissive image-URL recognizer — Sony firmware variations.
    /// CRITICAL: Sony appends a long, percent-encoded query string after the
    /// file extension (e.g. ".JPG?%211234%21%2a..."), so `hasSuffix(".jpg")`
    /// FAILS on real-world URLs.  Must use `contains` and inspect Sony's
    /// distinctive path names (`/pict`, `postview`, etc.).
    private func isImageURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        // Strip query string for suffix-style matching
        let pathOnly = lower.split(separator: "?").first.map(String.init) ?? lower
        return pathOnly.hasSuffix(".jpg")
            || pathOnly.hasSuffix(".jpeg")
            || lower.contains(".jpg")
            || lower.contains(".jpeg")
            || lower.contains("postview")
            || lower.contains("postviewimage")
            || lower.contains("/pict")         // Sony's standard photo prefix
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

    private func downloadAndProcess(url: String) async {
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

        // Always render to UIImage for UI (thumbnail strip, onPhotoProcessed
        // callback). This is also what gets saved IF a film sim is applied.
        let hasSim = applySimClosure != nil && (selectedSim != .none || activeCustomSim != nil)
        let processed = hasSim ? applySimClosure!(oriented, selectedSim, activeCustomSim) : oriented
        guard let cg = ciContext.createCGImage(processed, from: processed.extent) else {
            log("❌ Render failed (createCGImage)")
            return
        }
        let output = UIImage(cgImage: cg)
        let thumb = output.preparingThumbnail(of: CGSize(width: 200, height: 200)) ?? output

        processedCount += 1
        lastProcessedThumb = thumb
        log("✅ Photo processed (#\(processedCount))")

        // QUALITY: if no sim was applied we save the ORIGINAL Sony JPEG bytes
        // (zero quality loss — no decode/re-encode round trip). If a sim was
        // applied we have to re-encode, but at quality 1.0 instead of 0.95.
        if autoSave {
            if hasSim {
                await saveToPhotos(output, fallbackData: nil, label: "sim-rendered")
            } else {
                await saveToPhotos(output, fallbackData: data, label: "original Sony bytes")
            }
        }

        onPhotoProcessed?(output)
    }

    /// Save to Photos with maximum quality.
    /// - If `fallbackData` is provided (no sim was applied), saves those raw
    ///   bytes directly — no decode/re-encode → zero quality loss.
    /// - Otherwise re-encodes `image` as JPEG at quality 1.0.
    /// Every step updates shutterStatus so it's visible on-device.
    private func saveToPhotos(_ image: UIImage,
                              fallbackData: Data?,
                              label: String) async {
        log("📸 saveToPhotos start (\(label))")

        // Check existing authorization first — only prompt if needed.
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
            log("⚠️ Photos permission denied — grant in Settings → cam cam → Photos")
            return
        }

        // Resolve the bytes we'll save.  Prefer raw camera JPEG when available
        // (lossless), otherwise re-encode at quality 1.0.
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

    // MARK: - Camera Setting Setters

    /// Set shutter speed (e.g. "1/125", "1\"", "BULB").
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

    /// Set ISO (e.g. "100", "200", "ISO 400", "AUTO").
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

    /// Set aperture (f-number string, e.g. "5.6").
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

    /// Set exposure compensation in 1/3 EV steps (Sony's raw integer scale).
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

    // MARK: - Camera State Helpers

    /// Polls getEvent and snapshots the camera state into the log + returns
    /// a tuple (cameraStatus, shootMode). Used for diagnostics before a retry.
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

    /// Polls getEvent until cameraStatus = "IDLE" or the timeout elapses.
    /// If shootMode is wrong en route, fixes it. Returns true if IDLE reached.
    @discardableResult
    private func waitForCameraIdle(camURL: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            let snap = await snapshotCameraState(camURL: camURL)

            // If shootMode is "movie" or anything non-still, force it back.
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

    // MARK: - Shutter Trigger

    func triggerShutter() {
        // Debounce via simple Bool — taps while a shot is in flight are ignored.
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
        shutterStatus = "Shooting…"  // set immediately on main, no Task delay
        shutterTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isShooting = false }

            // ── Take the picture, with multi-attempt recovery ─────────────
            // FAST PATH: first attempt fires actTakePicture immediately, no
            // pre-checks. The retry logic below handles 1/5/40400 errors.
            // (Previously we did a snapshotCameraState first, but that added
            // ~500 ms to every shot even on the happy path.)
            // Sony bodies return 1/5/40400 in a few situations:
            //   • Camera still initializing right after connect
            //   • Shoot mode is "movie" / "intervalstill" instead of "still"
            //   • Lingering half-press / AF in progress
            //   • Camera status not yet "IDLE"
            //   • Camera menu open or playback mode active
            var shotResult: [String: Any]? = nil
            var lastError: String = ""
            let maxAttempts = 4   // 1 initial + 3 retries

            for attempt in 1...maxAttempts {
                if Task.isCancelled { return }
                do {
                    shotResult = try await SonyAPIClient.call(
                        endpoint: camURL, method: "actTakePicture",
                        params: [], timeout: 20
                    )
                    break   // success
                } catch SonyAPIError.apiError(let code, let msg)
                        where code == 1 || code == 5 || code == 40400 {
                    lastError = "API error \(code): \(msg)"
                    self.log("⚠️ \(lastError) — attempt \(attempt)/\(maxAttempts)")
                    self.shutterStatus = "⚠️ Not ready (\(attempt)/\(maxAttempts))…"

                    if attempt == maxAttempts {
                        // Final diagnostic before giving up
                        let final = await self.snapshotCameraState(camURL: camURL)
                        self.shutterStatus = "❌ \(lastError) — status:\(final.status) mode:\(final.shootMode)"
                        self.log("❌ Gave up after \(maxAttempts) attempts. Final state: cameraStatus=\(final.status) shootMode=\(final.shootMode)")
                        self.log("   Fix on camera: dial to P/A/S/M, close menu, exit playback")
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
                    // Attempt 2: try a half-press to trigger AF lock — some
                    // bodies refuse actTakePicture when AF hasn't engaged.
                    if attempt == 2 {
                        self.log("🛠 Half-press to engage AF")
                        _ = try? await SonyAPIClient.call(
                            endpoint: camURL, method: "actHalfPressShutter",
                            params: [], timeout: 5
                        )
                        try? await Task.sleep(nanoseconds: 1_200_000_000)  // wait for AF
                    }
                    // Attempt 3+: stop liveview before retrying — a known
                    // workaround for a7 mk1 family and some a7R III firmware
                    // that refuse actTakePicture while streaming.
                    if attempt >= 3 {
                        self.log("🛠 Stopping liveview before retry (some bodies require this)")
                        _ = try? await SonyAPIClient.call(
                            endpoint: camURL, method: "stopLiveview",
                            params: [], timeout: 5
                        )
                        self.liveViewTask?.cancel()
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                    }
                    // Wait for camera to report cameraStatus = IDLE
                    await self.waitForCameraIdle(camURL: camURL, timeout: 5)
                } catch {
                    self.shutterStatus = "❌ \(error.localizedDescription)"
                    self.log("❌ actTakePicture: \(error.localizedDescription)")
                    return
                }
            }
            guard let result = shotResult else { return }

            // If we stopped liveview during recovery, restart it before returning
            if self.liveViewTask?.isCancelled == true || self.liveViewTask == nil {
                Task { [weak self] in await self?.startLiveView() }
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
                await self.downloadAndProcess(url: photoURL)
                // Final status is set by saveToPhotos inside downloadAndProcess
                return
            }

            // ── Step 3: poll getEvent for up to 30 s ──────────────────────
            // This loop is inside shutterTask so cancellation in disconnect()
            // propagates naturally.
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
                        await self.downloadAndProcess(url: url)
                        self.shutterStatus = "✅ Done"
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

        liveViewStatus = "Waiting for camera ready…"
        for attempt in 1...15 {
            if Task.isCancelled { return }
            log("📹 startLiveview attempt \(attempt)/15…")
            do {
                let result = try await SonyAPIClient.call(
                    endpoint: camURL, method: "startLiveview", params: []
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
                liveFrameQueued = false   // clear mailbox slot for fresh stream
                liveViewTask?.cancel()
                liveViewTask = Task { [weak self] in
                    await self?.parseLiveViewStream(from: url)
                }
                startLiveViewWatchdog()
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

    /// Live-view watchdog. If no frame arrives for ≥ 5 s after the first frame
    /// has been seen, tear down the current stream and re-call startLiveView.
    private func startLiveViewWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                // Only watch *after* we've seen at least one frame — gives
                // the camera time to warm up without aggressive restarts.
                guard self.lastFrameTime != .distantPast else { continue }
                let elapsed = Date().timeIntervalSince(self.lastFrameTime)
                if elapsed > 5 {
                    self.log("🐶 Watchdog: no frame in \(Int(elapsed)) s — restarting stream")
                    self.liveViewTask?.cancel()
                    self.liveViewImage = nil
                    self.liveViewStatus = "Reconnecting stream…"
                    self.lastFrameTime = .distantPast
                    // startLiveView re-spawns the watchdog and stream task
                    await self.startLiveView()
                    return
                }
            }
        }
    }

    /// Sony live-view binary frame format (Camera Remote API spec v2.40):
    ///
    ///   Common header  [8 bytes]
    ///     buf[0]      = 0xFF  (start marker)
    ///     buf[1]      = payload type  (0x01 = JPEG, 0x02 = frame info)
    ///   Payload header [128 bytes]
    ///     buf[8..11]  = start code 0x24356879
    ///     buf[12..14] = payload data size  (3 bytes big-endian — NOT 4)
    ///     buf[15]     = padding data size
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

        // Capture only the bits the parser thread needs — NOT `self` directly.
        // The detached task previously rebound `self` strongly for its lifetime,
        // which kept the connector alive even after disconnect.
        let ctx = self.ciContext
        let snapshot = self.liveSimSnapshot

        await Task.detached(priority: .userInitiated) { [weak self] in
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

                        // Resync: jump forward to the next 0xFF instead of
                        // sliding byte-by-byte (O(n) per resync, not O(n²)).
                        if buf[0] != 0xFF {
                            if let idx = buf.firstIndex(of: 0xFF), idx > 0 {
                                buf.removeFirst(idx)
                            } else if buf.first != 0xFF {
                                buf.removeAll(keepingCapacity: true)
                            }
                            continue
                        }

                        // Payload header start code 0x24356879 at buf[8..11]
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
                        let jpeg = Data(buf[136 ..< (136 + pendingSize)])

                        // Lock-free read from the snapshot — no per-frame
                        // MainActor.run hop. Reference reads are atomic in
                        // Swift's ARC; stale value would just mean one frame
                        // rendered with the previous sim setting.
                        let closure = snapshot.applyClosure
                        let sim = snapshot.sim
                        let custom = snapshot.custom

                        if let ciImage = CIImage(data: jpeg) {
                            // DO NOT apply EXIF orientation to live-view frames.
                            // Sony streams a fixed-size landscape JPEG; the
                            // EXIF orientation field reflects camera tilt and
                            // makes the displayed frame the wrong shape.
                            let oriented = ciImage
                            let out: CIImage
                            if let fn = closure, sim != .none || custom != nil {
                                out = fn(oriented, sim, custom)
                            } else {
                                out = oriented
                            }
                            // Frame drop logic: skip this frame entirely if
                            // the main actor hasn't picked up the previous
                            // one yet. Prevents queue buildup that causes
                            // growing latency in long sessions.
                            if let strong = self, strong.liveFrameQueued {
                                frameCount += 1
                                // Even though we dropped the display, we
                                // STILL consumed the bytes — the parser
                                // continues at full stream speed.
                            } else if let cg = ctx.createCGImage(out, from: out.extent) {
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
                                    // Slot clear → next frame from the parser
                                    // is allowed through.
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
        }.value
    }
}
