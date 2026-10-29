import Foundation
import Testing
@testable import LaunchdKit

/// Fixtures are real `launchctl print` / `codesign` output captured on macOS 27.0.1.
func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct PrintParserTests {
    @Test func parsesNestedBlocksFieldsAndLines() throws {
        let text = """
        gui/501/x = {
        \tstate = running
        \targuments = {
        \t\t/bin/echo
        \t\ta = b
        \t}
        \tenvironment = {
        \t\tPATH => /usr/bin
        \t}
        }
        """
        let root = try #require(PrintParser.parse(text))
        #expect(root.name == "gui/501/x")
        #expect(root["state"] == "running")
        #expect(root.block("arguments")?.lines == ["/bin/echo", "a = b"])
        #expect(root.block("environment")?.dictionary == ["PATH": "/usr/bin"])
    }

    @Test func foldsTruncatedOutput() throws {
        let root = try #require(PrintParser.parse("svc = {\n\tstate = running\n\tinner = {\n\t\tk = v\n"))
        #expect(root["state"] == "running")
        #expect(root.block("inner")?["k"] == "v")
    }

    @Test func returnsNilForErrorText() {
        #expect(PrintParser.parse("Bad request.\nCould not find service") == nil)
    }
}

@Suite struct DomainSnapshotTests {
    @Test func parsesRealGUIDomain() throws {
        let snapshot = try #require(DomainSnapshot(parsing: fixture("domain-gui")))
        #expect(snapshot.domain == "gui/501")
        #expect(snapshot.services.count == 473)
        #expect(snapshot.overrides.count == 59)

        #expect(snapshot.services["homebrew.mxcl.sing-box"] == ServiceEntry(label: "homebrew.mxcl.sing-box", pid: nil, lastExit: .code(1)))
        #expect(snapshot.services["com.hapi.hub"]?.pid == 967)
        #expect(snapshot.services["com.hapi.hub"]?.lastExit == ExitStatus.none)
        #expect(snapshot.services["com.apple.knowledgeconstructiond"]?.lastExit == .other("(jt)"))

        #expect(snapshot.overrides["com.apple.Siri.agent"] == .disabled)
        #expect(snapshot.overrides["homebrew.mxcl.yabai"] == .enabled)
    }
}

@Suite struct ServiceDetailTests {
    @Test func parsesCrashLoopingAgent() throws {
        let detail = try #require(ServiceDetail(parsing: fixture("service-crashloop")))
        #expect(detail.target == "gui/501/homebrew.mxcl.sing-box")
        #expect(detail.path == "/Users/gxk/Library/LaunchAgents/homebrew.mxcl.sing-box.plist")
        #expect(detail.state == "spawn scheduled")
        #expect(detail.program == "/opt/homebrew/opt/sing-box/bin/sing-box")
        #expect(detail.arguments.count == 6)
        #expect(detail.runs == 21956)
        #expect(detail.lastExit == .code(1))
        #expect(detail.pid == nil)
        #expect(detail.keepAlive)
        #expect(detail.environment["XPC_SERVICE_NAME"] == "homebrew.mxcl.sing-box")
    }

    @Test func parsesRunningAgent() throws {
        let detail = try #require(ServiceDetail(parsing: fixture("service-running-agent")))
        #expect(detail.pid == 967)
        #expect(detail.lastExit == ExitStatus.none)
        #expect(detail.arguments == ["/Users/gxk/.local/bin/hapi", "hub"])
    }

    @Test func parsesAppSubmittedService() throws {
        let detail = try #require(ServiceDetail(parsing: fixture("service-submitted-app")))
        #expect(detail.path == nil)
        #expect(detail.submittedBy == "runningboardd.437")
        #expect(detail.bundleID == "com.mitchellh.ghostty")
        #expect(detail.pid == 744)
    }

    @Test func toleratesMissingExitCode() throws {
        let detail = try #require(ServiceDetail(parsing: fixture("service-no-exit-code")))
        #expect(detail.lastExit == ExitStatus.none)
        #expect(detail.pid == 24529)
    }
}

@Suite struct SignatureTests {
    @Test func parsesDeveloperID() throws {
        let signature = try #require(Signature(codesignOutput: fixture("codesign-developer-id")))
        #expect(signature.kind == .certificate("Developer ID Application: Mitchell Hashimoto (24VZTF6M5V)"))
        #expect(signature.teamID == "24VZTF6M5V")
        #expect(signature.identifier == "com.mitchellh.ghostty")
    }

    @Test func parsesAdhoc() throws {
        let signature = try #require(Signature(codesignOutput: fixture("codesign-adhoc")))
        #expect(signature.kind == .adhoc)
    }

    @Test func parsesUnsigned() {
        #expect(Signature(codesignOutput: "/tmp/x: code object is not signed at all")?.kind == .unsigned)
    }
}

@Suite struct OwnershipTests {
    @Test func guessesInstallerFromExecutablePath() {
        #expect(Ownership.hint(executable: "/Applications/Ghostty.app/Contents/MacOS/ghostty") == "Ghostty.app")
        #expect(Ownership.hint(executable: "/opt/homebrew/opt/sing-box/bin/sing-box") == "Homebrew")
        #expect(Ownership.hint(executable: "/usr/libexec/thing") == "macOS")
        #expect(Ownership.hint(executable: "/Users/me/.local/bin/hapi") == nil)
        #expect(Ownership.hint(executable: "/Users/me/bin/x", associatedBundleIDs: ["com.example.App"]) == "com.example.App")
    }
}
