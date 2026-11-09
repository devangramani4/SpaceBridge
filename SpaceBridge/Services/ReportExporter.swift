import AppKit
import Foundation
import UniformTypeIdentifiers

/// Writes reports to a file the user picks. Local only — nothing is sent anywhere.
enum ReportExporter {
    static func csv(files: [FileItem]) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["Name,Size (bytes),Size,Type,Category,Modified,Created,Path"]
        for file in files {
            let fields = [
                file.name, String(file.allocatedSize), ByteFormatter.string(file.allocatedSize), file.displayType,
                file.category.displayName, file.modified.map(formatter.string(from:)) ?? "",
                file.created.map(formatter.string(from:)) ?? "", file.path,
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// RFC 4180 quoting; also neutralizes spreadsheet formula injection (=, +, -, @).
    static func escape(_ field: String) -> String {
        var value = field
        if let first = value.first, "=+-@".contains(first) { value = "'" + value }
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    @MainActor
    static func saveCSV(files: [FileItem], suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedName + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv(files: files).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }
}
