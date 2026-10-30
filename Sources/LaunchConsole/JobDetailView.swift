import AppKit
import LaunchdKit
import SwiftUI

struct JobDetailView: View {
    let job: Job
    @Environment(JobStore.self) private var store
    @State private var inspection: Inspection?

    private var detail: ServiceDetail? { inspection?.detail }

    var body: some View {
        Form {
            overviewSection
            ActionsSection(job: job)
            if !issues.isEmpty { issuesSection }
            if job.isLoaded { runtimeSection }
            programSection
            // An unreadable plist is already explained under Issues.
            if let plist = job.plist, plist.error == nil { configurationSection(plist) }
            rawSection
        }
        .formStyle(.grouped)
        .onChange(of: job.id) { inspection = nil }
        // Re-inspect right away after an action instead of waiting for the next poll.
        .task(id: "\(job.id)#\(store.activity.count)") {
            while !Task.isCancelled {
                let latest = store.job(job.id) ?? job
                let fresh = await store.inspect(latest)
                if !Task.isCancelled { inspection = fresh }
                try? await Task.sleep(for: JobStore.pollInterval)
            }
        }
    }

    /// List-level issues plus the ones only the detail reveals, worst first.
    private var issues: [Issue] {
        var all = job.issues + (inspection?.issues ?? [])
        if all.contains(where: { if case .crashLoop = $0 { true } else { false } }) {
            all.removeAll { if case .lastExitFailed = $0 { true } else { false } }
        }
        return all.sorted { $0.severity > $1.severity }
    }

    // MARK: Sections

