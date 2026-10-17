//
//  LocationTagger.swift
//  cam cam
//
//  Supplies the phone's location for geotagging shots — mainly for the Sony
//  a7R III, which has no GPS (Imaging Edge Mobile does the same "location
//  linkage"). Uses the cheapest accuracy that's still useful for a photo map,
//  and only runs while the camera is in use.
//

import Foundation
import CoreLocation

@MainActor
@Observable
final class LocationTagger: NSObject, CLLocationManagerDelegate {
    static let shared = LocationTagger()
    /// The instance, for the save pipeline off the main thread (created on
    /// main at launch; CLLocationManager wants the main run loop).
    nonisolated(unsafe) private static weak var instance: LocationTagger?
    /// Where the phone is now, for a photo being saved (any thread).
    nonisolated static func photoLocation() -> CLLocation? { instance?.locationForPhoto() }

    /// User toggle (View menu). Persisted.
    var enabled: Bool = UserDefaults.standard.object(forKey: "cc_geotag") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "cc_geotag")
            enabled ? start() : stop()
        }
    }

    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @ObservationIgnored private let manager = CLLocationManager()
    /// Most recent fix. Read off-main by the save pipeline, hence the lock.
    @ObservationIgnored nonisolated(unsafe) private var _latest: CLLocation?
    @ObservationIgnored nonisolated private let lock = NSLock()

    override private init() {
        super.init()
        Self.instance = self
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
        authorization = manager.authorizationStatus
    }

    /// Begin updates (asks for When-In-Use permission the first time).
    func start() {
        guard enabled else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: break
        }
    }

    func stop() { manager.stopUpdatingLocation() }

    /// A fix suitable for tagging a photo taken *now*: recent (≤ 5 min) and
    /// reasonably accurate (≤ 250 m), or nil. Safe from any thread.
    nonisolated func locationForPhoto() -> CLLocation? {
        lock.lock(); defer { lock.unlock() }
        guard let loc = _latest,
              abs(loc.timestamp.timeIntervalSinceNow) < 300,
              loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 250
        else { return nil }
        return loc
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        lock.lock(); _latest = last; lock.unlock()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.start() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient (no fix indoors etc.) — keep the last good fix.
    }
}
