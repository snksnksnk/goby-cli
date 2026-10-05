import Foundation
import GobyApplication
import GobyDomain
import Testing
@testable import GobyExperience

@Suite("Temporary chat continuity")
struct TemporaryChatContinuityTests {
    @MainActor
    private func store(_ coordinator: GADCoordinator, _ deviceID: DeviceID) async -> ContinuityStore {
        let store = ContinuityStore(
            client: GADPairedContinuationFixture.makeClient(coordinator: coordinator, deviceID: deviceID),
            deviceID: deviceID,
            now: { GADPairedContinuationFixture.timestamp }
        )
        await store.connect()
        return store
    }

    @MainActor
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test("A question from the phone opens one chat that the Mac sees, and ending clears it everywhere")
    @MainActor
    func sharedChat() async throws {
        let coordinator = GADPairedContinuationFixture.makeCoordinator()
        let phone = await store(coordinator, GADPairedContinuationFixture.phoneDeviceID)
        let mac = await store(coordinator, GADPairedContinuationFixture.macDeviceID)
        #expect(phone.session?.supportsTemporaryChat == true)

        let asked = await phone.askTemporaryChat("  What is 17 × 23?  ", chatID: nil)
        #expect(asked?.disposition == .accepted)
        try await waitFor { phone.temporaryChat != nil && mac.temporaryChat != nil }
        let chat = try #require(mac.temporaryChat)
        #expect(chat.messages.map(\.role) == [.user, .assistant])
        #expect(chat.messages.first?.text == "What is 17 × 23?")

        // Continuing names the chat; a stale identifier cannot append to it.
        let stale = await mac.askTemporaryChat("Again?", chatID: "ended-chat")
        #expect(stale?.disposition == .rejectedStale)
        let followUp = await mac.askTemporaryChat("And 17 × 24?", chatID: chat.id)
        #expect(followUp?.disposition == .accepted)
        try await waitFor { phone.temporaryChat?.messages.count == 4 }

        let ended = await phone.endTemporaryChat(chat.id)
        #expect(ended?.disposition == .accepted)
        try await waitFor { phone.temporaryChat == nil && mac.temporaryChat == nil }
    }

    @Test("Empty questions are never sent")
    @MainActor
    func emptyQuestion() async {
        let coordinator = GADPairedContinuationFixture.makeCoordinator()
        let phone = await store(coordinator, GADPairedContinuationFixture.phoneDeviceID)
        #expect(await phone.askTemporaryChat(" \n ", chatID: nil) == nil)
        #expect(phone.temporaryChat == nil)
    }
}
