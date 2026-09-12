//
//  DiscoverView.swift
//  BatSign
//
//  User-added sources (AltStore JSON format) and the store app grid.
//  App pages mirror an App Store product page.
//

import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var sourceManager: SourceManager

    @State private var showAddSource = false
    @State private var showImportSourceFile = false
    @State private var errorText: String?
    @State private var searchText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if sourceManager.sources.isEmpty {
                    EmptyState(icon: "sparkles.rectangle.stack",
                               title: "No sources yet",
                               message: "Add an AltStore-format source URL to browse and sign apps right here — like an App Store on your device.")
                } else {
                    sourcesCard
                    appGrid
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 30)
        }
        .background(.clear)
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search apps")
        .refreshable {
            await sourceManager.refreshAll()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showAddSource = true
                    } label: {
                        Label("Add source URL", systemImage: "link")
                    }
                    Button {
                        showImportSourceFile = true
                    } label: {
                        Label("Import source .json", systemImage: "doc.badge.arrow.up")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSource) {
            AddSourceSheet()
        }
        .sheet(isPresented: $showImportSourceFile) {
            DocumentPicker(contentTypes: [.json, .data], title: "Import source JSON") { urls in
                showImportSourceFile = false
                guard let url = urls.first else { return }
                Task { @MainActor in
                    do {
                        let data = try Data(contentsOf: url)
                        let source = try AltSource.decode(data)
                        try await SourceManager.shared.addSourceData(name: source.name,
                                                                     iconURL: source.iconURL,
                                                                     headerURL: source.headerURL,
                                                                     tintColor: source.tintColor,
                                                                     apps: source.apps)
                        Haptics.success()
                    } catch {
                        errorText = error.localizedDescription
                        Haptics.error()
                    }
                }
            } onCancel: {
                showImportSourceFile = false
            }
            .ignoresSafeArea()
        }
        .navigationDestination(for: SourceNavID.self) { value in
            SourceDetailView(sourceID: value.id)
        }
        .navigationDestination(for: StoreAppNav.self) { value in
            if let stored = sourceManager.sources.first(where: { stored in
                (sourceManager.appsBySource[stored.id] ?? []).contains { $0.bundleIdentifier == value.appBundleID }
            }), let app = (sourceManager.appsBySource[stored.id] ?? []).first(where: { $0.bundleIdentifier == value.appBundleID }) {
                StoreAppPageView(source: stored, app: app)
            }
        }
        .alert("Source error", isPresented: Binding(get: { errorText != nil },
                                                    set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Your sources")
                Spacer()
                if sourceManager.isRefreshing {
                    ProgressView().tint(.batAmber)
                }
            }
            .padding(.horizontal, 6)

            VStack(spacing: 0) {
                ForEach(sourceManager.sources) { stored in
                    NavigationLink(value: SourceNavID(id: stored.id)) {
                        HStack(spacing: 12) {
                            SourceIcon(url: stored.iconURL, tint: Color(tintColor: stored.tintColor) ?? .batAmber)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stored.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if let error = stored.error {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.danger)
                                        .lineLimit(1)
                                } else {
                                    Text("\(stored.appCount) app\(stored.appCount == 1 ? "" : "s") · \(stored.host)")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.45))
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            sourceManager.remove(stored)
                        } label: {
                            Label("Remove source", systemImage: "trash")
                        }
                    }
                    if stored.id != sourceManager.sources.last?.id {
                        Divider().overlay(.white.opacity(0.06))
                    }
                }
            }
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 18)
        }
    }

    @ViewBuilder
    private var appGrid: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = sourceManager.allApps().filter { item in
            query.isEmpty
                || item.app.name.lowercased().contains(query)
                || item.app.bundleIdentifier.lowercased().contains(query)
                || (item.app.subtitle?.lowercased().contains(query) ?? false)
                || (item.app.developerName?.lowercased().contains(query) ?? false)
        }
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "All apps")
                    .padding(.horizontal, 6)
                if all.isEmpty {
                    EmptyState(icon: "magnifyingglass",
                               title: "No matches",
                               message: "No app in your sources matches the search.")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 14)], spacing: 14) {
                    ForEach(all, id: \.app.bundleIdentifier) { item in
                        NavigationLink(value: StoreAppNav(appBundleID: item.app.bundleIdentifier)) {
                            StoreAppCard(app: item.app,
                                         storeInfo: sourceManager.appStoreInfo(for: item.app.bundleIdentifier))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
        }
    }
}

struct SourceNavID: Hashable { let id: UUID }
struct StoreAppNav: Hashable { let appBundleID: String }

// MARK: - Source detail (apps within one source)

struct SourceDetailView: View {
    @EnvironmentObject private var sourceManager: SourceManager

    let sourceID: UUID

