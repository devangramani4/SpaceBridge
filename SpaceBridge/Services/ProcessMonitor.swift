import Darwin
import Foundation

/// Enumerates processes with libproc and computes per-process CPU% between samples.
///
/// For processes owned by other users (including root), macOS may refuse to report usage.
/// Those are returned with `nil` metrics instead of invented values.
actor ProcessMonitor {
    private var previousCPU: [Int32: (time: UInt64, at: UInt64)] = [:]
    private var userNames: [UInt32: String] = [:]

    func sample() -> [ProcessSnapshot] {
        let now = DispatchTime.now().uptimeNanoseconds
        var snapshots: [ProcessSnapshot] = []
        var nextCPU: [Int32: (time: UInt64, at: UInt64)] = [:]
        for pid in Self.allPIDs() where pid > 0 {
            guard var snapshot = Self.basicInfo(pid: pid) else { continue }
            if let owner = snapshot.ownerUID { snapshot.ownerName = userName(owner) }
            if let usage = Self.usage(pid: pid) {
                snapshot.memoryBytes = Int64(clamping: usage.footprint)
                let cpuTime = usage.cpuNanoseconds
                nextCPU[pid] = (cpuTime, now)
                if let previous = previousCPU[pid], now > previous.at, cpuTime >= previous.time {
                    snapshot.cpuPercent = Double(cpuTime - previous.time) / Double(now - previous.at) * 100
                }
            }
            snapshots.append(snapshot)
        }
        previousCPU = nextCPU
        return snapshots
    }

    private func userName(_ uid: UInt32) -> String {
        if let cached = userNames[uid] { return cached }
        var name = String(uid)
        if let entry = getpwuid(uid), let pwName = entry.pointee.pw_name {
            name = String(cString: pwName)
        }
        userNames[uid] = name
        return name
    }

    static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<Int32>.size))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    static func basicInfo(pid: Int32) -> ProcessSnapshot? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let gotBSD = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize

        let path = executablePath(pid: pid)
        var name = path?.lastPathComponentString ?? ""
        if name.isEmpty {
            var buffer = [CChar](repeating: 0, count: 256)
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { name = String(cString: buffer) }
        }
        if name.isEmpty && gotBSD {
            name = withUnsafeBytes(of: bsd.pbi_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        guard gotBSD || !name.isEmpty else { return nil } // process exited

        var threads: Int?
        var resident: Int64?
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize {
            threads = Int(task.pti_threadnum)
            resident = Int64(clamping: task.pti_resident_size)
        }

        return ProcessSnapshot(
            pid: pid,
            parentPID: gotBSD ? Int32(bsd.pbi_ppid) : 0,
            name: name.isEmpty ? "PID \(pid)" : name,
            executablePath: path,
            ownerUID: gotBSD ? bsd.pbi_uid : nil,
            ownerName: nil,
            cpuPercent: nil,
            memoryBytes: nil,
            residentBytes: resident,
            threadCount: threads,
            state: gotBSD ? ProcessState(bsdStatus: bsd.pbi_status) : .unknown,
            startTime: gotBSD ? Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000) : nil)
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    struct Usage: Sendable {
        var footprint: UInt64
        var cpuNanoseconds: UInt64
    }

    /// Physical footprint and cumulative CPU time via `proc_pid_rusage` (`nil` if not permitted).
    static func usage(pid: Int32) -> Usage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        let ticks = info.ri_user_time + info.ri_system_time
        return Usage(footprint: info.ri_phys_footprint, cpuNanoseconds: MachTime.nanoseconds(fromTicks: ticks))
    }

    /// Aggregates processes that belong to an app bundle (main executable plus helpers inside it).
    static func usage(forAppAt bundlePath: String, in processes: [ProcessSnapshot]) -> ApplicationUsage {
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        var usage = ApplicationUsage.notRunning
        for process in processes {
            guard let path = process.executablePath, path.hasPrefix(prefix) else { continue }
            usage.processCount += 1
            usage.pids.append(process.pid)
            if let memory = process.memoryBytes { usage.memoryBytes += memory } else { usage.restrictedProcessCount += 1 }
            usage.cpuPercent += process.cpuPercent ?? 0
        }
        return usage
    }
}
