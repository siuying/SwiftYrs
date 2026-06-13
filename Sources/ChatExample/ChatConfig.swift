import Foundation

/// Runtime configuration for a `ChatExample` session, assembled from
/// command-line flags with interactive and generated fallbacks for the sender
/// name.
///
/// Flags (hand-rolled parser, no package dependency):
/// - `--name <string>`   sender identity; falls back to an interactive prompt,
///                       then to `user-<short-uuid>`.
/// - `--room <string>`   room to join (default `chat-demo`).
/// - `--signaling <url>` signaling server URL; comma-separated and repeatable
///                       (default `ws://127.0.0.1:4444`).
/// - `--password <string>` optional shared-room password.
/// - `--database <path>` optional SQLite database path for local persistence.
struct ChatConfig {
    static let defaultSignaling = URL(string: "ws://127.0.0.1:4444")!

    var name: String
    var room: String
    var signaling: [URL]
    var password: String?
    var databasePath: String?

    /// Parses `arguments` (excluding the executable path) into a `ChatConfig`,
    /// resolving the sender name via `promptName` / `generateName` when no
    /// `--name` flag is supplied. Throws `ChatConfigError` on malformed input.
    static func parse(
        _ arguments: [String],
        promptName: () -> String? = ChatConfig.promptForName,
        generateName: () -> String = ChatConfig.generateName
    ) throws -> ChatConfig {
        var name: String?
        var room = "chat-demo"
        var signaling: [URL] = []
        var password: String?
        var databasePath: String?

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
            func value() throws -> String {
                let next = arguments.index(after: index)
                guard next < arguments.endIndex else {
                    throw ChatConfigError.missingValue(flag)
                }
                index = next
                return arguments[next]
            }

            switch flag {
            case "--name":
                name = try value()
            case "--room":
                room = try value()
            case "--password":
                password = try value()
            case "--database":
                databasePath = try value()
            case "--signaling":
                for piece in try value().split(separator: ",") {
                    let trimmed = piece.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    guard let url = URL(string: trimmed) else {
                        throw ChatConfigError.invalidURL(trimmed)
                    }
                    signaling.append(url)
                }
            default:
                throw ChatConfigError.unknownFlag(flag)
            }
            index = arguments.index(after: index)
        }

        let resolvedName = resolveName(name, prompt: promptName, generate: generateName)

        return ChatConfig(
            name: resolvedName,
            room: room,
            signaling: signaling.isEmpty ? [defaultSignaling] : signaling,
            password: password,
            databasePath: databasePath
        )
    }

    private static func resolveName(
        _ provided: String?,
        prompt: () -> String?,
        generate: () -> String
    ) -> String {
        if let provided, !provided.isEmpty {
            return provided
        }
        if let entered = prompt()?.trimmingCharacters(in: .whitespaces), !entered.isEmpty {
            return entered
        }
        return generate()
    }

    static func promptForName() -> String? {
        print("Enter your name: ", terminator: "")
        return readLine(strippingNewline: true)
    }

    static func generateName() -> String {
        "user-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

enum ChatConfigError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknownFlag(String)
    case invalidURL(String)

    var description: String {
        switch self {
        case let .missingValue(flag):
            "Missing value for \(flag)"
        case let .unknownFlag(flag):
            "Unknown flag: \(flag)"
        case let .invalidURL(value):
            "Invalid signaling URL: \(value)"
        }
    }
}
