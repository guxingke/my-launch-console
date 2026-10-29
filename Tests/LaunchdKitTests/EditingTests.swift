import Foundation
import Testing
@testable import LaunchdKit

@Suite struct JobDefinitionTests {
    @Test func preservesUnknownKeysAndTypesThroughARoundTrip() throws {
        let original: [String: Any] = [
            "Label": "com.example.job",
            "ProgramArguments": ["/bin/echo", "hi"],
            "RunAtLoad": true,
            "Nice": 5,
            "ThrottleInterval": 2.5,
            "MachServices": ["com.example.port": true],
            "Sockets": ["Listener": ["SockServiceName": "8080"]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
        var definition = try JobDefinition(xml: data)
        definition.arguments = ["/bin/echo", "bye"]

        let back = try #require(try PropertyListSerialization.propertyList(from: definition.xmlData(), format: nil) as? [String: Any])
        #expect(back["Nice"] as? Int == 5)
        #expect(back["ThrottleInterval"] as? Double == 2.5)
        #expect(back["RunAtLoad"] as? Bool == true)
        #expect((back["MachServices"] as? [String: Bool])?["com.example.port"] == true)
        #expect(back["ProgramArguments"] as? [String] == ["/bin/echo", "bye"])
        #expect(definition.otherKeys == ["MachServices", "Nice", "Sockets", "ThrottleInterval"])
    }

    @Test func boolsStayBoolsAndIntsStayInts() {
        #expect(PlistValue(true as Any) == .bool(true))
        #expect(PlistValue(1 as Any) == .integer(1))
        #expect(PlistValue(NSNumber(value: 0)) == .integer(0))
        #expect(PlistValue(1.5 as Any) == .real(1.5))
    }

    @Test func clearingAFieldRemovesItsKey() {
        var definition = JobDefinition(label: "x", arguments: ["/bin/true"])
        definition.stdoutPath = "/tmp/x.log"
        definition.runAtLoad = true
        definition.environment = ["A": "1"]
        definition.stdoutPath = ""
        definition.runAtLoad = false
        definition.environment = [:]
        #expect(Set(definition.dictionary.keys) == ["Label", "ProgramArguments"])
    }

    @Test func settingArgumentsDropsProgramKey() {
        var definition = JobDefinition(dictionary: ["Label": .string("x"), "Program": .string("/bin/old")])
        #expect(definition.arguments == ["/bin/old"])
        definition.arguments = ["/bin/new", "-v"]
        #expect(definition.dictionary["Program"] == nil)
        #expect(definition.arguments == ["/bin/new", "-v"])
    }

    @Test func keepAliveModes() {
        var definition = JobDefinition(label: "x", arguments: [])
        #expect(definition.keepAlive == .off)
        definition.keepAlive = .onFailure
        #expect(definition.dictionary["KeepAlive"] == .dictionary(["SuccessfulExit": .bool(false)]))
        definition.dictionary["KeepAlive"] = .dictionary(["NetworkState": .bool(true)])
        #expect(definition.keepAlive == .custom)
        definition.keepAlive = .custom
        #expect(definition.dictionary["KeepAlive"] == .dictionary(["NetworkState": .bool(true)]))
        definition.keepAlive = .off
        #expect(definition.dictionary["KeepAlive"] == nil)
    }

    @Test func calendarIntervalWritesSingleDictForOneEntry() {
        var definition = JobDefinition(label: "x", arguments: [])
        definition.calendarIntervals = [["Hour": 3]]
        #expect(definition.dictionary["StartCalendarInterval"] == .dictionary(["Hour": .integer(3)]))
        definition.calendarIntervals = [["Hour": 3], ["Weekday": 1]]
        #expect(definition.calendarIntervals.count == 2)
        definition.calendarIntervals = []
        #expect(definition.dictionary["StartCalendarInterval"] == nil)
    }

    @Test func rejectsNonDictionaryPlist() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["a"], format: .xml, options: 0)
        #expect(throws: DefinitionError.notADictionary) { try JobDefinition(xml: data) }
    }

    @Test func templatesLogToLibraryLogs() {
        let home = URL(fileURLWithPath: "/Users/me")
        for template in JobTemplate.allCases {
            let definition = template.definition(label: "local.me.job", home: home)
            #expect(definition.stdoutPath == "/Users/me/Library/Logs/local.me.job.log")
            #expect(definition.label == "local.me.job")
        }
        #expect(JobTemplate.keepAlive.definition(label: "x", home: home).keepAlive == .always)
        #expect(JobTemplate.calendar.definition(label: "x", home: home).calendarIntervals == [["Hour": 9, "Minute": 0]])
    }
}

@Suite struct ValidatorTests {
    var validator: Validator = {
        var validator = Validator()
        let existing: Set<String> = ["/bin/sleep", "/etc/hosts", "/tmp", "/Users/me/Library/Logs"]
        validator.exists = { existing.contains($0) }
        validator.isExecutable = { $0 == "/bin/sleep" }
        return validator
    }()

