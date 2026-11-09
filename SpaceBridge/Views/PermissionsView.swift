import SwiftUI

struct PermissionsView: View {
    @State private var statuses: [String: AccessStatus] = [:]
    @State private var fullDiskAccess: Bool?
    @State private var showHelp = false
    @State private var checked = false

    private let locations = PermissionManager.locations()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionCard("Storage Access", systemImage: "lock.shield") {
                    Button("Open System Settings") { PermissionManager.openFullDiskAccessSettings() }
                } content: {
                    HStack(spacing: 8) {
                        Image(systemName: fullDiskAccess == true ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(fullDiskAccess == true ? .green : .orange)
                        Text(fullDiskAccess == true ? "Full Disk Access is enabled."
                             : fullDiskAccess == false ? "Full Disk Access is off. Some folders can't be measured."
                             : "Full Disk Access status hasn't been checked.")
                            .fontWeight(.medium)
                    }
                    Text("Full Disk Access is optional. Without it SpaceBridge still measures Applications, your home folder and most of Library, and shows the rest as “Access Restricted”. SpaceBridge never tries to bypass macOS privacy protection.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(checked ? "Check Again" : "Check Access") { check() }
                            .buttonStyle(.borderedProminent)
                        Button("How to Grant Access…") { showHelp = true }
                    }
                    Text("Checking Documents, Desktop or Downloads for the first time may show a macOS permission prompt.")
                        .font(.caption).foregroundStyle(.tertiary)
                }

                SectionCard("Locations", systemImage: "folder.badge.questionmark") {
                    ForEach(locations) { location in
                        let status = statuses[location.path] ?? .notChecked
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: status.symbolName).foregroundStyle(color(status)).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(location.name).fontWeight(.medium)
                                    Text(location.requirement.rawValue).font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                }
                                Text(location.path.abbreviatingHome).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(location.explanation).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(status.label).font(.caption).foregroundStyle(color(status))
                        }
                        .padding(.vertical, 3)
                    }
                }
                PrivacyNotice()
            }
            .padding(20)
        }
        .navigationTitle("Storage Access")
        .sheet(isPresented: $showHelp) { PermissionHelpSheet() }
    }

    private func check() {
        let locations = self.locations
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([String: AccessStatus], Bool?) in
                var statuses: [String: AccessStatus] = [:]
                for location in locations { statuses[location.path] = PermissionManager.check(location.path) }
                return (statuses, PermissionManager.hasFullDiskAccess())
            }.value
            statuses = result.0
            fullDiskAccess = result.1
            checked = true
        }
    }

    private func color(_ status: AccessStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .orange
        case .notFound, .notChecked: return .secondary
        }
    }
}
