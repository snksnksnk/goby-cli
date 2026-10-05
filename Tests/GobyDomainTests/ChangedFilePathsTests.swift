import Foundation
import Testing
@testable import GobyDomain

@Suite("ChangedFilePathsTests")
struct ChangedFilePathsTests {
    private func step(_ id: String, _ kind: RunActivityStep.Kind, _ detail: String?, _ status: RunActivityStep.Status = .succeeded) -> RunActivityStep {
        RunActivityStep(id: id, assignmentID: "a", kind: kind, title: id, detail: detail, status: status)
    }

    @Test("Collects completed file changes in order without duplicates")
    func collectsUniquePaths() {
        let steps = [
            step("1", .fileChange, "/w/A.swift\n/w/B.swift"),
            step("2", .command, "/w/C.swift"),
            step("3", .fileChange, "/w/B.swift\n/w/D.swift"),
        ]
        #expect(steps.changedFilePaths == ["/w/A.swift", "/w/B.swift", "/w/D.swift"])
    }

    @Test("Ignores running and failed file changes")
    func ignoresUnfinishedChanges() {
        let steps = [
            step("1", .fileChange, "/w/A.swift", .running),
            step("2", .fileChange, "/w/B.swift", .failed),
            step("3", .fileChange, nil),
        ]
        #expect(steps.changedFilePaths.isEmpty)
    }
}
