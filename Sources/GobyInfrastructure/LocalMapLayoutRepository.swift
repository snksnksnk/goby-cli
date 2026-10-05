import Foundation
import GobyApplication
import GobyDomain

/// Desktop presentation preferences have their own file and writer. They do
/// not mutate the background host's catalog or require a provider connection.
public actor LocalMapLayoutRepository: MapLayoutRepository {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadMapLayout() throws -> MapLayoutOverrides {
        do {
            return try JSONDecoder().decode(MapLayoutOverrides.self, from: Data(contentsOf: fileURL))
        } catch CocoaError.fileReadNoSuchFile {
            return .empty
        }
    }

    public func saveMapLayout(_ layout: MapLayoutOverrides) throws {
        let data = try JSONEncoder().encode(layout)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
