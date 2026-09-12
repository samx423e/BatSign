//
//  SourceStore.swift
//  BatSign
//
//  User-added app sources in the AltStore JSON format (the de-facto standard
//  used by SideStore / AppStar / AltStore — the same format the signer this
//  design is modeled on consumes), plus public iTunes Lookup enrichment so
//  app pages show real App Store ratings, artwork and screenshots when the
//  app exists on the App Store.
//

import Foundation

struct AltScreenshot: Codable, Hashable {
    var imageURL: URL?
    var caption: String?
}

struct AltVersion: Codable, Hashable {
    var version: String
    var date: Date?
    var localizedDescription: String?
    var downloadURL: URL?
    var size: Int64?
    var minOSVersion: String?
}

struct AltApp: Codable, Identifiable, Hashable {
    var name: String
    var bundleIdentifier: String
    var developerName: String?
    var subtitle: String?
    var localizedDescription: String?
    var iconURL: URL?
    var headerURL: URL?
    var tintColor: String?
    var category: String?
    var screenshots: [AltScreenshot]?
    var versions: [AltVersion]?

    var id: String { bundleIdentifier }

    /// Latest version by list order (sources list newest first).
    var latestVersion: AltVersion? {
        versions?.first
    }
}

struct AltSource: Codable, Hashable {
    var name: String
    var identifier: String?
    var subtitle: String?
    var iconURL: URL?
    var headerURL: URL?
    var website: URL?
    var tintColor: String?
    var apps: [AltApp]

    static func decode(_ data: Data) throws -> AltSource {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AltSource.self, from: data)
    }
}

/// A source the user added, with its last fetch state.
struct StoredSource: Identifiable, Codable, Hashable {
    let id: UUID
    var url: URL
    var name: String
    var iconURL: URL?
    var headerURL: URL?
    var tintColor: String?
    var appCount: Int
    var fetchedAt: Date?
    var error: String?
}

/// Public App Store facts (ratings / artwork / screenshots), cached for a day.
struct AppStoreInfo: Codable, Hashable {
    var trackName: String?
    var artistName: String?
    var averageUserRating: Double?
    var userRatingCount: Int?
    var artworkURL: URL?
    var screenshotURLs: [URL]
    var fetchedAt: Date

    var isOnAppStore: Bool {
        averageUserRating != nil || userRatingCount != nil || !screenshotURLs.isEmpty || trackName != nil
    }
}

@MainActor
final class SourceManager: ObservableObject {
    static let shared = SourceManager()

    @Published private(set) var sources: [StoredSource] = []
    @Published private(set) var appsBySource: [UUID: [AltApp]] = [:]
    @Published private(set) var appStoreInfo: [String: AppStoreInfo] = [:]
    @Published private(set) var isRefreshing = false

    private let lookupURLBase = "https://itunes.apple.com/lookup?bundleId=%@&country=us"
    private let lookupTTL: TimeInterval = 24 * 3600
    private let lookupMissTTL: TimeInterval = 10 * 60

    private init() {
        load()
        Task { await refreshAll() }
    }

    // MARK: Persistence

    private struct CacheFile: Codable {
        var sources: [StoredSource]
        var appsBySource: [UUID: [AltApp]]
    }

    private func load() {
        if let cache = JSONStore.load(CacheFile.self, from: Paths.sourcesIndex) {
            sources = cache.sources
            appsBySource = cache.appsBySource
        }
        appStoreInfo = JSONStore.load([String: AppStoreInfo].self, from: Paths.data.appendingPathComponent("appstore-cache.json")) ?? [:]
    }

    private func persist() {
        JSONStore.save(CacheFile(sources: sources, appsBySource: appsBySource), to: Paths.sourcesIndex)
        JSONStore.save(appStoreInfo, to: Paths.data.appendingPathComponent("appstore-cache.json"))
    }

    // MARK: Source management

    func addSource(url: URL) async throws {
        let normalized = Self.normalizeSourceURL(url)
        guard !sources.contains(where: { $0.url == normalized }) else {
            throw SourceError.alreadyAdded
        }
        let source = try await fetchSource(normalized)
        let stored = StoredSource(id: UUID(),
                                  url: normalized,
                                  name: source.name,
                                  iconURL: source.iconURL,
                                  headerURL: source.headerURL,
                                  tintColor: source.tintColor,
                                  appCount: source.apps.count,
                                  fetchedAt: Date(),
                                  error: nil)
        sources.append(stored)
        appsBySource[stored.id] = source.apps
        persist()
        // Enrichment (App Store lookups) runs detached so the caller — and
        // the sheet the user is staring at — finishes immediately.
        Task { await self.enrich(with: source.apps) }
        Haptics.success()
    }

