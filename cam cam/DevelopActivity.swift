//
//  DevelopActivity.swift
//  cam cam
//
//  Photos keep developing after you leave the app, with their progress in
//  the Dynamic Island / Lock Screen.
//
//  • A BGContinuedProcessingTask (iOS 26) runs while shots are rendering:
//    iOS shows it as a Live Activity ("Developing 2 photos", progress) and
//    keeps the app alive in the background until they're saved.
//  • iOS doesn't allow GPU work in the background without an entitlement
//    personal teams can't get, so renders switch to the CPU while the app is
//    in the background (CameraManager.photoContext).
//

import BackgroundTasks
import UIKit

nonisolated final class DevelopActivity: @unchecked Sendable {
    static let shared = DevelopActivity()

    private let lock = NSLock()
    private var task: BGContinuedProcessingTask?
    private var submitting = false
    private var total = 0
    private var done = 0
    private var bgID: UIBackgroundTaskIdentifier = .invalid
    private var prefix: String { (Bundle.main.bundleIdentifier ?? "idk.cam-cam") + ".develop" }

    /// A shot was taken (call on the main thread: a submit must come from
    /// the foreground app, in response to the user).
    @MainActor func shotStarted(burst: Bool = false) {
        lock.lock()
        total += 1
        let t = task
        lock.unlock()
        if let t { update(t) }
        // No Live Activity for ordinary shots (it flashed up for every
        // photo): once per zoom burst, or when you leave the app with photos
        // still developing.
        if burst { showIfStillDeveloping() }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showIfStillDeveloping() }
            }
        }
        // Belt and braces: ~30 s of background time even if iOS declines the task.
        if bgID == .invalid {
            bgID = UIApplication.shared.beginBackgroundTask(withName: "Develop photos") { [weak self] in self?.endBackgroundTime() }
        }
        #if DEBUG
        print("[develop] started (\(total) in flight)")
        #endif
    }

    @MainActor private var resignObserver: NSObjectProtocol?

    /// One Live Activity for the whole batch, only while work remains.
    @MainActor private func showIfStillDeveloping() {
        lock.lock()
        let need = total > done && task == nil && !submitting
        if need { submitting = true }
        lock.unlock()
        if need { submit() }
    }

    private func endBackgroundTime() {
        Task { @MainActor [self] in
            guard bgID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(bgID); bgID = .invalid
        }
    }

    /// A shot finished rendering (saved or failed).
    func shotFinished() {
        lock.lock()
        done = min(total, done + 1)
        let finished = done >= total
        let t = task
        if finished { total = 0; done = 0; task = nil; submitting = false }
        lock.unlock()
        #if DEBUG
        print("[develop] finished one (all done: \(finished), task: \(t != nil), background: \(CameraManager.inBackground))")
        #endif
        if finished { endBackgroundTime() }
        guard let t else { return }
        if finished {
            t.progress.completedUnitCount = t.progress.totalUnitCount
            t.updateTitle("Photos developed", subtitle: "Saved to cam cam")
            t.setTaskCompleted(success: true)
        } else {
            update(t)
        }
    }

    private func update(_ t: BGContinuedProcessingTask) {
        lock.lock(); let (n, d) = (total, done); lock.unlock()
        t.progress.totalUnitCount = Int64(max(n, 1))
        t.progress.completedUnitCount = Int64(d)
        let left = n - d
        t.updateTitle(left == 1 ? "Developing 1 photo" : "Developing \(left) photos", subtitle: "cam cam")
    }

    private func submit() {
        let id = "\(prefix).\(UUID().uuidString.prefix(8))"
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { [weak self] bg in
            guard let self, let bg = bg as? BGContinuedProcessingTask else { bg.setTaskCompleted(success: false); return }
            bg.expirationHandler = { [weak self] in
                guard let self else { return }
                lock.lock(); if task === bg { task = nil; submitting = false }; lock.unlock()
                bg.setTaskCompleted(success: false)
            }
            #if DEBUG
            print("[develop] continued-processing task running")
            #endif
            lock.lock()
            let alreadyDone = total == 0
            if !alreadyDone { task = bg }
            submitting = false
            lock.unlock()
            if alreadyDone {                          // every shot finished before iOS started us
                bg.setTaskCompleted(success: true)
            } else {
                update(bg)
            }
        }
        guard ok else { lock.lock(); submitting = false; lock.unlock(); return }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "Developing photo", subtitle: "cam cam")
        request.strategy = .fail          // only useful right now, never queued for later
        do { try BGTaskScheduler.shared.submit(request) }
        catch {
            lock.lock(); submitting = false; lock.unlock()
            #if DEBUG
            print("DevelopActivity: submit failed: \(error)")
            #endif
        }
    }
}
