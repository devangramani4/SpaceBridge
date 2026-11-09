import Foundation

// Note: the type is named `ProcessSnapshot` to avoid clashing with Foundation's `ProcessInfo`.

enum ProcessState: String, Sendable {
    case running = "Running"
    case sleeping = "Sleeping"
    case stopped = "Stopped"
    case zombie = "Zombie"
    case idle = "Starting"
    case unknown = "Unknown"

    init(bsdStatus: UInt32) {
        switch bsdStatus {
        case 1: self = .idle      // SIDL
        case 2: self = .running   // SRUN
        case 3: self = .sleeping  // SSLEEP
        case 4: self = .stopped   // SSTOP
        case 5: self = .zombie    // SZOMB
        default: self = .unknown
        }
    }
}

/// One process sample. `nil` metrics mean macOS didn't allow SpaceBridge to read them
/// (typically processes owned by root or another user) — the UI shows "Restricted".
struct ProcessSnapshot: Identifiable, Hashable, Sendable {
    var pid: Int32
    var parentPID: Int32
    var name: String
    var executablePath: String?
    var ownerUID: UInt32?
    var ownerName: String?
    /// CPU usage since the previous sample. 100% = one full core. `nil` on the first sample.
    var cpuPercent: Double?
    /// Physical memory footprint (Activity Monitor's "Memory" column).
    var memoryBytes: Int64?
    var residentBytes: Int64?
    var threadCount: Int?
    var state: ProcessState
    var startTime: Date?

    var id: Int32 { pid }
    var isRestricted: Bool { memoryBytes == nil }
    var cpuSortKey: Double { cpuPercent ?? -1 }
    var memorySortKey: Int64 { memoryBytes ?? -1 }
    var threadSortKey: Int { threadCount ?? -1 }

    /// The `.app` bundle containing the executable, if any (outermost bundle).
    var appBundlePath: String? {
        guard let executablePath, let range = executablePath.range(of: ".app/") else { return nil }
        return String(executablePath[..<range.lowerBound]) + ".app"
    }
}
