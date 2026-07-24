import Foundation

public protocol ConfigStore {
    var fileURL: URL { get }
    func load() throws -> AppConfig
    func save(_ config: AppConfig) throws
}

extension FileConfigStore: ConfigStore {}

public enum HostCredentialOperation: Equatable, Sendable {
    case added
    case replaced
    case removed
}

public struct CredentialCleanupWarning: Equatable, Sendable {
    public let operation: HostCredentialOperation
    public let alias: String
    public let account: String
    public let failureDescription: String

    public var message: String {
        switch operation {
        case .added:
            return "Host \(alias) addition committed, but credential \(account) cleanup failed: \(failureDescription)"
        case .replaced:
            return "Host \(alias) replacement committed, but the superseded credential \(account) could not be deleted: \(failureDescription)"
        case .removed:
            return "Host \(alias) removal committed, but the orphaned credential \(account) could not be deleted: \(failureDescription)"
        }
    }
}

public struct HostCredentialChangeResult: Equatable, Sendable {
    public let operation: HostCredentialOperation
    public let cleanupWarning: CredentialCleanupWarning?
}

public final class HostCredentialCoordinator {
    private let configStore: any ConfigStore
    private let secretStore: any SecretStore
    private let referenceGenerator: () -> String

    public init(
        configStore: any ConfigStore,
        secretStore: any SecretStore,
        referenceGenerator: @escaping () -> String = { UUID().uuidString }
    ) {
        self.configStore = configStore
        self.secretStore = secretStore
        self.referenceGenerator = referenceGenerator
    }

    public func validateAdd(host: HostRecord, replace: Bool) throws {
        let validatedAlias = try ConfigurationValidator.validateAlias(host.alias)
        _ = try ConfigurationValidator.validateAndCanonicalizeBaseURL(host.url.absoluteString)
        let config = try configStore.load()
        if config.hosts.contains(where: { $0.alias == validatedAlias }), !replace {
            throw ProxmoxCtlError.hostAlreadyExists(validatedAlias)
        }
    }

    public func add(
        host: HostRecord,
        secret: String,
        makeDefault: Bool,
        replace: Bool
    ) throws -> HostCredentialChangeResult {
        try validateAdd(host: host, replace: replace)
        guard !secret.isEmpty else {
            throw ProxmoxCtlError.invalidTokenSecret
        }

        let alias = try ConfigurationValidator.validateAlias(host.alias)
        let baseURL = try ConfigurationValidator.validateAndCanonicalizeBaseURL(
            host.url.absoluteString
        )
        var config = try configStore.load()
        let existingHost = config.hosts.first(where: { $0.alias == alias })
        let oldIdentity = existingHost.flatMap {
            try? CredentialIdentityResolver.resolve(
                host: $0,
                configURL: configStore.fileURL
            )
        }

        let reference = referenceGenerator()
        let stagedHost = HostRecord(
            alias: alias,
            url: baseURL,
            tokenID: host.tokenID,
            credentialReference: reference
        )
        let stagedIdentity = SecretIdentity.referenced(
            config: ConfigIdentity(configURL: configStore.fileURL),
            credentialReference: reference,
            alias: alias
        )

        try secretStore.saveSecret(secret, for: stagedIdentity)
        config.upsertHost(stagedHost, makeDefault: makeDefault)

        do {
            try configStore.save(config)
        } catch {
            try? secretStore.deleteSecret(for: stagedIdentity)
            throw error
        }

        let operation: HostCredentialOperation = existingHost == nil ? .added : .replaced
        guard let oldIdentity else {
            return HostCredentialChangeResult(operation: operation, cleanupWarning: nil)
        }

        do {
            try secretStore.deleteSecret(for: oldIdentity)
            return HostCredentialChangeResult(operation: operation, cleanupWarning: nil)
        } catch {
            return HostCredentialChangeResult(
                operation: operation,
                cleanupWarning: CredentialCleanupWarning(
                    operation: operation,
                    alias: alias,
                    account: oldIdentity.account,
                    failureDescription: error.localizedDescription
                )
            )
        }
    }

    public func remove(alias: String) throws -> HostCredentialChangeResult {
        let alias = try ConfigurationValidator.validateAlias(alias)
        var config = try configStore.load()
        let host = try config.resolveHost(alias: alias)
        let identity = try CredentialIdentityResolver.resolve(
            host: host,
            configURL: configStore.fileURL
        )

        try config.removeHost(alias: alias)
        try configStore.save(config)

        do {
            try secretStore.deleteSecret(for: identity)
            return HostCredentialChangeResult(operation: .removed, cleanupWarning: nil)
        } catch {
            return HostCredentialChangeResult(
                operation: .removed,
                cleanupWarning: CredentialCleanupWarning(
                    operation: .removed,
                    alias: alias,
                    account: identity.account,
                    failureDescription: error.localizedDescription
                )
            )
        }
    }
}
