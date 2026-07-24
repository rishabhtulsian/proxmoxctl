import Foundation
@testable import ProxmoxCtlCore
import XCTest

final class HostCredentialCoordinatorTests: XCTestCase {
    func testDuplicateAliasWithoutReplaceFailsBeforeMutation() throws {
        let fixture = try Fixture()

        XCTAssertThrowsError(
            try fixture.coordinator.add(
                host: fixture.replacementHost,
                secret: "new-secret",
                makeDefault: false,
                replace: false
            )
        ) { error in
            XCTAssertEqual(error as? ProxmoxCtlError, .hostAlreadyExists("home"))
        }
        XCTAssertEqual(fixture.configStore.config, fixture.originalConfig)
        XCTAssertEqual(fixture.events.values, [])
        XCTAssertEqual(fixture.secretStore.secrets, [fixture.oldIdentity: "old-secret"])
    }

    func testExplicitReplacementStagesCommitsThenCleansUpSupersededSecret() throws {
        let fixture = try Fixture()

        let result = try fixture.coordinator.add(
            host: fixture.replacementHost,
            secret: "new-secret",
            makeDefault: false,
            replace: true
        )

        let activeHost = try fixture.configStore.config.resolveHost(alias: "home")
        let activeIdentity = try CredentialIdentityResolver.resolve(
            host: activeHost,
            configURL: fixture.configStore.fileURL,
            defaultConfigURL: fixture.configStore.fileURL
        )
        XCTAssertEqual(result.operation, .replaced)
        XCTAssertNil(result.cleanupWarning)
        XCTAssertEqual(
            fixture.events.values,
            [.saveSecret(activeIdentity), .saveConfig, .deleteSecret(fixture.oldIdentity)]
        )
        XCTAssertEqual(fixture.secretStore.secrets[activeIdentity], "new-secret")
        XCTAssertNil(fixture.secretStore.secrets[fixture.oldIdentity])
    }

    func testStagedSecretSaveFailureLeavesConfigAndActiveSecretUntouched() throws {
        let fixture = try Fixture()
        fixture.secretStore.failSave = true

        XCTAssertThrowsError(
            try fixture.coordinator.add(
                host: fixture.replacementHost,
                secret: "new-secret",
                makeDefault: false,
                replace: true
            )
        )

        XCTAssertEqual(fixture.configStore.config, fixture.originalConfig)
        XCTAssertEqual(fixture.secretStore.secrets, [fixture.oldIdentity: "old-secret"])
        XCTAssertEqual(fixture.events.values.count, 1)
    }

    func testConfigSaveFailureRollsBackStagedSecret() throws {
        let fixture = try Fixture()
        fixture.configStore.failSave = true

        XCTAssertThrowsError(
            try fixture.coordinator.add(
                host: fixture.replacementHost,
                secret: "new-secret",
                makeDefault: false,
                replace: true
            )
        )

        XCTAssertEqual(fixture.configStore.config, fixture.originalConfig)
        XCTAssertEqual(fixture.secretStore.secrets, [fixture.oldIdentity: "old-secret"])
        guard case .saveSecret(let stagedIdentity) = fixture.events.values.first else {
            return XCTFail("Expected a staged secret save")
        }
        XCTAssertEqual(
            fixture.events.values,
            [.saveSecret(stagedIdentity), .saveConfig, .deleteSecret(stagedIdentity)]
        )
    }

    func testReplacementCleanupFailureReturnsPreciseWarningAfterCommit() throws {
        let fixture = try Fixture()
        fixture.secretStore.failDeleteAccounts = [fixture.oldIdentity.account]

        let result = try fixture.coordinator.add(
            host: fixture.replacementHost,
            secret: "new-secret",
            makeDefault: false,
            replace: true
        )

        let activeHost = try fixture.configStore.config.resolveHost(alias: "home")
        let activeIdentity = try CredentialIdentityResolver.resolve(
            host: activeHost,
            configURL: fixture.configStore.fileURL,
            defaultConfigURL: fixture.configStore.fileURL
        )
        XCTAssertEqual(fixture.secretStore.secrets[activeIdentity], "new-secret")
        XCTAssertEqual(fixture.secretStore.secrets[fixture.oldIdentity], "old-secret")
        XCTAssertEqual(
            result.cleanupWarning?.message,
            "Host home replacement committed, but the superseded credential \(fixture.oldIdentity.account) could not be deleted: injected delete failure"
        )
    }

