import GobyDomain
import Testing
@testable import GobyApplication

@Suite("Instruction catalog policy")
struct InstructionCatalogPolicyTests {
    @Test("The shared limits accept the largest supported name and body")
    func acceptsBoundaryValues() throws {
        let pack = InstructionPack(
            name: String(repeating: "n", count: InstructionCatalogPolicy.maximumNameCharacters),
            body: String(repeating: "b", count: InstructionCatalogPolicy.maximumBodyBytes),
            scope: .allProjects
        )

        try InstructionCatalogPolicy.validate(pack)
        #expect(InstructionCatalogPolicy.acceptsContent(name: pack.name, body: pack.body))
    }

    @Test("The save use case rejects oversized remote-style content before persistence")
    func rejectsOversizedContentBeforePersistence() async {
        let repository = InstructionRepositoryProbe()
        let pack = InstructionPack(
            name: "Remote instruction",
            body: String(
                repeating: "b",
                count: InstructionCatalogPolicy.maximumBodyBytes + 1
            ),
            scope: .allProjects
        )

        await #expect(throws: GobyApplicationError.invalidInstruction(
            "keep the body at or below 64 KiB"
        )) {
            try await SaveInstructionUseCase(repository: repository)(pack)
        }
        #expect(await repository.savedPacks.isEmpty)
    }

    @Test("Names are bounded consistently for desktop and mobile editors")
    func rejectsOversizedName() {
        #expect(throws: GobyApplicationError.invalidInstruction(
            "use a name up to 160 characters"
        )) {
            try InstructionCatalogPolicy.validateContent(
                name: String(
                    repeating: "n",
                    count: InstructionCatalogPolicy.maximumNameCharacters + 1
                ),
                body: "Use the shared policy"
            )
        }
    }
}

private actor InstructionRepositoryProbe: InstructionRepository {
    private(set) var savedPacks: [InstructionPack] = []

    func allInstructionPacks() -> [InstructionPack] {
        savedPacks
    }

    func save(_ pack: InstructionPack) {
        savedPacks.append(pack)
    }
}
