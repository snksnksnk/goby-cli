import Foundation
import GobyApplication
import GobyDomain

/// Finds devices a run preview can show. Simulators come from `simctl`;
/// emulators come from the process list, so discovery never starts the
/// `adb` server as a side effect.
public actor PreviewDeviceDiscovery: RunPreviewDeviceDiscovering {
    public init() {}

    public func runningDevices() async -> [RunPreviewDevice] {
        bootedSimulators() + runningEmulators()
    }

    private func bootedSimulators() -> [RunPreviewDevice] {
        guard let result = try? BoundedProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "list", "devices", "booted", "-j"],
            timeout: 8
        ), result.status == 0 else { return [] }
        return Self.parseSimulators(Data(result.output.utf8))
    }

    private func runningEmulators() -> [RunPreviewDevice] {
        guard let result = try? BoundedProcess.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axww", "-o", "pid=,command="]
        ), result.status == 0 else { return [] }
        return Self.parseEmulators(result.output)
    }

    /// Parses `simctl list devices booted -j`.
    static func parseSimulators(_ data: Data) -> [RunPreviewDevice] {
        struct Listing: Decodable {
            struct Device: Decodable {
                let udid: String
                let name: String
                let state: String
            }
            let devices: [String: [Device]]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return [] }
        return listing.devices.values.flatMap { $0 }
            .filter { $0.state == "Booted" }
            .map { RunPreviewDevice(id: $0.udid, name: $0.name, platform: .iOSSimulator) }
            .sorted { $0.name < $1.name }
    }

    /// Finds `qemu-system-*` emulator processes and their `-avd` names in
    /// `ps -o pid=,command=` output.
    static func parseEmulators(_ output: String) -> [RunPreviewDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count > 2,
                  let pid = Int(fields[0]),
                  let executable = fields[1].split(separator: "/").last,
                  executable.hasPrefix("qemu-system"),
                  let avdIndex = fields.firstIndex(of: "-avd"),
                  fields.indices.contains(avdIndex + 1) else { return nil }
            let avd = fields[avdIndex + 1]
            return RunPreviewDevice(
                id: "emulator-\(pid)",
                name: avd.replacingOccurrences(of: "_", with: " "),
                platform: .androidEmulator
            )
        }
    }
}
