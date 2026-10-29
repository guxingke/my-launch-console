import AppKit
import Foundation
import LaunchdKit
import Observation
import UserNotifications

/// What the detail pane shows beyond the list row: fetched lazily for the selected job only.
struct Inspection: Equatable {
    var detail: ServiceDetail?
    var blame: String?
    var signature: Signature?
    var issues: [Issue] = []
    var error: String?
}

/// Owns everything that touches launchctl and the file system, off the main actor.
actor LaunchdSource {
    nonisolated let launchctl = Launchctl.currentUserGUI()
    nonisolated let system = Launchctl.system
    private let catalog = PlistCatalog()
    private let systemCatalog = PlistCatalog(directories: PlistCatalog.systemDomainDirectories)
    /// Why the system domain couldn't be read on the last refresh, if it couldn't.
    private(set) var systemError: String?

    nonisolated func launchctl(for job: Job) -> Launchctl {
        job.isSystem ? system : launchctl
    }
    /// codesign is slow-ish and executables rarely change, so cache per path for the session.
    private var signatures: [String: Signature?] = [:]
    /// Details from `sfltool dumpbtm`: parent app and developer. Slow to fetch, so refreshed rarely.
    private var loginItemDetails: [String: LoginItemInfo] = [:]
    /// The fast allowed/blocked check per plist, cached briefly so polling stays cheap.
    private var legacyAllowed: [URL: (allowed: Bool?, checked: Date)] = [:]

    /// Both domains. The user's session must be readable; the system domain is best effort.
    func jobs() async throws -> [Job] {
        let snapshot = try await launchctl.printDomain()
        let plists = catalog.scan()
        var jobs = Inventory.build(snapshot: snapshot, plists: plists, loginItems: loginItems(for: plists))
        do {
            let systemSnapshot = try await system.printDomain()
            let systemPlists = systemCatalog.scan()
            jobs += Inventory.build(snapshot: systemSnapshot, plists: systemPlists, loginItems: loginItems(for: systemPlists))
            systemError = nil
        } catch {
            systemError = error.localizedDescription
        }
        return jobs
    }

    /// Re-reads the Login Items database. Returns false if sfltool gave nothing usable.
    func reloadLoginItemDetails() async -> Bool {
        guard let items = await BackgroundItems.dump() else { return false }
        loginItemDetails = BackgroundItems.infoByLabel(items)
        return true
    }

    private func loginItems(for plists: [PlistJob]) -> [String: LoginItemInfo] {
        var result = loginItemDetails
        let now = Date.now
        // The public per-plist check is authoritative and current for LaunchAgents plists.
        for plist in plists where plist.origin != .apple {
            var entry = legacyAllowed[plist.url]
            if entry == nil || now.timeIntervalSince(entry!.checked) > 30 {
                entry = (BackgroundItems.isAllowed(legacyPlist: plist.url), now)
                legacyAllowed[plist.url] = entry
            }
            guard let allowed = entry?.allowed else { continue }
            let label = plist.effectiveLabel
            var info = result[label] ?? LoginItemInfo(isAllowed: allowed)
            info.isAllowed = allowed
            result[label] = info
        }
        return result
    }

    func inspect(_ job: Job) async -> Inspection {
        var inspection = Inspection()
        if job.isLoaded {
            do {
                inspection.detail = try await launchctl(for: job).printService(job.label)
            } catch {
                inspection.error = error.localizedDescription
            }
            inspection.blame = await launchctl(for: job).blame(job.label)
        }
        if let detail = inspection.detail {
            inspection.issues = Diagnostics.detailIssues(for: job, detail: detail)
        }
        if let executable = inspection.detail?.program ?? job.plist?.executable {
            inspection.signature = await signature(for: executable)
        }
        return inspection
    }

    func perform(_ command: LaunchctlCommand, on job: Job) async throws {
        try await launchctl(for: job).run(command, job: job)
    }

    private func signature(for path: String) async -> Signature? {
        if let cached = signatures[path] { return cached }
        let signature = await Signature.read(executable: path)
        signatures[path] = signature
        return signature
    }
}

@MainActor @Observable
final class JobStore {
    static let pollInterval: Duration = .seconds(2)

    private(set) var jobs: [Job] = []
    private(set) var error: String?
    private(set) var lastUpdated: Date?
    private(set) var hasLoaded = false

    private let source = LaunchdSource()
    /// Set when LaunchDaemons couldn't be listed; the user's agents still work.
    private(set) var systemError: String?
    private var polling: Task<Void, Never>?

    var domain: String { source.launchctl.domain }

    func job(_ id: Job.ID) -> Job? {
        jobs.first { $0.id == id }
    }

    /// A full target as-is; a bare label means an agent in the user's session.
    func id(forKey key: String) -> Job.ID {
        key.hasPrefix("system/") || key.hasPrefix("gui/") ? key : "\(domain)/\(key)"
    }

