import Darwin
import Foundation

struct CPUSnapshot: Sendable, Equatable {
    var date: Date
    /// Fractions 0…1 of all cores combined.
    var user: Double
    var system: Double
    var idle: Double
    var nice: Double
    var perCore: [Double]
    var loadAverage: [Double]
    var logicalCores: Int
    var physicalCores: Int?
    var performanceCores: Int?
    var efficiencyCores: Int?
    var brand: String?

    var total: Double { min(max(user + system + nice, 0), 1) }
}

/// Raw cumulative tick counters for one core.
struct CoreTicks: Sendable, Equatable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64
    var total: UInt64 { user + system + idle + nice }
}

/// Measures CPU usage from `host_processor_info` tick deltas between samples.
actor CPUMonitor {
    private var previous: [CoreTicks]?

    /// Returns `nil` for the very first call (a delta needs two samples).
    func sample() -> CPUSnapshot? {
        guard let current = Self.readTicks() else { return nil }
        defer { previous = current }
        guard let previous, previous.count == current.count else { return nil }
        return Self.snapshot(previous: previous, current: current)
    }

    /// Pure function — unit tested.
    static func snapshot(previous: [CoreTicks], current: [CoreTicks], date: Date = Date()) -> CPUSnapshot {
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        var perCore: [Double] = []
        for (old, new) in zip(previous, current) {
            let du = new.user &- old.user, ds = new.system &- old.system, di = new.idle &- old.idle, dn = new.nice &- old.nice
            // Counters may wrap or reset (sleep); ignore implausible deltas.
            let valid = new.user >= old.user && new.system >= old.system && new.idle >= old.idle && new.nice >= old.nice
            let coreTotal = valid ? du + ds + di + dn : 0
            perCore.append(coreTotal > 0 ? Double(du + ds + dn) / Double(coreTotal) : 0)
            if valid { user += du; system += ds; idle += di; nice += dn }
        }
        let total = Double(user + system + idle + nice)
        func fraction(_ value: UInt64) -> Double { total > 0 ? Double(value) / total : 0 }

        var loads = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loads, 3)
        return CPUSnapshot(
            date: date,
            user: fraction(user), system: fraction(system), idle: total > 0 ? fraction(idle) : 1, nice: fraction(nice),
            perCore: perCore,
            loadAverage: loadCount > 0 ? Array(loads.prefix(Int(loadCount))) : [],
            logicalCores: Foundation.ProcessInfo.processInfo.activeProcessorCount,
            physicalCores: Sysctl.int32("hw.physicalcpu").map(Int.init),
            performanceCores: Sysctl.int32("hw.perflevel0.physicalcpu").map(Int.init),
            efficiencyCores: Sysctl.int32("hw.perflevel1.physicalcpu").map(Int.init),
            brand: Sysctl.string("machdep.cpu.brand_string"))
    }

    static func readTicks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(MachHost.port, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }
        let stride = Int(CPU_STATE_MAX)
        var cores: [CoreTicks] = []
        cores.reserveCapacity(Int(cpuCount))
        for index in 0..<Int(cpuCount) {
            let base = index * stride
            // Values are 32-bit counters; reinterpret as unsigned.
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            cores.append(CoreTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                                   idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE)))
        }
        return cores
    }
}
