import Foundation

enum CodeSignatureStatus: Sendable, Hashable {
    case notChecked
    case signed(authority: String)
    case adHoc
    case unsigned
    case valid(authority: String)
    case invalid(String)
    case unavailable(String)

    var label: String {
        switch self {
        case .notChecked: return "Not checked"
        case .signed(let authority): return "Signed — \(authority)"
        case .adHoc: return "Ad-hoc signed (no developer identity)"
        case .unsigned: return "Not signed"
        case .valid(let authority): return "Valid — \(authority)"
        case .invalid(let reason): return "Invalid — \(reason)"
        case .unavailable(let reason): return "Unavailable — \(reason)"
        }
    }

    var symbolName: String {
        switch self {
        case .valid, .signed: return "checkmark.seal"
        case .adHoc: return "seal"
        case .unsigned, .invalid: return "exclamationmark.triangle"
        case .notChecked, .unavailable: return "questionmark.circle"
        }
    }
}

enum CPUArchitecture: String, Sendable, Hashable {
    case arm64 = "Apple silicon"
    case x86_64 = "Intel"
    case i386 = "Intel 32-bit"
    case powerPC = "PowerPC"
    case unknown = "Unknown"
}

/// Static information about an installed application bundle.
struct ApplicationInfo: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var bundleIdentifier: String?
    var version: String?
    var build: String?
    var minimumSystemVersion: String?
    var copyright: String?
    var executableName: String?
    var architectures: [CPUArchitecture]
    /// Developer name derived from the signing certificate (or "Apple").
    var developer: String?
    var teamIdentifier: String?
    var signature: CodeSignatureStatus
    var isAppStoreApp: Bool
    var isSystemApp: Bool
    var lastUsed: Date?
    var installLocation: String { (path as NSString).deletingLastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }

    var architectureLabel: String {
        if architectures.isEmpty { return "Unknown" }
        if architectures.contains(.arm64) && architectures.contains(.x86_64) { return "Universal" }
        return architectures.map(\.rawValue).joined(separator: ", ")
    }

    var displayVersion: String {
        switch (version, build) {
        case let (v?, b?) where v != b: return "\(v) (\(b))"
        case let (v?, _): return v
        case let (nil, b?): return b
        default: return "—"
        }
    }
}

/// Live resource usage of an application's processes (the app plus helpers inside its bundle).
struct ApplicationUsage: Sendable, Equatable {
    var processCount: Int
    /// Sum of physical memory footprints, like Activity Monitor's "Memory" column.
    var memoryBytes: Int64
    /// Sum of CPU% (100% = one full core).
    var cpuPercent: Double
    /// Processes whose usage macOS didn't let SpaceBridge read.
    var restrictedProcessCount: Int
    var pids: [Int32]

    static let notRunning = ApplicationUsage(processCount: 0, memoryBytes: 0, cpuPercent: 0, restrictedProcessCount: 0, pids: [])
    var isRunning: Bool { processCount > 0 }
}

/// Disk usage attributed to an app outside its bundle.
struct ApplicationStorageBreakdown: Sendable, Equatable {
    struct Entry: Identifiable, Sendable, Equatable {
        enum Kind: String, Sendable { case bundle = "Application Bundle", data = "Application Data", containers = "Containers", cache = "Caches", logs = "Logs", preferences = "Preferences", savedState = "Saved State" }
        var kind: Kind
        var path: String
        var bytes: Int64
        var isPartial: Bool
        var id: String { path }
    }
    var entries: [Entry]
    var total: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    func bytes(for kind: Entry.Kind) -> Int64 { entries.filter { $0.kind == kind }.reduce(0) { $0 + $1.bytes } }
}
