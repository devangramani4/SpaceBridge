import AppKit
import SwiftUI

/// Sortable process table. Metrics macOS doesn't expose are shown as "Restricted", never guessed.
struct ProcessTable: View {
    var processes: [ProcessSnapshot]
    @Binding var selection: Set<ProcessSnapshot.ID>
    var onQuit: (ProcessSnapshot, Bool) -> Void

    @State private var sortOrder: [KeyPathComparator<ProcessSnapshot>] = [KeyPathComparator(\.cpuSortKey, order: .reverse)]

    var body: some View {
        Table(processes.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Process", value: \.name) { process in
                HStack(spacing: 6) {
                    ProcessIcon(process: process)
                    Text(process.name).lineLimit(1)
                }
                .help(process.executablePath ?? "Path unavailable")
            }
            .width(min: 160, ideal: 220)
            TableColumn("PID", value: \.pid) { Text(String($0.pid)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 50, ideal: 60)
            TableColumn("CPU %", value: \.cpuSortKey) { process in
                if let cpu = process.cpuPercent {
                    Text(String(format: "%.1f", cpu)).monospacedDigit()
                } else {
                    RestrictedText(isRestricted: process.isRestricted)
                }
            }
            .width(min: 60, ideal: 70).alignment(.trailing)
            TableColumn("Memory", value: \.memorySortKey) { process in
                if let memory = process.memoryBytes {
                    Text(ByteFormatter.string(memory)).monospacedDigit()
                } else {
                    RestrictedText(isRestricted: true)
                }
            }
            .width(min: 70, ideal: 90).alignment(.trailing)
            TableColumn("Threads", value: \.threadSortKey) { process in
                Text(process.threadCount.map(String.init) ?? "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60).alignment(.trailing)
            TableColumn("State", value: \.state.rawValue) { Text($0.state.rawValue).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 80)
            TableColumn("User", value: \.userSortKey) { Text($0.ownerName ?? "—").foregroundStyle(.secondary) }
                .width(min: 60, ideal: 90)
        }
        .contextMenu(forSelectionType: ProcessSnapshot.ID.self) { ids in
            if let pid = ids.first, let process = processes.first(where: { $0.pid == pid }) {
                ProcessContextMenu(process: process, onQuit: onQuit)
            }
        }
    }
}

extension ProcessSnapshot {
    var userSortKey: String { ownerName ?? "~" }
}

struct RestrictedText: View {
    var isRestricted: Bool
    var body: some View {
        Text(isRestricted ? "Restricted" : "—")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .help("macOS doesn't allow other apps to read this process's usage.")
    }
}

struct ProcessIcon: View {
    var process: ProcessSnapshot
    var body: some View {
        if let bundle = process.appBundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundle))
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 16)
        }
    }
}

struct ProcessContextMenu: View {
    var process: ProcessSnapshot
    var onQuit: (ProcessSnapshot, Bool) -> Void

    var body: some View {
        let safety = SecurityUtils.evaluateProcess(pid: process.pid, name: process.name, executablePath: process.executablePath, ownerUID: process.ownerUID)
        if let app = NSRunningApplication(processIdentifier: process.pid) {
            Button("Bring to Front") { app.activate() }
        }
        if let path = process.appBundlePath ?? process.executablePath {
            Button("Reveal in Finder") { FinderActions.reveal(path) }
            Button("Copy Path") { FinderActions.copyPaths([path]) }
        }
        Divider()
        Button("Quit…") { onQuit(process, false) }.disabled(!safety.canTerminate)
        Button("Force Quit…") { onQuit(process, true) }.disabled(!safety.canTerminate)
        if case .protected(let reason) = safety {
            Text(reason)
        }
    }
}
