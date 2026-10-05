import Foundation
import GobyApplication
import GobyDomain
import Testing
@testable import GobyInfrastructure

@Suite("Instruction persistence capacity", .serialized)
struct InstructionPersistenceCapacityTests {
    @Test("Creation stops at the catalog count limit while bounded edits remain available")
    func enforcesPackCountWithoutBlockingEdits() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(
            directoryURL: directory,
            maximumInstructionPacks: 2
        )
        let first = pack(id: "first", body: "First")

        try await store.save(first)
        try await store.save(pack(id: "second", body: "Second"))
        await #expect(throws: (any Error).self) {
            try await store.save(self.pack(id: "third", body: "Third"))
        }

        let edited = InstructionPack(
            id: first.id,
            name: first.name,
            body: "Edited safely",
            scope: first.scope,
            version: first.version + 1
        )
        try await store.save(edited)

        let restored = try await PersistentStore(
            directoryURL: directory,
            maximumInstructionPacks: 2
        ).allInstructionPacks()
        #expect(restored.count == 2)
        #expect(restored.first { $0.id == first.id }?.body == "Edited safely")
    }

    @Test("A rejected encoded-size overflow leaves the prior catalog loadable")
    func encodedBudgetRejectsWithoutReplacingCurrentCatalog() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(
            directoryURL: directory,
            maximumInstructionCatalogBytes: 2_048
        )
        try await store.save(pack(id: "first", body: "Safe"))
        let catalogURL = directory.appending(path: "instructions.json")
        let before = try Data(contentsOf: catalogURL)

        await #expect(throws: (any Error).self) {
            try await store.save(self.pack(
                id: "large",
                body: String(repeating: "x", count: 10_000)
            ))
        }

        #expect(try Data(contentsOf: catalogURL) == before)
        let restored = try await PersistentStore(
            directoryURL: directory,
            maximumInstructionCatalogBytes: 2_048
        ).allInstructionPacks()
        #expect(restored.map(\.id) == ["first"])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "goby-instruction-capacity-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func pack(id: InstructionPackID, body: String) -> InstructionPack {
        InstructionPack(
            id: id,
            name: "Pack \(id.rawValue)",
            body: body,
            scope: .allProjects
        )
    }
}
