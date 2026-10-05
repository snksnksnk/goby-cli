import Foundation
import GobyApplication

/// Keeps the desktop composer's unsaved request on this Mac while the
/// background host is unreachable, so a relaunch (for example after the app
/// bundle is rebuilt or updated) never loses typed text. The host remains the
/// canonical draft owner; a restored local draft that differs from the host's
/// draft is surfaced as a conflict rather than silently replacing it.
public actor LocalDraftFileCache: GADLocalDraftCaching {
    private struct Record: Codable, Sendable {
        let version: UInt16
        let text: String
    }

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadLocalDraft() throws -> String? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1, record.text.count <= 32_000 else { return nil }
        return record.text
    }

    public func saveLocalDraft(_ text: String?) throws {
        guard let text, !text.isEmpty else {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch CocoaError.fileNoSuchFile {
            }
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Record(version: 1, text: String(text.prefix(32_000))))
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
