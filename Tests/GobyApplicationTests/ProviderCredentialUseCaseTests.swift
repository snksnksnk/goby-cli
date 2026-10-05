import Testing
import GobyApplication
import GobyDomain

@Suite("ProviderCredentialUseCaseTests")
struct ProviderCredentialUseCaseTests {
    @Test("Provider credentials validate, persist outside the catalog, and can be removed")
    func credentialLifecycle() async throws {
        let repository = MemoryProviderCredentialRepository()
        let inspect = InspectProviderCredentialUseCase(repository: repository)
        let save = SaveProviderCredentialUseCase(repository: repository)
        let remove = RemoveProviderCredentialUseCase(repository: repository)

        #expect(try await inspect(providerID: .claude) == false)
        await #expect(throws: GobyApplicationError.invalidProviderCredential(.claude)) {
            try await save(providerID: .claude, credential: "short")
        }
        await #expect(throws: GobyApplicationError.invalidProviderCredential(.claude)) {
            try await save(
                providerID: .claude,
                credential: "sk-ant-api03-key with-space"
            )
        }

        let credential = "test-credential-value-123456789"
        try await save(providerID: .claude, credential: "  \(credential)  ")
        #expect(try await inspect(providerID: .claude))
        #expect(try await repository.credential(for: .claude) == credential)

        try await remove(providerID: .claude)
        #expect(try await inspect(providerID: .claude) == false)
    }

    @Test("A Claude subscription token and API key occupy separate slots")
    func claudeSubscriptionSlot() async throws {
        let repository = MemoryProviderCredentialRepository()
        let inspect = InspectProviderCredentialUseCase(repository: repository)
        let save = SaveProviderCredentialUseCase(repository: repository)
        let remove = RemoveProviderCredentialUseCase(repository: repository)
        let token = "sk-ant-oat01-subscription-token-value"
        let apiKey = "sk-ant-api03-api-key-value-123456"

        await #expect(throws: GobyApplicationError.misplacedProviderCredential(.claude, expected: .subscriptionToken)) {
            try await save(providerID: .claude, credential: apiKey, kind: .subscriptionToken)
        }
        await #expect(throws: GobyApplicationError.misplacedProviderCredential(.claude, expected: .apiKey)) {
            try await save(providerID: .claude, credential: token, kind: .apiKey)
        }
        await #expect(throws: GobyApplicationError.invalidProviderCredential(.githubCopilot)) {
            try await save(providerID: .githubCopilot, credential: token, kind: .subscriptionToken)
        }

        try await save(providerID: .claude, credential: token, kind: .subscriptionToken)
        try await save(providerID: .claude, credential: apiKey)
        #expect(await repository.credential(for: .claude, kind: .subscriptionToken) == token)
        #expect(try await repository.credential(for: .claude) == apiKey)

        try await remove(providerID: .claude, kind: .subscriptionToken)
        #expect(try await inspect(providerID: .claude, kind: .subscriptionToken) == false)
        #expect(try await inspect(providerID: .claude))
    }
}

private actor MemoryProviderCredentialRepository: ProviderCredentialRepository {
    private var values: [String: String] = [:]

    func credential(for providerID: AgentProviderID, kind: ProviderCredentialKind) -> String? {
        values["\(providerID.rawValue)/\(kind.rawValue)"]
    }

    func saveCredential(_ credential: String, for providerID: AgentProviderID, kind: ProviderCredentialKind) {
        values["\(providerID.rawValue)/\(kind.rawValue)"] = credential
    }

    func removeCredential(for providerID: AgentProviderID, kind: ProviderCredentialKind) {
        values.removeValue(forKey: "\(providerID.rawValue)/\(kind.rawValue)")
    }
}
