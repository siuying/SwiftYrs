import Foundation
import Testing
import SwiftYrs

private struct Lib0AnyFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let value: AnyCodable
        let bytes: Data

        private enum CodingKeys: String, CodingKey {
            case name, value, bytes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            value = try container.decode(AnyCodable.self, forKey: .value)
            let base64 = try container.decode(String.self, forKey: .bytes)
            guard let data = Data(base64Encoded: base64) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .bytes, in: container, debugDescription: "Expected base64 bytes"
                )
            }
            bytes = data
        }
    }

    let cases: [Case]

    static func load() throws -> Lib0AnyFixture {
        let url = try #require(
            Bundle.module.url(forResource: "lib0-any", withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "lib0-any", withExtension: "json")
        )
        return try JSONDecoder().decode(Lib0AnyFixture.self, from: Data(contentsOf: url))
    }
}

/// Carries an arbitrary JSON value across `Codable` back into the Foundation
/// JSON object representation that `Lib0Any` consumes.
private struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let object = try? container.decode([String: AnyCodable].self) {
            value = object.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value"
            )
        }
    }
}

@Test
func lib0AnyEncodingMatchesJSWriteAnyByteForByte() throws {
    // Swift→JS: bytes produced by Lib0Any.encode are identical to lib0 writeAny.
    for testCase in try Lib0AnyFixture.load().cases {
        let encoded = try Lib0Any.encode(testCase.value.value)
        #expect(encoded == testCase.bytes, "encode mismatch for case '\(testCase.name)'")
    }
}

@Test
func lib0AnyDecodesJSWriteAnyBytesLosslessly() throws {
    // JS→Swift: Lib0Any.decode reads lib0 writeAny bytes; re-encoding reproduces them.
    for testCase in try Lib0AnyFixture.load().cases {
        let decoded = try Lib0Any.decode(testCase.bytes)
        let reencoded = try Lib0Any.encode(decoded)
        #expect(reencoded == testCase.bytes, "round-trip mismatch for case '\(testCase.name)'")
    }
}
