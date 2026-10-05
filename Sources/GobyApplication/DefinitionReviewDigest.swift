import CryptoKit
import Foundation

/// Stable integrity binding between the exact bytes shown during an agent
/// definition review and the bytes later activated in a provider.
public enum DefinitionReviewDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ source: String) -> String {
        sha256(Data(source.utf8))
    }
}
