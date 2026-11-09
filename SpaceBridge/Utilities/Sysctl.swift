import Darwin
import Foundation

/// Typed helpers around `sysctlbyname`. Returns `nil` when a key is unavailable.
enum Sysctl {
    static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func int64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size { return Int64(Int32(truncatingIfNeeded: value)) }
        return value
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func value<T>(_ name: String, as type: T.Type, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            sysctlbyname(name, pointer, &size, nil, 0)
        }
        return result == 0 ? value : nil
    }
}

/// Mach absolute time → nanoseconds conversion (on Apple silicon, rusage CPU times are in mach ticks).
enum MachTime {
    static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return (1, 1) }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    static func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        let base = timebase
        if base.numer == base.denom { return ticks }
        return ticks / base.denom * base.numer + (ticks % base.denom) * base.numer / base.denom
    }
}

/// A cached send right to the host port (calling `mach_host_self()` repeatedly leaks rights).
enum MachHost {
    static let port: mach_port_t = mach_host_self()
}
