import Foundation
import LocalAuthentication
import Security

public enum ProxmoxCtlError: LocalizedError, Equatable {
    case configNotFound(URL)
    case hostNotFound(String)
    case noDefaultHost
    case secretMissing(String)
    case invalidResponse
    case httpStatus(Int, String)
    case unauthorizedToken(String)
    case guestNotFound(Int, String)
    case nodeRequired([String])
    case mismatchedTokenID(expected: String, actual: String)
    case unsupportedOperation(LifecycleOperation, GuestType)
    case confirmationDeclined
    case invalidAPITimeout

    public var errorDescription: String? {
        switch self {
        case .configNotFound(let url):
            return "Config file not found at \(url.path)."
        case .hostNotFound(let alias):
            return "Host \(alias) is not configured."
        case .noDefaultHost:
            return "No default host is configured. Pass --host or run proxmoxctl host use <alias>."
        case .secretMissing(let alias):
            return "No API token secret is stored for host \(alias)."
        case .invalidResponse:
            return "The Proxmox API returned an invalid response."
        case .httpStatus(let statusCode, let body):
            return "The Proxmox API returned HTTP \(statusCode): \(body)"
        case .unauthorizedToken(let tokenID):
            return "Proxmox rejected API token \(tokenID) with HTTP 401. Check that the token ID uses the exact user realm and token name, and that the stored token secret is the UUID/secret value, not a password."
        case .guestNotFound(let vmid, let node):
            return "No QEMU VM or LXC container with VMID \(vmid) exists on node \(node)."
        case .nodeRequired(let nodes):
            if nodes.isEmpty {
                return "No Proxmox nodes were returned. Pass --node."
            }
            return "Cluster has multiple nodes (\(nodes.joined(separator: ", "))). Pass --node."
        case .mismatchedTokenID(let expected, let actual):
            return "The pasted API token belongs to \(actual), but this host is configured for \(expected)."
        case .unsupportedOperation(let operation, let type):
            return "Operation \(operation.rawValue) is not supported for \(type.rawValue) guests."
        case .confirmationDeclined:
            return "Operation cancelled."
        case .invalidAPITimeout:
            return "API timeout must be a finite number greater than zero."
        }
    }
}

public struct TokenCredential: Equatable {
    public var tokenID: String
    public var secret: String

    public init(tokenID: String, inputSecret: String) throws {
        self.tokenID = tokenID
        let trimmed = inputSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("PVEAPIToken=")
            ? String(trimmed.dropFirst("PVEAPIToken=".count))
            : trimmed

        if let separator = value.firstIndex(of: "=") {
            let actualTokenID = String(value[..<separator])
            let secret = String(value[value.index(after: separator)...])
            if actualTokenID.contains("!") {
                guard actualTokenID == tokenID else {
                    throw ProxmoxCtlError.mismatchedTokenID(expected: tokenID, actual: actualTokenID)
                }
                self.secret = secret
                return
            }
        }

        self.secret = value
    }
}

public struct KeychainError: LocalizedError, Equatable {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) {
        self.status = status
        self.operation = operation
    }

    public var errorDescription: String? {
        if status == errSecMissingEntitlement {
            return "Keychain failed to \(operation): missing required entitlement (-34018). The current storage path uses standard local Keychain items; rebuild with ./script/build_and_run.sh to replace any stale custom-signed binary."
        }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus error \(status)"
        return "Keychain failed to \(operation): \(message) (\(status))."
    }
}

public struct HostRecord: Codable, Equatable {
    public var alias: String
    public var url: URL
    public var tokenID: String

    public init(alias: String, url: URL, tokenID: String) {
        self.alias = alias
        self.url = url
        self.tokenID = tokenID
    }
}

public struct AppConfig: Codable, Equatable {
    public static let defaultAPITimeoutSeconds: TimeInterval = 5

    public var version: Int
    public var defaultHostAlias: String?
    public var hosts: [HostRecord]
    public private(set) var apiTimeoutSeconds: TimeInterval?

    public var effectiveAPITimeoutSeconds: TimeInterval {
        apiTimeoutSeconds ?? Self.defaultAPITimeoutSeconds
    }

