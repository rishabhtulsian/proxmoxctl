import Foundation
@testable import ProxmoxCtlCore
import XCTest

final class CredentialIdentityTests: XCTestCase {
    func testConfigIdentityHashesTheCanonicalConfigPath() {
        let identity = ConfigIdentity(
            configURL: URL(fileURLWithPath: "/private/tmp/proxmoxctl/config.json")
        )

        XCTAssertEqual(
            identity.scope,
            "e478bf63ee3b0ea8f02edd04a5c349857101d774f1327b5a936f162ffd823c10"
        )
        XCTAssertEqual(identity.canonicalConfigURL.path, "/private/tmp/proxmoxctl/config.json")
    }

    func testEquivalentConfigPathsHaveTheSameScope() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let direct = directory.appendingPathComponent("config.json")
        let normalized = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("config.json")

        XCTAssertEqual(ConfigIdentity(configURL: direct), ConfigIdentity(configURL: normalized))
    }

    func testDistinctCustomConfigsHaveDistinctScopes() {
        let first = ConfigIdentity(configURL: URL(fileURLWithPath: "/private/tmp/one/config.json"))
        let second = ConfigIdentity(configURL: URL(fileURLWithPath: "/private/tmp/two/config.json"))

        XCTAssertNotEqual(first.scope, second.scope)
    }

    func testReferencedSecretIdentityUsesOpaqueReferenceAndConfigScope() {
        let config = ConfigIdentity(configURL: URL(fileURLWithPath: "/private/tmp/one/config.json"))
        let identity = SecretIdentity.referenced(
            config: config,
            credentialReference: "353EB681-9D74-4C25-A93E-0B92F26081D5",
            alias: "home"
        )

        XCTAssertEqual(
            identity.account,
            "v2:\(config.scope):353EB681-9D74-4C25-A93E-0B92F26081D5"
        )
        XCTAssertFalse(identity.account.contains("home"))
        XCTAssertEqual(identity.alias, "home")
    }

    func testDefaultConfigLegacyHostUsesAliasIdentity() throws {
        let host = HostRecord(
            alias: "home",
            url: try XCTUnwrap(URL(string: "https://proxmox.example.com:8006")),
            tokenID: "root@pam!cli"
        )

        let identity = try CredentialIdentityResolver.resolve(
            host: host,
            configURL: FileConfigStore.defaultURL,
            defaultConfigURL: FileConfigStore.defaultURL
        )

        XCTAssertEqual(identity, .legacy(alias: "home"))
    }

    func testCustomConfigLegacyHostIsRejectedAsAmbiguous() throws {
        let host = HostRecord(
            alias: "home",
            url: try XCTUnwrap(URL(string: "https://proxmox.example.com:8006")),
            tokenID: "root@pam!cli"
        )
        let customURL = URL(fileURLWithPath: "/private/tmp/custom/config.json")

        XCTAssertThrowsError(
            try CredentialIdentityResolver.resolve(
                host: host,
                configURL: customURL,
                defaultConfigURL: FileConfigStore.defaultURL
            )
        ) { error in
            XCTAssertEqual(error as? ProxmoxCtlError, .ambiguousLegacyCredential("home"))
        }
    }
}
