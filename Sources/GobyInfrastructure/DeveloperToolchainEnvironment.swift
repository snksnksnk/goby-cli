import Foundation

/// Locates developer toolchains that agent shells need but that a sanitized,
/// non-login provider environment cannot discover on its own. Only paths to
/// installed toolchains are exposed; no credentials or user settings.
enum DeveloperToolchainEnvironment {
    /// Candidate JDK homes in preference order: a system-registered JDK,
    /// Android Studio's bundled runtime (what Android Gradle builds are tested
    /// with), then Homebrew's OpenJDK on Apple silicon and Intel.
    static let javaHomeCandidates = [
        "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
        "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
        "/usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
    ]

    static func javaHome(
        systemJavaHome: () -> String? = registeredJavaHome,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let system = systemJavaHome(), isExecutable(system + "/bin/java") { return system }
        return javaHomeCandidates.first { isExecutable($0 + "/bin/java") }
    }

    /// `JAVA_HOME` for agent shells, or nothing when no JDK is installed.
    static func variables() -> [String: String] {
        javaHome().map { ["JAVA_HOME": $0] } ?? [:]
    }

    /// Asks macOS for a registered JDK without triggering its install prompt.
    private static func registeredJavaHome() -> String? {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return nil }
        return entries
            .filter { $0.pathExtension == "jdk" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appending(path: "Contents/Home").path(percentEncoded: false) }
            .first
    }
}
