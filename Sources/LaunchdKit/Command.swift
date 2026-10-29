import Foundation

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

public enum Command {
    /// Runs a tool to completion off the calling thread and captures both output streams.
    public static func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Drain stderr concurrently so neither pipe can fill up and block the child.
                let stderrBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrBox.data, as: UTF8.self)
                ))
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
