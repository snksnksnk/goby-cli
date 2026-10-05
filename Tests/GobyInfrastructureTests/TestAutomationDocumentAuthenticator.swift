import Foundation
@testable import GobyInfrastructure

actor TestAutomationDocumentAuthenticator: GADAutomationDocumentAuthenticating {
    private var currentGeneration: UInt64 = 0
    private var currentPayload: Data?
    private var previousGeneration: UInt64 = 0
    private var previousPayload: Data?
    private var preparedGeneration: UInt64?
    private var preparedPayload: Data?
    private var payloads: [UInt64: Data] = [:]
    private var shouldFailNextCommit = false
    private var shouldSuspendNextIssue = false
    private var issueContinuation: CheckedContinuation<Void, Never>?

    func failNextCommit() {
        shouldFailNextCommit = true
    }

    func suspendNextIssue() {
        shouldSuspendNextIssue = true
    }

    var isIssueSuspended: Bool { issueContinuation != nil }

    func releaseIssue() {
        issueContinuation?.resume()
        issueContinuation = nil
    }

    func issue(for payload: Data) async throws -> GADAutomationDocumentAuthentication {
        if shouldSuspendNextIssue {
            shouldSuspendNextIssue = false
            await withCheckedContinuation { continuation in
                issueContinuation = continuation
            }
        }
        let proposedGeneration = currentGeneration + 1
        if let preparedGeneration, let preparedPayload {
            guard preparedGeneration == proposedGeneration,
                  preparedPayload == payload else {
                throw GADAutomationDocumentAuthenticationError.authenticationFailed
            }
        } else {
            preparedGeneration = proposedGeneration
            preparedPayload = payload
        }
        payloads[proposedGeneration] = payload
        return GADAutomationDocumentAuthentication(
            generation: proposedGeneration,
            tag: tag(generation: proposedGeneration, payload: payload)
        )
    }

    func commit(
        _ authentication: GADAutomationDocumentAuthentication,
        payload: Data
    ) async throws {
        if shouldFailNextCommit {
            shouldFailNextCommit = false
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        guard authentication.generation == preparedGeneration,
              payload == preparedPayload,
              authentication.tag == tag(generation: authentication.generation, payload: payload) else {
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        previousGeneration = currentGeneration
        previousPayload = currentPayload
        currentGeneration = authentication.generation
        currentPayload = payload
        preparedGeneration = nil
        preparedPayload = nil
        payloads = payloads.filter { $0.key + 1 >= currentGeneration }
    }

    func verify(
        _ authentication: GADAutomationDocumentAuthentication,
        payload: Data
    ) async throws -> GADAutomationDocumentFreshness {
        guard payloads[authentication.generation] == payload,
              authentication.tag == tag(generation: authentication.generation, payload: payload) else {
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        if authentication.generation == currentGeneration,
           payload == currentPayload {
            return .current
        }
        if authentication.generation == preparedGeneration,
           payload == preparedPayload {
            return .prepared
        }
        guard authentication.generation == previousGeneration,
              payload == previousPayload else {
            throw GADAutomationDocumentAuthenticationError.authenticationFailed
        }
        return .previous
    }

    func discardPrepared() async throws {
        preparedGeneration = nil
        preparedPayload = nil
    }

    private func tag(generation: UInt64, payload: Data) -> Data {
        var value = generation.bigEndian
        var result = Data(bytes: &value, count: MemoryLayout<UInt64>.size)
        result.append(payload)
        return result
    }
}
