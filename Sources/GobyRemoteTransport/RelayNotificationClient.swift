import Foundation
import GobyApplication

public enum GADRelayNotificationError: LocalizedError, Equatable, Sendable {
    case invalidRelayURL
    case invalidRevocationProof
    case rejected(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRelayURL:
            "The relay notification endpoint is invalid."
        case .invalidRevocationProof:
            "The relay could not prove that this route was revoked by the paired Goby host."
        case let .rejected(status):
            "The relay rejected the generic notification operation (HTTP \(status))."
        }
    }
}

public enum GADRelayRouteStatus: Equatable, Sendable {
    case active
    case revoked
}

public struct GADRelayHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let revocationProof: String?

    public init(statusCode: Int, revocationProof: String? = nil) {
        self.statusCode = statusCode
        self.revocationProof = revocationProof
    }
}

public protocol GADRelayHTTPRequestSending: Sendable {
    func response(for request: URLRequest) async throws -> GADRelayHTTPResponse
}

final class GADRelayStatusOnlyRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumRevocationProofBytes = 43

    private let lock = NSLock()
    private var continuation: CheckedContinuation<GADRelayHTTPResponse, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancellationRequested = false
    private var completed = false

    func response(
        for request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> GADRelayHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(request: request, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func start(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        continuation: CheckedContinuation<GADRelayHTTPResponse, any Error>
    ) {
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
        let task = session.dataTask(with: request)
        let shouldCancel = lock.withLock {
            if cancellationRequested {
                completed = true
                return true
            }
            self.continuation = continuation
            self.session = session
            self.task = task
            return false
        }
        if shouldCancel {
            session.invalidateAndCancel()
            continuation.resume(throwing: CancellationError())
        } else {
            task.resume()
        }
    }

    private func cancel() {
        let pending: (
            CheckedContinuation<GADRelayHTTPResponse, any Error>,
            URLSessionDataTask?,
            URLSession?
        )? = lock.withLock {
            cancellationRequested = true
            guard !completed, let continuation else { return nil }
            completed = true
            self.continuation = nil
            let pending = (continuation, task, session)
            task = nil
            session = nil
            return pending
        }
        guard let pending else { return }
        pending.1?.cancel()
        pending.2?.invalidateAndCancel()
        pending.0.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<GADRelayHTTPResponse, any Error>) {
        let pending: (
            CheckedContinuation<GADRelayHTTPResponse, any Error>,
            URLSessionDataTask?,
            URLSession?
        )? = lock.withLock {
            guard !completed, let continuation else { return nil }
            completed = true
            self.continuation = nil
            let pending = (continuation, task, session)
            task = nil
            session = nil
            return pending
        }
        guard let pending else { return }
        pending.1?.cancel()
        pending.2?.invalidateAndCancel()
        pending.0.resume(with: result)
    }

    private func relayResponse(from response: URLResponse) -> GADRelayHTTPResponse {
        guard let response = response as? HTTPURLResponse else {
            return GADRelayHTTPResponse(statusCode: 0)
        }
        let proof = response.value(forHTTPHeaderField: GADRelayURLBuilder.revocationProofHeader)
            .flatMap { candidate in
                candidate.utf8.count <= Self.maximumRevocationProofBytes ? candidate : nil
            }
        return GADRelayHTTPResponse(
            statusCode: response.statusCode,
            revocationProof: proof
        )
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(.cancel)
        finish(.success(relayResponse(from: response)))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.success(relayResponse(from: response)))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.failure(URLError(.badServerResponse)))
        }
    }
}

public actor GADURLSessionRelayHTTPRequestSender: GADRelayHTTPRequestSending {
    private static let requestTimeout: TimeInterval = 15
    private static let resourceTimeout: TimeInterval = 20

    private let configuration: URLSessionConfiguration

    public init(session: URLSession = .shared) {
        let configuration = session.configuration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.waitsForConnectivity = false
        self.configuration = configuration
    }

    public func response(for request: URLRequest) async throws -> GADRelayHTTPResponse {
        var request = request
        if request.timeoutInterval <= 0 || request.timeoutInterval > Self.requestTimeout {
            request.timeoutInterval = Self.requestTimeout
        }
        let operation = GADRelayStatusOnlyRequest()
        return try await operation.response(
            for: request,
            configuration: configuration.copy() as! URLSessionConfiguration
        )
    }
}

