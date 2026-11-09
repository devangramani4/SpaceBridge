import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible, Sendable {
    var code: Int32
    var message: String
    var description: String { "SQLite error \(code): \(message)" }
}

/// Minimal, dependency-free wrapper around the system SQLite library.
/// Not thread-safe by itself; it is owned and serialized by the `StorageDatabase` actor.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(code: result, message: message)
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        for statement in cache.values { sqlite3_finalize(statement) }
        cache.removeAll()
        sqlite3_close(handle)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw SQLiteError(code: result, message: message)
        }
    }

    /// Returns a cached, reset prepared statement.
    func prepare(_ sql: String) throws -> Statement {
        if let cached = cache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return Statement(handle: cached)
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)))
        }
        cache[sql] = statement
        return Statement(handle: statement)
    }

    /// Runs a statement that returns no rows.
    @discardableResult
    func run(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql)
        try statement.bind(values)
        while try statement.step() {}
        return changes
    }

    /// Runs a query and maps each row.
    func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (Statement) -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(values)
        var rows: [T] = []
        while try statement.step() {
            rows.append(map(statement))
        }
        return rows
    }

    func scalarInt(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        try query(sql, values) { $0.int64(0) }.first ?? 0
    }

    struct Statement {
        let handle: OpaquePointer

        func bind(_ values: [SQLValue]) throws {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case .null: result = sqlite3_bind_null(handle, index)
                case .int(let v): result = sqlite3_bind_int64(handle, index, v)
                case .double(let v): result = sqlite3_bind_double(handle, index, v)
                case .text(let v): result = sqlite3_bind_text(handle, index, v, -1, SQLiteConnection.transient)
                }
                guard result == SQLITE_OK else {
                    throw SQLiteError(code: result, message: "bind failed at \(index)")
                }
            }
        }

        /// Returns `true` while rows are available.
        func step() throws -> Bool {
            let result = sqlite3_step(handle)
            switch result {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default:
                let message = String(cString: sqlite3_errmsg(sqlite3_db_handle(handle)))
                sqlite3_reset(handle)
                throw SQLiteError(code: result, message: message)
            }
        }

        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
        func optionalInt64(_ column: Int32) -> Int64? { isNull(column) ? nil : int64(column) }
        func optionalDate(_ column: Int32) -> Date? {
            guard !isNull(column) else { return nil }
            let value = double(column)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        func text(_ column: Int32) -> String {
            guard let pointer = sqlite3_column_text(handle, column) else { return "" }
            return String(cString: pointer)
        }
    }
}

enum SQLValue: Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    static func integer(_ value: Int) -> SQLValue { .int(Int64(value)) }
    static func bool(_ value: Bool) -> SQLValue { .int(value ? 1 : 0) }
    static func optional(_ value: Int64?) -> SQLValue { value.map { .int($0) } ?? .null }
}
