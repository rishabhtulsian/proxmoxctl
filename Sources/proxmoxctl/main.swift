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

    @Option(help: "Path to the proxmoxctl config file. May appear before the subcommand.")
    var config: String?

    @Flag(
        name: [.customShort("v"), .long],
        help: "Log redacted HTTP details. May appear before the subcommand."
    )
    var verbose = false

    var globalOptions: GlobalOptions {
        GlobalOptions(config: config, verbose: verbose)
    }

    mutating func validate() throws {
        try GlobalOptionOccurrenceValidator.validate(
            arguments: Array(ProcessInfo.processInfo.arguments.dropFirst())
        )
    }
}

struct GlobalOptions: ParsableArguments {
    @Option(help: "Path to the proxmoxctl config file.")
    var config: String?

    @Flag(name: [.customShort("v"), .long], help: "Log HTTP requests and responses to standard error with secrets redacted.")
    var verbose = false

    init() {}

    init(config: String?, verbose: Bool) {
        self.config = config
        self.verbose = verbose
    }

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

enum EffectiveOptionsResolver {
    static func resolve(root: GlobalOptions, leaf: GlobalOptions) throws -> GlobalOptions {
        let config: String?
        switch (root.config, leaf.config) {
        case (nil, nil):
            config = nil
        case (let value?, nil), (nil, let value?):
            config = value
        case (let rootValue?, let leafValue?):
            let rootIdentity = ConfigIdentity(configURL: URL(fileURLWithPath: rootValue))
            let leafIdentity = ConfigIdentity(configURL: URL(fileURLWithPath: leafValue))
            guard rootIdentity == leafIdentity else {
                throw ValidationError(
                    "Conflicting config paths: \(rootValue) and \(leafValue). Supply one config or equivalent paths."
                )
            }
            config = rootValue
        }
        return GlobalOptions(config: config, verbose: root.verbose || leaf.verbose)
    }
}

enum GlobalOptionOccurrenceValidator {
    static func validate(arguments: [String]) throws {
        var suppliedConfigs: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--config", index + 1 < arguments.count {
                suppliedConfigs.append(arguments[index + 1])
                index += 2
                continue
            }
            if argument.hasPrefix("--config=") {
                suppliedConfigs.append(String(argument.dropFirst("--config=".count)))
            }
            index += 1
        }

        guard let first = suppliedConfigs.first else {
            return
        }
        let firstIdentity = ConfigIdentity(configURL: URL(fileURLWithPath: first))
        if let conflicting = suppliedConfigs.dropFirst().first(where: {
            ConfigIdentity(configURL: URL(fileURLWithPath: $0)) != firstIdentity
        }) {
            throw ValidationError(
                "Conflicting config paths: \(first) and \(conflicting). Supply one config or equivalent paths."
            )
        }
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
        let identity = try CredentialIdentityResolver.resolve(
            host: host,
            configURL: configStore.fileURL
        )
        let secret = try secretStore.loadSecret(
            for: identity,
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

    @ParentCommand var parent: ProxmoxCtl
    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        let effective = try EffectiveOptionsResolver.resolve(
            root: parent.globalOptions,
            leaf: options
        )
        let session = InteractiveRuntimeSession(
            fileURL: effective.fileURL,
            verbose: effective.verbose
        )
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
        try GlobalOptionOccurrenceValidator.validate(arguments: tokens)
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

    @ParentCommand var root: ProxmoxCtl
}

struct ConfigSetTimeout: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-timeout",
        abstract: "Set the global Proxmox API timeout."
    )

    @ParentCommand var parent: Config
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Timeout in seconds. Must be finite and greater than zero.")
    var seconds: Double

    func run() throws {
        let runtime = try EffectiveOptionsResolver.resolve(
            root: parent.root.globalOptions,
            leaf: options
        ).runtime()
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

    @ParentCommand var root: ProxmoxCtl
}