    func startPolling() {
        guard polling == nil else { return }
        #if DEBUG
        let loadLoginItems = !isReadOnlySession || DebugSnapshot.environment["LAUNCHCONSOLE_LOGINITEMS"] != nil
        #else
        let loadLoginItems = true
        #endif
        if loadLoginItems { reloadLoginItems() }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func refresh() async {
        do {
            let fresh = try await source.jobs()
            if fresh != jobs {
                notifyFailures(previous: jobs, current: fresh)
                jobs = fresh
            }
            error = nil
            systemError = await source.systemError
        } catch {
            self.error = error.localizedDescription
        }
        lastUpdated = .now
        hasLoaded = true
    }

    func inspect(_ job: Job) async -> Inspection {
        await source.inspect(job)
    }

    // MARK: Login Items

    private(set) var isLoadingLoginItems = false
    private(set) var loginItemsUpdated: Date?

    /// Fetches app and developer names from Login Items. Takes about 20 s.
    func reloadLoginItems() {
        guard !isLoadingLoginItems else { return }
        isLoadingLoginItems = true
        Task {
            if await source.reloadLoginItemDetails() { loginItemsUpdated = .now }
            isLoadingLoginItems = false
            await refresh()
        }
    }

    // MARK: Failure notifications

    private static let watchedKey = "watchedLabels"
    /// Jobs to notify about when they start failing. Kept across launches.
    /// Job IDs (launchctl targets). Older versions stored bare labels, which were always agents.
    private(set) var watched: Set<String> = Set((UserDefaults.standard.stringArray(forKey: JobStore.watchedKey) ?? []).map {
        $0.contains("/") ? $0 : "gui/\(getuid())/\($0)"
    })
    private var watcher = FailureWatcher()
    private(set) var notificationsDenied = false

    /// Notifications need a real app bundle; a bare `swift run` binary would crash asking for them.
    private var canNotify: Bool {
        Bundle.main.bundlePath.hasSuffix(".app") && Bundle.main.bundleIdentifier != nil && !isReadOnlySession
    }

    func isWatched(_ job: Job) -> Bool {
        watched.contains(job.id)
    }

    func setWatched(_ on: Bool, for job: Job) {
        if on { watched.insert(job.id) } else { watched.remove(job.id) }
        UserDefaults.standard.set(watched.sorted(), forKey: Self.watchedKey)
        if on, canNotify {
            Task {
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                notificationsDenied = !granted
            }
        }
    }

    private func notifyFailures(previous: [Job], current: [Job]) {
        guard !previous.isEmpty else { return }
        // Don't report what the app itself just did, like an unload you asked for.
        let recentLabels = Set(activity.filter { $0.date.timeIntervalSinceNow > -30 }.map(\.label))
        let recentlyActedOn = Set(current.filter { recentLabels.contains($0.label) }.map(\.id))
        let events = watcher.events(previous: previous, current: current, watched: watched.subtracting(recentlyActedOn))
        guard canNotify else { return }
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.label
            content.body = event.message
            content.sound = .default
            content.userInfo = ["label": event.label]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Actions

    /// Debug snapshot runs show real windows on the user's screen for a few seconds.
    /// They must not be able to change anything, whatever gets clicked.
    #if DEBUG
    let isReadOnlySession = DebugSnapshot.environment["LAUNCHCONSOLE_SNAPSHOT"] != nil
    #else
    let isReadOnlySession = false
    #endif

    /// Everything the app changed this session, newest first.
    private(set) var activity: [ActionRecord] = []
    /// An action waiting for the user to confirm it.
    var pendingConfirmation: PendingAction?
    /// A job waiting for the user to confirm moving its plist to the Trash.
    var pendingTrash: Job?
    private(set) var busyLabels: Set<String> = []

    func command(for action: JobAction, on job: Job) -> LaunchctlCommand? {
        source.launchctl(for: job).command(for: action, on: job)
    }

    func isBusy(_ job: Job) -> Bool {
        busyLabels.contains(job.label)
    }

    func lastRecord(for label: String) -> ActionRecord? {
        activity.first { $0.label == label }
    }

    /// Runs the action, or asks for confirmation first when it's disruptive.
    func request(_ action: JobAction, on job: Job) {
        guard let command = command(for: action, on: job) else { return }
        if action.needsConfirmation {
            pendingConfirmation = PendingAction(job: job, command: command)
        } else {
            Task { await perform(command, on: job) }
        }
    }

    func perform(_ command: LaunchctlCommand, on job: Job) async {
        guard !isReadOnlySession, !busyLabels.contains(job.label) else { return }
        busyLabels.insert(job.label)
        defer { busyLabels.remove(job.label) }

        var record = ActionRecord(title: command.action.title, label: job.label, lines: [command.shellString])
        do {
            try await source.perform(command, on: job)
        } catch {
            record.fail(error)
        }
        activity.insert(record, at: 0)
        await settle()
    }

    /// launchd applies most changes asynchronously; give it a moment before re-reading.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(250))
        await refresh()
    }

    // MARK: Editing

    let plistStore = PlistStore.user()
    var editorRequest: EditorRequest?
    /// Set after creating an agent, so the list can select it.
    private(set) var lastCreatedLabel: String?

    func edit(_ job: Job) {
        guard EditPolicy.editReadOnlyReason(for: job) == nil, let url = job.plist?.url else { return }
        do {
            editorRequest = EditorRequest(job: job, definition: try JobDefinition(contentsOf: url))
        } catch {
            var record = ActionRecord(title: "Open", label: job.label, lines: [url.path])
            record.fail(error)
            activity.insert(record, at: 0)
        }
    }

    func newAgent(from template: JobTemplate) {
        editorRequest = EditorRequest(job: nil, definition: template.definition(label: "local.\(NSUserName()).untitled"))
    }

    /// Labels other jobs already use, for validating a definition.
    func takenLabels(excluding job: Job?) -> Set<String> {
        Set(jobs.map(\.label)).subtracting([job?.label].compactMap { $0 })
    }

    enum AfterSave {
        case nothing
        /// Load it now (a new agent, or one that wasn't loaded).
        case load
        /// Unload the running copy and load the saved file.
        case reload
    }

    /// Writes the plist, then loads or reloads it if asked.
    /// Returns an error message if nothing was saved (the editor stays open), nil otherwise.
    func save(_ definition: JobDefinition, for request: EditorRequest, then after: AfterSave) async -> String? {
        guard !request.isPreview, !isReadOnlySession else { return "This is a preview; it can't be saved." }
        let label = definition.label
        busyLabels.insert(label)
        defer { busyLabels.remove(label) }

        let url: URL
        var record = ActionRecord(title: request.job == nil ? "Create" : "Save", label: label, lines: [])
        do {
            let result: SaveResult
            if let existing = request.job?.plist?.url {
                result = try await plistStore.save(definition, to: existing)
                record.lines.append("Wrote \(existing.path)")
            } else {
                result = try await plistStore.create(definition)
                record.lines.append("Created \(result.url.path)")
            }
            if let backup = result.backup {
                record.lines.append("Previous version kept at \(backup.path)")
            }
            url = result.url
            activity.insert(record, at: 0)
            if request.job == nil { lastCreatedLabel = label }
        } catch {
            record.fail(error)
            activity.insert(record, at: 0)
            return error.localizedDescription
        }

        if after != .nothing {
            let unloading = after == .reload ? request.job?.label : nil
            var load = ActionRecord(title: unloading == nil ? "Load" : "Reload", label: label, lines: [])
            do {
                let ran = try await source.launchctl.reload(unloading: unloading, plist: url, label: label)
                load.lines = ran.map(\.shellString)
            } catch {
                if let failure = error as? ActionFailure { load.lines = [failure.command.shellString] }
                load.fail(error)
            }
            activity.insert(load, at: 0)
        }
        await settle()
        return nil
    }

    func moveToTrash(_ job: Job) async {
        guard !isReadOnlySession, EditPolicy.canMoveToTrash(job), let url = job.plist?.url else { return }
        busyLabels.insert(job.label)
        defer { busyLabels.remove(job.label) }

        var record = ActionRecord(title: "Move to Trash", label: job.label, lines: [])
        do {
            if job.isLoaded {
                let bootout = source.launchctl.bootoutCommand(label: job.label)
                record.lines.append(bootout.shellString)
                try await source.perform(bootout, on: job)
            }
            _ = try plistStore.moveToTrash(url)
            record.lines.append("Moved \(url.path) to the Trash")
        } catch {
            record.fail(error)
        }
        activity.insert(record, at: 0)
        await settle()
    }
}

struct PendingAction: Identifiable {
    let id = UUID()
    var job: Job
    var command: LaunchctlCommand
    /// Shown only to be looked at (debug snapshots). Confirming it does nothing.
    var isPreview = false
}

struct EditorRequest: Identifiable {
    let id = UUID()
    /// nil for a new agent.
    var job: Job?
    var definition: JobDefinition
    /// Shown only to be looked at (debug snapshots). Saving is disabled.
    var isPreview = false
}

/// One thing the app did: the commands or file operations, and launchctl's own words if it failed.
struct ActionRecord: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var label: String
    var lines: [String]
    var date = Date.now
    var failure: String?
    var hint: String?

    mutating func fail(_ error: Error) {
        if let failure = error as? ActionFailure {
            self.failure = failure.errorDescription
            hint = failure.hint
        } else {
            failure = error.localizedDescription
        }
    }
}
