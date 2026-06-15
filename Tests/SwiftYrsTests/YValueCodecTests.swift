import Foundation
@testable import SwiftYrs
import Testing

@Test
func valueCodecRoundTripsAttributeRawScalars() throws {
    let attributes: YAttributes = [
        "bold": .bool(true),
        "name": .string("Ada"),
        "width": .int(320),
        "ratio": .double(1.5),
        "bytes": .binary(Data([1, 2, 3])),
        "none": .null
    ]

    let json = try YValueCodec.jsonString(from: attributes, rawScalars: true)
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))

    #expect(YValueCodec.attributes(fromJSON: object) == attributes)
}

@Test
func valueCodecRoundTripsTextDeltaJSON() throws {
    let delta: [YTextDeltaOperation] = [
        .retain(2, attributes: ["bold": .bool(true)]),
        .insert(.string("hi"), attributes: ["lang": .string("en")]),
        .insert(.binary(Data([9, 8])), attributes: [:]),
        .delete(1)
    ]

    let json = try YValueCodec.jsonString(from: delta)
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))

    #expect(YValueCodec.delta(fromJSON: object) == delta)
}

@Test
func valueCodecDecodesEventStyleMultiValueDelta() {
    let object: [[String: Any]] = [
        [
            "kind": "insert",
            "values": [
                ["tag": "string", "value": "a"],
                ["tag": "int", "value": 7]
            ],
            "attributes": ["bold": ["tag": "bool", "value": true]]
        ],
        ["kind": "retain", "length": 3, "attributes": ["name": ["tag": "string", "value": "Ada"]]],
        ["kind": "delete", "length": 2]
    ]

    #expect(YValueCodec.delta(fromJSON: object) == [
        .insert(.string("a"), attributes: ["bold": .bool(true)]),
        .insert(.int(7), attributes: ["bold": .bool(true)]),
        .retain(3, attributes: ["name": .string("Ada")]),
        .delete(2)
    ])
}
