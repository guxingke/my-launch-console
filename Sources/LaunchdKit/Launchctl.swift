import Foundation

public struct LaunchctlError: Error, LocalizedError, Sendable {
    public var command: String
    public var status: Int32
    public var output: String

    public var errorDescription: String? {
        "\(command) failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Read-only access to one launchd domain. Uses the modern `print`/`blame` verbs only.
public struct Launchctl: Sendable {
    public static let executable = "/bin/launchctl"
    /// `launchctl print` exits with this when the service isn't loaded.
    static let notFoundStatus: Int32 = 113

    public var domain: String

    public init(domain: String) {
        self.domain = domain
    }

    /// The logged-in user's GUI session, e.g. `gui/501`.
    public static func currentUserGUI() -> Launchctl {
        Launchctl(domain: "gui/\(getuid())")
    }

    /// LaunchDaemons. Readable without root; changes go through an admin prompt.
    public static let system = Launchctl(domain: "system")

    public func target(_ label: String) -> String {
        "\(domain)/\(label)"
    }

    public func printDomain() async throws -> DomainSnapshot {
        let result = try await Command.run(Self.executable, ["print", domain])
        guard result.status == 0, let snapshot = DomainSnapshot(parsing: result.stdout) else {
            throw LaunchctlError(command: "launchctl print \(domain)", status: result.status, output: result.stderr + result.stdout)
        }
        return snapshot
    }

    /// nil when the service isn't loaded in this domain.
    public func printService(_ label: String) async throws -> ServiceDetail? {
        let result = try await Command.run(Self.executable, ["print", target(label)])
        if result.status == Self.notFoundStatus { return nil }
        guard result.status == 0 else {
            throw LaunchctlError(command: "launchctl print \(target(label))", status: result.status, output: result.stderr + result.stdout)
        }
        return ServiceDetail(parsing: result.stdout)
    }

    /// Why launchd last started the service, e.g. `ipc (mach)`, `speculative`, `(not running)`.
    public func blame(_ label: String) async -> String? {
        guard let result = try? await Command.run(Self.executable, ["blame", target(label)]),
              result.status == 0 else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
