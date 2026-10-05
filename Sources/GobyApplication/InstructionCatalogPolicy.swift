import Foundation
import GobyDomain

/// One policy shared by desktop, remote, and persistence entry points so an
/// individually valid instruction cannot grow durable state without bounds.
public enum InstructionCatalogPolicy {
    public static let maximumPackCount = 256
    public static let maximumNameCharacters = 160
    public static let maximumBodyBytes = 64 * 1_024
    public static let maximumEncodedCatalogBytes = 32 * 1_024 * 1_024

    public static func validate(_ pack: InstructionPack) throws {
        try validateContent(name: pack.name, body: pack.body)
    }

    public static func validateContent(name: String, body: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GobyApplicationError.emptyPrompt
        }
        guard name.count <= maximumNameCharacters else {
            throw GobyApplicationError.invalidInstruction(
                "use a name up to \(maximumNameCharacters) characters"
            )
        }
        guard body.utf8.count <= maximumBodyBytes else {
            throw GobyApplicationError.invalidInstruction(
                "keep the body at or below \(maximumBodyBytes / 1_024) KiB"
            )
        }
    }

    public static func acceptsContent(name: String, body: String) -> Bool {
        (try? validateContent(name: name, body: body)) != nil
    }
}
