import CoreServices
import Foundation
import Security

/// Discovers installed `.app` bundles and reads their metadata without loading them.
struct ApplicationScanner: Sendable {
    var searchDirectories: [String]

    static let defaultDirectories = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"]

    init(searchDirectories: [String] = ApplicationScanner.defaultDirectories) {
        self.searchDirectories = searchDirectories
    }

    /// Finds app bundles up to two levels deep (e.g. /Applications/Utilities/*.app). Never enters bundles.
    func findApplicationBundles() -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func visit(_ directory: String, depth: Int) {
            _ = DirectoryReader.read(path: directory) { entry in
                guard entry.hasValidName, !entry.name.hasPrefix(".") else { return }
                let path = directory + "/" + entry.name
                let isDirectoryLike = entry.kind == .directory
                if entry.name.lowercased().hasSuffix(".app") {
                    if isDirectoryLike || entry.kind == .symlink {
                        let real = SecurityUtils.realPath(path) ?? path
                        if seen.insert(real).inserted { found.append(path) }
                    }
                } else if isDirectoryLike && depth < 2 {
                    visit(path, depth: depth + 1)
                }
            }
        }
        for directory in searchDirectories { visit(directory, depth: 0) }
        return found
    }

    func scanApplications() -> [ApplicationInfo] {
        findApplicationBundles().compactMap { Self.readApplication(at: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads Info.plist, architecture and signing identity (no full signature validation — see `validateSignature`).
    static func readApplication(at path: String) -> ApplicationInfo? {
        let plistPath = path + "/Contents/Info.plist"
        let plist: [String: Any]
        if let data = FileManager.default.contents(atPath: plistPath),
           let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            plist = parsed
        } else {
            plist = [:]
        }
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = (plist["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (plist["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? fileName
        let executable = plist["CFBundleExecutable"] as? String
        var architectures: [CPUArchitecture] = []
        if let executable {
            architectures = MachOInspector.architectures(ofFileAt: path + "/Contents/MacOS/" + executable)
        }
        let signing = signingIdentity(for: path)
        let isSystem = SecurityUtils.isPath(path.lowercased(), within: "/system")
        let receipt = FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")

        return ApplicationInfo(
            name: name,
            path: path,
            bundleIdentifier: plist["CFBundleIdentifier"] as? String,
            version: plist["CFBundleShortVersionString"] as? String,
            build: plist["CFBundleVersion"] as? String,
            minimumSystemVersion: plist["LSMinimumSystemVersion"] as? String,
            copyright: plist["NSHumanReadableCopyright"] as? String,
            executableName: executable,
            architectures: architectures,
            developer: isSystem ? "Apple" : signing.developer,
            teamIdentifier: signing.teamID,
            signature: signing.status,
            isAppStoreApp: receipt,
            isSystemApp: isSystem,
            lastUsed: lastUsedDate(for: path))
    }

    struct SigningIdentity: Sendable {
        var developer: String?
        var teamID: String?
        var status: CodeSignatureStatus
    }

    /// Reads the signing certificate summary (fast; doesn't hash the bundle).
    static func signingIdentity(for path: String) -> SigningIdentity {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return SigningIdentity(status: .unavailable("Could not read the bundle"))
        }
        var infoRef: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        guard status == errSecSuccess, let info = infoRef as? [String: Any] else {
            return SigningIdentity(status: .unavailable("OSStatus \(status)"))
        }
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        guard info[kSecCodeInfoIdentifier as String] != nil else {
            return SigningIdentity(teamID: nil, status: .unsigned)
        }
        if certificates.isEmpty || flags & 0x0002 != 0 { // kSecCodeSignatureAdhoc
            return SigningIdentity(teamID: teamID, status: .adHoc)
        }
        let summary = SecCertificateCopySubjectSummary(certificates[0]) as String? ?? "Unknown authority"
        return SigningIdentity(developer: developerName(fromCertificateSummary: summary), teamID: teamID, status: .signed(authority: summary))
    }

    /// "Developer ID Application: Google LLC (EQHXZ8M8AV)" → "Google LLC".
    static func developerName(fromCertificateSummary summary: String) -> String? {
        if summary == "Software Signing" || summary.hasPrefix("Apple ") && !summary.contains(":") {
            return summary == "Apple Mac OS Application Signing" ? nil : "Apple"
        }
        var name = summary
        if let colon = name.range(of: ": ") { name = String(name[colon.upperBound...]) }
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) { name = String(name[..<open.lowerBound]) }
        return name.isEmpty ? nil : name
    }

    /// Full signature validation (hashes the whole bundle — can take seconds for large apps).
    static func validateSignature(for path: String) -> CodeSignatureStatus {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return .unavailable("Could not read the bundle") }
        let identity = signingIdentity(for: path)
        let result = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil)
        switch result {
        case errSecSuccess:
            if case .signed(let authority) = identity.status { return .valid(authority: authority) }
            return identity.status
        case OSStatus(errSecCSUnsigned):
            return .unsigned
        default:
            let message = SecCopyErrorMessageString(result, nil) as String? ?? "OSStatus \(result)"
            return .invalid(message)
        }
    }

    /// Last-opened date from Spotlight metadata, when Spotlight has it.
    static func lastUsedDate(for path: String) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, URL(fileURLWithPath: path) as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Paths in ~/Library commonly holding an app's data, matched by bundle id and name.
    static func dataLocations(for app: ApplicationInfo, home: String = NSHomeDirectory()) -> [(kind: ApplicationStorageBreakdown.Entry.Kind, path: String)] {
        var result: [(ApplicationStorageBreakdown.Entry.Kind, String)] = []
        let library = home + "/Library"
        let bundleID = app.bundleIdentifier
        var names: [String] = []
        if let bundleID { names.append(bundleID) }
        if !names.contains(app.name) { names.append(app.name) }
        for name in names {
            result.append((.data, "\(library)/Application Support/\(name)"))
            result.append((.cache, "\(library)/Caches/\(name)"))
            result.append((.logs, "\(library)/Logs/\(name)"))
        }
        if let bundleID {
            result.append((.containers, "\(library)/Containers/\(bundleID)"))
            result.append((.cache, "\(library)/HTTPStorages/\(bundleID)"))
            result.append((.preferences, "\(library)/Preferences/\(bundleID).plist"))
            result.append((.savedState, "\(library)/Saved Application State/\(bundleID).savedState"))
        }
        if let team = app.teamIdentifier {
            // Group containers are named "<TEAMID>.something"
            _ = DirectoryReader.read(path: "\(library)/Group Containers") { entry in
                if entry.kind == .directory && entry.name.hasPrefix(team + ".") {
                    result.append((.containers, "\(library)/Group Containers/\(entry.name)"))
                }
            }
        }
        var seen = Set<String>()
        return result.filter { FileManager.default.fileExists(atPath: $0.1) && seen.insert($0.1.lowercased()).inserted }
            .map { (kind: $0.0, path: $0.1) }
    }
}

