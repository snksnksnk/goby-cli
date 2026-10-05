// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "GobyCLI",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "goby", targets: ["GobyCLI"])
    ],
    targets: [
        .target(name: "GobyDomain"),
        .target(
            name: "GobyApplication",
            dependencies: ["GobyDomain"]
        ),
        .target(
            name: "GobyInfrastructure",
            dependencies: ["GobyDomain", "GobyApplication"],
            resources: [.copy("Resources/ProjectTemplates")]
        ),
        .target(
            name: "GobyRemoteContract",
            dependencies: ["GobyDomain", "GobyApplication"]
        ),
        .target(
            name: "GobyRemoteTransport",
            dependencies: ["GobyApplication", "GobyRemoteContract"]
        ),
        .target(
            name: "GobyExperience",
            dependencies: ["GobyDomain", "GobyApplication"]
        ),
        .target(
            name: "GobyOperations",
            dependencies: ["GobyDomain", "GobyApplication", "GobyExperience"]
        ),
        .target(
            name: "GobyHostCore",
            dependencies: [
                "GobyDomain", "GobyApplication", "GobyInfrastructure",
                "GobyOperations", "GobyRemoteTransport"
            ]
        ),
        .target(
            name: "GobyCLIKit",
            dependencies: ["GobyHostCore", "GobyExperience", "GobyInfrastructure", "GobyApplication", "GobyDomain"]
        ),
        .executableTarget(name: "GobyCLI", dependencies: ["GobyCLIKit"]),
        // Test-only host process used by the CLI signal and transport tests.
        .executableTarget(
            name: "GobyCLIHostFixture",
            dependencies: ["GobyCLIKit", "GobyHostCore", "GobyDomain", "GobyApplication", "GobyInfrastructure"]
        ),
        .testTarget(name: "GobyDomainTests", dependencies: ["GobyDomain"]),
        .testTarget(
            name: "GobyApplicationTests",
            dependencies: ["GobyDomain", "GobyApplication"]
        ),
        .testTarget(
            name: "GobyRemoteContractTests",
            dependencies: ["GobyDomain", "GobyApplication", "GobyRemoteContract"]
        ),
        .testTarget(
            name: "GobyRemoteTransportTests",
            dependencies: ["GobyApplication", "GobyRemoteContract", "GobyRemoteTransport"]
        ),
        .testTarget(
            name: "GobyExperienceTests",
            dependencies: ["GobyDomain", "GobyApplication", "GobyExperience"]
        ),
        .testTarget(
            name: "GobyInfrastructureTests",
            dependencies: ["GobyDomain", "GobyApplication", "GobyInfrastructure"]
        ),
        .testTarget(
            name: "GobyHostCoreTests",
            dependencies: ["GobyDomain", "GobyApplication", "GobyHostCore", "GobyInfrastructure"]
        ),
        .testTarget(
            name: "GobyCLIKitTests",
            dependencies: ["GobyCLIKit", "GobyHostCore", "GobyApplication", "GobyDomain", "GobyInfrastructure", "GobyExperience"]
        )
    ],
    swiftLanguageModes: [.v6]
)
