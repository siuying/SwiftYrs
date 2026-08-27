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