struct HostAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a host, or explicitly replace one with --replace."
    )

    @ParentCommand var parent: Host
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Host alias: non-empty, no control characters or surrounding whitespace.")
    var alias: String
    @Option(help: "HTTPS base URL with host and optional port; paths, credentials, queries, and fragments are rejected.")
    var url: String
    @Option(help: "Proxmox API token ID, for example root@pam!cli.")
    var tokenID: String
    @Flag(name: .customLong("default"), help: "Make this host the default.")
    var makeDefault = false
    @Flag(help: "Replace an existing alias using a newly staged, config-scoped credential.")
    var replace = false
    @Flag(help: "Read the API token secret from standard input.")
    var tokenSecretStdin = false

    func run() throws {
        let validatedAlias = try ConfigurationValidator.validateAlias(alias)
        let hostURL = try ConfigurationValidator.validateAndCanonicalizeBaseURL(url)
        let runtime = try EffectiveOptionsResolver.resolve(
            root: parent.root.globalOptions,
            leaf: options
        ).runtime()
        let candidate = HostRecord(alias: validatedAlias, url: hostURL, tokenID: tokenID)
        let coordinator = HostCredentialCoordinator(
            configStore: runtime.configStore,
            secretStore: runtime.secretStore
        )
        try coordinator.validateAdd(host: candidate, replace: replace)
        let credential = try TokenCredential(tokenID: tokenID, inputSecret: readTokenSecret())
        guard !credential.secret.isEmpty else {
            throw ValidationError("API token secret cannot be empty")
        }
        let result = try coordinator.add(
            host: HostRecord(
                alias: validatedAlias,
                url: hostURL,
                tokenID: credential.tokenID
            ),
            secret: credential.secret,
            makeDefault: makeDefault,
            replace: replace
        )
        if let warning = result.cleanupWarning {
            FileHandle.standardError.write(Data(("Warning: \(warning.message)\n").utf8))
        }
        print("Stored host \(validatedAlias)")
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

    @ParentCommand var parent: Host
    @OptionGroup var options: GlobalOptions

    func run() throws {
        let effective = try EffectiveOptionsResolver.resolve(
            root: parent.root.globalOptions,
            leaf: options
        )
        let config = try effective.runtime().config()
        print(TableRenderer.renderHosts(config.hosts, defaultAlias: config.defaultHostAlias))
    }
}

struct HostUse: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "use")

    @ParentCommand var parent: Host
    @OptionGroup var options: GlobalOptions
    @Argument var alias: String

    func run() throws {
        let runtime = try EffectiveOptionsResolver.resolve(
            root: parent.root.globalOptions,
            leaf: options
        ).runtime()
        var config = try runtime.config()
        _ = try config.resolveHost(alias: alias)
        config.defaultHostAlias = alias
        try runtime.configStore.save(config)
        print("Default host is now \(alias)")
    }
}

struct HostRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove")

    @ParentCommand var parent: Host
    @OptionGroup var options: GlobalOptions
    @Argument var alias: String

    func run() throws {
        let runtime = try EffectiveOptionsResolver.resolve(
            root: parent.root.globalOptions,
            leaf: options
        ).runtime()
        let result = try HostCredentialCoordinator(
            configStore: runtime.configStore,
            secretStore: runtime.secretStore
        )
        .remove(alias: alias)
        if let warning = result.cleanupWarning {
            FileHandle.standardError.write(Data(("Warning: \(warning.message)\n").utf8))
        }
        print("Removed host \(alias)")
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check connectivity and authentication for a host.")

    @ParentCommand var parent: ProxmoxCtl
    @OptionGroup var options: GlobalOptions
    @Option(help: "Configured host alias. Defaults to the selected default host.")
    var host: String?

    mutating func run() async throws {
        let effective = try EffectiveOptionsResolver.resolve(
            root: parent.globalOptions,
            leaf: options
        )
        let version = try await effective.runtime().client(host: host).version()
        let display = [version.version, version.release].compactMap { $0 }.joined(separator: " ")
        print(display.isEmpty ? "Connected" : "Connected to Proxmox VE \(display)")
    }
}

struct Nodes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List Proxmox nodes.")

    @ParentCommand var parent: ProxmoxCtl
    @OptionGroup var options: GlobalOptions
    @Option(help: "Configured host alias. Defaults to the selected default host.")
    var host: String?
    @Flag(help: "Emit JSON.")
    var json = false

    mutating func run() async throws {
        let effective = try EffectiveOptionsResolver.resolve(
            root: parent.globalOptions,
            leaf: options
        )
        let nodes = try await effective.runtime().client(host: host).nodes()
        print(json ? try JSONRenderer.render(nodes) : TableRenderer.renderNodes(nodes))
    }
}

struct Guests: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List guests on online nodes; fail if none are online unless --node is supplied."
    )

    @ParentCommand var parent: ProxmoxCtl
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
        let effective = try EffectiveOptionsResolver.resolve(
            root: parent.globalOptions,
            leaf: options
        )
        let client = try effective.runtime().client(host: host)
        let nodeNames = try await GuestListPlanner.nodeNames(
            explicitNode: node,
            inventory: node == nil ? client.nodes() : nil
        )
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

    @ParentCommand var root: ProxmoxCtl
}

