import Darwin
import Foundation
import os
import UIKit

/// Capacity of the device's storage, from Apple's volume resource keys.
struct DeviceStorage: Sendable, Equatable {
    var total: Int64
    /// Free space including what iOS can reclaim on demand (what Settings ▸ iPhone Storage shows).
    var availableForImportantUsage: Int64
    var availableStrict: Int64

    var available: Int64 { max(availableForImportantUsage, availableStrict) }
    var used: Int64 { max(total - available, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// System-wide memory plus SpaceBridge's own usage. iOS doesn't let apps see other apps' memory.
struct DeviceMemory: Sendable, Equatable {
    var total: UInt64
    var used: UInt64?
    var wired: UInt64?
    var compressed: UInt64?
    var free: UInt64?
    /// SpaceBridge's own physical footprint.
    var appFootprint: UInt64?
    /// How much more memory iOS would let SpaceBridge allocate.
    var appAvailable: UInt64?
}

struct DeviceStatus: Sendable, Equatable {
    var model: String
    var hardwareIdentifier: String
    var systemName: String
    var systemVersion: String
    var batteryLevel: Float?
    var batteryState: String
    var lowPowerMode: Bool
    var thermalState: String
    var uptime: TimeInterval
    var processorCount: Int
}

enum DeviceInfoService {
    static func storage() -> DeviceStorage? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let strict = Int64(values.volumeAvailableCapacity ?? 0)
        return DeviceStorage(total: Int64(total), availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage ?? strict, availableStrict: strict)
    }

    static func memory() -> DeviceMemory {
        var result = DeviceMemory(total: Foundation.ProcessInfo.processInfo.physicalMemory)
        let host = mach_host_self()
        var pageSize: vm_size_t = 0
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        if host_page_size(host, &pageSize) == KERN_SUCCESS {
            let status = withUnsafeMutablePointer(to: &stats) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(host, HOST_VM_INFO64, $0, &count)
                }
            }
            if status == KERN_SUCCESS {
                let page = UInt64(pageSize)
                let internal = UInt64(stats.internal_page_count)
                let purgeable = UInt64(stats.purgeable_count)
                let app = internal > purgeable ? internal - purgeable : 0
                let wired = UInt64(stats.wire_count) * page
                let compressed = UInt64(stats.compressor_page_count) * page
                result.wired = wired
                result.compressed = compressed
                result.used = app * page + wired + compressed
                result.free = UInt64(stats.free_count) * page
            }
        }
        mach_port_deallocate(mach_task_self_, host)

        var info = task_vm_info_data_t()
        var infoCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let taskStatus = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &infoCount)
            }
        }
        if taskStatus == KERN_SUCCESS { result.appFootprint = info.phys_footprint }
        result.appAvailable = UInt64(os_proc_available_memory())
        return result
    }

    @MainActor
    static func status() -> DeviceStatus {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let process = Foundation.ProcessInfo.processInfo
        let battery: String
        switch device.batteryState {
        case .charging: battery = "Charging"
        case .full: battery = "Full"
        case .unplugged: battery = "On battery"
        default: battery = "Unknown"
        }
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "Normal"
        case .fair: thermal = "Fair"
        case .serious: thermal = "Serious"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Unknown"
        }
        return DeviceStatus(
            model: device.model, hardwareIdentifier: hardwareIdentifier(), systemName: device.systemName,
            systemVersion: device.systemVersion, batteryLevel: device.batteryLevel >= 0 ? device.batteryLevel : nil,
            batteryState: battery, lowPowerMode: process.isLowPowerModeEnabled, thermalState: thermal,
            uptime: process.systemUptime, processorCount: process.activeProcessorCount)
    }

    /// e.g. "iPhone16,2". On the simulator, the simulated model.
    static func hardwareIdentifier() -> String {
        if let simulated = Foundation.ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Whole-device CPU usage from tick deltas between samples.
final class DeviceCPUSampler: @unchecked Sendable {
    private var previous: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)]?
    private let lock = NSLock()

    /// Fraction 0…1, or `nil` on the first call or if iOS doesn't provide the counters.
    func sample() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var current: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
        for index in 0..<Int(cpuCount) {
            let base = index * Int(CPU_STATE_MAX)
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            current.append((tick(CPU_STATE_USER), tick(CPU_STATE_SYSTEM), tick(CPU_STATE_IDLE), tick(CPU_STATE_NICE)))
        }
        lock.lock()
        defer { lock.unlock() }
        defer { previous = current }
        guard let previous, previous.count == current.count else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for (old, new) in zip(previous, current) where new.user >= old.user && new.system >= old.system && new.idle >= old.idle && new.nice >= old.nice {
            let b = (new.user - old.user) + (new.system - old.system) + (new.nice - old.nice)
            busy += b
            total += b + (new.idle - old.idle)
        }
        return total > 0 ? Double(busy) / Double(total) : 0
    }
}
