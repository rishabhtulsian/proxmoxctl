import Foundation
@testable import ProxmoxCtlCore
import XCTest

final class ConfigStoreTests: XCTestCase {
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
}
