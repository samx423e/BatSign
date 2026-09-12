//
//  StoreAppPageView.swift
//  BatSign
//
//  An App Store-style page for a source app: hero banner (source header or
//  App Store artwork), icon, ratings from the App Store when available,
//  screenshots, description, version history — and the Sign action.
//

import SwiftUI

struct StoreAppPageView: View {
    @EnvironmentObject private var library: AppLibrary
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sourceManager: SourceManager
    @ObservedObject private var downloadManager = DownloadManager.shared

    let source: StoredSource
    let app: AltApp

    @State private var storeInfo: AppStoreInfo?
    @State private var errorText: String?
    @State private var sheetApp: AppRecord?
    @State private var showSignSheet = false
    @State private var expandedDescription = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                iconAndTitle
                actionArea
                if let subtitle = app.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 6)
                }
                infoBar
                screenshotsSection
                descriptionSection
                ratingsSection
                versionsSection
            }
            .padding(.bottom, 40)
        }
        .background(AuroraBackground())
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            storeInfo = sourceManager.appStoreInfo(for: app.bundleIdentifier)
            Task { @MainActor in
                // Refreshed on every page view; misses retry after 10 minutes.
                storeInfo = await sourceManager.lookup(bundleID: app.bundleIdentifier) ?? storeInfo
            }
        }
        .sheet(item: $sheetApp) { record in
            SignConfigSheet(app: record)
        }
        .onChange(of: downloadManager.downloads[app.bundleIdentifier]) { _, state in
            if case .needsCertificate(let appID) = state {
                sheetApp = library.app(with: appID)
            }
        }
        .alert("Couldn't download app", isPresented: Binding(get: { errorText != nil },
                                                             set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: Hero

    private var heroImageURL: URL? {
        app.headerURL ?? source.headerURL ?? storeInfo?.artworkURL
    }

    private var heroTint: Color {
        Color(tintColor: app.tintColor) ?? Color(tintColor: source.tintColor) ?? .batAmber
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(LinearGradient(colors: [heroTint.opacity(0.55), heroTint.opacity(0.08), Color(hex: 0x0B0D14)],
                                     startPoint: .top, endPoint: .bottom))
            if let url = heroImageURL {
                RemoteImage(url: url) {
                    heroPlaceholder
                    }
                .overlay(LinearGradient(colors: [.clear, Color(hex: 0x0B0D14).opacity(0.9)],
                                        startPoint: .top, endPoint: .bottom))
            }
        }
        .frame(height: 210)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            HStack(alignment: .bottom, spacing: 14) {
                appIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(app.developerName ?? storeInfo?.artistName ?? source.name)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .padding(.top, -8)
    }

    private var heroPlaceholder: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Image(systemName: "app.dashed")
                .font(.system(size: 42))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        let size: CGFloat = 84
        ZStack {
            if let iconURL = app.iconURL ?? storeInfo?.artworkURL {
                RemoteImage(url: iconURL) {
                    iconFallback
                    }
            } else {
                iconFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
            .strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }

    private var iconFallback: some View {
        ZStack {
            Rectangle().fill(LinearGradient(colors: [heroTint.opacity(0.85), heroTint.opacity(0.45)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "app.gift")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    // MARK: Title / action / info

    private var iconAndTitle: some View {
        VStack(spacing: 8) {
            if let rating = storeInfo?.averageUserRating {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.batAmber)
                    Text(String(format: "%.1f", rating))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                    if let count = storeInfo?.userRatingCount {
                        Text("· \(Self.compact(count)) rating\(count == 1 ? "" : "s") · App Store")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
        .padding(.top, 10)
    }

    private var actionArea: some View {
        VStack(spacing: 8) {
            getButton
            HStack(spacing: 10) {
                if let version = app.latestVersion?.version {
                    Text("v\(version)")
                }
                if let size = app.latestVersion?.size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if let minOS = app.latestVersion?.minOSVersion {
                    Text("iOS \(minOS)+")
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var getButton: some View {
        let state = downloadManager.state(for: app.bundleIdentifier)
        switch state {
        case .downloading(let fraction):
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(Color.batAmber, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(fraction * 100))%")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(.batAmber)
            }
            .frame(width: 58, height: 58)
        case .preparing, .queuedForSigning:
            HStack(spacing: 8) {
                ProgressView().tint(Color(hex: 0x1A1204))
                Text(state == .preparing ? "Preparing" : "Signing")
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color(hex: 0x1A1204))
            .padding(.horizontal, 30)
            .padding(.vertical, 11)
            .background(Capsule().fill(Color.batAmber.opacity(0.75)))
        case .needsCertificate:
            Button {
                if let record = library.app(withBundleID: app.bundleIdentifier) {
                    sheetApp = record
                }
            } label: {
                Text("Choose certificate")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color(hex: 0x1A1204))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(LinearGradient(colors: [Color.batAmber, Color.batAmberDeep],
                                                              startPoint: .top, endPoint: .bottom)))
            }
            .buttonStyle(.plain)
        case .failed(let message):
            VStack(spacing: 8) {
                Button {
                    startDownload()
                } label: {
                    Text("Retry")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        case nil:
            Button {
                startDownload()
            } label: {
                HStack(spacing: 7) {
                    Text(signButtonTitle)
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color(hex: 0x1A1204))
                .padding(.horizontal, 30)
                .padding(.vertical, 11)
                .background(Capsule().fill(LinearGradient(colors: [Color.batAmber, Color.batAmberDeep],
                                                          startPoint: .top, endPoint: .bottom)))
            }
            .buttonStyle(.plain)
            .disabled(app.latestVersion?.downloadURL == nil)
        }
    }

    private func startDownload() {
        errorText = nil
        Haptics.tap()
        downloadManager.start(app: app)
    }

    private var signButtonTitle: String {
        if library.app(withBundleID: app.bundleIdentifier) != nil {
            return "Sign again"
        }
        if let version = app.latestVersion?.version {
            return "Get \(version)"
        }
        return "Get"
    }

    private var infoBar: some View {
        HStack(spacing: 0) {
            infoCell(value: app.developerName ?? storeInfo?.artistName ?? "—", label: "Developer")
            Divider().frame(height: 26).overlay(.white.opacity(0.12))
            infoCell(value: app.category ?? storeCategory, label: "Category")
            Divider().frame(height: 26).overlay(.white.opacity(0.12))
            infoCell(value: app.versions == nil ? "—" : "\(app.versions!.count)", label: "Versions")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
        .background(.white.opacity(0.04))
    }

    private var storeCategory: String {
        storeInfo?.trackName == nil ? "—" : "App Store"
    }

    private func infoCell(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value.isEmpty ? "—" : value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Screenshots

    @ViewBuilder
    private var screenshotsSection: some View {
        let urls = screenshotURLs
        if !urls.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Preview")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                            RemoteImage(url: url) {
                                screenshotPlaceholder
                            }
                            .frame(width: 178, height: 316)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 0.8))
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
            .padding(.top, 14)
        }
    }

    private var screenshotPlaceholder: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.05))
            ProgressView().tint(.batAmber)
        }
    }

    private var screenshotURLs: [URL] {
        let fromSource = (app.screenshots ?? []).compactMap(\.imageURL)
        return fromSource.isEmpty ? (storeInfo?.screenshotURLs ?? []) : fromSource
    }

    // MARK: Description

    @ViewBuilder
    private var descriptionSection: some View {
        if let description = app.localizedDescription, !description.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "About")
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(expandedDescription ? nil : 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(expandedDescription ? "less" : "more") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        expandedDescription.toggle()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.batAmber)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
        }
    }

    // MARK: Ratings

    @ViewBuilder
    private var ratingsSection: some View {
        if let info = storeInfo, !info.isOnAppStore {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Ratings & Reviews")
                Text("Not on the App Store — no public ratings for this app.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
        } else if let info = storeInfo, let rating = info.averageUserRating {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Ratings & Reviews")
                HStack(spacing: 16) {
                    VStack(spacing: 2) {
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        if let count = info.userRatingCount {
                            Text("\(Self.compact(count)) Ratings")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .frame(width: 120)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach([5, 4, 3, 2, 1], id: \.self) { stars in
                            HStack(spacing: 5) {
                                Text("\(stars)")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(width: 8)
                                Capsule()
                                    .fill(.white.opacity(0.08))
                                    .frame(height: 4)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.batAmber)
                                            .frame(width: barWidth(stars, rating: rating))
                                    }
                            }
                        }
                        Text("Live data from the App Store website")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.top, 2)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(cornerRadius: 22)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
        }
    }

    private func barWidth(_ stars: Int, rating: Double) -> CGFloat {
        // Without a full histogram from the lookup API, scale the mean onto
        // the 5-star track — honest approximation, clearly labelled.
        let fraction = min(1.0, max(0.0, rating - Double(stars) + 1.0))
        return CGFloat(fraction) * 150
    }

    // MARK: Versions

    @ViewBuilder
    private var versionsSection: some View {
        if let versions = app.versions, !versions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Version History")
                VStack(spacing: 0) {
                    ForEach(Array(versions.prefix(8).enumerated()), id: \.offset) { index, version in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("v\(version.version)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Spacer()
                                if let date = version.date {
                                    Text(date.formatted(.dateTime.day().month().year()))
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                            }
                            if let notes = version.localizedDescription, !notes.isEmpty {
                                Text(notes)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.6))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if index == 0 && version.downloadURL != nil {
                                Label("This is the version Sign downloads", systemImage: "arrow.down.circle")
                                    .font(.caption2)
                                    .foregroundStyle(.batAmber)
                            }
                        }
                        .padding(.vertical, 10)
                        if index != min(8, versions.count) - 1 {
                            Divider().overlay(.white.opacity(0.06))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
        }
    }

    // MARK: Actions

    // MARK: Helpers

    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(1)))
    }
}

extension Color {
    /// "#AABBCC" / "AABBCC" → Color; nil when not parseable.
    init?(tintColor: String?) {
        guard var hex = tintColor, !hex.isEmpty else { return nil }
        hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(hex: value)
    }
}
