import Darwin
import Foundation
import Security

public enum ProviderRuntimeIntegrityError: LocalizedError, Sendable {
    case invalidBundle
    case mutableInstallation

    public var errorDescription: String? {
        switch self {
        case .invalidBundle:
            "Goby blocked the provider helper because its application signature or sealed resources do not match the running Goby app. Reinstall the verified app before reconnecting credentials."
        case .mutableInstallation:
            "Goby blocked provider credentials because this app installation can be modified by the signed-in account. Install the signed beta through Goby's privileged installer in /Applications."
        }
    }
}

/// Revalidates the outer resource seal immediately before a bundled provider
/// helper can receive a Keychain credential or start a lazily loaded runtime.
public enum ProviderRuntimeIntegrity {
    public static func validateSignedBundle(
        at bundleURL: URL,
        protecting runtimeURLs: [URL] = [],
        runningBundleURL: URL = Bundle.main.bundleURL
    ) throws {
#if DEBUG
        // SwiftPM/Xcode debug products are intentionally ad-hoc or unsigned.
        // Release/provider credential paths always execute the strict branch.
        guard ProcessInfo.processInfo.environment["GOBY_REQUIRE_SIGNED_PROVIDER_RUNTIME"] == "1" else {
            return
        }
#endif
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundleURL.standardizedFileURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode else {
            throw ProviderRuntimeIntegrityError.invalidBundle
        }
        let flags = SecCSFlags(rawValue:
            kSecCSStrictValidate
                | kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
        )
        var runningCode: SecCode?
        var runningStaticCode: SecStaticCode?
        var designatedRequirement: SecRequirement?
        guard SecCodeCopySelf(SecCSFlags(), &runningCode) == errSecSuccess,
              let runningCode,
              SecCodeCopyStaticCode(
                  runningCode,
                  SecCSFlags(),
                  &runningStaticCode
              ) == errSecSuccess,
              let runningStaticCode,
              let requirement = try requirementForProtectedBundle(
                bundleURL: bundleURL,
                runningBundleURL: runningBundleURL,
                runningStaticCode: runningStaticCode,
                designatedRequirement: &designatedRequirement
              ),
              SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw ProviderRuntimeIntegrityError.invalidBundle
        }
        try validateImmutableInstallation(bundleURL: bundleURL, runtimeURLs: runtimeURLs)
    }

    private static func requirementForProtectedBundle(
        bundleURL: URL,
        runningBundleURL: URL,
        runningStaticCode: SecStaticCode,
        designatedRequirement: inout SecRequirement?
    ) throws -> SecRequirement? {
        let protected = bundleURL.standardizedFileURL
        let running = runningBundleURL.standardizedFileURL
        if protected == running {
            guard SecCodeCopyDesignatedRequirement(
                runningStaticCode,
                SecCSFlags(),
                &designatedRequirement
            ) == errSecSuccess else {
                throw ProviderRuntimeIntegrityError.invalidBundle
            }
            return designatedRequirement
        }

        guard isDescendant(running, of: protected),
              Bundle(url: protected)?.bundleIdentifier
                == "com.demetrisgeorgiou.GobyAgenticDashboard" else {
            throw ProviderRuntimeIntegrityError.invalidBundle
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            runningStaticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let information = signingInformation as? [CFString: Any],
              let teamID = information[kSecCodeInfoTeamIdentifier] as? String,
              teamID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw ProviderRuntimeIntegrityError.invalidBundle
        }
        let expression = "anchor apple generic and identifier \"com.demetrisgeorgiou.GobyAgenticDashboard\" and certificate leaf[subject.OU] = \"\(teamID)\""
        var containerRequirement: SecRequirement?
        guard SecRequirementCreateWithString(
            expression as CFString,
            SecCSFlags(),
            &containerRequirement
        ) == errSecSuccess else {
            throw ProviderRuntimeIntegrityError.invalidBundle
        }
        return containerRequirement
    }

    private static func validateImmutableInstallation(
        bundleURL: URL,
        runtimeURLs: [URL]
    ) throws {
        let bundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard bundle.path(percentEncoded: false).hasPrefix("/Applications/"),
              bundle == bundleURL.standardizedFileURL else {
            throw ProviderRuntimeIntegrityError.mutableInstallation
        }
        try validateRootOwnedPath(bundle)
        for runtimeURL in runtimeURLs {
            let runtime = runtimeURL.resolvingSymlinksInPath().standardizedFileURL
            guard runtime == runtimeURL.standardizedFileURL,
                  isDescendant(runtime, of: bundle) else {
                throw ProviderRuntimeIntegrityError.invalidBundle
            }
            var cursor = runtime
            while cursor != bundle {
                try validateRootOwnedPath(cursor)
                let parent = cursor.deletingLastPathComponent().standardizedFileURL
                guard parent != cursor else {
                    throw ProviderRuntimeIntegrityError.invalidBundle
                }
                cursor = parent
            }
        }
    }

    private static func validateRootOwnedPath(_ url: URL) throws {
        var status = stat()
        let result = url.path(percentEncoded: false).withCString { lstat($0, &status) }
        guard result == 0,
              status.st_uid == 0,
              status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw ProviderRuntimeIntegrityError.mutableInstallation
        }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.path(percentEncoded: false)
        let rootPath = root.path(percentEncoded: false)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
