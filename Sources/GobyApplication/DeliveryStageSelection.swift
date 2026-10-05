import Foundation
import GobyDomain

/// Chooses which delivery stages a request needs. The vocabulary and order are
/// fixed by Goby; the request only decides which stages are included.
public enum DeliveryStageSelection {
    static let planWords: Set<String> = [
        "plan", "planning", "architect", "architecture", "spec", "specification"
    ]
    static let testWords: Set<String> = [
        "test", "tests", "testing", "qa", "verify", "verification", "regression"
    ]
    static let stressWords: Set<String> = [
        "stress", "load", "performance", "benchmark", "benchmarks", "throughput",
        "latency", "scalability", "soak"
    ]
    static let securityWords: Set<String> = [
        "security", "secure", "pentest", "penetration", "vulnerability", "vulnerabilities",
        "exploit", "leak", "leaks", "leaked", "injection", "xss", "csrf", "secret", "secrets", "threat"
    ]
    static let releaseWords: Set<String> = ["release", "ship", "deploy", "publish"]

    /// Stages the request explicitly names, plus implementation for change
    /// requests. QA is added for implementation separately, only when a
    /// distinct testing owner exists, so labs without specialists keep
    /// single-step execution.
    public static func requestedKinds(for prompt: String, mutatesCode: Bool) -> [DeliveryStageKind] {
        let tokens = prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let words = Set(tokens)
        // "stress test" or "security test" names that stage, not QA.
        let qualifiers = stressWords.union(securityWords).union(["pen"])
        let asksForQA = tokens.indices.contains { index in
            testWords.contains(tokens[index]) && (index == 0 || !qualifiers.contains(tokens[index - 1]))
        }
        var kinds: Set<DeliveryStageKind> = []
        if mutatesCode { kinds.insert(.implement) }
        if !words.isDisjoint(with: planWords) { kinds.insert(.plan) }
        if asksForQA { kinds.insert(.qualityAssurance) }
        if !words.isDisjoint(with: stressWords) { kinds.insert(.stressTest) }
        if !words.isDisjoint(with: securityWords) { kinds.insert(.securityTest) }
        if !words.isDisjoint(with: releaseWords) { kinds.insert(.release) }
        if kinds.contains(.release), kinds.isDisjoint(with: [.qualityAssurance, .stressTest, .securityTest]) {
            kinds.insert(.qualityAssurance)
        }
        return DeliveryStageKind.allCases.filter(kinds.contains)
    }

    /// Capabilities that describe a stage responsibility rather than the
    /// ability to make the change itself.
    public static let stageOnlyCapabilities: Set<AgentCapability> = [
        .routing, .research, .testing, .review, .security, .release
    ]

    /// The implementation owner is the router's own choice unless it picked
    /// only stage specialists (for example because the request mentioned
    /// "release"); then the project's platform engineer makes the change.
    public static func implementationOwner(
        routedAgentIDs: [AgentID],
        among agents: [AgentProfile],
        project: LabProject
    ) -> AgentProfile? {
        let routed = routedAgentIDs.compactMap { id in agents.first { $0.id == id } }
        if let builder = routed.first(where: { !$0.capabilities.isSubset(of: stageOnlyCapabilities) }) {
            return builder
        }
        let platform = Set(project.platforms.compactMap(AgentRoutingMatcher.platformCapability))
        let builders = agents.filter { !$0.capabilities.isSubset(of: stageOnlyCapabilities) }
        let preferred = builders.filter { !$0.capabilities.isDisjoint(with: platform) }
        return (preferred.isEmpty ? builders : preferred).sorted { lhs, rhs in
            let lhsExtra = lhs.capabilities.subtracting(platform).count
            let rhsExtra = rhs.capabilities.subtracting(platform).count
            if lhsExtra != rhsExtra { return lhsExtra < rhsExtra }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.first ?? routed.first
    }

    /// The best owner for a stage: the fewest unrelated capabilities, then name.
    public static func owner(
        for kind: DeliveryStageKind,
        among agents: [AgentProfile]
    ) -> AgentProfile? {
        let required = kind.requiredCapabilities
        guard !required.isEmpty else { return nil }
        return agents
            .filter { required.isSubset(of: $0.capabilities) }
            .sorted { lhs, rhs in
                let lhsExtra = lhs.capabilities.subtracting(required).count
                let rhsExtra = rhs.capabilities.subtracting(required).count
                if lhsExtra != rhsExtra { return lhsExtra < rhsExtra }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .first
    }

    public static func passCriteria(for kind: DeliveryStageKind) -> String {
        switch kind {
        case .plan: "A concrete plan with affected files, steps, risks, and tests."
        case .implement: "The change is complete, builds, and project checks pass."
        case .qualityAssurance: "The build succeeds, relevant tests pass, and review finds no correctness defects."
        case .stressTest: "No crashes, hangs, or unacceptable slowdowns under load on the local build."
        case .securityTest: "No exploitable vulnerability, secret leak, or unsafe input handling in the change."
        case .release: "Release notes and a readiness checklist are complete. Nothing is pushed or published."
        }
    }
}