    private func messages(_ definition: JobDefinition, fileName: String? = nil, taken: Set<String> = []) -> [String] {
        validator.validate(definition, fileName: fileName ?? "\(definition.label).plist", takenLabels: taken).map(\.message)
    }

    private func errors(_ definition: JobDefinition, taken: Set<String> = []) -> [ValidationIssue] {
        validator.validate(definition, fileName: "\(definition.label).plist", takenLabels: taken).filter { $0.severity == .error }
    }

    private var good: JobDefinition {
        var definition = JobDefinition(label: "local.me.job", arguments: ["/bin/sleep", "5"])
        definition.runAtLoad = true
        definition.stdoutPath = "/Users/me/Library/Logs/job.log"
        return definition
    }

    @Test func goodDefinitionPasses() {
        #expect(messages(good).isEmpty)
    }

    @Test func labelRules() {
        var definition = good
        definition.label = ""
        #expect(errors(definition).count == 1)
        definition.label = "has space"
        #expect(errors(definition).first?.message.contains("spaces") == true)
        #expect(errors(good, taken: ["local.me.job"]).first?.message.contains("already uses") == true)
        #expect(messages(good, fileName: "other.plist").first?.contains("doesn't match the label") == true)
    }

    @Test func programRules() {
        var definition = good
        definition.arguments = []
        #expect(errors(definition).first?.message == "Choose the program to run.")
        definition.arguments = ["~/bin/x"]
        #expect(errors(definition).first?.message.contains("doesn't expand ~") == true)
        definition.arguments = ["/nope"]
        #expect(errors(definition).first?.message == "/nope doesn't exist.")
        definition.arguments = ["/etc/hosts"]
        #expect(errors(definition).first?.message == "/etc/hosts isn't executable.")
        definition.arguments = ["sleep", "5"]
        #expect(errors(definition).isEmpty)
        #expect(messages(definition).first?.contains("isn't a full path") == true)
    }

    @Test func scheduleRules() {
        var definition = good
        definition.runAtLoad = false
        #expect(messages(definition).last?.contains("Nothing will start this job") == true)
        definition.startInterval = 0
        #expect(errors(definition).first?.message.contains("at least 1 second") == true)
        definition.startInterval = nil
        definition.calendarIntervals = [["Hour": 24]]
        #expect(errors(definition).first?.message == "Schedule Hour must be between 0 and 23.")
        definition.calendarIntervals = [["Hours": 3]]
        #expect(errors(definition).first?.message.contains("isn't a schedule field") == true)
        var socketJob = good
        socketJob.runAtLoad = false
        socketJob.dictionary["Sockets"] = .dictionary([:])
        #expect(messages(socketJob).isEmpty)
    }

    @Test func outputRules() {
        var definition = good
        definition.stderrPath = "~/Library/Logs/x.log"
        #expect(errors(definition).first?.message.contains("doesn't expand ~") == true)
        definition.stderrPath = "/nowhere/x.log"
        #expect(errors(definition).isEmpty)
        #expect(messages(definition).contains { $0.contains("launchd won't create it") })
    }

    @Test func errorsComeFirst() {
        var definition = good
        definition.label = "x"
        definition.arguments = ["/nope"]
        let issues = validator.validate(definition, fileName: "y.plist", takenLabels: [])
        #expect(issues.map(\.severity) == [.error, .warning])
    }
}

@Suite struct PlistStoreTests {
    let root: URL
    let store: PlistStore
    let trashed: TrashRecorder

    final class TrashRecorder: @unchecked Sendable {
        var urls: [URL] = []
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let recorder = TrashRecorder()
        trashed = recorder
        let trashDir = root.appending(path: "Trash")
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        store = PlistStore(
            agentsDirectory: root.appending(path: "LaunchAgents"),
            backupDirectory: root.appending(path: "Backups"),
            trash: { url in
                recorder.urls.append(url)
                let destination = trashDir.appending(path: url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
        )
    }

    @Test func createWritesValidXMLAndRefusesToOverwrite() async throws {
        let definition = JobDefinition(label: "local.test.job", arguments: ["/bin/true"])
        let result = try await store.create(definition)
        #expect(result.url.lastPathComponent == "local.test.job.plist")
        #expect(try JobDefinition(contentsOf: result.url) == definition)
        #expect(String(decoding: try Data(contentsOf: result.url), as: UTF8.self).hasPrefix("<?xml"))

        await #expect(throws: PlistStoreError.alreadyExists(result.url.path)) {
            try await store.create(definition)
        }
    }

