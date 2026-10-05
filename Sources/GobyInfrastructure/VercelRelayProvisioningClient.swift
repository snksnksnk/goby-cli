import Foundation
import GobyApplication

public enum VercelRelayProvisioningError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case invalidAuthorization
    case unauthorized
    case rateLimited
    case serviceUnavailable
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Automatic relay setup is not configured in this Goby build."
        case .invalidAuthorization:
            "Vercel could not complete this sign-in. Try generating the relay again."
        case .unauthorized:
            "This Vercel account is not authorized to provision a Goby beta relay."
        case .rateLimited:
            "Relay setup is temporarily rate limited. Wait a minute and try again."
        case .serviceUnavailable:
            "The Goby relay setup service is temporarily unavailable."
        case .invalidResponse:
            "The Goby relay setup service returned an invalid response."
        }
    }
}

public protocol GADRelayProvisioningHTTPSending: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class GADRejectRedirectsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public actor GADURLSessionRelayProvisioningHTTPSender: GADRelayProvisioningHTTPSending {
    private let session: URLSession
    private let redirectDelegate = GADRejectRedirectsDelegate()

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(
            for: request,
            delegate: redirectDelegate
        )
        guard let response = response as? HTTPURLResponse else {
            throw VercelRelayProvisioningError.invalidResponse
        }
        return (data, response)
    }
}

public actor VercelRelayProvisioningClient: GADRelayProvisioning {
    private struct RequestBody: Encodable {
        let code: String
        let codeVerifier: String
        let redirectURI: String
        let clientInstallationID: String
    }

    private struct ResponseBody: Decodable {
        let relayURL: String
        let relayAdmission: String
    }

    private static let maximumResponseBytes = 16_384
    private let endpoint: URL
    private let sender: any GADRelayProvisioningHTTPSending

    public init(
        baseURL: URL,
        sender: any GADRelayProvisioningHTTPSending = GADURLSessionRelayProvisioningHTTPSender()
    ) throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw VercelRelayProvisioningError.invalidEndpoint
        }
        components.scheme = "https"
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty ? "/api/v1/installations" : components.path + "/api/v1/installations"
        guard let endpoint = components.url else {
            throw VercelRelayProvisioningError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.sender = sender
    }

    public func provision(
        authorization: GADRelayProvisioningAuthorization
    ) async throws -> GADProvisionedRelay {
        guard authorization.code.count <= 2_048,
              authorization.codeVerifier.count >= 43,
              authorization.codeVerifier.count <= 128,
              authorization.redirectURI.count <= 2_048,
              Self.isBase64URL32(authorization.clientInstallationID) else {
            throw VercelRelayProvisioningError.invalidAuthorization
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            code: authorization.code,
            codeVerifier: authorization.codeVerifier,
            redirectURI: authorization.redirectURI,
            clientInstallationID: authorization.clientInstallationID
        ))

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await sender.send(request)
        } catch let error as VercelRelayProvisioningError {
            throw error
        } catch {
            throw VercelRelayProvisioningError.serviceUnavailable
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw VercelRelayProvisioningError.invalidResponse
        }
        switch response.statusCode {
        case 200: break
        case 400: throw VercelRelayProvisioningError.invalidAuthorization
        case 401, 403: throw VercelRelayProvisioningError.unauthorized
        case 429: throw VercelRelayProvisioningError.rateLimited
        case 500...599: throw VercelRelayProvisioningError.serviceUnavailable
        default: throw VercelRelayProvisioningError.invalidResponse
        }

        guard response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().hasPrefix("application/json") == true,
              let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let relayURL = try? Self.validatedRelayURL(decoded.relayURL),
              let admission = try? GADRelayHostAdmissionCredential(decoded.relayAdmission) else {
            throw VercelRelayProvisioningError.invalidResponse
        }
        return GADProvisionedRelay(relayURL: relayURL, admission: admission)
    }

    private static func validatedRelayURL(_ source: String) throws -> URL {
        guard var components = URLComponents(string: source),
              components.scheme?.lowercased() == "wss",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw VercelRelayProvisioningError.invalidResponse
        }
        components.scheme = "wss"
        guard let url = components.url else {
            throw VercelRelayProvisioningError.invalidResponse
        }
        return url
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
}
