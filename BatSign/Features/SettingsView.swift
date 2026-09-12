//
//  SettingsView.swift
//  BatSign
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: AppLibrary
    @EnvironmentObject private var certManager: CertificateManager
    @EnvironmentObject private var jobQueue: JobQueue
    @EnvironmentObject private var notificationHub: NotificationHub

    @AppStorage("preventSleep") private var preventSleep = true
    @AppStorage("systemNotifications") private var systemNotifications = true
    @AppStorage("autoSign") private var autoSign = true
    @AppStorage("zipLevel") private var zipLevel = 6

    @State private var version = ""
    @State private var confirmClearJobs = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                madeByHeader

                VStack(spacing: 6) {
                    SectionHeader(title: "Signing")
                    VStack(spacing: 14) {
                        GlassToggle(title: "Keep device awake while signing",
                                    subtitle: "Prevents mid-sign suspension on large apps",
                                    isOn: $preventSleep)
                        Divider().overlay(.white.opacity(0.08))
                        GlassToggle(title: "Auto-sign after import",
                                    subtitle: "Opens the Sign sheet immediately — SignOS-style fast flow",
                                    isOn: $autoSign)
                        Divider().overlay(.white.opacity(0.08))
                        VStack(alignment: .leading, spacing: 8) {
                            Text("IPA packing")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                            Text("Fast finishes big apps quicker; Maximum makes smaller downloads.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.45))
                            Picker("Packing", selection: $zipLevel) {
                                Text("Fast").tag(1)
                                Text("Balanced").tag(6)
                                Text("Maximum").tag(9)
                            }
                            .pickerStyle(.segmented)
                            .colorMultiply(.batAmber)
                        }
                    }
                    .padding(14)
                    .glassSurface(cornerRadius: 22)
                }

                VStack(spacing: 6) {
                    SectionHeader(title: "Notifications")
                    VStack(spacing: 14) {
                        GlassToggle(title: "Notifications",
                                    subtitle: "Instant banners, even while BatSign is open",
                                    isOn: $systemNotifications)
                        Divider().overlay(.white.opacity(0.08))
                        Button {
                            notificationHub.requestAuthorization()
                            Haptics.tap()
                        } label: {
                            HStack {
                                Text("Re-check system permission")
                                    .font(.subheadline)
                                    .foregroundStyle(.batAmber)
                                Spacer()
                                Image(systemName: notificationHub.systemDeliveryEnabled ? "checkmark.circle.fill" : "bell.slash")
                                    .foregroundStyle(notificationHub.systemDeliveryEnabled ? .success : .white.opacity(0.4))
                            }
                        }
                    }
                    .padding(14)
                    .glassSurface(cornerRadius: 22)
                }

                storageCard

                VStack(spacing: 6) {
                    SectionHeader(title: "How installing works")
                    VStack(alignment: .leading, spacing: 10) {
                        installStep("1", text: "Sign and share the .ipa from BatSign.")
                        installStep("2", text: "Install it with SideStore, Feather, AltStore, eSign, or Xcode — any installer that owns your certificate.")
                        installStep("3", text: "BatSign focuses on signing; installation always needs a provisioning identity valid for your device.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassSurface(cornerRadius: 22)
                }

                VStack(spacing: 6) {
                    SectionHeader(title: "About")
                    VStack(spacing: 0) {
                        InfoRow(label: "Version", value: version.isEmpty ? "1.0.0" : version)
                        Divider().overlay(.white.opacity(0.08))
                        InfoRow(label: "Signing engine", value: "zsign (vendored, MIT)")
                        Divider().overlay(.white.opacity(0.08))
                        InfoRow(label: "Crypto", value: "OpenSSL 3.5 (Apache-2.0)")
                        Divider().overlay(.white.opacity(0.08))
                        InfoRow(label: "Tweak unpacking", value: "libzstd (BSD)")
                        Divider().overlay(.white.opacity(0.08))
                        InfoRow(label: "Telemetry", value: "None. Everything is local.")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassSurface(cornerRadius: 22)
                }
            }
            .padding(18)
            .padding(.bottom, 30)
        }
        .navigationTitle("Settings")
        .background(.clear)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        }
        .onChange(of: systemNotifications) { _, enabled in
            notificationHub.systemDeliveryEnabled = enabled
            if enabled {
                notificationHub.requestAuthorization()
            }
        }
        .confirmationDialog("Delete all finished job files?", isPresented: $confirmClearJobs, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                jobQueue.clearFinished()
                Haptics.success()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var madeByHeader: some View {
        VStack(spacing: 4) {
            Text("Made By @ihateios")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [Color.batAmber, Color.white, Color.batAmber],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .shadow(color: Color.batAmber.opacity(0.65), radius: 12)
                .shadow(color: Color.batAmberDeep.opacity(0.35), radius: 26)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassSurface(cornerRadius: 22)
    }

    private var storageCard: some View {
        VStack(spacing: 6) {
            SectionHeader(title: "Storage")
            VStack(spacing: 0) {
                InfoRow(label: "Apps", value: "\(library.apps.count)")
                Divider().overlay(.white.opacity(0.08))
                InfoRow(label: "Certificates", value: "\(certManager.certificates.count)")
                Divider().overlay(.white.opacity(0.08))
                InfoRow(label: "Jobs", value: "\(jobQueue.jobs.count)")
                Divider().overlay(.white.opacity(0.08))
                InfoRow(label: "Library size",
                        value: ByteCountFormatter.string(fromByteCount: library.totalBytesUsed(), countStyle: .file))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassSurface(cornerRadius: 22)

            Button {
                confirmClearJobs = true
            } label: {
                Label("Clear finished job files", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .glassSurface(cornerRadius: 18)
        }
    }

    private func installStep(_ number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.batAmber)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.batAmber.opacity(0.15)))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
