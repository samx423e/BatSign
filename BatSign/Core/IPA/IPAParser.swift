//
//  IPAParser.swift
//  BatSign
//
//  Extracts app metadata, icons, and structure from an .ipa without
//  unpacking the whole archive.
//

import Foundation
import UIKit

struct AppRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var bundleID: String
    var version: String
    var build: String
    var minimumOS: String
    var bundleFileName: String
    var executableName: String
    var architectures: [String]
    var sizeBytes: Int64
    var hasExtensions: Bool
    var hasWatchApp: Bool
    var hasIcon: Bool
    var addedAt: Date

    var fileURL: URL { Paths.apps.appendingPathComponent(id.uuidString).appendingPathComponent("app.ipa") }
    var iconURL: URL { Paths.apps.appendingPathComponent(id.uuidString).appendingPathComponent("icon.png") }

    var versionLabel: String {
        build.isEmpty ? version : "\(version) (\(build))"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: AppRecord, rhs: AppRecord) -> Bool { lhs.id == rhs.id }
}

enum IPAParser {
    struct ParseResult {
        let record: AppRecord
        let iconData: Data?
    }

    static func parse(ipaURL: URL) throws -> ParseResult {
        let reader = try ZipReader(url: ipaURL)
        let size = (try? FileManager.default.attributesOfItem(atPath: ipaURL.path)[.size] as? Int64) ?? 0

        // Info.plist inside Payload/<App>.app/
        guard let infoEntry = reader.firstEntry(matching: { entry in
            !entry.isDirectory && entry.name.hasPrefix("Payload/") &&
            entry.name.hasSuffix(".app/Info.plist") &&
            entry.name.dropFirst("Payload/".count).dropLast("/Info.plist".count).contains(".app") &&
            !entry.name.dropFirst("Payload/".count).dropLast("/Info.plist".count).contains("/")
        }) else {
            throw ParseError.missingInfoPlist
        }

        let bundleFileName = infoEntry.name
            .dropFirst("Payload/".count)
            .dropLast("/Info.plist".count)
            .replacingOccurrences(of: ".app", with: "")

        let infoData = try reader.readData(infoEntry)
        guard let plist = try PropertyListSerialization.propertyList(
            from: infoData, options: [], format: nil) as? [String: Any] else {
            throw ParseError.badInfoPlist
        }

        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? bundleFileName
        let bundleID = plist["CFBundleIdentifier"] as? String ?? "unknown"
        let version = plist["CFBundleShortVersionString"] as? String ?? ""
        let build = plist["CFBundleVersion"] as? String ?? ""
        let minOS = plist["MinimumOSVersion"] as? String ?? ""
        let executable = plist["CFBundleExecutable"] as? String ?? bundleFileName

        // Nested structure detection (plugins / watch apps / PlugIns directory).
        let appPrefix = "Payload/\(bundleFileName).app/"
        let allNames = reader.entries.map { $0.name }
        let hasExtensions = allNames.contains { $0.hasPrefix("\(appPrefix)PlugIns/") }
            || allNames.contains { $0.hasPrefix("\(appPrefix)Extensions/") }
        let hasWatchApp = allNames.contains { $0.hasPrefix("\(appPrefix)Watch/") }
            || allNames.contains { $0.hasPrefix("\(appPrefix)WatchKit/") }

        let architectures = probeArchitectures(reader: reader,
                                               appPrefix: appPrefix,
                                               executable: executable)

        // Icon: prefer the largest loose PNG the app ships.
        let iconData = extractLargestIcon(reader: reader, plist: plist, appPrefix: appPrefix)

        let record = AppRecord(id: UUID(),
                               name: name,
                               bundleID: bundleID,
                               version: version,
                               build: build,
                               minimumOS: minOS,
                               bundleFileName: bundleFileName,
                               executableName: executable,
                               architectures: architectures,
                               sizeBytes: size ?? 0,
                               hasExtensions: hasExtensions,
                               hasWatchApp: hasWatchApp,
                               hasIcon: iconData != nil,
                               addedAt: Date())
        return ParseResult(record: record, iconData: iconData)
    }

    enum ParseError: LocalizedError {
        case missingInfoPlist
        case badInfoPlist

        var errorDescription: String? {
            switch self {
            case .missingInfoPlist: return "No Payload/<App>.app/Info.plist found — is this a valid IPA?"
            case .badInfoPlist: return "Info.plist inside the IPA could not be parsed."
            }
        }
    }

