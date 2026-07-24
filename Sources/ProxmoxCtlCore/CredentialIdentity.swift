import CryptoKit
import Foundation

public struct ConfigIdentity: Equatable, Hashable, Sendable {
    public let canonicalConfigURL: URL
    public let scope: String

    public init(configURL: URL) {
        let canonicalURL = configURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let digest = SHA256.hash(data: Data(canonicalURL.path.utf8))

        self.canonicalConfigURL = canonicalURL
        self.scope = digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct SecretIdentity: Equatable, Hashable, Sendable {
    public let account: String
    public let alias: String

    public init(account: String, alias: String) {
        self.account = account
        self.alias = alias
    }

    public static func referenced(
        config: ConfigIdentity,
        credentialReference: String,
        alias: String
    ) -> SecretIdentity {
        SecretIdentity(
            account: "v2:\(config.scope):\(credentialReference)",
            alias: alias
        )
    }

    public static func legacy(alias: String) -> SecretIdentity {
        SecretIdentity(account: alias, alias: alias)
    }
}

public enum CredentialIdentityResolver {
    public static func resolve(
        host: HostRecord,
        configURL: URL,
        defaultConfigURL: URL = FileConfigStore.defaultURL
    ) throws -> SecretIdentity {
        let configIdentity = ConfigIdentity(configURL: configURL)

        if let reference = host.credentialReference {
            return .referenced(
                config: configIdentity,
                credentialReference: reference,
                alias: host.alias
            )
        }

        guard configIdentity == ConfigIdentity(configURL: defaultConfigURL) else {
            throw ProxmoxCtlError.ambiguousLegacyCredential(host.alias)
        }
        return .legacy(alias: host.alias)
    }
}