struct GuestCommonOptions: ParsableArguments {
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Guest VMID.")
    var vmid: Int
    @Option(help: "Cluster node name. If omitted, proxmoxctl uses the only node on the host.")
    var node: String?
    @Option(help: "Guest type: qemu or lxc. If omitted, cluster inventory is checked first, then guest endpoints are probed as fallback.")
    var type: GuestType?
    @Option(help: "Configured host alias. Defaults to the selected default host.")
    var host: String?
    @Flag(help: "Emit JSON.")
    var json = false
}

struct GuestLifecycleOptions: ParsableArguments {
    @OptionGroup var common: GuestCommonOptions
    @Flag(help: "Approve the lifecycle mutation without prompting; required for non-interactive input.")
    var yes = false
}

struct GuestStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    @ParentCommand var parent: Guest
    @OptionGroup var options: GuestCommonOptions

    mutating func run() async throws {
        let effective = try EffectiveOptionsResolver.resolve(
            root: parent.root.globalOptions,
            leaf: options.global
        )
        let client = try effective.runtime().client(host: options.host)
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
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start a guest after confirmation.")
    @ParentCommand var parent: Guest
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws {
        try await runLifecycle(.start, options: options, rootOptions: parent.root.globalOptions)
    }
}

struct GuestShutdown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shutdown", abstract: "Shut down a guest after confirmation.")
    @ParentCommand var parent: Guest
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws {
        try await runLifecycle(.shutdown, options: options, rootOptions: parent.root.globalOptions)
    }
}

struct GuestStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop a guest after confirmation.")
    @ParentCommand var parent: Guest
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws {
        try await runLifecycle(.stop, options: options, rootOptions: parent.root.globalOptions)
    }
}

struct GuestReboot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reboot", abstract: "Reboot a guest after confirmation.")
    @ParentCommand var parent: Guest
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws {
        try await runLifecycle(.reboot, options: options, rootOptions: parent.root.globalOptions)
    }
}

struct GuestReset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Reset a supported guest after confirmation.")
    @ParentCommand var parent: Guest
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws {
        try await runLifecycle(.reset, options: options, rootOptions: parent.root.globalOptions)
    }
}

struct GuestSuspend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "suspend", abstract: "Suspend a guest after confirmation.")
    @ParentCommand var parent: Guest
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws {
        try await runLifecycle(.suspend, options: options, rootOptions: parent.root.globalOptions)
    }
}

struct GuestPause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pause", abstract: "Alias for suspend.")
    @ParentCommand var parent: Guest
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws {
        try await runLifecycle(.suspend, options: options, rootOptions: parent.root.globalOptions)
    }
}

struct GuestResume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "Resume a guest after confirmation.")
    @ParentCommand var parent: Guest
    @OptionGroup var options: GuestLifecycleOptions
    mutating func run() async throws {
        try await runLifecycle(.resume, options: options, rootOptions: parent.root.globalOptions)
    }
}

func runLifecycle(
    _ operation: LifecycleOperation,
    options: GuestLifecycleOptions,
    rootOptions: GlobalOptions
) async throws {
    let common = options.common
    let effective = try EffectiveOptionsResolver.resolve(
        root: rootOptions,
        leaf: common.global
    )
    let client = try effective.runtime().client(host: common.host)
    let task = try await LifecyclePreflight.execute(
        operation: operation,
        resolveNode: {
            try await resolveNode(common: common, client: client)
        },
        resolveType: { node in
            try await resolveGuestType(common: common, node: node, client: client)
        },
        authorize: { node, type in
            try confirmIfNeeded(
                operation: operation,
                vmid: common.vmid,
                node: node,
                type: type,
                yes: options.yes
            )
        },
        perform: { node, type in
            try await client.lifecycle(
                node: node,
                type: type,
                vmid: common.vmid,
                operation: operation
            )
        }
    )
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
    try ConfirmationPolicy.authorize(
        operation: operation,
        assumeYes: yes,
        isInteractive: isatty(STDIN_FILENO) == 1,
        prompt: {
            fputs(
                "Confirm \(operation.rawValue) for \(type.rawValue) guest \(vmid) on \(node) by typing yes: ",
                stderr
            )
            return readLine()?.lowercased() == "yes"
        }
    )
}
