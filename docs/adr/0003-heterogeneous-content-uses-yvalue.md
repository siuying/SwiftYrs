# Heterogeneous Content Uses YValue

The core Swift API will represent Yjs/Yrs container content with a single `YValue` enum rather than generic collection element types. Yjs arrays and maps can contain mixed scalar values, nested shared types, subdocuments, XML nodes, weak links, binary data, `null`, and `undefined`, so generic containers would either misrepresent the model or reject valid CRDT content. Typed helpers and Codable bridges can be layered over `YValue` where they are genuinely safe.
