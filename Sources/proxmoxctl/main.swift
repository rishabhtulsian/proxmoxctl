import ArgumentParser
import CEditLine
import Darwin
import Foundation
import ProxmoxCtlCore

final class TerminalInteractiveLineReader: InteractiveLineReader {
    private let reader: any InteractiveLineReader

    init() {
        if isatty(STDIN_FILENO) == 1 {
            reader = ReadlineInteractiveLineReader()
        } else {
            reader = PlainInteractiveLineReader()
        }
    }

    func readLine(prompt: String) -> String? {
        reader.readLine(prompt: prompt)
    }
}

private final class ReadlineInteractiveLineReader: InteractiveLineReader {
    init() {
        using_history()
        rl_initialize()
        rl_parse_and_bind("bind -e")
        rl_parse_and_bind("bind ^R em-inc-search-prev")
    }

    func readLine(prompt: String) -> String? {
        prompt.withCString { promptPointer in
            guard let linePointer = readline(promptPointer) else {
                return nil
            }
            defer {
                free(linePointer)
            }

            let line = String(cString: linePointer)
            if InteractiveHistoryPolicy.shouldRecord(line) {
                add_history(linePointer)
            }
            return line
        }
    }
}

private struct PlainInteractiveLineReader: InteractiveLineReader {
    func readLine(prompt: String) -> String? {
        fputs(prompt, stdout)
        fflush(stdout)
        return Swift.readLine()
    }
}

@main
struct ProxmoxCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proxmoxctl",
        abstract: "Query and control Proxmox VE nodes, VMs, and containers.",
        subcommands: [
            Config.self,
            Host.self,
            Doctor.self,
            Nodes.self,
            Guests.self,
            Guest.self,
            Interactive.self
        ]
    )
}

struct GlobalOptions: ParsableArguments {
    @Option(help: "Path to the proxmoxctl config file.")
    var config: String?

    @Flag(name: [.customShort("v"), .long], help: "Log HTTP requests and responses to standard error with secrets redacted.")
    var verbose = false

    var fileURL: URL {
        (config.map { URL(fileURLWithPath: $0) } ?? FileConfigStore.defaultURL).standardizedFileURL
    }

    func runtime() -> Runtime {
        if let session = InteractiveRuntimeContext.current,
           config == nil || session.usesConfig(fileURL) {
            return session.runtime(commandVerbose: verbose)
        }
        return Runtime.standard(fileURL: fileURL, verbose: verbose)
    }
}

struct Runtime {
    let configStore: FileConfigStore
    let secretStore: SecretStore
    let debugLogger: HTTPDebugLogger?
    let sessionCache: SessionCache?

    static func standard(fileURL: URL, verbose: Bool) -> Runtime {
        Runtime(
            configStore: FileConfigStore(fileURL: fileURL),
            secretStore: AuthorizingSecretStore(
                base: KeychainSecretStore(),
                authorizer: LocalAuthenticationAuthorizer()
            ),
            debugLogger: verbose ? StderrHTTPDebugLogger() : nil,
            sessionCache: nil
        )
    }

    func config() throws -> AppConfig {
        try configStore.load()
    }

    func client(host alias: String?) throws -> ProxmoxClient {
        let config = try configStore.load()
        let host = try config.resolveHost(alias: alias)
        let secret = try secretStore.loadSecret(
            for: host.alias,
            reason: "Access the Proxmox API token for \(host.alias)"
        )
        return ProxmoxClient(
            baseURL: host.url,
            tokenID: host.tokenID,
            tokenSecret: secret,
            apiTimeoutSeconds: config.effectiveAPITimeoutSeconds,
            debugLogger: debugLogger,
            hostAlias: host.alias,
            sessionCache: sessionCache
        )
    }
}

enum InteractiveRuntimeContext {
    @TaskLocal static var current: InteractiveRuntimeSession?
}

final class InteractiveRuntimeSession: @unchecked Sendable {
    let fileURL: URL
    let verbose: Bool
    let cache = SessionCache()
    private let secretStore: SecretStore

