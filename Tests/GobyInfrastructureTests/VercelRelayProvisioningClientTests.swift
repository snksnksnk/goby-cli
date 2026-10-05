import Foundation
import GobyApplication
import Testing
@testable import GobyInfrastructure

@Suite("Vercel relay provisioning client")
struct VercelRelayProvisioningClientTests {
    @Test("Posts only the one-time exchange values and accepts a bounded relay credential")
    func provisionsRelay() async throws {
        let body = Data(
            "{\"relayURL\":\"wss://relay.example/v1/connect\",\"relayAdmission\":\"v1.\(String(repeating: "A", count: 43)).2000000000.\(String(repeating: "B", count: 43))\"}"
                .utf8
        )
        let sender = StubProvisioningHTTPSender(status: 200, body: body)
        let client = try VercelRelayProvisioningClient(
            baseURL: #require(URL(string: "https://goby-provisioning.vercel.app")),
            sender: sender
        )

        let relay = try await client.provision(authorization: authorization())

        #expect(relay.relayURL.absoluteString == "wss://relay.example/v1/connect")
        #expect(relay.admission.rawValue.hasPrefix("v1."))
        let request = try #require(await sender.lastRequest())
        #expect(request.url?.absoluteString == "https://goby-provisioning.vercel.app/api/v1/installations")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        let requestBody = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: String])
        #expect(payload["code"] == "authorization-code")
        #expect(payload["codeVerifier"] == String(repeating: "v", count: 43))
        #expect(payload["clientInstallationID"] == String(repeating: "I", count: 43))
        #expect(payload["client_secret"] == nil)
    }

    @Test("Maps authorization rejection without surfacing an untrusted server body")
    func rejectsUnauthorizedAccount() async throws {
        let sender = StubProvisioningHTTPSender(
            status: 403,
            body: Data("server-controlled detail".utf8),
            contentType: "text/plain"
        )
        let client = try VercelRelayProvisioningClient(
            baseURL: #require(URL(string: "https://goby-provisioning.vercel.app")),
            sender: sender
        )

        await #expect(throws: VercelRelayProvisioningError.unauthorized) {
            try await client.provision(authorization: authorization())
        }
    }

    @Test("Rejects credential-bearing and insecure provisioning endpoints")
    func rejectsUnsafeEndpoints() {
        #expect(throws: VercelRelayProvisioningError.invalidEndpoint) {
            try VercelRelayProvisioningClient(
                baseURL: #require(URL(string: "http://goby.example"))
            )
        }
        #expect(throws: VercelRelayProvisioningError.invalidEndpoint) {
            try VercelRelayProvisioningClient(
                baseURL: #require(URL(string: "https://user:secret@goby.example"))
            )
        }
    }

    @Test("Rejects query-bearing relay URLs returned by the service")
    func rejectsUnsafeRelayURL() async throws {
        let body = Data(
            "{\"relayURL\":\"wss://relay.example/v1/connect?token=leak\",\"relayAdmission\":\"v1.\(String(repeating: "A", count: 43)).2000000000.\(String(repeating: "B", count: 43))\"}"
                .utf8
        )
        let sender = StubProvisioningHTTPSender(status: 200, body: body)
        let client = try VercelRelayProvisioningClient(
            baseURL: #require(URL(string: "https://goby-provisioning.vercel.app")),
            sender: sender
        )

        await #expect(throws: VercelRelayProvisioningError.invalidResponse) {
            try await client.provision(authorization: authorization())
        }
    }

    private func authorization() -> GADRelayProvisioningAuthorization {
        GADRelayProvisioningAuthorization(
            code: "authorization-code",
            codeVerifier: String(repeating: "v", count: 43),
            redirectURI: "https://goby-provisioning.vercel.app/api/v1/oauth/callback",
            clientInstallationID: String(repeating: "I", count: 43)
        )
    }
}

private actor StubProvisioningHTTPSender: GADRelayProvisioningHTTPSending {
    private let status: Int
    private let body: Data
    private let contentType: String
    private var request: URLRequest?

    init(status: Int, body: Data, contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        guard let requestURL = request.url,
              let response = HTTPURLResponse(
            url: requestURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
              ) else {
            throw VercelRelayProvisioningError.invalidResponse
        }
        return (body, response)
    }

    func lastRequest() -> URLRequest? { request }
}