    public init(
        version: Int = 1,
        defaultHostAlias: String? = nil,
        hosts: [HostRecord] = []
    ) {
        self.version = version
        self.defaultHostAlias = defaultHostAlias
        self.hosts = hosts
        self.apiTimeoutSeconds = nil
    }

    public mutating func setAPITimeoutSeconds(_ seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds > 0 else {
            throw ProxmoxCtlError.invalidAPITimeout
        }
        apiTimeoutSeconds = seconds
    }

    public func resolveHost(alias: String?) throws -> HostRecord {
        let selectedAlias: String
        if let alias, !alias.isEmpty {
            selectedAlias = alias
        } else if let defaultHostAlias, !defaultHostAlias.isEmpty {
            selectedAlias = defaultHostAlias
        } else {
            throw ProxmoxCtlError.noDefaultHost
        }

        guard let host = hosts.first(where: { $0.alias == selectedAlias }) else {
            throw ProxmoxCtlError.hostNotFound(selectedAlias)
        }
        return host
    }

    public mutating func upsertHost(_ host: HostRecord, makeDefault: Bool) {
        hosts.removeAll { $0.alias == host.alias }
        hosts.append(host)
        hosts.sort { $0.alias < $1.alias }
        if makeDefault || defaultHostAlias == nil {
            defaultHostAlias = host.alias
        }
    }

    public mutating func removeHost(alias: String) throws {
        let countBefore = hosts.count
        hosts.removeAll { $0.alias == alias }
        guard hosts.count != countBefore else {
            throw ProxmoxCtlError.hostNotFound(alias)
        }
        if defaultHostAlias == alias {
            defaultHostAlias = hosts.first?.alias
        }
    }
}

public final class FileConfigStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.decoder = JSONDecoder()
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("proxmoxctl", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public func load() throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AppConfig()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(AppConfig.self, from: data)
    }

    public func save(_ config: AppConfig) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public enum GuestType: String, Codable, CaseIterable, Equatable, Sendable {
    case qemu
    case lxc
}

public enum LifecycleOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case start
    case shutdown
    case stop
    case reboot
    case reset
    case suspend
    case resume

    public func isSupported(for type: GuestType) -> Bool {
        switch (self, type) {
        case (.reset, .lxc):
            return false
        default:
            return true
        }
    }

    public var isDisruptive: Bool {
        switch self {
        case .stop, .reboot, .reset, .suspend:
            return true
        case .start, .shutdown, .resume:
            return false
        }
    }
}

public enum ConfirmationPolicy {
    public static func requiresPrompt(for operation: LifecycleOperation, assumeYes: Bool) -> Bool {
        operation.isDisruptive && !assumeYes
    }
}

public struct NodeSummary: Codable, Equatable {
    public var node: String
    public var status: String
    public var cpu: Double?
    public var mem: Int64?
    public var maxmem: Int64?
    public var uptime: Int64?

    public init(node: String, status: String, cpu: Double? = nil, mem: Int64? = nil, maxmem: Int64? = nil, uptime: Int64? = nil) {
        self.node = node
        self.status = status
        self.cpu = cpu
        self.mem = mem
        self.maxmem = maxmem
        self.uptime = uptime
    }
}

public struct GuestSummary: Codable, Equatable {
    public var vmid: Int
    public var name: String?
    public var status: String
    public var type: GuestType
    public var node: String?
    public var mem: Int64?
    public var maxmem: Int64?
    public var uptime: Int64?

    public init(
        vmid: Int,
        name: String? = nil,
        status: String,
        type: GuestType,
        node: String? = nil,
        mem: Int64? = nil,
        maxmem: Int64? = nil,
        uptime: Int64? = nil
    ) {
        self.vmid = vmid
        self.name = name
        self.status = status
        self.type = type
        self.node = node
        self.mem = mem
        self.maxmem = maxmem
        self.uptime = uptime
    }

