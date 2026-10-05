import Foundation
import Testing
import GobyDomain
@testable import GobyInfrastructure

@Suite("Preview device discovery")
struct PreviewDeviceDiscoveryTests {
    @Test("Booted simulators are read from simctl JSON")
    func simulators() {
        let json = """
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
            {"udid":"A1","name":"iPhone 17 Pro","state":"Booted","isAvailable":true},
            {"udid":"B2","name":"iPad Air","state":"Shutdown","isAvailable":true}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-26-0":[]
        }}
        """
        let devices = PreviewDeviceDiscovery.parseSimulators(Data(json.utf8))
        #expect(devices == [RunPreviewDevice(id: "A1", name: "iPhone 17 Pro", platform: .iOSSimulator)])
        #expect(PreviewDeviceDiscovery.parseSimulators(Data("not json".utf8)).isEmpty)
    }

    @Test("Running emulators are found by their qemu process and AVD name")
    func emulators() {
        let ps = """
          312 /Applications/Safari.app/Contents/MacOS/Safari
         4410 /Users/me/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -netdelay none -avd Pixel_9_API_35 -qt-hide-window
         4411 /usr/bin/grep -avd qemu-system
        """
        #expect(PreviewDeviceDiscovery.parseEmulators(ps)
            == [RunPreviewDevice(id: "emulator-4410", name: "Pixel 9 API 35", platform: .androidEmulator)])
    }

    @Test("The bounded runner returns tool output and enforces its limits")
    func boundedProcess() throws {
        let echo = try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"])
        #expect(echo.status == 0)
        #expect(echo.output == "hello\n")
        #expect(throws: BoundedProcess.Failure.timedOut) {
            try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.2)
        }
        #expect(throws: BoundedProcess.Failure.outputTooLarge) {
            try BoundedProcess.run(
                executable: URL(fileURLWithPath: "/usr/bin/yes"),
                arguments: [],
                timeout: 3,
                maximumOutputBytes: 1_000
            )
        }
    }
}
