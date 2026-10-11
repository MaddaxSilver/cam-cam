//
//  FilmSuggest.swift
//  cam cam
//
//  "What film would suit this light?" Reads the real scene — colour
//  temperature from the camera's white balance, brightness (EV), the time of
//  day and whether people are in frame — and suggests three films with a
//  plain reason, the way you'd pick a stock before loading a camera.
//

import AVFoundation

nonisolated struct SceneReading: Equatable, Sendable {
    var kelvin: Float
    var ev: Float
    var hour: Int
    var faces: Bool
}

nonisolated enum FilmSuggest {

    /// Current reading from the camera, or nil when there's no device yet.
    static func read(device: AVCaptureDevice?, ev: Float, faces: Bool) -> SceneReading? {
        guard let device else { return nil }
        let g = device.deviceWhiteBalanceGains
        let maxG = device.maxWhiteBalanceGain
        let clamped = AVCaptureDevice.WhiteBalanceGains(
            redGain: min(max(g.redGain, 1), maxG),
            greenGain: min(max(g.greenGain, 1), maxG),
            blueGain: min(max(g.blueGain, 1), maxG))
        let tt = device.temperatureAndTintValues(for: clamped)
        let hour = Calendar.current.component(.hour, from: Date())
        return SceneReading(kelvin: tt.temperature, ev: ev, hour: hour, faces: faces)
    }

    static func suggest(_ r: SceneReading) -> (reason: String, films: [FilmSimulation]) {
        var reason: String
        var films: [FilmSimulation]
        let golden = (5...8).contains(r.hour) || (17...20).contains(r.hour)

        if r.ev < 4 {
            if r.kelvin < 3800 {
                reason = "Tungsten light after dark"
                films = [.cinestill800T, .kodakVision3, .kodakP3200]
            } else {
                reason = "Low light — a fast, grainy film"
                films = [.ilfordHP5, .kodakP3200, .cinestill800T]
            }
        } else if r.kelvin < 3600 {
            reason = "Warm indoor light"
            films = [.cinestill800T, .kodakVision3, .kodakGold]
        } else if golden && r.kelvin < 5200 {
            reason = "Warm low sun"
            films = [.kodakPortra, .kodakGold, .cinestill50D]
        } else if r.kelvin > 6800 {
            reason = "Flat, cool light — add some punch"
            films = [.fujiVelvia, .kodakEktar, .fujiProvia]
        } else if r.ev > 12 {
            reason = "Hard midday sun"
            films = [.fujiClassicChrome, .fujiProvia, .kodakTriX]
        } else {
            reason = "Even, natural light"
            films = [.kodakPortra, .fujiClassicChrome, .fujiAcros]
        }

        if r.faces {
            reason = "People in frame · " + reason.lowercased()
            films = [.kodakPortra160, .fujiPro400H] + films
        }
        var seen = Set<FilmSimulation>()
        return (reason, films.filter { seen.insert($0).inserted }.prefix(3).map { $0 })
    }
}
