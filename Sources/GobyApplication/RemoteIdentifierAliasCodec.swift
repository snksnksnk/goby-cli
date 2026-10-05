import CryptoKit
import Foundation

public enum RemoteIdentifierAliasCodecError: Error, Equatable, Sendable {
    case invalidKey
    case invalidRepresentation
    case unknownAlias
}

public struct RemoteIdentifierAliasTable: Equatable, Sendable {
    fileprivate var localByRemote: [String: String]

    public init() {
        localByRemote = [:]
    }

    fileprivate mutating func record(local: String, remote: String) {
        localByRemote[remote] = local
    }

    fileprivate mutating func merge(_ other: Self) {
        localByRemote.merge(other.localByRemote) { current, _ in current }
    }
}

public struct RemoteIdentifierAliasResult<Value: Sendable>: Sendable {
    public let value: Value
    public let aliases: RemoteIdentifierAliasTable

    public init(value: Value, aliases: RemoteIdentifierAliasTable) {
        self.value = value
        self.aliases = aliases
    }
}

/// Converts only typed, path-derived identifier `rawValue` fields at the
/// authenticated host boundary. Local identifiers remain unchanged in the
/// canonical store, while paired clients receive stable keyed aliases that
/// cannot be tested against guessed Mac paths without the installation key.
public struct RemoteIdentifierAliasCodec: Sendable {
    private let key: SymmetricKey

    public init(keyData: Data) throws {
        guard keyData.count == 32 else { throw RemoteIdentifierAliasCodecError.invalidKey }
        key = SymmetricKey(data: keyData)
    }

    public func aliasing<Value: Codable & Sendable>(
        _ value: Value
    ) throws -> RemoteIdentifierAliasResult<Value> {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        var aliases = RemoteIdentifierAliasTable()
        let transformed = aliasObject(object, keyName: nil, aliases: &aliases)
        guard JSONSerialization.isValidJSONObject(transformed) else {
            throw RemoteIdentifierAliasCodecError.invalidRepresentation
        }
        let transformedData = try JSONSerialization.data(withJSONObject: transformed)
        return RemoteIdentifierAliasResult(
            value: try JSONDecoder().decode(Value.self, from: transformedData),
            aliases: aliases
        )
    }

    public func localizing<Value: Codable & Sendable>(
        _ value: Value,
        aliases: RemoteIdentifierAliasTable
    ) throws -> Value {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        let transformed = try localizeObject(object, keyName: nil, aliases: aliases)
        guard JSONSerialization.isValidJSONObject(transformed) else {
            throw RemoteIdentifierAliasCodecError.invalidRepresentation
        }
        let transformedData = try JSONSerialization.data(withJSONObject: transformed)
        return try JSONDecoder().decode(Value.self, from: transformedData)
    }

    public func merging(
        _ current: RemoteIdentifierAliasTable,
        with additional: RemoteIdentifierAliasTable
    ) -> RemoteIdentifierAliasTable {
        var result = current
        result.merge(additional)
        return result
    }

    private func aliasObject(
        _ object: Any,
        keyName: String?,
        aliases: inout RemoteIdentifierAliasTable
    ) -> Any {
        if let dictionary = object as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                result[key] = aliasObject(value, keyName: key, aliases: &aliases)
            }
            return result
        }
        if let array = object as? [Any] {
            return array.map { aliasObject($0, keyName: keyName, aliases: &aliases) }
        }
        guard isIdentifierField(keyName), let source = object as? String,
              let kind = pathDerivedKind(source) else { return object }
        let remote = remoteAlias(kind: kind, local: source)
        aliases.record(local: source, remote: remote)
        return remote
    }

    private func localizeObject(
        _ object: Any,
        keyName: String?,
        aliases: RemoteIdentifierAliasTable
    ) throws -> Any {
        if let dictionary = object as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                result[key] = try localizeObject(value, keyName: key, aliases: aliases)
            }
            return result
        }
        if let array = object as? [Any] {
            return try array.map { try localizeObject($0, keyName: keyName, aliases: aliases) }
        }
        guard isIdentifierField(keyName), let source = object as? String,
              source.hasPrefix("remote-project-v1-")
                || source.hasPrefix("remote-agent-v1-")
                || source.hasPrefix("remote-binding-v1-") else { return object }
        guard let local = aliases.localByRemote[source] else {
            throw RemoteIdentifierAliasCodecError.unknownAlias
        }
        return local
    }

    private func pathDerivedKind(_ source: String) -> String? {
        for kind in ["project", "agent", "binding"] {
            let prefix = "\(kind)-"
            guard source.hasPrefix(prefix) else { continue }
            let suffix = source.dropFirst(prefix.count)
            guard !suffix.isEmpty, suffix.count <= 16,
                  suffix.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            return kind
        }
        return nil
    }

    private func remoteAlias(kind: String, local: String) -> String {
        let material = Data("goby.remote-id.v1\u{1f}\(kind)\u{1f}\(local)".utf8)
        let digest = HMAC<SHA256>.authenticationCode(for: material, using: key)
        return "remote-\(kind)-v1-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isIdentifierField(_ keyName: String?) -> Bool {
        guard let keyName else { return true }
        return keyName == "id"
            || keyName == "rawValue"
            || keyName == "projectID"
            || keyName == "projectIDs"
            || keyName == "selectedProjectIDs"
            || keyName == "agentID"
            || keyName == "agentIDs"
            || keyName == "bindingID"
            || keyName == "_0"
            || keyName == "_1"
    }

}