    init(fileURL: URL, verbose: Bool) {
        self.fileURL = fileURL.standardizedFileURL
        self.verbose = verbose
        self.secretStore = CachingSecretStore(
            base: AuthorizingSecretStore(
                base: KeychainSecretStore(),
                authorizer: LocalAuthenticationAuthorizer()
            ),
            cache: cache
        )
    }

    func usesConfig(_ candidate: URL) -> Bool {
        candidate.standardizedFileURL.path == fileURL.path
    }

    func runtime(commandVerbose: Bool) -> Runtime {
        Runtime(
            configStore: FileConfigStore(fileURL: fileURL),
            secretStore: secretStore,
            debugLogger: (verbose || commandVerbose) ? StderrHTTPDebugLogger() : nil,
            sessionCache: cache
        )
    }
}

extension GuestType: ExpressibleByArgument {}
extension LifecycleOperation: ExpressibleByArgument {}

enum GuestSelection: String, ExpressibleByArgument {
    case qemu
    case lxc
    case all
}

struct Interactive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interactive",
        abstract: "Start an interactive proxmoxctl session."
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        let session = InteractiveRuntimeSession(fileURL: options.fileURL, verbose: options.verbose)
        await InteractiveRuntimeContext.$current.withValue(session) {
            await InteractiveShell(session: session).run()
        }
    }
}

struct InteractiveShell {
    let session: InteractiveRuntimeSession
    let lineReader: any InteractiveLineReader

    init(session: InteractiveRuntimeSession, lineReader: any InteractiveLineReader = TerminalInteractiveLineReader()) {
        self.session = session
        self.lineReader = lineReader
    }

    func run() async {
        let loop = InteractiveLoop(lineReader: lineReader)
        await loop.run(
            handle: { input in
                await handle(input)
            },
            handleError: { error in
                printInteractiveError(error)
            }
        )
    }

    private func handle(_ input: InteractiveInput) async {
        do {
            switch input {
            case .empty, .exit:
                return
            case .help:
                print(ProxmoxCtl.helpMessage())
            case .cacheClear:
                session.cache.clearAll()
                print("Cleared in-memory cache")
            case .command(let tokens):
                try await execute(tokens: tokens)
            }
        } catch {
            printInteractiveError(error)
        }
    }

    private func execute(tokens: [String]) async throws {
        var command = try ProxmoxCtl.parseAsRoot(tokens)
        if var asyncCommand = command as? AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
    }

    private func printInteractiveError(_ error: Error) {
        let message: String
        if error is InteractiveInputError {
            message = error.localizedDescription
        } else {
            message = ProxmoxCtl.fullMessage(for: error)
        }
        fputs(message.hasSuffix("\n") ? message : "\(message)\n", stderr)
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage proxmoxctl configuration.",
        subcommands: [ConfigSetTimeout.self]
    )
}

struct ConfigSetTimeout: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-timeout",
        abstract: "Set the global Proxmox API timeout."
    )

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Timeout in seconds. Must be finite and greater than zero.")
    var seconds: Double

    func run() throws {
        let runtime = options.runtime()
        var config = try runtime.config()
        try config.setAPITimeoutSeconds(seconds)
        try runtime.configStore.save(config)
        print("API timeout is now \(seconds) seconds")
    }
}

struct Host: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage Proxmox host configuration.",
        subcommands: [HostAdd.self, HostList.self, HostUse.self, HostRemove.self]
    )
}

