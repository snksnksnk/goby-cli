import Foundation

enum ProviderProcessEnvironment {
    /// Provider helpers receive only the small process context required for
    /// locale, temporary files, account lookup and executable discovery.
    /// Everything else—including loader/runtime injection variables—is denied
    /// unless the composition root supplies one exact credential name.
    private static let inheritedNames: Set<String> = [
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LOGNAME",
        "PATH",
        "TMPDIR",
        "TZ",
        "USER",
    ]

    static func sanitized(
        _ source: [String: String],
        allowing allowedCredentialNames: Set<String> = []
    ) -> [String: String] {
        source.filter { name, _ in
            allowedCredentialNames.contains(name) || inheritedNames.contains(name)
        }
    }
}
