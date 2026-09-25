//  JSONValue.swift — a minimal, lossless JSON value.
//
//  Exists so unknown keys written by a future version of the agent's shell script (or a
//  future version of the app) survive a decode/encode round trip instead of being
//  silently dropped the next time we rewrite tasks.json.

import Foundation

public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        // Bool must be tried before Int: JSONDecoder will happily turn `true` into 1
        // on some paths, and we want `true` to stay `true`.
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container,
                                               debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:            try container.encodeNil()
        case .bool(let v):     try container.encode(v)
        case .int(let v):      try container.encode(v)
        case .double(let v):   try container.encode(v)
        case .string(let v):   try container.encode(v)
        case .array(let v):    try container.encode(v)
        case .object(let v):   try container.encode(v)
        }
    }
}

public extension JSONValue {
    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(exactly: v.rounded())
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }
    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
}