    /// Adds a source from already-decoded data (local .json import).
    func addSourceData(name: String, iconURL: URL?, headerURL: URL?,
                       tintColor: String?, apps: [AltApp]) async throws {
        let stored = StoredSource(id: UUID(),
                                  url: URL(string: "local:\(UUID().uuidString)")!,
                                  name: name,
                                  iconURL: iconURL,
                                  headerURL: headerURL,
                                  tintColor: tintColor,
                                  appCount: apps.count,
                                  fetchedAt: Date(),
                                  error: nil)
        sources.append(stored)
        appsBySource[stored.id] = apps
        persist()
        await enrich(with: apps)
        Haptics.success()
    }

    func remove(_ stored: StoredSource) {
        sources.removeAll { $0.id == stored.id }
        appsBySource[stored.id] = nil
        persist()
    }

    func refresh(_ stored: StoredSource) async {
        guard stored.url.scheme != "local" else { return } // imported file, nothing to fetch
        do {
            let source = try await fetchSource(stored.url)
            if let index = sources.firstIndex(where: { $0.id == stored.id }) {
                sources[index].name = source.name
                sources[index].iconURL = source.iconURL
                sources[index].headerURL = source.headerURL
                sources[index].tintColor = source.tintColor
                sources[index].appCount = source.apps.count
                sources[index].fetchedAt = Date()
                sources[index].error = nil
            }
            appsBySource[stored.id] = source.apps
            persist()
            Task { await self.enrich(with: source.apps) }
        } catch {
            if let index = sources.firstIndex(where: { $0.id == stored.id }) {
                sources[index].error = error.localizedDescription
            }
            persist()
        }
    }

    func refreshAll() async {
        guard !sources.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for stored in sources {
            await refresh(stored)
        }
    }

    func allApps() -> [(source: StoredSource, app: AltApp)] {
        var result: [(StoredSource, AltApp)] = []
        for stored in sources {
            for app in appsBySource[stored.id] ?? [] {
                result.append((stored, app))
            }
        }
        return result
    }

    func source(for app: AltApp) -> StoredSource? {
        sources.first { (appsBySource[$0.id] ?? []).contains { $0.bundleIdentifier == app.bundleIdentifier } }
    }

    private func fetchSource(_ url: URL) async throws -> AltSource {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.badStatus(http.statusCode)
        }
        return try AltSource.decode(data)
    }

    static func normalizeSourceURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.scheme == nil {
            components = URLComponents()
            components?.scheme = "https"
            components?.host = url.absoluteString
        }
        return components?.url ?? url
    }

    // MARK: App Store enrichment

    func appStoreInfo(for bundleID: String) -> AppStoreInfo? {
        guard let info = appStoreInfo[bundleID] else { return nil }
        let ttl = info.isOnAppStore ? lookupTTL : lookupMissTTL
        guard Date().timeIntervalSince(info.fetchedAt) < ttl else { return nil }
        return info
    }

    private func enrich(with apps: [AltApp]) async {
        for app in apps {
            _ = await lookup(bundleID: app.bundleIdentifier)
        }
    }

    func lookup(bundleID: String) async -> AppStoreInfo? {
        if let cached = appStoreInfo(for: bundleID) { return cached }
        guard let url = URL(string: String(format: lookupURLBase, bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleID)) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)
            struct LookupResponse: Decodable {
                struct Result: Decodable {
                    var trackName: String?
                    var artistName: String?
                    var averageUserRating: Double?
                    var userRatingCount: Int?
                    var artworkUrl512: String?
                    var artworkUrl100: String?
                    var screenshotUrls: [String]?
                }
                var results: [Result]
            }
            let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
            guard let result = decoded.results.first else {
                // Not on the App Store — cache the miss so we don't re-hit.
                let miss = AppStoreInfo(trackName: nil, artistName: nil, averageUserRating: nil,
                                        userRatingCount: nil, artworkURL: nil, screenshotURLs: [],
                                        fetchedAt: Date())
                appStoreInfo[bundleID] = miss
                persist()
                return nil
            }
            let info = AppStoreInfo(trackName: result.trackName,
                                    artistName: result.artistName,
                                    averageUserRating: result.averageUserRating,
                                    userRatingCount: result.userRatingCount,
                                    artworkURL: (result.artworkUrl512 ?? result.artworkUrl100).flatMap(URL.init),
                                    screenshotURLs: (result.screenshotUrls ?? []).compactMap(URL.init),
                                    fetchedAt: Date())
            appStoreInfo[bundleID] = info
            persist()
            return info
        } catch {
            return nil
        }
    }
}

enum SourceError: LocalizedError {
    case alreadyAdded
    case badStatus(Int)
    case noDownload

    var errorDescription: String? {
        switch self {
        case .alreadyAdded: return "This source is already in your list."
        case .badStatus(let code): return "The source server responded with HTTP \(code)."
        case .noDownload: return "This app's source doesn't provide a downloadable package."
        }
    }
}

extension StoredSource {
    var host: String {
        url.scheme == "local" ? "imported file" : (url.host ?? url.absoluteString)
    }
}
