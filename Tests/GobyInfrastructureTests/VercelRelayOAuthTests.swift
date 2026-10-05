import Foundation
import Testing
@testable import GobyInfrastructure

@Suite("Vercel relay OAuth")
struct VercelRelayOAuthTests {
    private let token = String(repeating: "A", count: 43)
    private let redirectURI = "https://goby-preview.vercel.app/api/v1/oauth/callback"

    @Test("Derives the exact HTTPS callback from a Preview origin")
    func derivesAuthorizationRedirect() throws {
        let origin = try #require(URL(string: "https://goby-preview.vercel.app"))
        #expect(
            try VercelRelayOAuth.authorizationRedirectURI(for: origin)
                == redirectURI
        )
    }

    @Test("Builds the exact authorization-code and PKCE request")
    func buildsAuthorizationRequest() throws {
        let url = try VercelRelayOAuth.authorizationURL(
            clientID: "client_123",
            redirectURI: redirectURI,
            state: token,
            nonce: String(repeating: "B", count: 43),
            codeChallenge: String(repeating: "C", count: 43)
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: try #require(components.queryItems).map {
            ($0.name, $0.value)
        })

        #expect(components.scheme == "https")
        #expect(components.host == "vercel.com")
        #expect(components.path == "/oauth/authorize")
        #expect(values["client_id"] == "client_123")
        #expect(values["scope"] == "openid email profile")
        #expect(values["redirect_uri"] == redirectURI)
        #expect(values["response_type"] == "code")
        #expect(values["state"] == token)
        #expect(values["code_challenge_method"] == "S256")
    }

    @Test("Accepts one bounded authorization code with exact state")
    func acceptsValidCallback() throws {
        let url = try #require(URL(string: "goby-relay-auth://oauth/callback?code=once&state=\(token)"))
        #expect(try VercelRelayOAuth.callback(from: url, expectedState: token) == .authorizationCode("once"))

        let macOSCallback = try #require(
            URL(string: "goby-relay-auth://oauth/callback?code=once&state=\(token)#")
        )
        #expect(
            try VercelRelayOAuth.callback(from: macOSCallback, expectedState: token)
                == .authorizationCode("once")
        )
    }

    @Test("Maps an exact access denial to cancellation")
    func acceptsAccessDenial() throws {
        let url = try #require(URL(string: "goby-relay-auth://oauth/callback?error=access_denied&state=\(token)"))
        #expect(try VercelRelayOAuth.callback(from: url, expectedState: token) == .accessDenied)
    }

    @Test(arguments: [
        "goby-relay-auth://oauth/callback?code=once&state=wrong",
        "goby-relay-auth://oauth/callback?code=one&code=two&state=\(String(repeating: "A", count: 43))",
        "goby-relay-auth://oauth/callback?code=once&error=access_denied&state=\(String(repeating: "A", count: 43))",
        "goby-relay-auth://oauth/callback?error_description=nope&state=\(String(repeating: "A", count: 43))",
        "goby-relay-auth://oauth/callback?code=once&state=\(String(repeating: "A", count: 43))&extra=value",
        "goby-relay-auth://oauth/callback?code=once&state=\(String(repeating: "A", count: 43))#content",
        "goby-relay-auth://other/callback?code=once&state=\(String(repeating: "A", count: 43))",
    ])
    func rejectsMalformedOrAmbiguousCallbacks(source: String) throws {
        let url = try #require(URL(string: source))
        #expect(throws: VercelRelayOAuthError.invalidCallback) {
            try VercelRelayOAuth.callback(from: url, expectedState: token)
        }
    }

    @Test("Rejects malformed authorization inputs")
    func rejectsMalformedAuthorizationRequest() {
        #expect(throws: VercelRelayOAuthError.invalidRequest) {
            try VercelRelayOAuth.authorizationURL(
                clientID: "",
                redirectURI: redirectURI,
                state: token,
                nonce: token,
                codeChallenge: token
            )
        }
        #expect(throws: VercelRelayOAuthError.invalidRequest) {
            try VercelRelayOAuth.authorizationURL(
                clientID: "client",
                redirectURI: "https://attacker.example/callback",
                state: token,
                nonce: token,
                codeChallenge: token
            )
        }
        #expect(throws: VercelRelayOAuthError.invalidRequest) {
            try VercelRelayOAuth.authorizationRedirectURI(
                for: #require(URL(string: "https://goby-preview.vercel.app/extra"))
            )
        }
    }
}
