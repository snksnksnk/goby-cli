import Foundation
import GobyApplication
import GobyDomain
import Observation

/// Live previews for the run thread on the Mac. Discovery runs only while the
/// panel is open, and nothing here is ever sent to paired devices.
@MainActor
@Observable
public final class RunPreviewStore {
    public static let deviceRefreshInterval: Duration = .seconds(5)

    public private(set) var isPresented = false
    public var selectedTargetID: String?
    public private(set) var devices: [RunPreviewDevice] = []

    @ObservationIgnored private var discovery: (any RunPreviewDeviceDiscovering)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var cachedSignature: String?
    @ObservationIgnored private var cachedTargets: [RunPreviewTarget] = []

    public init(discovery: (any RunPreviewDeviceDiscovering)? = nil) {
        self.discovery = discovery
    }

    /// Set once from the app's composition root.
    public func configure(discovery: any RunPreviewDeviceDiscovering) {
        self.discovery = discovery
    }

    /// What this run can preview. Re-detected only when its activity changes.
    public func targets(for run: RunRecord?) -> [RunPreviewTarget] {
        guard let run else { return [] }
        let signature = "\(run.id.rawValue)|\(run.activity.count)|\(run.activity.last?.id ?? "")|\(run.activity.last?.status.rawValue ?? "")"
        if signature != cachedSignature {
            cachedSignature = signature
            cachedTargets = RunPreviewDetector.targets(in: run.activity)
        }
        return cachedTargets
    }

    public func selectedTarget(in targets: [RunPreviewTarget]) -> RunPreviewTarget? {
        targets.first { $0.id == selectedTargetID } ?? targets.first
    }

    public func devices(for target: RunPreviewTarget) -> [RunPreviewDevice] {
        switch target {
        case .simulator: devices.filter { $0.platform == .iOSSimulator }
        case .emulator: devices.filter { $0.platform == .androidEmulator }
        case .web, .automationBrowser: []
        }
    }

    public func toggle() {
        isPresented ? dismiss() : present()
    }

    public func present() {
        guard !isPresented else { return }
        isPresented = true
        startRefreshing()
    }

    public func dismiss() {
        isPresented = false
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func refreshDevices() async {
        guard let discovery else { return }
        let found = await discovery.runningDevices()
        if found != devices { devices = found }
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshDevices()
                do { try await Task.sleep(for: Self.deviceRefreshInterval) } catch { return }
            }
        }
    }
}