    @Test func saveBacksUpThePreviousVersionAndLeavesNoTempFiles() async throws {
        var definition = JobDefinition(label: "local.test.job", arguments: ["/bin/true"])
        let url = try await store.create(definition).url
        let firstVersion = try Data(contentsOf: url)

        definition.arguments = ["/bin/echo", "changed"]
        let result = try await store.save(definition, to: url, now: Date(timeIntervalSince1970: 0))
        let backup = try #require(result.backup)
        #expect(backup.deletingLastPathComponent().lastPathComponent == "local.test.job")
        #expect(try Data(contentsOf: backup) == firstVersion)
        #expect(try JobDefinition(contentsOf: url).arguments == ["/bin/echo", "changed"])

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.agentsDirectory.path)
        #expect(leftovers == ["local.test.job.plist"])
    }

    @Test func trashUsesTheInjectedTrash() async throws {
        let url = try await store.create(JobDefinition(label: "local.test.gone", arguments: ["/bin/true"])).url
        let moved = try store.moveToTrash(url)
        #expect(trashed.urls == [url])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(moved.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }
}

@Suite struct EditPolicyTests {
    private func job(origin: Origin, url: URL, error: String? = nil) -> Job {
        var plist = PlistJob(url: url, origin: origin)
        plist.label = "x"
        plist.error = error
        return Inventory.build(snapshot: DomainSnapshot(domain: "gui/501", services: [:], overrides: [:]), plists: [plist])[0]
    }

    @Test func onlyUserRegularFilesAreEditable() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "x.plist")
        try JobDefinition(label: "x", arguments: ["/bin/true"]).xmlData().write(to: file)
        let link = dir.appending(path: "link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        #expect(EditPolicy.editReadOnlyReason(for: job(origin: .user, url: file)) == nil)
        #expect(EditPolicy.editReadOnlyReason(for: job(origin: .global, url: file))?.contains("root") == true)
        #expect(EditPolicy.editReadOnlyReason(for: job(origin: .global, url: URL(fileURLWithPath: "/Library/LaunchDaemons/x.plist")))?.contains("/Library/LaunchDaemons and belongs to root") == true)
        #expect(EditPolicy.editReadOnlyReason(for: job(origin: .user, url: link))?.contains("symlink") == true)
        #expect(EditPolicy.editReadOnlyReason(for: job(origin: .user, url: file, error: "bad")) != nil)

        #expect(EditPolicy.canMoveToTrash(job(origin: .user, url: link)))
        #expect(!EditPolicy.canMoveToTrash(job(origin: .global, url: file)))
    }

    @Test func homebrewNote() {
        #expect(EditPolicy.notes(for: "homebrew.mxcl.nginx").count == 1)
        #expect(EditPolicy.notes(for: "local.me.x").isEmpty)
    }
}

/// Creates, loads, edits, reloads and trashes a throwaway `/bin/sleep` agent in a temp directory,
/// using real launchctl. Off by default because it changes launchd state:
/// `LAUNCHD_INTEGRATION=1 swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LAUNCHD_INTEGRATION"] == "1"), .serialized)
struct EditingIntegrationTests {
    static let label = "local.prototype.launchconsole.integration-edit"

    @Test func createEditReloadTrash() async throws {
        let launchctl = Launchctl.currentUserGUI()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let trashDir = root.appending(path: "Trash")
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let store = PlistStore(
            agentsDirectory: root.appending(path: "LaunchAgents"),
            backupDirectory: root.appending(path: "Backups"),
            trash: { url in
                let destination = trashDir.appending(path: url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
        )
        defer {
            _ = try? Process.run(URL(fileURLWithPath: Launchctl.executable), arguments: ["bootout", launchctl.target(Self.label)])
            try? FileManager.default.removeItem(at: root)
        }

        var definition = JobTemplate.keepAlive.definition(label: Self.label)
        definition.arguments = ["/bin/sleep", "600"]
        definition.stdoutPath = ""
        definition.stderrPath = ""
        let url = try await store.create(definition).url

        _ = try await launchctl.reload(unloading: nil, plist: url, label: Self.label)
        try await Task.sleep(for: .milliseconds(300))
        let first = try #require(try await launchctl.printService(Self.label))
        #expect(first.arguments == ["/bin/sleep", "600"])
        #expect(first.pid != nil)

        definition.arguments = ["/bin/sleep", "601"]
        let saved = try await store.save(definition, to: url)
        #expect(saved.backup != nil)
        let ran = try await launchctl.reload(unloading: Self.label, plist: url, label: Self.label)
        #expect(ran.map(\.arguments.first) == ["bootout", "bootstrap"])
        try await Task.sleep(for: .milliseconds(300))
        let second = try #require(try await launchctl.printService(Self.label))
        #expect(second.arguments == ["/bin/sleep", "601"])
        #expect(second.pid != first.pid)

        try await launchctl.run(launchctl.bootoutCommand(label: Self.label), job: nil)
        _ = try store.moveToTrash(url)
        #expect(try await launchctl.printService(Self.label) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
