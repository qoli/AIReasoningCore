// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

package enum PackageJSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PackageJSONValue])
    case object([String: PackageJSONValue])

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PackageJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PackageJSONValue].self))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    package var objectValue: [String: PackageJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    package var arrayValue: [PackageJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    package var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    package var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    package var integerValue: Int? {
        guard case .number(let value) = self, value.rounded() == value else { return nil }
        return Int(value)
    }

    package var jsonData: Data {
        get throws {
            try JSONEncoder().encode(self)
        }
    }

    package var jsonString: String {
        get throws {
            let data = try jsonData
            guard let string = String(data: data, encoding: .utf8) else {
                throw AgentLanguageModelError.structuredOutputDecodingFailed(
                    "JSON encoder produced non-UTF-8 data"
                )
            }
            return string
        }
    }

    package static func decode(_ data: Data) throws -> PackageJSONValue {
        try JSONDecoder().decode(PackageJSONValue.self, from: data)
    }

    package static func decode(_ string: String) throws -> PackageJSONValue {
        guard let data = string.data(using: .utf8) else {
            throw AgentLanguageModelError.structuredOutputDecodingFailed(
                "String is not valid UTF-8"
            )
        }
        return try decode(data)
    }
}
