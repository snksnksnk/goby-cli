import Dispatch
import Foundation
import GobyCLIKit

@main
enum GobyCLI {
    static func main() {
        Task { @MainActor in
            let code = await GobyCLIEntrypoint.run(arguments: Array(CommandLine.arguments.dropFirst()))
            exit(code)
        }
        dispatchMain()
    }
}