    enum CodingKeys: String, CodingKey {
        case vmid
        case name
        case status
        case type
        case node
        case mem
        case maxmem
        case uptime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.vmid = try container.decode(Int.self, forKey: .vmid)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        self.type = try container.decodeIfPresent(GuestType.self, forKey: .type) ?? .qemu
        self.node = try container.decodeIfPresent(String.self, forKey: .node)
        self.mem = try container.decodeIfPresent(Int64.self, forKey: .mem)
        self.maxmem = try container.decodeIfPresent(Int64.self, forKey: .maxmem)
        self.uptime = try container.decodeIfPresent(Int64.self, forKey: .uptime)
    }

    public func assigning(type: GuestType, node: String) -> GuestSummary {
        GuestSummary(
            vmid: vmid,
            name: name,
            status: status,
            type: type,
            node: node,
            mem: mem,
            maxmem: maxmem,
            uptime: uptime
        )
    }
}

public struct TaskID: Codable, Equatable {
    public var value: String

    public init(value: String) {
        self.value = value
    }
}

public struct VersionInfo: Codable, Equatable {
    public var version: String?
    public var release: String?
    public var repoid: String?

    public init(version: String? = nil, release: String? = nil, repoid: String? = nil) {
        self.version = version
        self.release = release
        self.repoid = repoid
    }
}

public protocol ProxmoxTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionProxmoxTransport: ProxmoxTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxmoxCtlError.invalidResponse
        }
        return (data, httpResponse)
    }
}

public protocol HTTPDebugLogger: AnyObject {
    func logRequest(_ request: URLRequest)
    func logResponse(_ response: HTTPURLResponse, data: Data)
}

public enum HTTPDebugFormatter {
    public static func formatRequest(_ request: URLRequest) -> String {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "<missing url>"
        var lines = ["> \(method) \(url)"]

        for (name, value) in sortedHeaders(request.allHTTPHeaderFields ?? [:]) {
            lines.append("> \(name): \(redactedHeaderValue(name: name, value: value))")
        }

        if let body = request.httpBody, !body.isEmpty {
            lines.append("> Body: \(bodyDescription(body))")
        }

        return lines.joined(separator: "\n")
    }

    public static func formatResponse(_ response: HTTPURLResponse, data: Data) -> String {
        var lines = ["< HTTP \(response.statusCode)"]

        for (name, value) in sortedHeaders(response.allHeaderFields) {
            lines.append("< \(name): \(redactedHeaderValue(name: name, value: value))")
        }

        lines.append("< Body: \(bodyDescription(data))")
        return lines.joined(separator: "\n")
    }