    var body: some View {
        Group {
            if let stored = sourceManager.sources.first(where: { $0.id == sourceID }),
               let apps = sourceManager.appsBySource[sourceID] {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(apps) { app in
                            NavigationLink(value: StoreAppNav(appBundleID: app.bundleIdentifier)) {
                                HStack(spacing: 12) {
                                    StoreAppIcon(app: app, size: 52)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text(app.subtitle ?? app.developerName ?? app.bundleIdentifier)
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.5))
                                            .lineLimit(1)
                                        if let rating = sourceManager.appStoreInfo(for: app.bundleIdentifier)?.averageUserRating {
                                            HStack(spacing: 3) {
                                                Image(systemName: "star.fill").font(.caption2)
                                                Text(String(format: "%.1f", rating))
                                            }
                                            .foregroundStyle(.batAmber)
                                        }
                                    }
                                    Spacer()
                                    Text("View")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color(hex: 0x1A1204))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(Capsule().fill(Color.batAmber))
                                }
                                .padding(12)
                            }
                            .buttonStyle(.plain)
                            .glassSurface(cornerRadius: 20)
                        }
                    }
                    .padding(18)
                    .padding(.bottom, 30)
                }
                .background(AuroraBackground())
                .navigationTitle(stored.name)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                EmptyState(icon: "questionmark.folder", title: "Source unavailable", message: "Refresh from the Discover tab.")
            }
        }
        .background(.clear)
        .navigationDestination(for: StoreAppNav.self) { value in
            if let stored = sourceManager.sources.first(where: { $0.id == sourceID }),
               let app = (sourceManager.appsBySource[sourceID] ?? []).first(where: { $0.bundleIdentifier == value.appBundleID }) {
                StoreAppPageView(source: stored, app: app)
            }
        }
    }
}

// MARK: - Cards & icons

struct StoreAppCard: View {
    let app: AltApp
    let storeInfo: AppStoreInfo?

    var body: some View {
        VStack(spacing: 9) {
            StoreAppIcon(app: app, size: 62)
            VStack(spacing: 2) {
                Text(app.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(app.subtitle ?? app.developerName ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            if let rating = storeInfo?.averageUserRating {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill").font(.caption2)
                    Text(String(format: "%.1f", rating)).font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.batAmber)
            } else {
                Text(" ")
                    .font(.caption2)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 20)
    }
}

struct StoreAppIcon: View {
    let app: AltApp
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            if let url = app.iconURL {
                RemoteImage(url: url) {
                    placeholder
                    }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .strokeBorder(.white.opacity(0.14), lineWidth: 0.8))
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.07))
            Image(systemName: "app.gift")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

struct SourceIcon: View {
    let url: URL?
    let tint: Color

    var body: some View {
        ZStack {
            if let url {
                RemoteImage(url: url) {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 0.8))
    }

    private var fallback: some View {
        ZStack {
            Rectangle().fill(LinearGradient(colors: [tint.opacity(0.8), tint.opacity(0.4)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "sparkles.rectangle.stack")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - Add source sheet

struct AddSourceSheet: View {
    @EnvironmentObject private var sourceManager: SourceManager
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var working = false
    @State private var errorText: String?

    /// Public AltStore-format sources, the same well-known ones this class of
    /// signer ships with.
    private let suggestions = [
        ("SideStore Community", "https://community-apps.sidestore.io/sidecommunity.json"),
        ("Crystalline", "https://alt.crystall1ne.dev"),
        ("OatmealDome", "https://altstore.oatmealdome.me/"),
        ("Manic EMU", "https://apps.manicemu.site/altstore"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Source URL")
                        GlassTextField(placeholder: "https://example.com/source.json",
                                       icon: "link", text: $urlText)
                    }

                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    }

                    Button {
                        add()
                    } label: {
                        Label(working ? "Fetching source…" : "Add source",
                              systemImage: working ? "hourglass" : "plus.circle.fill")
                    }
                    .buttonStyle(PrimaryGlassButtonStyle())
                    .disabled(urlText.isEmpty || working)

                    VStack(spacing: 6) {
                        SectionHeader(title: "Popular sources")
                        VStack(spacing: 0) {
                            ForEach(suggestions, id: \.1) { name, url in
                                Button {
                                    urlText = url
                                    add()
                                } label: {
                                    HStack {
                                        Image(systemName: "sparkles")
                                            .foregroundStyle(.batAmber)
                                        Text(name)
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Image(systemName: "plus.circle")
                                            .foregroundStyle(.white.opacity(0.35))
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 11)
                                }
                                .buttonStyle(.plain)
                                if url != suggestions.last?.1 {
                                    Divider().overlay(.white.opacity(0.06))
                                }
                            }
                        }
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    }

                    Text("Sources are AltStore-format JSON files. Anyone can host one; you choose whom to trust.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                }
                .padding(18)
            }
            .background(AuroraBackground())
            .navigationTitle("Add source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func add() {
        guard !urlText.isEmpty else { return }
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let normalized = URLComponents(url: SourceManager.normalizeSourceURL(url),
                                             resolvingAgainstBaseURL: false),
              normalized.host != nil else {
            errorText = "That doesn't look like a valid URL."
            return
        }
        working = true
        errorText = nil
        Task { @MainActor in
            defer { working = false }
            do {
                try await sourceManager.addSource(url: url)
                dismiss()
            } catch {
                errorText = error.localizedDescription
                Haptics.error()
            }
        }
    }
}
