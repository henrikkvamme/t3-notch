import Foundation

/// A loose JSON value. T3's wire format changes between releases, so the app reads
/// only the fields it needs and ignores the rest instead of decoding strict structs.
enum JSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 9e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    /// Milliseconds since epoch for ISO-8601 strings or numeric epoch-ms values. Parsed dates
    /// are cached: sorting the chat list compares the same timestamps many times, and
    /// ISO8601DateFormatter is slow.
    var epochMs: Double? {
        if let n = double { return n }
        guard let s = string else { return nil }
        return JSON.epochCache.value(for: s) {
            JSON.iso.date(from: s).map { $0.timeIntervalSince1970 * 1000 }
                ?? JSON.isoNoFrac.date(from: s).map { $0.timeIntervalSince1970 * 1000 }
        }
    }

    private static let epochCache = EpochCache()

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoNoFrac = ISO8601DateFormatter()

    /// Parses with JSONSerialization, several times faster than a Codable decode of this enum.
    static func parse(_ data: Data) throws -> JSON {
        JSON(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(any value: Any) {
        switch value {
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSON.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// A small thread-safe memo of ISO timestamp → epoch ms.
final class EpochCache: @unchecked Sendable {
    private var values: [String: Double] = [:]
    private let lock = NSLock()

    func value(for key: String, compute: () -> Double?) -> Double? {
        lock.lock()
        if let v = values[key] { lock.unlock(); return v }
        lock.unlock()
        guard let v = compute() else { return nil }
        lock.lock()
        if values.count > 50_000 { values.removeAll() }
        values[key] = v
        lock.unlock()
        return v
    }
}
