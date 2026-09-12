//
//  AppLibrary.swift
//  BatSign
//
//  Imported IPA library with icons and metadata.
//

import Foundation
import UIKit

@MainActor
final class AppLibrary: ObservableObject {
    /// Single shared instance — views and the download completion pipeline
    /// must observe the same library.
    static let shared = AppLibrary()

    @Published private(set) var apps: [AppRecord] = []

    init() {
        load()
    }

    func load() {
        apps = JSONStore.load([AppRecord].self, from: Paths.appsIndex) ?? []
        apps.sort { $0.addedAt > $1.addedAt }
    }

    private func persist() {
        JSONStore.save(apps, to: Paths.appsIndex)
    }

    func app(with id: UUID) -> AppRecord? {
        apps.first { $0.id == id }
    }

    /// Copies a picked IPA into the library and parses it.
    @discardableResult
    func importApp(from sourceURL: URL) async throws -> AppRecord {
        let id = UUID()
        let dir = Paths.apps.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent("app.ipa")

        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        let parsed = try IPAParser.parse(ipaURL: destination)
        var record = parsed.record
        // Keep the identity the parser generated for its own temp handling:
        record.id = id

        if let iconData = parsed.iconData {
            try? iconData.write(to: record.iconURL, options: [.atomic])
        }
        apps.insert(record, at: 0)
        persist()
        return record
    }

    func remove(_ record: AppRecord) {
        try? FileManager.default.removeItem(at: Paths.apps.appendingPathComponent(record.id.uuidString))
        apps.removeAll { $0.id == record.id }
        persist()
    }

    func app(withBundleID bundleID: String) -> AppRecord? {
        apps.first { $0.bundleID == bundleID }
    }

    func icon(for record: AppRecord) -> UIImage? {
        UIImage(contentsOfFile: record.iconURL.path)
    }

    func totalBytesUsed() -> Int64 {
        apps.reduce(0) { $0 + $1.sizeBytes }
    }
}
