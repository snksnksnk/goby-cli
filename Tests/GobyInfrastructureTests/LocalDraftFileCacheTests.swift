import Foundation
import Testing
@testable import GobyInfrastructure

@Suite("Local composer draft cache")
struct LocalDraftFileCacheTests {
    @Test("A saved draft survives a new cache instance and clearing removes it privately")
    func roundTripsAndClears() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goby-draft-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "Presentation/composer-draft.json")

        #expect(try await LocalDraftFileCache(fileURL: fileURL).loadLocalDraft() == nil)
        try await LocalDraftFileCache(fileURL: fileURL).saveLocalDraft("make me a plan")
        #expect(try await LocalDraftFileCache(fileURL: fileURL).loadLocalDraft() == "make me a plan")
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        try await LocalDraftFileCache(fileURL: fileURL).saveLocalDraft(nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        try await LocalDraftFileCache(fileURL: fileURL).saveLocalDraft(nil)
    }
}
