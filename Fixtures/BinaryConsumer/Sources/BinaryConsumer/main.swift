import YrsBridgeFFI

guard let document = yrs_bridge_doc_new() else {
    fatalError("YrsBridge failed to create a document")
}
yrs_bridge_doc_destroy(document)
