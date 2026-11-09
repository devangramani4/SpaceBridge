import Foundation

/// Parses search text into a `SearchQuery` that runs against the local index.
///
/// Supported syntax (case-insensitive, combinable):
///
///     *.zip                 glob on the file name (a bare *.ext becomes an extension filter)
///     ext:mov               extension
///     node_modules          name contains
///     "my report"           quoted phrase
///     size > 1 GB           also >=, <, <=, e.g. size<500MB
///     modified > 1 year ago older than; "modified < 7 days ago" = newer than
///     in:Downloads          folder path contains
///     kind:folder           files | folders
///     app:Chrome            search installed applications
enum SearchParser {
    static func parse(_ input: String, now: Date = Date()) -> SearchQuery {
        var query = SearchQuery()
        var text = input

        // size comparisons
        let sizePattern = #"(?i)\bsize\s*(>=|<=|>|<|=)\s*([0-9]+(?:[.,][0-9]+)?)\s*(bytes|b|kb|k|mb|m|gb|g|tb|t)?\b"#
        for match in matches(sizePattern, in: text).reversed() {
            let op = match.groups[0] ?? ">"
            let number = match.groups[1] ?? "0"
            let unit = match.groups[2] ?? "b"
            if let bytes = ByteFormatter.parse(number + unit) {
                switch op {
                case ">", ">=": query.minSize = bytes
                case "<", "<=": query.maxSize = bytes
                default: query.minSize = bytes; query.maxSize = bytes
                }
            }
            text.removeSubrange(match.range)
        }

        // modified comparisons
        let datePattern = #"(?i)\b(?:modified|date)\s*(>|<)\s*([0-9]+)\s*(days|day|d|weeks|week|w|months|month|mo|m|years|year|yrs|yr|y)?\b\s*(?:ago)?"#
        for match in matches(datePattern, in: text).reversed() {
            let op = match.groups[0] ?? ">"
            let amount = Int(match.groups[1] ?? "0") ?? 0
            let unit = (match.groups[2] ?? "d").lowercased()
            var components = DateComponents()
            switch unit.first {
            case "w": components.day = -7 * amount
            case "m": components.month = -amount
            case "y": components.year = -amount
            default: components.day = -amount
            }
            if let date = Calendar.current.date(byAdding: components, to: now) {
                if op == ">" { query.modifiedBefore = date } else { query.modifiedAfter = date }
            }
            text.removeSubrange(match.range)
        }

        // Remaining tokens
        for token in tokenize(text) {
            let lower = token.lowercased()
            if let value = value(of: lower, prefixes: ["ext:", "extension:"]) {
                query.fileExtension = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            } else if let value = value(of: token, prefixes: ["in:", "folder:", "path:"]) {
                query.folderContains = value
            } else if let value = value(of: lower, prefixes: ["kind:", "type:"]) {
                if value.hasPrefix("folder") || value.hasPrefix("dir") { query.kind = .folders }
                else if value.hasPrefix("file") { query.kind = .files }
                else if let category = StorageCategory.allCases.first(where: { $0.displayName.lowercased().hasPrefix(value) }) {
                    query.category = category
                }
            } else if let value = value(of: token, prefixes: ["app:", "application:"]) {
                query.applicationName = value
            } else if lower.hasPrefix("*.") && !lower.dropFirst(2).contains(where: { "*?[".contains($0) }) && lower.count > 2 {
                query.fileExtension = String(lower.dropFirst(2))
                query.kind = query.kind == .folders ? .folders : .files
            } else if token.contains(where: { "*?[".contains($0) }) {
                query.nameGlob = token
            } else if !token.isEmpty {
                query.nameContains = query.nameContains.map { $0 + " " + token } ?? token
            }
        }
        return query
    }

    private static func value(of token: String, prefixes: [String]) -> String? {
        for prefix in prefixes where token.lowercased().hasPrefix(prefix) {
            let value = String(token.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                if !quoted, !current.isEmpty { tokens.append(current); current = "" }
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private struct Match {
        var range: Range<String.Index>
        var groups: [String?]
    }

    private static func matches(_ pattern: String, in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            var groups: [String?] = []
            for index in 1..<result.numberOfRanges {
                let groupRange = result.range(at: index)
                if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: text) {
                    groups.append(String(text[swiftRange]))
                } else {
                    groups.append(nil)
                }
            }
            return Match(range: range, groups: groups)
        }
    }
}

struct SearchResults: Sendable {
    var files: [FileItem] = []
    var folders: [FolderItem] = []
    var applications: [ApplicationInfo] = []
    var query = SearchQuery()
    var duration: TimeInterval = 0
}

enum SearchService {
    static func run(_ text: String, database: StorageDatabase, applications: [ApplicationInfo]) async -> SearchResults {
        let started = Date()
        let query = SearchParser.parse(text)
        var results = SearchResults(query: query)
        if let appName = query.applicationName ?? (query.kind == .all ? query.nameContains : nil) {
            results.applications = applications.filter {
                $0.name.localizedCaseInsensitiveContains(appName) || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(appName) ?? false)
            }
        }
        var indexQuery = query
        indexQuery.applicationName = nil
        if !indexQuery.isEmpty {
            if query.kind != .folders { results.files = (try? await database.searchFiles(indexQuery)) ?? [] }
            if query.kind != .files { results.folders = (try? await database.searchFolders(indexQuery)) ?? [] }
        }
        results.duration = Date().timeIntervalSince(started)
        return results
    }
}
