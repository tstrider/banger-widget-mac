//  BangerTask.swift — one line on the list.
//
//  JSON shape:
//    { "id": "a1", "text": "Call the realtor", "done": false, "source": "iris",
//      "completedAt": "2026-09-21T14:22:10Z" }
//
//  Any key we do not know about is kept in `extra` and written back out verbatim, so
//  a newer writer adding e.g. "due" does not lose it when an older build rewrites the file.

import Foundation

public struct BangerTask: Sendable, Equatable, Identifiable {

    public var id: String
    public var text: String
    public var done: Bool
    /// "me" | "iris" | anything else a writer wants to claim.
    public var source: String
    public var completedAt: Date?
    /// Unknown JSON keys, preserved across a round trip.
    public var extra: [String: JSONValue]

    public init(id: String = BangerTask.newID(),
                text: String,
                done: Bool = false,
                source: String = BangerSource.me,
                completedAt: Date? = nil,
                extra: [String: JSONValue] = [:]) {
        self.id = id
        self.text = text
        self.done = done
        self.source = source
        self.completedAt = completedAt
        self.extra = extra
    }

    /// Short, lowercase, unambiguous in a shell. Not a UUID because people type these.
    public static func newID() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789") // no l/i/o/0/1
        var generator = SystemRandomNumberGenerator()
        return String((0..<6).map { _ in alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))] })
    }
}

/// The values `source` is expected to hold. Not an enum: the file must tolerate new ones.
public enum BangerSource {
    public static let me = "me"
    public static let iris = "iris"
    public static let widget = "widget"
}

// MARK: - Codable with an overflow bag

extension BangerTask: Codable {

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { self.stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private enum K {
        static let id = "id", text = "text", done = "done"
        static let source = "source", completedAt = "completedAt"
        static let known: Set<String> = [id, text, done, source, completedAt]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        self.id = try container.decode(String.self, forKey: AnyKey(K.id))
        self.text = try container.decodeIfPresent(String.self, forKey: AnyKey(K.text)) ?? ""
        self.done = try container.decodeIfPresent(Bool.self, forKey: AnyKey(K.done)) ?? false
        self.source = try container.decodeIfPresent(String.self, forKey: AnyKey(K.source)) ?? BangerSource.me

        var overflow: [String: JSONValue] = [:]

        if container.contains(AnyKey(K.completedAt)) {
            if let raw = try? container.decode(String.self, forKey: AnyKey(K.completedAt)),
               let parsed = BangerDate.parseTimestamp(raw) {
                self.completedAt = parsed
            } else {
                // Unparseable but present: keep whatever it was rather than destroying it.
                self.completedAt = nil
                if let raw = try? container.decode(JSONValue.self, forKey: AnyKey(K.completedAt)),
                   raw != .null {
                    overflow[K.completedAt] = raw
                }
            }
        } else {
            self.completedAt = nil
        }

        for key in container.allKeys where !K.known.contains(key.stringValue) {
            overflow[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.extra = overflow
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(id, forKey: AnyKey(K.id))
        try container.encode(text, forKey: AnyKey(K.text))
        try container.encode(done, forKey: AnyKey(K.done))
        try container.encode(source, forKey: AnyKey(K.source))
        if let completedAt {
            try container.encode(BangerDate.timestampString(completedAt), forKey: AnyKey(K.completedAt))
        }
        for (key, value) in extra {
            // A known key can only reach `extra` when we failed to parse it above; in that
            // case the real property is nil, so writing the preserved value back is correct.
            if K.known.contains(key), !(key == K.completedAt && completedAt == nil) { continue }
            try container.encode(value, forKey: AnyKey(key))
        }
    }
}