struct HostAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Host alias.")
    var alias: String
    @Option(help: "Proxmox base URL, for example https://proxmox.example.com:8006.")
    var url: String
    @Option(help: "Proxmox API token ID, for example root@pam!cli.")
    var tokenID: String
    @Flag(name: .customLong("default"), help: "Make this host the default.")
    var makeDefault = false
    @Flag(help: "Read the API token secret from standard input.")
    var tokenSecretStdin = false

    func run() throws {
        guard let hostURL = URL(string: url), hostURL.scheme == "https" else {
            throw ValidationError("url must be an https URL")
        }
        let runtime = options.runtime()
        var config = try runtime.config()
        let credential = try TokenCredential(tokenID: tokenID, inputSecret: readTokenSecret())
        guard !credential.secret.isEmpty else {
            throw ValidationError("API token secret cannot be empty")
        }
        let host = HostRecord(alias: alias, url: hostURL, tokenID: credential.tokenID)
        config.upsertHost(host, makeDefault: makeDefault)
        try runtime.secretStore.saveSecret(credential.secret, for: alias)
        try runtime.configStore.save(config)
        print("Stored host \(alias)")
    }

    private func readTokenSecret() throws -> String {
        if tokenSecretStdin {
            return FileHandle.standardInput.readDataToEndOfFile()
                .withUnsafeBytes { buffer in
                    String(decoding: buffer, as: UTF8.self)
                }
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let pointer = getpass("API token secret: ") else {
            throw ValidationError("Unable to read API token secret")
        }
        return String(cString: pointer)
    }
}

struct HostList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let config = try options.runtime().config()
        print(TableRenderer.renderHosts(config.hosts, defaultAlias: config.defaultHostAlias))
    }
}

struct HostUse: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "use")

    @OptionGroup var options: GlobalOptions
    @Argument var alias: String

    func run() throws {
        let runtime = options.runtime()
        var config = try runtime.config()
        _ = try config.resolveHost(alias: alias)
        config.defaultHostAlias = alias
        try runtime.configStore.save(config)
        print("Default host is now \(alias)")
    }
}

struct HostRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove")

    @OptionGroup var options: GlobalOptions
    @Argument var alias: String

    func run() throws {
        let runtime = options.runtime()
        var config = try runtime.config()
        try config.removeHost(alias: alias)
        try runtime.secretStore.deleteSecret(for: alias)
        try runtime.configStore.save(config)
        print("Removed host \(alias)")
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check connectivity and authentication for a host.")

    @OptionGroup var options: GlobalOptions
    @Option(help: "Configured host alias. Defaults to the selected default host.")
    var host: String?

    mutating func run() async throws {
        let version = try await options.runtime().client(host: host).version()
        let display = [version.version, version.release].compactMap { $0 }.joined(separator: " ")
        print(display.isEmpty ? "Connected" : "Connected to Proxmox VE \(display)")
    }
}

struct Nodes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List Proxmox nodes.")

    @OptionGroup var options: GlobalOptions
    @Option(help: "Configured host alias. Defaults to the selected default host.")
    var host: String?
    @Flag(help: "Emit JSON.")
    var json = false

    mutating func run() async throws {
        let nodes = try await options.runtime().client(host: host).nodes()
        print(json ? try JSONRenderer.render(nodes) : TableRenderer.renderNodes(nodes))
    }
}

struct Guests: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List QEMU VMs and LXC containers.")

    @OptionGroup var options: GlobalOptions
    @Option(help: "Configured host alias. Defaults to the selected default host.")
    var host: String?
    @Option(help: "Cluster node name. If omitted, online nodes are queried.")
    var node: String?
    @Option(help: "Guest type: qemu, lxc, or all.")
    var type: GuestSelection = .all
    @Flag(help: "Emit JSON.")
    var json = false

    mutating func run() async throws {
        let client = try options.runtime().client(host: host)
        let nodeNames: [String]
        if let node {
            nodeNames = [node]
        } else {
            nodeNames = try await client.nodes().filter { $0.status == "online" }.map(\.node)
        }
        var guests: [GuestSummary] = []
        for nodeName in nodeNames {
            if type == .qemu || type == .all {
                guests += try await client.guests(node: nodeName, type: .qemu)
            }
            if type == .lxc || type == .all {
                guests += try await client.guests(node: nodeName, type: .lxc)
            }
        }
        guests.sort { ($0.node ?? "", $0.vmid, $0.type.rawValue) < ($1.node ?? "", $1.vmid, $1.type.rawValue) }
        print(json ? try JSONRenderer.render(guests) : TableRenderer.renderGuests(guests))
    }
}

