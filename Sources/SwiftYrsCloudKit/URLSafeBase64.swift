import Foundation

/// URL-safe, unpadded base64 for the one job this package needs it for: turning
/// an arbitrary caller string into a component of a CloudKit name or a file
/// path.
///
/// It never emits `.` or `/`, which is what lets a record name be split on `.`
/// unambiguously (ADR-0025) and a document name be used as a directory name.
enum URLSafeBase64 {
    /// The sentinel for an empty value. Base64 never produces a single
    /// character, so it cannot collide with a real encoding.
    private static let emptyComponent = "_"

    static func encode(_ value: String) -> String {
        let encoded = Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return encoded.isEmpty ? emptyComponent : encoded
    }

    /// `nil` for a component that is not valid encoded UTF-8.
    static func decode(_ component: String) -> String? {
        if component == emptyComponent { return "" }
        var base64 = component
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// How many raw bytes survive encoding within `characters` of output.
    static func encodableBytes(within characters: Int) -> Int {
        characters * 3 / 4
    }
}
