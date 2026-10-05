import GobyApplication
import GobyDomain

public actor AgentRuntimeRegistry: AgentRuntimeResolving {
    private var runtimes: [AgentProviderID: any AgentRuntimeServing]

    public init(runtimes: [any AgentRuntimeServing] = []) {
        self.runtimes = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.providerID, $0) })
    }

    public func register(_ runtime: any AgentRuntimeServing) {
        runtimes[runtime.providerID] = runtime
    }

    public func unregister(providerID: AgentProviderID) {
        runtimes.removeValue(forKey: providerID)
    }

    public func providerIDs() -> [AgentProviderID] {
        runtimes.keys.sorted()
    }

    public func runtime(for providerID: AgentProviderID) -> (any AgentRuntimeServing)? {
        runtimes[providerID]
    }
}
