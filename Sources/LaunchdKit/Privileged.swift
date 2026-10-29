import Foundation

/// Runs launchctl as root for system-domain actions, one command at a time, through the
/// standard macOS administrator password dialog.
///
/// There is deliberately no persistent root helper: nothing listens for commands, so no other
/// process can borrow root through this app. Each command is checked against a strict allowlist
/// before the user is even asked, so the prompt can only ever run what the UI showed.
public enum PrivilegedLaunchctl {
    public enum Rejection: Error, LocalizedError, Equatable {
        case notAllowed(String)

        public var errorDescription: String? {
            switch self {
            case .notAllowed(let reason): "Refused to run as root: \(reason)"
            }
        }
    }

    /// AppleScript's error number when the user cancels the password dialog.
    public static let cancelledStatus: Int32 = -128

    static let daemonDirectory = "/Library/LaunchDaemons/"

    /// Checks that a command is one of the app's own system-domain actions and nothing else.
    public static func validate(_ command: LaunchctlCommand) throws {
        func reject(_ reason: String) -> Rejection { .notAllowed(reason) }
        let args = command.arguments
        guard let verb = args.first else { throw reject("empty command") }

        func checkTarget(_ target: String) throws {
            guard target.hasPrefix("system/"), target.count > "system/".count else {
                throw reject("\(target) isn't in the system domain")
            }
            let label = target.dropFirst("system/".count)
            guard !label.contains("/"), !label.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true }) else {
                throw reject("\(target) isn't a plain service target")
            }
        }

        switch verb {
        case "kickstart":
            guard args.count == 2 || (args.count == 3 && args[1] == "-k") else { throw reject("unexpected kickstart options") }
            try checkTarget(args[args.count - 1])
        case "kill":
            guard args.count == 3, ["SIGTERM", "SIGKILL"].contains(args[1]) else { throw reject("unexpected kill arguments") }
            try checkTarget(args[2])
        case "bootout", "enable", "disable":
            guard args.count == 2 else { throw reject("unexpected \(verb) arguments") }
            try checkTarget(args[1])
        case "bootstrap":
            guard args.count == 3, args[1] == "system" else { throw reject("bootstrap must target the system domain") }
            let path = args[2]
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard path.hasPrefix(daemonDirectory), !path.contains("/../"), path.hasSuffix(".plist"),
                  resolved.hasPrefix(daemonDirectory) || resolved.hasPrefix("/private" + daemonDirectory) else {
                throw reject("only plists in \(daemonDirectory) can be loaded")
            }
        default:
            throw reject("\(verb) isn't an allowed action")
        }
    }

    /// The AppleScript that asks for the password and runs exactly this command.
    public static func appleScript(for command: LaunchctlCommand) -> String {
        let shell = ([Launchctl.executable] + command.arguments).map(LaunchctlCommand.shellQuote).joined(separator: " ")
        let prompt = "launchd Console wants to run:\n\n" + command.shellString
        return "do shell script \(appleScriptString(shell)) with administrator privileges with prompt \(appleScriptString(prompt))"
    }

    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Turns osascript's `0:74: execution error: <stderr> (<status>)` back into launchctl's own
    /// message and exit status.
    public static func parseFailure(_ stderr: String) -> (status: Int32, message: String) {
        var text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "execution error: ") {
            text = String(text[range.upperBound...])
        }
        var status: Int32 = 1
        if text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards),
           let code = Int32(text[open.upperBound..<text.index(before: text.endIndex)]) {
            status = code
            text = String(text[..<open.lowerBound])
        }
        if status == cancelledStatus { return (status, "Cancelled. Nothing was changed.") }
        if text == "The command exited with a non-zero status." { text = "" }
        let message = text
            .split(separator: "\n")
            .filter { !$0.hasPrefix("Try re-running the command as root") }
            .joined(separator: "\n")
        return (status, message)
    }

    public static func run(_ command: LaunchctlCommand, job: Job?) async throws {
        try validate(command)
        let result = try await Command.run("/usr/bin/osascript", ["-e", appleScript(for: command)])
        guard result.status != 0 else { return }
        let (status, message) = parseFailure(result.stderr)
        throw ActionFailure(
            command: command,
            status: status,
            output: message,
            hint: status == cancelledStatus ? nil : Launchctl.hint(for: command.action, status: status, job: job)
        )
    }
}