/// Host-side adapter for the relay's narrow push control surface. Requests
/// contain only a transport-specific token, environment and allowlisted generic category.
public actor GADRelayNotificationClient {
    private struct RegistrationBody: Encodable {
        let transport: String
        let token: String
        let environment: String?
        let categories: [String]
    }

    private struct CategoryBody: Encodable {
        let category: String
    }

    private let sender: any GADRelayHTTPRequestSending
    private let encoder = JSONEncoder()

    public init(sender: any GADRelayHTTPRequestSending = GADURLSessionRelayHTTPRequestSender()) {
        self.sender = sender
    }

    public func register(
        _ registration: GADNotificationRegistration,
        for profile: GADPairingProfile,
        hostAdmission: GADRelayHostAdmissionCredential
    ) async throws {
        guard registration.isValid else {
            throw GADRelayNotificationError.rejected(400)
        }
        let token: String
        switch registration.transport {
        case .apns:
            token = registration.token.map { String(format: "%02x", $0) }.joined()
        case .fcm:
            guard let value = String(data: registration.token, encoding: .utf8) else {
                throw GADRelayNotificationError.rejected(400)
            }
            token = value
        }
        try await send(
            path: "/v1/notifications/register",
            profile: profile,
            hostAdmission: hostAdmission,
            body: RegistrationBody(
                transport: registration.transport.rawValue,
                token: token,
                environment: registration.transport == .apns
                    ? registration.environment.rawValue
                    : nil,
                categories: registration.categories.map(\.rawValue)
            )
        )
    }

    public func remove(
        for profile: GADPairingProfile,
        hostAdmission: GADRelayHostAdmissionCredential
    ) async throws {
        try await send(
            path: "/v1/notifications/remove",
            profile: profile,
            hostAdmission: hostAdmission,
            body: Optional<CategoryBody>.none
        )
    }

    public func routeStatus(
        for profile: GADPairingProfile,
        role: GADRelayRole
    ) async throws -> GADRelayRouteStatus {
        let response = try await request(
            path: "/v1/status",
            method: "GET",
            profile: profile,
            role: role,
            body: nil
        )
        switch response.statusCode {
        case 204: return .active
        case 410:
            guard let proof = response.revocationProof,
                  GADRelayURLBuilder.isValidRevocationProof(proof, for: profile) else {
                throw GADRelayNotificationError.invalidRevocationProof
            }
            return .revoked
        default: throw GADRelayNotificationError.rejected(response.statusCode)
        }
    }

    public func revoke(
        for profile: GADPairingProfile,
        hostAdmission: GADRelayHostAdmissionCredential
    ) async throws {
        let response = try await request(
            path: "/v1/revoke",
            method: "POST",
            profile: profile,
            role: .host,
            hostAdmission: hostAdmission,
            body: nil,
            revocationProof: GADRelayURLBuilder.revocationProof(for: profile)
        )
        guard response.statusCode == 204 else {
            throw GADRelayNotificationError.rejected(response.statusCode)
        }
    }

    public func send(
        _ category: GADNotificationCategory,
        for profile: GADPairingProfile,
        hostAdmission: GADRelayHostAdmissionCredential
    ) async throws {
        try await send(
            path: "/v1/notifications/send",
            profile: profile,
            hostAdmission: hostAdmission,
            body: CategoryBody(category: category.rawValue)
        )
    }

    private func send<Body: Encodable>(
        path: String,
        profile: GADPairingProfile,
        hostAdmission: GADRelayHostAdmissionCredential,
        body: Body?
    ) async throws {
        let response = try await request(
            path: path,
            method: "POST",
            profile: profile,
            role: .host,
            hostAdmission: hostAdmission,
            body: try body.map(encoder.encode)
        )
        guard response.statusCode == 204 else {
            throw GADRelayNotificationError.rejected(response.statusCode)
        }
    }

    private func request(
        path: String,
        method: String,
        profile: GADPairingProfile,
        role: GADRelayRole,
        hostAdmission: GADRelayHostAdmissionCredential? = nil,
        body: Data?,
        revocationProof: String? = nil
    ) async throws -> GADRelayHTTPResponse {
        var request = GADRelayURLBuilder.request(
            for: profile,
            role: role,
            hostAdmission: hostAdmission
        )
        guard var components = URLComponents(url: profile.relayURL, resolvingAgainstBaseURL: false) else {
            throw GADRelayNotificationError.invalidRelayURL
        }
        components.scheme = "https"
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw GADRelayNotificationError.invalidRelayURL }
        request.url = url
        request.httpMethod = method
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let revocationProof {
            request.setValue(
                revocationProof,
                forHTTPHeaderField: GADRelayURLBuilder.revocationProofHeader
            )
        }
        request.httpBody = body
        return try await sender.response(for: request)
    }
}
