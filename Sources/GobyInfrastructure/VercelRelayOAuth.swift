import Foundation

public enum VercelRelayOAuthError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidCallback
}

public enum VercelRelayOAuthCallback: Equatable, Sendable {
    case authorizationCode(String)
    case accessDenied
}

/// Constructs and validates the browser-facing portion of relay provisioning.
/// The authorization code remains single-use and is exchanged only by the
/// provisioning service; this type never handles a client secret or access token.
public enum VercelRelayOAuth {
    public static let nativeCallbackURI = "goby-relay-auth://oauth/callback"

    /// Vercel redirects to an HTTPS Function first. That fixed Function then
    /// returns the one-time result to `nativeCallbackURI`, which is captured by
    /// `ASWebAuthenticationSession` without registering a global URL handler.
    public static func authorizationRedirectURI(for baseURL: URL) throws -> String {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw VercelRelayOAuthError.invalidRequest
        }
        components.scheme = "https"
        components.path = "/api/v1/oauth/callback"
        guard let url = components.url else {
            throw VercelRelayOAuthError.invalidRequest
        }
        return url.absoluteString
    }

    public static func authorizationURL(
        clientID: String,
        redirectURI: String,
        state: String,
        nonce: String,
        codeChallenge: String
    ) throws -> URL {
        guard !clientID.isEmpty,
              clientID.count <= 256,
              !clientID.unicodeScalars.contains(where: Self.isControlCharacter),
              isValidAuthorizationRedirectURI(redirectURI),
              isBase64URL32(state),
              isBase64URL32(nonce),
              isBase64URL32(codeChallenge),
              var components = URLComponents(string: "https://vercel.com/oauth/authorize") else {
            throw VercelRelayOAuthError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else {
            throw VercelRelayOAuthError.invalidRequest
        }
        return url
    }

    public static func callback(
        from url: URL,
        expectedState: String
    ) throws -> VercelRelayOAuthCallback {
        guard isBase64URL32(expectedState),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "goby-relay-auth",
              components.host?.lowercased() == "oauth",
              components.path == "/callback",
              components.user == nil,
              components.password == nil,
              components.fragment?.isEmpty ?? true,
              let items = components.queryItems else {
            throw VercelRelayOAuthError.invalidCallback
        }

        let allowedNames = Set(["code", "state", "error", "error_description"])
        let grouped = Dictionary(grouping: items, by: \URLQueryItem.name)
        guard items.allSatisfy({ allowedNames.contains($0.name) }),
              grouped["state"]?.count == 1,
              grouped["state"]?.first?.value == expectedState,
              (grouped["code"]?.count ?? 0) <= 1,
              (grouped["error"]?.count ?? 0) <= 1,
              (grouped["error_description"]?.count ?? 0) <= 1 else {
            throw VercelRelayOAuthError.invalidCallback
        }

        let error = grouped["error"]?.first?.value
        if error != nil {
            guard grouped["code"] == nil else {
                throw VercelRelayOAuthError.invalidCallback
            }
            if error == "access_denied" {
                return .accessDenied
            }
            throw VercelRelayOAuthError.invalidCallback
        }
        guard grouped["error_description"] == nil,
              let code = grouped["code"]?.first?.value,
              !code.isEmpty,
              code.count <= 2_048,
              !code.unicodeScalars.contains(where: Self.isControlCharacter) else {
            throw VercelRelayOAuthError.invalidCallback
        }
        return .authorizationCode(code)
    }

    private static func isBase64URL32(_ value: String) -> Bool {
        value.count == 43 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || scalar == "_"
                || scalar == "-"
        }
    }

    private static func isValidAuthorizationRedirectURI(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.path == "/api/v1/oauth/callback",
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        return true
    }

    private static func isControlCharacter(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 32 || scalar.value == 127
    }
}