struct Guest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect and manage a guest.",
        subcommands: [
            GuestStatus.self,
            GuestStart.self,
            GuestShutdown.self,
            GuestStop.self,
            GuestReboot.self,
            GuestReset.self,
            GuestSuspend.self,
            GuestPause.self,
            GuestResume.self
        ]
    )
}

struct GuestCommonOptions: ParsableArguments {
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Guest VMID.")
    var vmid: Int
    @Option(help: "Cluster node name. If omitted, proxmoxctl uses the only node on the host.")
    var node: String?
    @Option(help: "Guest type: qemu or lxc. If omitted, proxmoxctl probes QEMU then LXC.")
    var type: GuestType?
    @Option(help: "Configured host alias. Defaults to the selected default host.")
    var host: String?
    @Flag(help: "Emit JSON.")
    var json = false
}

struct GuestLifecycleOptions: ParsableArguments {
    @OptionGroup var common: GuestCommonOptions
    @Flag(help: "Skip confirmation prompts for disruptive operations.")
    var yes = false
}

struct GuestStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    @OptionGroup var options: GuestCommonOptions

    mutating func run() async throws {
        let client = try options.global.runtime().client(host: options.host)
        let node = try await resolveNode(common: options, client: client)
        let guest: GuestSummary
        if let type = options.type {
            guest = try await client.guestStatus(node: node, type: type, vmid: options.vmid)
        } else {
            guest = try await client.guestStatus(node: node, vmid: options.vmid)
        }
        if options.json {
            print(try JSONRenderer.render(guest))
        } else {
            print(TableRenderer.renderGuests([guest]))
        }
    }
}

struct GuestStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start")
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws { try await runLifecycle(.start, options: options) }
}

struct GuestShutdown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shutdown")
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws { try await runLifecycle(.shutdown, options: options) }
}

struct GuestStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop")
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws { try await runLifecycle(.stop, options: options) }
}

struct GuestReboot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reboot")
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws { try await runLifecycle(.reboot, options: options) }
}

struct GuestReset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reset")
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws { try await runLifecycle(.reset, options: options) }
}

struct GuestSuspend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "suspend")
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws { try await runLifecycle(.suspend, options: options) }
}

struct GuestPause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pause", abstract: "Alias for suspend.")
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws { try await runLifecycle(.suspend, options: options) }
}

struct GuestResume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume")
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws { try await runLifecycle(.resume, options: options) }
}

func runLifecycle(_ operation: LifecycleOperation, options: GuestLifecycleOptions) async throws {
    let common = options.common
    let client = try common.global.runtime().client(host: common.host)
    let node = try await resolveNode(common: common, client: client)
    let type = try await resolveGuestType(common: common, node: node, client: client)
    try confirmIfNeeded(operation: operation, vmid: common.vmid, node: node, type: type, yes: options.yes)
    let task = try await client.lifecycle(node: node, type: type, vmid: common.vmid, operation: operation)
    if common.json {
        print(try JSONRenderer.render(task))
    } else {
        print(task.value)
    }
}

func resolveNode(common: GuestCommonOptions, client: ProxmoxClient) async throws -> String {
    if let node = common.node, !node.isEmpty {
        return node
    }
    return try await client.singleNodeName()
}

func resolveGuestType(common: GuestCommonOptions, node: String, client: ProxmoxClient) async throws -> GuestType {
    if let type = common.type {
        return type
    }
    return try await client.resolveGuestType(node: node, vmid: common.vmid)
}

func confirmIfNeeded(operation: LifecycleOperation, vmid: Int, node: String, type: GuestType, yes: Bool) throws {
    guard ConfirmationPolicy.requiresPrompt(for: operation, assumeYes: yes) else {
        return
    }
    guard isatty(STDIN_FILENO) == 1 else {
        throw ValidationError("Operation \(operation.rawValue) requires --yes when standard input is not interactive.")
    }
    fputs("Confirm \(operation.rawValue) for \(type.rawValue) guest \(vmid) on \(node) by typing yes: ", stderr)
    guard readLine()?.lowercased() == "yes" else {
        throw ProxmoxCtlError.confirmationDeclined
    }
}
