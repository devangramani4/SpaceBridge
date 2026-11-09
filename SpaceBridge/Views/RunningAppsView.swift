import AppKit
import SwiftUI

struct RunningAppsView: View {
    @Environment(AppModel.self) private var model

    enum Scope: String, CaseIterable, Identifiable {
        case apps = "Apps", mine = "My Processes", all = "All Processes"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .apps
    @State private var filter = ""
    @State private var selection = Set<ProcessSnapshot.ID>()
    @State private var pendingQuit: (process: ProcessSnapshot, force: Bool)?
    @State private var errorMessage: String?

    private var visible: [ProcessSnapshot] {
        let uid = getuid()
        return model.monitor.processes.filter { process in
            switch scope {
            case .apps: guard process.appBundlePath != nil, process.ownerUID == uid else { return false }
            case .mine: guard process.ownerUID == uid else { return false }
            case .all: break
            }
            return filter.isEmpty || process.name.localizedCaseInsensitiveContains(filter) || String(process.pid) == filter
        }
    }

    var body: some View {
        let processes = visible
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 360)
                TextField("Filter by name or PID", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer()
                Text("\(processes.count) processes").foregroundStyle(.secondary)
                if let date = model.monitor.lastProcessSample {
                    Text("Updated \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            ProcessTable(processes: processes, selection: $selection) { process, force in
                pendingQuit = (process: process, force: force)
            }
            Divider()
            Text("CPU %: 100% equals one full core. Memory is the physical footprint (as in Activity Monitor). “Restricted” means macOS doesn't let other apps read that process.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Running Apps")
        .toolbar {
            ToolbarItemGroup {
                let selected = processes.first { selection.contains($0.pid) }
                let safety = selected.map {
                    SecurityUtils.evaluateProcess(pid: $0.pid, name: $0.name, executablePath: $0.executablePath, ownerUID: $0.ownerUID)
                }
                Button {
                    if let selected, let app = NSRunningApplication(processIdentifier: selected.pid) { app.activate() }
                } label: { Label("Bring to Front", systemImage: "macwindow") }
                .disabled(selected.flatMap { NSRunningApplication(processIdentifier: $0.pid) } == nil)
                Button {
                    if let path = selected?.appBundlePath ?? selected?.executablePath { FinderActions.reveal(path) }
                } label: { Label("Reveal", systemImage: "folder") }
                .disabled(selected?.executablePath == nil)
                Button {
                    if let selected { pendingQuit = (process: selected, force: false) }
                } label: { Label("Quit", systemImage: "xmark.circle") }
                .disabled(safety?.canTerminate != true)
                .help(safety.flatMap { if case .protected(let reason) = $0 { return reason } else { return nil } } ?? "Quit the selected process")
            }
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } })) {
            if let pending = pendingQuit {
                Button(pending.force ? "Force Quit" : "Quit", role: pending.force ? .destructive : nil) {
                    terminate(pending.process, force: pending.force)
                    pendingQuit = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingQuit = nil }
        } message: {
            Text(pendingQuit?.force == true ? "The process stops immediately. Unsaved work will be lost." : "The app may ask you to save changes first.")
        }
        .alert("Couldn't quit the process", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .onAppear { model.monitor.subscribe(processes: true) }
        .onDisappear { model.monitor.unsubscribe(processes: true) }
    }

    private var dialogTitle: String {
        guard let pending = pendingQuit else { return "" }
        return pending.force ? "Force quit “\(pending.process.name)” (PID \(pending.process.pid))?" : "Quit “\(pending.process.name)”?"
    }

    /// Re-checks safety at the moment of action; never targets protected or other users' processes.
    private func terminate(_ process: ProcessSnapshot, force: Bool) {
        let safety = SecurityUtils.evaluateProcess(pid: process.pid, name: process.name, executablePath: process.executablePath, ownerUID: process.ownerUID)
        guard safety.canTerminate else {
            if case .protected(let reason) = safety { errorMessage = reason }
            return
        }
        if let app = NSRunningApplication(processIdentifier: process.pid) {
            let sent = force ? app.forceTerminate() : app.terminate()
            if !sent { errorMessage = "macOS declined the request." }
        } else if kill(process.pid, force ? SIGKILL : SIGTERM) != 0 {
            errorMessage = String(cString: strerror(errno))
        }
    }
}
