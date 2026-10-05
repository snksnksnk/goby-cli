import Foundation

public enum GADRelayEndpointValidationError: Error, Equatable, Sendable {
    case invalidURL
}

/// Canonical validation for the public, untrusted relay endpoint.
///
/// Authentication material belongs in Goby's role-bound headers and secure
/// stores. Keeping credentials and capability-like query data out of the URL
/// prevents them from entering pairing codes, preferences, diagnostics, or
/// platform URL handling.
public enum GADRelayEndpoint {
    public static func validated(_ source: String) throws -> URL {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            throw GADRelayEndpointValidationError.invalidURL
        }
        return try validated(url)
    }

    public static func validated(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "wss",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw GADRelayEndpointValidationError.invalidURL
        }

        components.scheme = "wss"
        guard let normalized = components.url else {
            throw GADRelayEndpointValidationError.invalidURL
        }
        return normalized
    }
}