    private var overviewSection: some View {
        Section {
            LabeledContent("Status") { StatusBadge(status: job.status) }
            LabeledContent("Origin", value: job.originTitle)
            LabeledContent("Target") { Mono(job.id) }
            if let plist = job.plist {
                LabeledContent("Plist") {
                    HStack {
                        Mono(plist.url.path)
                        Button("Reveal in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([plist.url])
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            } else if let submitter = detail?.submittedBy {
                LabeledContent("Plist", value: "None (submitted by \(submitter))")
            } else if let path = detail?.path {
                LabeledContent("Plist") { Mono(path) }
            } else {
                LabeledContent("Plist", value: "None found")
            }
            if let override = job.override {
                LabeledContent("Override", value: override == .disabled ? "Disabled" : "Enabled")
            }
            if let loginItem = job.loginItem {
                LabeledContent("Login Items") {
                    HStack {
                        VStack(alignment: .trailing, spacing: 2) {
                            Label(loginItem.isAllowed ? "Allowed" : "Switched off",
                                  systemImage: loginItem.isAllowed ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(loginItem.isAllowed ? Color.secondary : Color.orange)
                            if let owner = [loginItem.appName, loginItem.developer].compactMap({ $0 }).first {
                                Text(loginItem.appName != nil && loginItem.developer != nil && loginItem.appName != loginItem.developer
                                     ? "\(loginItem.appName!) · \(loginItem.developer!)" : owner)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if store.isLoadingLoginItems {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Load App Names", systemImage: "person.crop.rectangle.stack") {
                                store.reloadLoginItems()
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help(loginItemsHelp)
                        }
                        Button("Open Login Items Settings", systemImage: "gear") {
                            NSWorkspace.shared.open(BackgroundItems.settingsURL)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Open System Settings → Login Items & Extensions")
                    }
                }
            }
        } header: {
            Text(job.label)
                .font(.title2.bold())
                .textSelection(.enabled)
        }
    }

    private var loginItemsHelp: String {
        let base = "Look up app and developer names in Login Items (asks for your password, takes about 20 s)"
        guard let updated = store.loginItemsUpdated else { return base }
        return base + "\nLast loaded \(updated.formatted(.relative(presentation: .named)))"
    }

    private var issuesSection: some View {
        Section("Issues") {
            ForEach(issues, id: \.self) { issue in
                Label {
                    Text(issue.message)
                } icon: {
                    Image(systemName: issue.severity.systemImage).foregroundStyle(issue.severity.color)
                }
            }
        }
    }

    private var runtimeSection: some View {
        Section("Runtime") {
            if let error = inspection?.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let detail {
                Row("State", detail.state)
                Row("PID", detail.pid.map(String.init))
                Row("Last exit", lastExitText(detail))
                Row("Runs", detail.runs?.formatted())
                Row("Last started because", inspection?.blame)
                Row("Trigger", detail.immediateReason)
                Row("Spawn type", detail.spawnType)
                Row("Run interval", detail.runInterval)
            } else if inspection == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var programSection: some View {
        Section("Program") {
            let arguments = detail.map { $0.arguments.isEmpty ? [$0.program].compactMap { $0 } : $0.arguments }
                ?? job.plist?.commandLine ?? []
            Row("Executable", detail?.program ?? job.plist?.executable, monospaced: true)
            if arguments.count > 1 {
                LabeledContent("Arguments") {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(Array(arguments.dropFirst().enumerated()), id: \.offset) { _, argument in
                            Mono(argument)
                        }
                    }
                }
            }
            Row("Working directory", detail?.workingDirectory ?? job.plist?.workingDirectory, monospaced: true)
            Row("Installed by", Ownership.hint(
                executable: detail?.program ?? job.plist?.executable,
                bundleID: detail?.bundleID,
                associatedBundleIDs: job.plist?.associatedBundleIDs ?? []
            ))
            Row("Signed by", inspection?.signature?.description)
        }
    }

    private func configurationSection(_ plist: PlistJob) -> some View {
        Section("Configuration (plist on disk)") {
            Row("Run at load", plist.runAtLoad ? "Yes" : "No")
            Row("Keep alive", Format.keepAlive(plist.keepAlive))
            Row("Start interval", plist.startInterval.map { "Every \(Format.seconds($0))" })
            ForEach(Array(plist.calendarIntervals.enumerated()), id: \.offset) { index, interval in
                Row(index == 0 ? "Schedule" : "", Format.calendarInterval(interval))
            }
            ForEach(Array(plist.watchPaths.enumerated()), id: \.offset) { index, path in
                Row(index == 0 ? "Watch paths" : "", path, monospaced: true)
            }
            Row("Standard output", plist.stdoutPath, monospaced: true)
            Row("Standard error", plist.stderrPath, monospaced: true)
            Row("Session types", plist.sessionTypes.isEmpty ? nil : plist.sessionTypes.joined(separator: ", "))
            if plist.disabledKey {
                Row("Disabled key", "Yes")
            }
            ForEach(plist.environment.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                Row(key, value, monospaced: true)
            }
        }
    }

    private var rawSection: some View {
        Section("Raw") {
            if let xml = job.plist?.xml {
                DisclosureGroup("Plist XML") { RawText(xml) }
            }
            if let raw = detail?.raw {
                DisclosureGroup("launchctl print") { RawText(raw) }
            }
        }
    }

    private func lastExitText(_ detail: ServiceDetail) -> String {
        var text = detail.lastExit == .none ? "Never exited" : detail.lastExit.description
        if let signal = detail.lastSignal { text += " (\(signal))" }
        if let reason = detail.lastExitReason { text += " — \(reason)" }
        return text
    }
}

/// A labeled row that disappears when there's no value.
private struct Row: View {
    let title: String
    let value: String?
    let monospaced: Bool

    init(_ title: String, _ value: String?, monospaced: Bool = false) {
        self.title = title
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        if let value, !value.isEmpty {
            LabeledContent(title) {
                if monospaced { Mono(value) } else { Text(value).textSelection(.enabled) }
            }
        }
    }
}

private struct Mono: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .multilineTextAlignment(.trailing)
    }
}

private struct RawText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
