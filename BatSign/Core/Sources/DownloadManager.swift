//
//  DownloadManager.swift
//  BatSign
//
//  Store app downloads on a background URLSession. Downloads keep running
//  when the user leaves the app; iOS delivers the finished file (and wakes
//  the app if needed), then the app is imported and — when a certificate is
//  available — queued for signing immediately.
//

import Foundation
import SwiftUI

/// Nonisolated whole-percent progress throttle shared by delegate callbacks.
private final class FractionThrottle {
    private let lock = NSLock()
    private var storage: [Int: Double] = [:]

    func shouldPublish(id: Int, fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let previous = storage[id] ?? -1
        guard fraction - previous >= 0.01 || fraction >= 1.0 else { return false }
        storage[id] = fraction
        return true
    }
}

enum StoreDownloadState: Equatable {
    case downloading(Double)          // 0...1
    case preparing                    // moving + parsing the package
    case queuedForSigning             // handed to the signing queue
    case needsCertificate(appID: UUID)
    case failed(String)

    static func == (lhs: StoreDownloadState, rhs: StoreDownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.downloading(let a), .downloading(let b)): return a == b
        case (.preparing, .preparing): return true
        case (.queuedForSigning, .queuedForSigning): return true
        case (.needsCertificate(let a), .needsCertificate(let b)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var downloads: [String: StoreDownloadState] = [:]

    private var session: URLSession!
    // Task identity: `taskDescription` carries the bundle identifier. It is
    // set once before resume and read from any thread — no mutable map, so
    // delegate-queue callbacks cannot race the main actor.
    private let throttle = FractionThrottle()

    override private init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "app.batsign.store-downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func state(for bundleID: String) -> StoreDownloadState? {
        downloads[bundleID]
    }

    func start(app: AltApp) {
        guard let url = app.latestVersion?.downloadURL else {
            downloads[app.bundleIdentifier] = .failed("This source provides no downloadable package.")
            return
        }
        // Reuse an in-flight download instead of starting a second one.
        if case .downloading = downloads[app.bundleIdentifier] { return }
        if case .preparing = downloads[app.bundleIdentifier] { return }

        downloads[app.bundleIdentifier] = .downloading(0)
        let task = session.downloadTask(with: url)
        task.taskDescription = app.bundleIdentifier
        task.resume()
    }

    // MARK: Completion pipeline (main actor)

    private func handleFinishedFile(at location: URL, bundleID: String) {
        downloads[bundleID] = .preparing
        let staged = Paths.temp.appendingPathComponent("store-\(UUID().uuidString).ipa")
        do {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            downloads[bundleID] = .failed(error.localizedDescription)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let record = try await AppLibrary.shared.importApp(from: staged)
                try? FileManager.default.removeItem(at: staged)

                // Get & Sign means sign: queue immediately when any certificate
                // exists, otherwise surface the missing certificate.
                let cert = self.lastUsableCertificate()
                guard let cert else {
                    self.downloads[bundleID] = .needsCertificate(appID: record.id)
                    NotificationHub.shared.post(kind: .info,
                                                title: "\(record.name) is ready",
                                                body: "Import a certificate to sign it.",
                                                dedupeKey: "needs-cert:\(record.id)")
                    return
                }

                let options = SignOptions(bundleID: nil, displayName: nil, version: nil, minVersion: nil,
                                          entitlementsXML: nil, infoPlistOverridesXML: nil, iconFileName: nil,
                                          removeExtensions: record.hasExtensions,
                                          removeWatch: record.hasWatchApp,
                                          removeProvision: false, removeSupportedDevices: false,
                                          weakInject: false, dylibNames: [])
                JobQueue.shared.enqueue(app: record, cert: cert, adhoc: false,
                                        options: options, dylibs: [], iconURL: nil)
                self.downloads[bundleID] = .queuedForSigning
            } catch {
                try? FileManager.default.removeItem(at: staged)
                self.downloads[bundleID] = .failed(error.localizedDescription)
            }
        }
    }

    private func lastUsableCertificate() -> CertificateRecord? {
        let lastID = UUID(uuidString: UserDefaults.standard.string(forKey: "lastCertID") ?? "")
        if let lastID, let cert = CertificateManager.shared.certificate(with: lastID) {
            return cert
        }
        return CertificateManager.shared.certificates.first
    }

    private nonisolated func bundleID(for task: URLSessionTask) -> String? {
        task.taskDescription
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    // URLSession invokes these on its own queue, so the witnesses are
    // explicitly nonisolated; all main-actor state is touched via hops.
    nonisolated func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let bundleID = bundleID(for: downloadTask) else { return }
        let fraction = totalBytesExpectedToWrite > 0
            ? min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            : 0
        // Throttle: publish at most every whole percent of progress.
        guard throttle.shouldPublish(id: downloadTask.taskIdentifier, fraction: fraction) else { return }
        Task { @MainActor [weak self] in
            self?.downloads[bundleID] = .downloading(fraction)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted the moment this delegate method
        // returns, so it must be moved synchronously, on this thread.
        guard let bundleID = bundleID(for: downloadTask) else { return }
        let staged = Paths.temp.appendingPathComponent("store-\(UUID().uuidString).ipa")
        do {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            Task { @MainActor [weak self] in
                self?.downloads[bundleID] = .failed(error.localizedDescription)
            }
            return
        }
        Task { @MainActor [weak self] in
            self?.consumeStagedDownload(at: staged, bundleID: bundleID)
        }
    }

    /// Runs on the main actor with the staged file already safe on disk.
    private func consumeStagedDownload(at staged: URL, bundleID: String) {
        downloads[bundleID] = .preparing
        Task { [weak self] in
            guard let self else { return }
            do {
                let record = try await AppLibrary.shared.importApp(from: staged)
                try? FileManager.default.removeItem(at: staged)

                // Get & Sign means sign: queue immediately when any certificate
                // exists, otherwise surface the missing certificate.
                let cert = self.lastUsableCertificate()
                guard let cert else {
                    self.downloads[bundleID] = .needsCertificate(appID: record.id)
                    NotificationHub.shared.post(kind: .info,
                                                title: "\(record.name) is ready",
                                                body: "Import a certificate to sign it.",
                                                dedupeKey: "needs-cert:\(record.id)")
                    return
                }

                let options = SignOptions(bundleID: nil, displayName: nil, version: nil, minVersion: nil,
                                          entitlementsXML: nil, infoPlistOverridesXML: nil, iconFileName: nil,
                                          removeExtensions: record.hasExtensions,
                                          removeWatch: record.hasWatchApp,
                                          removeProvision: false, removeSupportedDevices: false,
                                          weakInject: false, dylibNames: [])
                JobQueue.shared.enqueue(app: record, cert: cert, adhoc: false,
                                        options: options, dylibs: [], iconURL: nil)
                self.downloads[bundleID] = .queuedForSigning
            } catch {
                try? FileManager.default.removeItem(at: staged)
                self.downloads[bundleID] = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // nil error = success path
        guard let bundleID = bundleID(for: task) else { return }
        Task { @MainActor [weak self] in
            self?.downloads[bundleID] = .failed(error.localizedDescription)
        }
    }
}
