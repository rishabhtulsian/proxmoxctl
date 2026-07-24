import Foundation
@testable import ProxmoxCtlCore
import XCTest

final class ConfigStoreTests: XCTestCase {
    func testVersionOneHostWithoutCredentialReferenceDecodesAsLegacy() throws {
        let data = Data(
            #"""
            {
              "version": 1,
              "defaultHostAlias": "home",
              "hosts": [{
                "alias": "home",
                "url": "https://proxmox.example.com:8006",
                "tokenID": "root@pam!cli"
              }]
            }
            """#.utf8
        )

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertNil(try XCTUnwrap(config.hosts.first).credentialReference)
    }

    func testFileConfigStoreRoundTripsOpaqueCredentialReferenceWithoutSecret() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("config.json")
        let store = FileConfigStore(fileURL: fileURL)
        let host = HostRecord(
            alias: "home",
            url: try XCTUnwrap(URL(string: "https://proxmox.example.com:8006")),
            tokenID: "root@pam!cli",
            credentialReference: "353EB681-9D74-4C25-A93E-0B92F26081D5"
        )

        try store.save(AppConfig(defaultHostAlias: "home", hosts: [host]))

        let loaded = try store.load()
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(loaded.hosts.first?.credentialReference, host.credentialReference)
        XCTAssertTrue(raw.contains("353EB681-9D74-4C25-A93E-0B92F26081D5"))
        XCTAssertFalse(raw.contains("secret-token"))
    }

    func testFileConfigStorePersistsHostsWithoutTokenSecret() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("config.json")
        let store = FileConfigStore(fileURL: fileURL)
        let host = HostRecord(
            alias: "home",
            url: try XCTUnwrap(URL(string: "https://proxmox.example.com:8006")),
            tokenID: "root@pam!cli"
        )
        let config = AppConfig(version: 1, defaultHostAlias: "home", hosts: [host])

        try store.save(config)

        let loaded = try store.load()
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber

        XCTAssertEqual(loaded, config)
        XCTAssertTrue(raw.contains("root@pam!cli"))
        XCTAssertFalse(raw.contains("secret"))
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testDefaultHostResolvesTheSelectedHost() throws {
        let host = HostRecord(
            alias: "home",
            url: try XCTUnwrap(URL(string: "https://proxmox.example.com:8006")),
            tokenID: "root@pam!cli"
        )
        let config = AppConfig(version: 1, defaultHostAlias: "home", hosts: [host])

        XCTAssertEqual(try config.resolveHost(alias: nil), host)
        XCTAssertEqual(try config.resolveHost(alias: "home"), host)
    }

    func testMissingAPITimeoutUsesFiveSecondDefault() throws {
        let data = Data(#"{"version":1,"hosts":[]}"#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertNil(config.apiTimeoutSeconds)
        XCTAssertEqual(config.effectiveAPITimeoutSeconds, 5)
    }

    func testFileConfigStorePersistsConfiguredAPITimeout() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("config.json")
        let store = FileConfigStore(fileURL: fileURL)
        var config = AppConfig()
        try config.setAPITimeoutSeconds(12.5)

        try store.save(config)

        let loaded = try store.load()
        XCTAssertEqual(loaded.apiTimeoutSeconds, 12.5)
        XCTAssertEqual(loaded.effectiveAPITimeoutSeconds, 12.5)
    }

    func testAPITimeoutRejectsNonPositiveAndNonFiniteValues() throws {
        for value in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
            var config = AppConfig()

            XCTAssertThrowsError(try config.setAPITimeoutSeconds(value)) { error in
                XCTAssertEqual(error as? ProxmoxCtlError, .invalidAPITimeout)
            }
            XCTAssertNil(config.apiTimeoutSeconds)
            XCTAssertEqual(config.effectiveAPITimeoutSeconds, 5)
        }
    }

    func testFileConfigStoreRejectsDecodedNonPositiveTimeouts() throws {
        for value in [0, -1] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let fileURL = directory.appendingPathComponent("config.json")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"version":1,"hosts":[],"apiTimeoutSeconds":\#(value)}"#.utf8)
                .write(to: fileURL)

            XCTAssertThrowsError(try FileConfigStore(fileURL: fileURL).load()) { error in
                XCTAssertEqual(error as? ProxmoxCtlError, .invalidAPITimeout)
            }
        }
    }

    func testFileConfigStoreRejectsInvalidConfigBeforeSave() throws {
        let data = Data(#"{"version":1,"hosts":[],"apiTimeoutSeconds":0}"#.utf8)
        let invalidConfig = try JSONDecoder().decode(AppConfig.self, from: data)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("config.json")

        XCTAssertThrowsError(try FileConfigStore(fileURL: fileURL).save(invalidConfig)) { error in
            XCTAssertEqual(error as? ProxmoxCtlError, .invalidAPITimeout)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
