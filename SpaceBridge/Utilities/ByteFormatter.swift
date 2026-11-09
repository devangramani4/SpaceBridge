import Foundation

/// Units used to display storage sizes. SpaceBridge uses decimal (SI) units,
/// the same convention Finder and System Settings use (1 GB = 1,000,000,000 bytes).
enum ByteUnit: String, CaseIterable, Sendable, Identifiable {
    case bytes = "bytes"
    case kb = "KB"
    case mb = "MB"
    case gb = "GB"
    case tb = "TB"

    var id: String { rawValue }

    var multiplier: Double {
        switch self {
        case .bytes: return 1
        case .kb: return 1_000
        case .mb: return 1_000_000
        case .gb: return 1_000_000_000
        case .tb: return 1_000_000_000_000
        }
    }

    /// Picks the most readable unit for a byte count.
    static func bestFit(for bytes: Int64) -> ByteUnit {
        let value = Double(bytes.magnitude)
        if value >= ByteUnit.tb.multiplier { return .tb }
        if value >= ByteUnit.gb.multiplier { return .gb }
        if value >= ByteUnit.mb.multiplier { return .mb }
        if value >= ByteUnit.kb.multiplier { return .kb }
        return .bytes
    }
}

enum ByteFormatter {
    /// Formats a byte count, e.g. `18400000000` → `"18.4 GB"`.
    /// - Parameter unit: force a unit; `nil` picks the best fit.
    static func string(_ bytes: Int64, unit: ByteUnit? = nil) -> String {
        let unit = unit ?? ByteUnit.bestFit(for: bytes)
        if unit == .bytes {
            return bytes == 1 ? "1 byte" : "\(bytes) bytes"
        }
        let value = Double(bytes) / unit.multiplier
        let decimals: Int
        switch abs(value) {
        case ..<10: decimals = 2
        case ..<100: decimals = 1
        default: decimals = unit == .kb ? 0 : 1
        }
        return String(format: "%.\(decimals)f %@", value, unit.rawValue)
    }

    static func string(_ bytes: UInt64, unit: ByteUnit? = nil) -> String {
        string(Int64(clamping: bytes), unit: unit)
    }

    static func string(optional bytes: Int64?, placeholder: String = "—") -> String {
        guard let bytes else { return placeholder }
        return string(bytes)
    }

    /// Parses user input such as `"1GB"`, `"1.5 gb"`, `"500 MB"`, `"200k"` or `"4096"`.
    static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        var numberPart = ""
        var unitPart = ""
        for character in trimmed {
            if unitPart.isEmpty, character.isNumber || character == "." || character == "," {
                numberPart.append(character == "," ? "." : character)
            } else if character != " " {
                unitPart.append(character)
            }
        }
        guard let value = Double(numberPart), value >= 0 else { return nil }
        let multiplier: Double
        switch unitPart {
        case "", "b", "byte", "bytes": multiplier = 1
        case "k", "kb", "kilobyte", "kilobytes": multiplier = ByteUnit.kb.multiplier
        case "m", "mb", "megabyte", "megabytes": multiplier = ByteUnit.mb.multiplier
        case "g", "gb", "gigabyte", "gigabytes": multiplier = ByteUnit.gb.multiplier
        case "t", "tb", "terabyte", "terabytes": multiplier = ByteUnit.tb.multiplier
        default: return nil
        }
        let result = value * multiplier
        guard result < Double(Int64.max) else { return nil }
        return Int64(result)
    }
}

extension Int64 {
    var formattedBytes: String { ByteFormatter.string(self) }
}

enum CountFormatter {
    static func string(_ value: Int) -> String { value.formatted(.number) }
    static func string(_ value: Int64) -> String { value.formatted(.number) }
}

enum PercentFormatter {
    /// `0.623` → `"62%"`; values above 1 are allowed (per-process CPU can exceed 100%).
    static func string(_ fraction: Double, decimals: Int = 0) -> String {
        guard fraction.isFinite else { return "—" }
        return String(format: "%.\(decimals)f%%", fraction * 100)
    }
}

extension String {
    /// Abbreviates the user's home directory to `~` for display.
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return self
    }

    var lastPathComponentString: String {
        (self as NSString).lastPathComponent
    }

    var deletingLastPathComponentString: String {
        (self as NSString).deletingLastPathComponent
    }
}