    func testRemovalCommitsConfigBeforeDeletingSecret() throws {
        let fixture = try Fixture()

        let result = try fixture.coordinator.remove(alias: "home")

        XCTAssertEqual(result.operation, .removed)
        XCTAssertNil(result.cleanupWarning)
        XCTAssertTrue(fixture.configStore.config.hosts.isEmpty)
        XCTAssertEqual(
            fixture.events.values,
            [.saveConfig, .deleteSecret(fixture.oldIdentity)]
        )
    }

    func testRemovalCleanupFailureLeavesHostRemovedAndReturnsPreciseWarning() throws {
        let fixture = try Fixture()
        fixture.secretStore.failDeleteAccounts = [fixture.oldIdentity.account]

        let result = try fixture.coordinator.remove(alias: "home")

        XCTAssertTrue(fixture.configStore.config.hosts.isEmpty)
        XCTAssertEqual(fixture.secretStore.secrets[fixture.oldIdentity], "old-secret")
        XCTAssertEqual(
            result.cleanupWarning?.message,
            "Host home removal committed, but the orphaned credential \(fixture.oldIdentity.account) could not be deleted: injected delete failure"
        )
    }
}

private extension HostCredentialCoordinatorTests {
    final class Fixture {
        let events = EventLog()
        let configStore: FakeConfigStore
        let secretStore: FakeSecretStore
        let coordinator: HostCredentialCoordinator
        let originalConfig: AppConfig
        let oldIdentity = SecretIdentity.legacy(alias: "home")
        let replacementHost: HostRecord

        init() throws {
            let host = HostRecord(
                alias: "home",
                url: try XCTUnwrap(URL(string: "https://old.example.com:8006")),
                tokenID: "root@pam!old"
            )
            originalConfig = AppConfig(defaultHostAlias: "home", hosts: [host])
            replacementHost = HostRecord(
                alias: "home",
                url: try XCTUnwrap(URL(string: "https://new.example.com:8006")),
                tokenID: "root@pam!new"
            )
            configStore = FakeConfigStore(
                fileURL: FileConfigStore.defaultURL,
                config: originalConfig,
                events: events
            )
            secretStore = FakeSecretStore(
                secrets: [oldIdentity: "old-secret"],
                events: events
            )
            coordinator = HostCredentialCoordinator(
                configStore: configStore,
                secretStore: secretStore,
                referenceGenerator: { "NEW-REFERENCE" }
            )
        }
    }

    final class EventLog {
        var values: [Event] = []
    }

    enum Event: Equatable {
        case saveSecret(SecretIdentity)
        case saveConfig
        case deleteSecret(SecretIdentity)
    }

    final class FakeConfigStore: ConfigStore {
        let fileURL: URL
        var config: AppConfig
        var failSave = false
        let events: EventLog

        init(fileURL: URL, config: AppConfig, events: EventLog) {
            self.fileURL = fileURL
            self.config = config
            self.events = events
        }

        func load() throws -> AppConfig {
            config
        }

        func save(_ config: AppConfig) throws {
            events.values.append(.saveConfig)
            if failSave {
                throw TestFailure.injected
            }
            self.config = config
        }
    }

    final class FakeSecretStore: SecretStore {
        var secrets: [SecretIdentity: String]
        var failSave = false
        var failDeleteAccounts: Set<String> = []
        let events: EventLog

        init(secrets: [SecretIdentity: String], events: EventLog) {
            self.secrets = secrets
            self.events = events
        }

        func saveSecret(_ secret: String, for identity: SecretIdentity) throws {
            events.values.append(.saveSecret(identity))
            if failSave {
                throw TestFailure.injected
            }
            secrets[identity] = secret
        }

        func loadSecret(for identity: SecretIdentity, reason: String) throws -> String {
            guard let secret = secrets[identity] else {
                throw ProxmoxCtlError.secretMissing(identity.alias)
            }
            return secret
        }

        func deleteSecret(for identity: SecretIdentity) throws {
            events.values.append(.deleteSecret(identity))
            if failDeleteAccounts.contains(identity.account) {
                throw TestFailure.injected
            }
            secrets.removeValue(forKey: identity)
        }
    }

    enum TestFailure: LocalizedError {
        case injected

        var errorDescription: String? {
            "injected delete failure"
        }
    }
}
