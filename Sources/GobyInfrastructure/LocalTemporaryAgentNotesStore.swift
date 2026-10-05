import Foundation
import GobyApplication
import GobyDomain

/// Keeps one Markdown continuation file per project in the host's store,
/// outside the project repository so notes never appear as working-tree
/// changes. Files are owner-only and bounded to the newest entries.
public actor LocalTemporaryAgentNotesStore: TemporaryAgentNotesStoring {
    public static let maximumEntries = 20

    private let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public nonisolated func fileURL(for projectID: ProjectID) -> URL {
        let safeName = projectID.rawValue.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        return directoryURL.appending(path: String(safeName) + ".md", directoryHint: .notDirectory)
    }

    public func notes(for projectID: ProjectID) throws -> String? {
        do {
            let text = try String(contentsOf: fileURL(for: projectID), encoding: .utf8)
            let entries = Self.entries(in: text)
            return entries.isEmpty ? nil : entries.joined(separator: "\n\n")
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    public func append(_ entry: TemporaryAgentNoteEntry, projectID: ProjectID, projectName: String) throws {
        let url = fileURL(for: projectID)
        let existing: String
        do {
            existing = try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            existing = ""
        }
        guard !existing.contains(entry.marker) else { return }
        let entries = Array((Self.entries(in: existing) + [entry.markdown]).suffix(Self.maximumEntries))
        let header = """
        # Temporary agent notes · \(projectName)

        Goby records these notes when a temporary agent finishes, and gives them to the next temporary agent in this project. The newest entry is last. Delete this file to start fresh.
        """
        let document = ([header] + entries).joined(separator: "\n\n") + "\n"
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data(document.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Splits a notes file into its `## ` entries, dropping the header.
    static func entries(in text: String) -> [String] {
        var entries: [String] = []
        var current: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if !current.isEmpty { entries.append(current.joined(separator: "\n")) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { entries.append(current.joined(separator: "\n")) }
        return entries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
