import Foundation

/// Produces a reversible, perceptible representation of untrusted approval
/// text. Literal backslashes are doubled so an attacker cannot forge the
/// scalar-escape syntax used for invisible or bidirectional Unicode.
public enum ApprovalDisplayPolicy {
    public static func exactVisibleText(_ source: String) -> String {
        source.unicodeScalars.map { scalar -> String in
            if scalar == "\\" {
                return "\\\\"
            }
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                return String(scalar)
            default:
                if scalar.properties.isDefaultIgnorableCodePoint {
                    return scalarEscape(scalar)
                }
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    return scalarEscape(scalar)
                default:
                    return String(scalar)
                }
            }
        }.joined()
    }

    private static func scalarEscape(_ scalar: UnicodeScalar) -> String {
        "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
    }
}