/// Reads CPU architectures from a Mach-O executable's header (thin or universal).
enum MachOInspector {
    static func architectures(ofFileAt path: String) -> [CPUArchitecture] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return [] }
        return architectures(fromHeader: data)
    }

    static func architectures(fromHeader data: Data) -> [CPUArchitecture] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return [] }
        func bigEndian32(_ offset: Int) -> UInt32 {
            guard offset + 4 <= bytes.count else { return 0 }
            return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        func littleEndian32(_ offset: Int) -> UInt32 {
            guard offset + 4 <= bytes.count else { return 0 }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        let magic = bigEndian32(0)
        switch magic {
        case 0xCAFE_BABE, 0xCAFE_BABF: // FAT_MAGIC / FAT_MAGIC_64 (big-endian)
            let count = Int(bigEndian32(4))
            guard count > 0 && count < 32 else { return [] } // also rejects Java class files
            let entrySize = magic == 0xCAFE_BABE ? 20 : 32
            var result: [CPUArchitecture] = []
            for index in 0..<count {
                let arch = architecture(cpuType: bigEndian32(8 + index * entrySize))
                if !result.contains(arch) { result.append(arch) }
            }
            return result
        case 0xCFFA_EDFE, 0xCEFA_EDFE: // MH_MAGIC_64 / MH_MAGIC stored little-endian
            return [architecture(cpuType: littleEndian32(4))]
        default:
            return []
        }
    }

    static func architecture(cpuType: UInt32) -> CPUArchitecture {
        switch cpuType {
        case 0x0100_000C: return .arm64
        case 0x0100_0007: return .x86_64
        case 0x0000_0007: return .i386
        case 0x0000_0012, 0x0100_0012: return .powerPC
        default: return .unknown
        }
    }
}
