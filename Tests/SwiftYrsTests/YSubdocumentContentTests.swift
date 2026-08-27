import Foundation
import SwiftYrs
import Testing

@Test
func subdocumentOpensByKeyAndSharesContentAcrossHandles() throws {
    let doc = YDoc()
    let map = try doc.map(named: "pages")

    let created = try doc.write { transaction in
        try transaction.setNewSubdoc(forKey: "home", in: map)
    }

    let first = try doc.read { transaction in
        try transaction.subdocDoc(forKey: "home", in: map)
    }
    try #expect(first.guid == created.guid)

    let body = try first.text(named: "body")
    try first.write { transaction in
        try transaction.insert("hello", into: body, at: 0)
    }

    let second = try doc.read { transaction in
        try transaction.subdocDoc(forKey: "home", in: map)
    }
    let secondBody = try second.text(named: "body")
    let value = try second.read { transaction in
        try transaction.string(from: secondBody)
    }
    #expect(value == "hello")
}

@Test
func subdocumentLookupRejectsValuesThatAreNotSubdocuments() throws {
    let doc = YDoc()
    let map = try doc.map(named: "pages")
    try doc.write { transaction in
        try transaction.set(.string("not a document"), forKey: "home", in: map)
    }

    #expect(throws: YError.typeMismatch) {
        try doc.read { transaction in
            _ = try transaction.subdocDoc(forKey: "home", in: map)
        }
    }

    #expect(throws: YError.typeMismatch) {
        try doc.read { transaction in
            _ = try transaction.subdocDoc(forKey: "missing", in: map)
        }
    }
}

@Test
func subdocumentMadeByYjsMaterialisesWithTheSameGuid() throws {
    let fixture = try YjsSubdocumentFixture.load("subdocument-document")

    let doc = YDoc()
    try doc.apply(.v1(fixture.updateV1))

    let map = try doc.map(named: "pages")
    try doc.read { transaction in
        #expect(try transaction.subdocGuids() == [fixture.guid])
        try #expect(transaction.subdoc(forKey: "home", in: map).guid == fixture.guid)
    }

    let subdoc = try doc.read { transaction in
        try transaction.subdocDoc(forKey: "home", in: map)
    }
    try #expect(subdoc.guid == fixture.guid)

    let body = try subdoc.text(named: "body")
    // The parent update carried the entry only; the content arrives separately.
    try #expect(subdoc.read { try $0.string(from: body) } == "")

    try subdoc.apply(.v1(fixture.subdocUpdateV1))
    try #expect(subdoc.read { try $0.string(from: body) } == "Yjs page body")

    // The same subdocument is reachable by its GUID alone.
    let byGuid = try doc.read { try $0.subdocDoc(guid: fixture.guid) }
    let byGuidBody = try byGuid.text(named: "body")
    try #expect(byGuid.read { try $0.string(from: byGuidBody) } == "Yjs page body")
}

struct YjsSubdocumentFixture: Decodable {
    let guid: String
    let updateV1: Data
    let subdocUpdateV1: Data

    private enum CodingKeys: String, CodingKey {
        case guid
        case updateV1
        case subdocUpdateV1
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guid = try container.decode(String.self, forKey: .guid)
        updateV1 = try Self.decodeBase64(.updateV1, from: container)
        subdocUpdateV1 = try Self.decodeBase64(.subdocUpdateV1, from: container)
    }

    static func load(_ name: String) throws -> YjsSubdocumentFixture {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(forResource: name, withExtension: "json")
        )
        return try JSONDecoder().decode(YjsSubdocumentFixture.self, from: Data(contentsOf: url))
    }

    private static func decodeBase64(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Data {
        let value = try container.decode(String.self, forKey: key)
        guard let data = Data(base64Encoded: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Expected base64-encoded bytes"
            )
        }
        return data
    }
}
