import Darwin
import Foundation

enum MemoryPressure: String, Sendable {
    case normal = "Normal"
    case warning = "Moderate"
    case critical = "Critical"
    case unknown = "Unknown"

    /// From `kern.memorystatus_vm_pressure_level` (1 = normal, 2 = warning, 4 = critical).
    init(level: Int32?) {
        switch level {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }
}

/// Memory figures computed the same way Activity Monitor does, from `host_statistics64`.
struct MemorySnapshot: Sendable, Equatable {
    var date: Date
    var total: UInt64
    var pageSize: UInt64
    /// App memory: anonymous pages minus purgeable pages.
    var app: UInt64
    var wired: UInt64
    /// Physical memory occupied by the compressor.
    var compressed: UInt64
    /// File-backed and purgeable memory macOS can reclaim instantly ("Cached Files").
    var cached: UInt64
    var free: UInt64
    var swapTotal: UInt64?
    var swapUsed: UInt64?
    var swapAvailable: UInt64?
    var pressure: MemoryPressure
    /// `kern.memorystatus_level`: percentage of memory macOS considers available.
    var systemFreePercent: Int?

    /// Used = App + Wired + Compressed (Activity Monitor's "Memory Used").
    var used: UInt64 { app + wired + compressed }
    /// Free plus instantly reclaimable cache.
    var available: UInt64 { total > used ? total - used : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    /// Fraction used for the pressure bar: prefers the kernel's own availability metric.
    var pressureFraction: Double {
        if let systemFreePercent { return min(max(1 - Double(systemFreePercent) / 100, 0), 1) }
        return usedFraction
    }
}

/// Reads system memory statistics. Stateless and cheap (a handful of syscalls).
struct MemoryMonitor: Sendable {
    func sample() -> MemorySnapshot? {
        let host = MachHost.port
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(pageSize)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        let speculative = UInt64(stats.speculative_count)
        let freePages = UInt64(stats.free_count)

        var swapTotal: UInt64?
        var swapUsed: UInt64?
        var swapAvailable: UInt64?
        if let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self, initial: xsw_usage()) {
            swapTotal = swap.xsu_total
            swapUsed = swap.xsu_used
            swapAvailable = swap.xsu_avail
        }

        return MemorySnapshot(
            date: Date(),
            total: Foundation.ProcessInfo.processInfo.physicalMemory,
            pageSize: page,
            app: (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: (UInt64(stats.external_page_count) + purgeablePages + speculative) * page,
            free: (freePages > speculative ? freePages - speculative : 0) * page,
            swapTotal: swapTotal,
            swapUsed: swapUsed,
            swapAvailable: swapAvailable,
            pressure: MemoryPressure(level: Sysctl.int32("kern.memorystatus_vm_pressure_level")),
            systemFreePercent: Sysctl.int32("kern.memorystatus_level").map(Int.init))
    }
}
