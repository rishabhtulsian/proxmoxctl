import Foundation

public enum ConfigurationValidator {
    public static func validateAlias(_ alias: String) throws -> String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == alias,
              alias.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw ProxmoxCtlError.invalidHostAlias
        }
        return alias
    }

    public static func validateAndCanonicalizeBaseURL(_ value: String) throws -> URL {
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw ProxmoxCtlError.invalidHostURL
        }

        components.scheme = "https"
        components.path = ""
        guard let url = components.url else {
            throw ProxmoxCtlError.invalidHostURL
        }
        return url
    }
}

public extension AppConfig {
    func validate() throws {
        if let apiTimeoutSeconds {
            guard apiTimeoutSeconds.isFinite, apiTimeoutSeconds > 0 else {
                throw ProxmoxCtlError.invalidAPITimeout
            }
        }

        for host in hosts {
            _ = try ConfigurationValidator.validateAlias(host.alias)
            _ = try ConfigurationValidator.validateAndCanonicalizeBaseURL(host.url.absoluteString)
        }
    }
}