    // MARK: Icons

    private static func extractLargestIcon(reader: ZipReader, plist: [String: Any], appPrefix: String) -> Data? {
        var candidates: Set<String> = []

        func addIconNames(from dict: [String: Any]?) {
            guard let dict else { return }
            if let files = dict["CFBundleIconFiles"] as? [Any] {
                for f in files { if let s = f as? String { candidates.insert(s) } }
            }
            if let n = dict["CFBundleIconName"] as? String { candidates.insert(n) }
        }

        addIconNames(from: plist["CFBundleIcons"] as? [String: Any])
        if let ipad = plist["CFBundleIcons~ipad"] as? [String: Any] {
            addIconNames(from: ipad)
        }
        if let legacy = plist["CFBundleIconFiles"] as? [Any] {
            for f in legacy { if let s = f as? String { candidates.insert(s) } }
        }
        if let single = plist["CFBundleIconFile"] as? String { candidates.insert(single) }

        // Build lookup of loose PNG entries in the app bundle.
        let pngEntries = reader.entries.filter {
            !$0.isDirectory && $0.name.hasPrefix(appPrefix) &&
            !$0.name.dropFirst(appPrefix.count).contains("/") && $0.name.hasSuffix(".png")
        }

        var best: ZipEntry?
        for candidate in candidates {
            for entry in pngEntries where entry.uncompressedSize > (best?.uncompressedSize ?? 0) {
                let base = (entry.name as NSString).lastPathComponent
                    .replacingOccurrences(of: ".png", with: "")
                let stripped = base
                    .replacingOccurrences(of: "@3x", with: "")
                    .replacingOccurrences(of: "@2x", with: "")
                    .replacingOccurrences(of: "~ipad", with: "")
                    .replacingOccurrences(of: "~iphone", with: "")
                if stripped == candidate {
                    best = entry
                }
            }
        }
        // Fallback: apps that ship icons as loose PNGs with unexpected names
        // (or only largest-square files). Decode the biggest few and take the
        // first square image large enough to be an app icon.
        if best == nil {
            let biggest = pngEntries.sorted { $0.uncompressedSize > $1.uncompressedSize }.prefix(8)
            for entry in biggest {
                guard let data = try? reader.readData(entry),
                      let image = UIImage(data: data) else { continue }
                let width = image.size.width * image.scale
                let height = image.size.height * image.scale
                if width == height, width >= 100 {
                    best = entry
                    break
                }
            }
        }

        guard let iconEntry = best, let data = try? reader.readData(iconEntry) else { return nil }
        return data
    }

    // MARK: Mach-O probe

    private static func probeArchitectures(reader: ZipReader, appPrefix: String, executable: String) -> [String] {
        guard let entry = reader.firstEntry(matching: { $0.name == "\(appPrefix)\(executable)" }),
              let header = try? reader.readData(entry),
              header.count >= 8 else { return [] }

        let magic = readU32(header, 0)
        guard magic == 0xFEED_FACF || magic == 0xCFFA_EDFE else { return [] }
        let cputype = readU32(header, 4)
        let ncmds = readU32(header, 16)

        var archs: [String] = []
        switch cputype {
        case 0x0100_000C: archs.append("arm64")
        case 0x0000_000C: archs.append("armv7")
        case 0x0100_0007: archs.append("x86_64")
        default: archs.append(String(format: "cpu 0x%08X", cputype))
        }

        // Fat binaries: magic 0xCAFEBABE → arm64 slice usually first for iOS.
        if magic == 0xBEBA_FECA || readU32(header, 0) == 0xCAFEBABE {
            archs.append("fat")
        }

        // Walk load commands for LC_FILESET (multi-arch containers used by iOS apps).
        if magic == 0xFEED_FACF, ncmds > 0 && ncmds < 4096, header.count >= 32 {
            var offset = 32
            for _ in 0..<ncmds {
                guard offset + 8 <= header.count else { break }
                let cmd = readU32(header, offset)
                let cmdSize = readU32(header, offset + 4)
                if cmd == 0x62 { // LC_FILESET
                    archs.append("fileset")
                    break
                }
                if cmdSize == 0 { break }
                offset += Int(cmdSize)
            }
        }
        return archs
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        guard i + 3 < data.endIndex else { return 0 }
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }
}