    private static func sortedHeaders(_ headers: [AnyHashable: Any]) -> [(String, String)] {
        headers
            .map { (String(describing: $0.key), String(describing: $0.value)) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    private static func sortedHeaders(_ headers: [String: String]) -> [(String, String)] {
        headers.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private static func redactedHeaderValue(name: String, value: String) -> String {
        switch name.lowercased() {
        case "authorization":
            return redactedAuthorization(value)
        case "cookie", "set-cookie", "proxy-authorization", "x-api-key":
            return "<redacted>"
        default:
            return value
        }
    }

    private static func redactedAuthorization(_ value: String) -> String {
        let prefix = "PVEAPIToken="
        guard value.hasPrefix(prefix) else {
            return "<redacted>"
        }

        let tokenAndSecret = String(value.dropFirst(prefix.count))
        guard let separator = tokenAndSecret.lastIndex(of: "=") else {
            return "\(prefix)<redacted>"
        }

        let tokenID = tokenAndSecret[..<separator]
        return "\(prefix)\(tokenID)=<redacted>"
    }

    private static func bodyDescription(_ data: Data) -> String {
        guard !data.isEmpty else {
            return "<empty>"
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return "<\(data.count) bytes binary body>"
        }
        return text
    }
}

public final class StderrHTTPDebugLogger: HTTPDebugLogger {
    public init() {}

    public func logRequest(_ request: URLRequest) {
        write(HTTPDebugFormatter.formatRequest(request))
    }

    public func logResponse(_ response: HTTPURLResponse, data: Data) {
        write(HTTPDebugFormatter.formatResponse(response, data: data))
    }

    private func write(_ output: String) {
        FileHandle.standardError.write(Data((output + "\n").utf8))
    }
}

final class BufferingHTTPDebugLogger: HTTPDebugLogger {
    var entries: [String] = []

    func logRequest(_ request: URLRequest) {
        entries.append(HTTPDebugFormatter.formatRequest(request))
    }

    func logResponse(_ response: HTTPURLResponse, data: Data) {
        entries.append(HTTPDebugFormatter.formatResponse(response, data: data))
    }
}

public final class ProxmoxClient {
    private let baseURL: URL
    private let tokenID: String
    private let tokenSecret: String
    private let apiTimeoutSeconds: TimeInterval
    private let transport: ProxmoxTransport
    private let debugLogger: HTTPDebugLogger?
    private let hostAlias: String?
    private let sessionCache: SessionCache?
    private let decoder = JSONDecoder()

    public init(
        baseURL: URL,
        tokenID: String,
        tokenSecret: String,
        apiTimeoutSeconds: TimeInterval = AppConfig.defaultAPITimeoutSeconds,
        transport: ProxmoxTransport = URLSessionProxmoxTransport(),
        debugLogger: HTTPDebugLogger? = nil,
        hostAlias: String? = nil,
        sessionCache: SessionCache? = nil
    ) {
        self.baseURL = baseURL
        self.tokenID = tokenID
        self.tokenSecret = tokenSecret
        self.apiTimeoutSeconds = apiTimeoutSeconds
        self.transport = transport
        self.debugLogger = debugLogger
        self.hostAlias = hostAlias
        self.sessionCache = sessionCache
    }

    public func version() async throws -> VersionInfo {
        try await get(["version"])
    }

    public func nodes() async throws -> [NodeSummary] {
        if let hostAlias, let nodes = sessionCache?.nodes(for: hostAlias) {
            return nodes
        }
        let nodes: [NodeSummary] = try await get(["nodes"])
        if let hostAlias {
            sessionCache?.storeNodes(nodes, for: hostAlias)
        }
        return nodes
    }

    public func singleNodeName() async throws -> String {
        let nodeNames = try await nodes().map(\.node).sorted()
        guard nodeNames.count == 1, let nodeName = nodeNames.first else {
            throw ProxmoxCtlError.nodeRequired(nodeNames)
        }
        return nodeName
    }

    public func guests(node: String, type: GuestType) async throws -> [GuestSummary] {
        let guests: [GuestSummary] = try await get(["nodes", node, type.rawValue])
        return guests.map { $0.assigning(type: type, node: node) }
    }

    public func clusterGuests() async throws -> [GuestSummary] {
        try await get(["cluster", "resources"], queryItems: [URLQueryItem(name: "type", value: "vm")])
    }

    public func guestStatus(node: String, type: GuestType, vmid: Int) async throws -> GuestSummary {
        let guest: GuestSummary = try await get(["nodes", node, type.rawValue, String(vmid), "status", "current"])
        return guest.assigning(type: type, node: node)
    }

    public func guestStatus(node: String, vmid: Int) async throws -> GuestSummary {
        if let type = try await guestTypeFromInventoryIfAvailable(node: node, vmid: vmid) {
            return try await guestStatus(node: node, type: type, vmid: vmid)
        }
        return try await resolveGuestStatusByEndpointProbe(node: node, vmid: vmid)
    }

    public func resolveGuestType(node: String, vmid: Int) async throws -> GuestType {
        if let type = try await guestTypeFromInventoryIfAvailable(node: node, vmid: vmid) {
            return type
        }
        return try await resolveGuestStatusByEndpointProbe(node: node, vmid: vmid).type
    }

    public func lifecycle(node: String, type: GuestType, vmid: Int, operation: LifecycleOperation) async throws -> TaskID {
        guard operation.isSupported(for: type) else {
            throw ProxmoxCtlError.unsupportedOperation(operation, type)
        }
        let task: String = try await post(["nodes", node, type.rawValue, String(vmid), "status", operation.rawValue])
        return TaskID(value: task)
    }

    private func guestTypeFromInventoryIfAvailable(node: String, vmid: Int) async throws -> GuestType? {
        do {
            return try await clusterGuests()
                .first { guest in
                    guest.vmid == vmid && guest.node == node
                }?
                .type
        } catch ProxmoxCtlError.unauthorizedToken {
            throw ProxmoxCtlError.unauthorizedToken(tokenID)
        } catch {
            return nil
        }
    }

    private func resolveGuestStatusByEndpointProbe(node: String, vmid: Int) async throws -> GuestSummary {
        do {
            return try await guestStatus(node: node, type: .qemu, vmid: vmid)
        } catch {
            guard isMissingGuestConfiguration(error) else {
                throw error
            }
        }

        do {
            return try await guestStatus(node: node, type: .lxc, vmid: vmid)
        } catch {
            guard isMissingGuestConfiguration(error) else {
                throw error
            }
            throw ProxmoxCtlError.guestNotFound(vmid, node)
        }
    }

    private func isMissingGuestConfiguration(_ error: Error) -> Bool {
        guard case ProxmoxCtlError.httpStatus(let statusCode, let body) = error else {
            return false
        }
        guard statusCode == 404 || statusCode == 500 else {
            return false
        }
        let lowercasedBody = body.lowercased()
        return lowercasedBody.contains("configuration file") && lowercasedBody.contains("does not exist")
    }

    private func get<T: Decodable>(_ path: [String], queryItems: [URLQueryItem] = []) async throws -> T {
        var request = request(url: endpoint(path, queryItems: queryItems))
        request.httpMethod = "GET"
        authorize(&request)
        return try await perform(request)
    }

    private func post<T: Decodable>(_ path: [String]) async throws -> T {
        var request = request(url: endpoint(path))
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        return try await perform(request)
    }

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = apiTimeoutSeconds
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        debugLogger?.logRequest(request)
        let (data, response) = try await transport.send(request)
        debugLogger?.logResponse(response, data: data)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                throw ProxmoxCtlError.unauthorizedToken(tokenID)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProxmoxCtlError.httpStatus(response.statusCode, body)
        }
        return try decoder.decode(ProxmoxEnvelope<T>.self, from: data).data
    }

    private func endpoint(_ path: [String], queryItems: [URLQueryItem] = []) -> URL {
        var url = baseURL
        for component in ["api2", "json"] + path {
            url.appendPathComponent(component)
        }
        guard !queryItems.isEmpty else {
            return url
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        return components?.url ?? url
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("PVEAPIToken=\(tokenID)=\(tokenSecret)", forHTTPHeaderField: "Authorization")
    }
}

private struct ProxmoxEnvelope<T: Decodable>: Decodable {
    var data: T
}

public enum TableRenderer {
    public static func renderHosts(_ hosts: [HostRecord], defaultAlias: String?) -> String {
        let rows = hosts.map { host in
            [
                host.alias == defaultAlias ? "*" : "",
                host.alias,
                host.url.absoluteString,
                host.tokenID
            ]
        }
        return render(headers: ["", "ALIAS", "URL", "TOKEN ID"], rows: rows)
    }

    public static func renderNodes(_ nodes: [NodeSummary]) -> String {
        let rows = nodes.map { node in
            [
                node.node,
                node.status,
                formatPercent(node.cpu),
                formatBytes(node.mem),
                formatBytes(node.maxmem),
                formatDuration(node.uptime)
            ]
        }
        return render(headers: ["NODE", "STATUS", "CPU", "MEM", "MAXMEM", "UPTIME"], rows: rows)
    }

    public static func renderGuests(_ guests: [GuestSummary]) -> String {
        let rows = guests.map { guest in
            [
                guest.node ?? "",
                String(guest.vmid),
                guest.type.rawValue,
                guest.name ?? "",
                guest.status,
                formatBytes(guest.mem),
                formatBytes(guest.maxmem),
                formatDuration(guest.uptime)
            ]
        }
        return render(headers: ["NODE", "VMID", "TYPE", "NAME", "STATUS", "MEM", "MAXMEM", "UPTIME"], rows: rows)
    }

    private static func render(headers: [String], rows: [[String]]) -> String {
        let allRows = [headers] + rows
        let widths = headers.indices.map { index in
            allRows.map { $0[index].count }.max() ?? 0
        }
        return allRows.map { row in
            row.enumerated()
                .map { index, value in value.padding(toLength: widths[index], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
        }
        .joined(separator: "\n")
    }

    private static func formatBytes(_ value: Int64?) -> String {
        guard let value else { return "" }
        let gib = Double(value) / 1_073_741_824.0
        return String(format: "%.1f GiB", gib)
    }

    private static func formatDuration(_ value: Int64?) -> String {
        guard let value else { return "" }
        if value < 60 { return "\(value)s" }
        if value < 3_600 { return "\(value / 60)m" }
        if value < 86_400 { return "\(value / 3_600)h" }
        return "\(value / 86_400)d"
    }

    private static func formatPercent(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.1f%%", value * 100)
    }
}

public enum JSONRenderer {
    public static func render<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

public enum InteractiveInput: Equatable {
    case empty
    case exit
    case help
    case cacheClear
    case command([String])
}

public enum InteractiveInputError: LocalizedError, Equatable {
    case unterminatedQuote
    case nestedInteractive

    public var errorDescription: String? {
        switch self {
        case .unterminatedQuote:
            return "Unterminated quoted string."
        case .nestedInteractive:
            return "Already in interactive mode."
        }
    }
}

public enum InteractiveInputParser {
    public static func parse(_ line: String) throws -> InteractiveInput {
        var tokens = try tokenize(line)
        guard !tokens.isEmpty else {
            return .empty
        }
        if tokens.first == "proxmoxctl" {
            tokens.removeFirst()
        }
        guard !tokens.isEmpty else {
            return .empty
        }

        if tokens == ["exit"] || tokens == ["quit"] {
            return .exit
        }
        if tokens == ["help"] {
            return .help
        }
        if tokens == ["cache", "clear"] {
            return .cacheClear
        }
        if tokens.first == "interactive" {
            throw InteractiveInputError.nestedInteractive
        }

        return .command(tokens)
    }

    public static func tokenize(_ line: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var buildingToken = false
        var quote: Character?
        var escaping = false

        for character in line {
            if escaping {
                current.append(character)
                buildingToken = true
                escaping = false
                continue
            }

            if character == "\\", quote != "'" {
                escaping = true
                buildingToken = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    buildingToken = true
                } else {
                    current.append(character)
                    buildingToken = true
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                buildingToken = true
                continue
            }

            if character.isShellWhitespace {
                if buildingToken {
                    tokens.append(current)
                    current = ""
                    buildingToken = false
                }
                continue
            }

            current.append(character)
            buildingToken = true
        }

        if escaping {
            current.append("\\")
        }
        guard quote == nil else {
            throw InteractiveInputError.unterminatedQuote
        }
        if buildingToken {
            tokens.append(current)
        }
        return tokens
    }
}

public protocol InteractiveLineReader {
    func readLine(prompt: String) -> String?
}

public final class InteractiveLoop {
    private let lineReader: InteractiveLineReader
    private let prompt: String

    public init(lineReader: InteractiveLineReader, prompt: String = "proxmoxctl> ") {
        self.lineReader = lineReader
        self.prompt = prompt
    }

    public func run(
        handle: @escaping (InteractiveInput) async -> Void,
        handleError: @escaping (Error) -> Void
    ) async {
        while true {
            guard let line = lineReader.readLine(prompt: prompt) else {
                return
            }

            do {
                let input = try InteractiveInputParser.parse(line)
                switch input {
                case .empty:
                    continue
                case .exit:
                    return
                case .help, .cacheClear, .command:
                    await handle(input)
                }
            } catch {
                handleError(error)
            }
        }
    }
}

public enum InteractiveHistoryPolicy {
    public static func shouldRecord(_ line: String) -> Bool {
        !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension Character {
    var isShellWhitespace: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

public final class SessionCache {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private var nodesByHostAlias: [String: [NodeSummary]] = [:]

    public init() {}

    public func secret(for alias: String) -> String? {
        lock.lock()
        let secret = secrets[alias]
        lock.unlock()
        return secret
    }

    public func storeSecret(_ secret: String, for alias: String) {
        lock.lock()
        secrets[alias] = secret
        lock.unlock()
    }

    public func nodes(for alias: String) -> [NodeSummary]? {
        lock.lock()
        let nodes = nodesByHostAlias[alias]
        lock.unlock()
        return nodes
    }

    public func storeNodes(_ nodes: [NodeSummary], for alias: String) {
        lock.lock()
        nodesByHostAlias[alias] = nodes
        lock.unlock()
    }

    public func clearNodes(for alias: String) {
        lock.lock()
        nodesByHostAlias.removeValue(forKey: alias)
        lock.unlock()
    }

    public func invalidateHost(_ alias: String) {
        lock.lock()
        secrets.removeValue(forKey: alias)
        nodesByHostAlias.removeValue(forKey: alias)
        lock.unlock()
    }

    public func clearAll() {
        lock.lock()
        secrets.removeAll()
        nodesByHostAlias.removeAll()
        lock.unlock()
    }
}

public protocol SecretStore {
    func saveSecret(_ secret: String, for alias: String) throws
    func loadSecret(for alias: String, reason: String) throws -> String
    func deleteSecret(for alias: String) throws
}

public final class CachingSecretStore: SecretStore {
    private let base: SecretStore
    private let cache: SessionCache

    public init(base: SecretStore, cache: SessionCache) {
        self.base = base
        self.cache = cache
    }

    public func saveSecret(_ secret: String, for alias: String) throws {
        try base.saveSecret(secret, for: alias)
        cache.storeSecret(secret, for: alias)
        cache.clearNodes(for: alias)
    }

    public func loadSecret(for alias: String, reason: String) throws -> String {
        if let cached = cache.secret(for: alias) {
            return cached
        }
        let secret = try base.loadSecret(for: alias, reason: reason)
        cache.storeSecret(secret, for: alias)
        return secret
    }

    public func deleteSecret(for alias: String) throws {
        try base.deleteSecret(for: alias)
        cache.invalidateHost(alias)
    }
}

public protocol LocalAuthorizer {
    func authorize(reason: String) throws
}

public final class LocalAuthenticationAuthorizer: LocalAuthorizer {
    public init() {}

    public func authorize(reason: String) throws {
        let context = LAContext()
        var policyError: NSError?
        let policy = LAPolicy.deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &policyError) else {
            throw policyError ?? ProxmoxCtlError.confirmationDeclined
        }

        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = AuthorizationResultBox()
        context.evaluatePolicy(policy, localizedReason: reason) { success, error in
            if success {
                resultBox.set(.success(()))
            } else {
                resultBox.set(.failure(error ?? ProxmoxCtlError.confirmationDeclined))
            }
            semaphore.signal()
        }
        semaphore.wait()
        try resultBox.get()
    }
}

private final class AuthorizationResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error> = .failure(ProxmoxCtlError.confirmationDeclined)

    func set(_ result: Result<Void, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() throws {
        lock.lock()
        let result = self.result
        lock.unlock()
        try result.get()
    }
}

public final class AuthorizingSecretStore: SecretStore {
    private let base: SecretStore
    private let authorizer: LocalAuthorizer

    public init(base: SecretStore, authorizer: LocalAuthorizer) {
        self.base = base
        self.authorizer = authorizer
    }

    public func saveSecret(_ secret: String, for alias: String) throws {
        try authorizer.authorize(reason: "Authorize storing the Proxmox API token for \(alias)")
        try base.saveSecret(secret, for: alias)
    }

    public func loadSecret(for alias: String, reason: String) throws -> String {
        try authorizer.authorize(reason: reason)
        return try base.loadSecret(for: alias, reason: reason)
    }

    public func deleteSecret(for alias: String) throws {
        try base.deleteSecret(for: alias)
    }
}

public final class KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "com.tulsian.proxmoxctl") {
        self.service = service
    }

    public func saveSecret(_ secret: String, for alias: String) throws {
        try deleteSecret(for: alias)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: alias,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(secret.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status, operation: "save API token")
        }
    }

    public func loadSecret(for alias: String, reason: String = "Access your Proxmox API token") throws -> String {
        let context = LAContext()
        context.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: alias,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw ProxmoxCtlError.secretMissing(alias)
        }
        guard status == errSecSuccess, let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status, operation: "load API token")
        }
        return secret
    }

    public func deleteSecret(for alias: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: alias
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete API token")
        }
    }
}
