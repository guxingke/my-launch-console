import Foundation
import Testing
@testable import LaunchdKit

private func systemJob(_ label: String = "com.example.daemon", loaded: Bool = true) -> Job {
    var plist = PlistJob(url: URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist"), origin: .global)
    plist.label = label
    let services = loaded ? [label: ServiceEntry(label: label, pid: 9, lastExit: .none)] : [:]
    return Inventory.build(snapshot: DomainSnapshot(domain: "system", services: services, overrides: [:]), plists: [plist])[0]
}

private func command(_ arguments: [String]) -> LaunchctlCommand {
    LaunchctlCommand(action: .start, label: "x", arguments: arguments)
}

@Suite struct PrivilegedLaunchctlTests {
    @Test func everyActionTheAppBuildsForADaemonIsAllowed() throws {
        let loaded = systemJob()
        let unloaded = systemJob(loaded: false)
        #expect(loaded.id == "system/com.example.daemon")
        #expect(loaded.isSystem)
        for action in JobAction.allCases {
            let job = action == .load ? unloaded : loaded
            let built = try #require(Launchctl.system.command(for: action, on: job))
            try PrivilegedLaunchctl.validate(built)
        }
    }

    @Test(arguments: [
        ["kickstart", "gui/501/x"],
        ["kickstart", "-p", "system/x"],
        ["kill", "SIGSTOP", "system/x"],
        ["bootout", "system/x", "extra"],
        ["bootout", "system/"],
        ["bootout", "system/a/b"],
        ["bootout", "system/a b"],
        ["bootout", "system/a\nb"],
        ["print", "system"],
        ["setenv", "DYLD_INSERT_LIBRARIES", "/tmp/x.dylib"],
        ["bootstrap", "gui/501", "/Library/LaunchDaemons/x.plist"],
        ["bootstrap", "system", "/tmp/evil.plist"],
        ["bootstrap", "system", "/Library/LaunchDaemons/../../tmp/evil.plist"],
        ["bootstrap", "system", "/Library/LaunchDaemons/x.sh"],
        [],
    ])
    func rejectsAnythingElse(_ arguments: [String]) {
        #expect(throws: PrivilegedLaunchctl.Rejection.self) { try PrivilegedLaunchctl.validate(command(arguments)) }
    }

    @Test func appleScriptStringsSurviveOsascript() async throws {
        // Round-trip through the real AppleScript parser. No privileges are involved.
        for text in [#"plain"#, #"with "quotes""#, #"back\slash"#, "'single' and \"double\" \\ mixed"] {
            let result = try await Command.run("/usr/bin/osascript", ["-e", "return " + PrivilegedLaunchctl.appleScriptString(text)])
            #expect(result.stdout.trimmingCharacters(in: .newlines) == text)
        }
    }

    @Test func scriptRunsOnlyTheShownCommand() throws {
        let built = try #require(Launchctl.system.command(for: .unload, on: systemJob()))
        let script = PrivilegedLaunchctl.appleScript(for: built)
        #expect(script.hasPrefix(#"do shell script "/bin/launchctl bootout system/com.example.daemon" with administrator privileges with prompt "#))
        #expect(script.contains("launchctl bootout system/com.example.daemon\""))
    }

    @Test func interpretsAppleScriptErrors() {
        // Messages as AppleScript reports them for `do shell script` (number = exit status).
        #expect(PrivilegedLaunchctl.failure(number: 3, message: "Boot-out failed: 3: No such process\n") == (3, "Boot-out failed: 3: No such process"))
        #expect(PrivilegedLaunchctl.failure(number: 113, message: "The command exited with a non-zero status.") == (113, ""))
        #expect(PrivilegedLaunchctl.failure(number: -128, message: "User canceled.") == (-128, "Cancelled. Nothing was changed."))
        #expect(PrivilegedLaunchctl.failure(number: 5, message: "Bootstrap failed: 5: Input/output error\nTry re-running the command as root for richer errors.")
            == (5, "Bootstrap failed: 5: Input/output error"))
    }
    // `execute` (NSAppleScript) isn't unit-tested: off the main thread it needs the main run
    // loop, which the app has and the test runner doesn't.
}

@Suite struct LoginItemCacheTests {
    @Test func roundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "LaunchConsoleTests-\(UUID().uuidString)/login-items.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(LoginItemCache.load(from: url) == nil)
        let cache = LoginItemCache(
            updated: Date(timeIntervalSince1970: 1_800_000_000),
            info: ["com.adobe.ccxprocess": LoginItemInfo(isAllowed: true, appName: "Adobe Creative Cloud", developer: "Adobe Inc.")]
        )
        try cache.save(to: url)
        #expect(LoginItemCache.load(from: url) == cache)
    }
}

@Suite struct SystemDomainTests {
    @Test func parsesRealSystemDomain() throws {
        let snapshot = try #require(DomainSnapshot(parsing: fixture("domain-system")))
        #expect(snapshot.domain == "system")
        #expect(snapshot.services.count > 300)
        #expect(snapshot.services["com.docker.vmnetd"]?.pid == 560)

        let jobs = Inventory.build(snapshot: snapshot, plists: [])
        let vmnetd = try #require(jobs.first { $0.label == "com.docker.vmnetd" })
        #expect(vmnetd.id == "system/com.docker.vmnetd")
        #expect(vmnetd.isSystem)
        #expect(vmnetd.status == .running)
    }

    @Test func sameLabelInBothDomainsStaysDistinct() {
        let gui = Inventory.build(snapshot: DomainSnapshot(domain: "gui/501", services: ["x": ServiceEntry(label: "x", pid: 1, lastExit: .none)], overrides: [:]), plists: [])
        let system = Inventory.build(snapshot: DomainSnapshot(domain: "system", services: ["x": ServiceEntry(label: "x", pid: 2, lastExit: .none)], overrides: [:]), plists: [])
        #expect(gui[0].id != system[0].id)
    }
}
