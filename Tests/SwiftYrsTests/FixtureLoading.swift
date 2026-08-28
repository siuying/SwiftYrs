import Foundation
import Testing

/// Decodes an Interop Fixture from the test bundle's `Fixtures` directory.
///
/// This is the one place that knows where fixtures live and how they are
/// decoded, so a fixture model only declares its fields. `JSONDecoder` decodes
/// `Data` properties from base64 strings by default, which is exactly how
/// `scripts/generate-yjs-fixtures.mjs` writes updates, state vectors, and
/// awareness payloads.
func loadFixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
    let url = try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? Bundle.module.url(forResource: name, withExtension: "json")
    )
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}
