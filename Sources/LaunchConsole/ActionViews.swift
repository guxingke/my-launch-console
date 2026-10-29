import AppKit
import LaunchdKit
import SwiftUI

/// The detail pane's action buttons plus the outcome of the last action on this job.
struct ActionsSection: View {
    let job: Job
    @Environment(JobStore.self) private var store

    var body: some View {
        Section("Actions") {
            if let reason = ActionPolicy.readOnlyReason(for: job) {
                Label(reason, systemImage: "lock")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    ForEach(ActionPolicy.actions(for: job)) { action in
                        Button(action.title, systemImage: action.systemImage) {
                            store.request(action, on: job)
                        }
                        .help(store.command(for: action, on: job)?.shellString ?? "")
                    }
                    Spacer()
                    if store.isBusy(job) {
                        ProgressView().controlSize(.small)
                    }
                }
                .disabled(store.isBusy(job))
                if job.isSystem {
                    Label("Daemons run as root. macOS asks for your administrator password for each action.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if job.plist != nil, job.origin != .apple {
                HStack {
                    let editReason = EditPolicy.editReadOnlyReason(for: job)
                    if editReason == nil {
                        Button("Edit…", systemImage: "pencil") { store.edit(job) }
                    }
                    if EditPolicy.canMoveToTrash(job) {
                        Button("Move to Trash…", systemImage: "trash") { store.pendingTrash = job }
                    }
                    Spacer()
                    if let editReason, job.origin == .user || job.origin == .global {
                        Text(editReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(store.isBusy(job))
            }
            if job.status != .staleOverride {
                Toggle(isOn: Binding(get: { store.isWatched(job) }, set: { store.setWatched($0, for: job) })) {
                    Label("Notify me if it starts failing", systemImage: "bell")
                }
                .help("While this app is open, get a notification when the job exits with an error, stops despite KeepAlive, or is unloaded by something else")
                if store.isWatched(job), store.notificationsDenied {
                    Text("Notifications are turned off for this app in System Settings → Notifications.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let record = store.lastRecord(for: job.label) {
                ActionRecordView(record: record)
            }
        }
    }
}

/// One thing the app did: what ran, whether it worked, and launchctl's own words if not.
struct ActionRecordView: View {
    let record: ActionRecord
    var showsLabel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: record.failure == nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(record.failure == nil ? .green : .red)
                Text(summary)
                Spacer()
                Text(record.date.formatted(date: .omitted, time: .standard))
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            if !record.lines.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.lines.joined(separator: "\n"), forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            }
            if let failure = record.failure {
                Text(failure)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                if let hint = record.hint {
                    Label(hint, systemImage: "lightbulb")
                        .font(.caption)
                }
            }
        }
    }

    private var summary: String {
        let what = showsLabel ? "\(record.title) \(record.label)" : record.title
        return record.failure == nil ? "\(what) succeeded" : "\(what) failed"
    }
}

/// Context-menu items for a job: the same actions as the detail pane.
struct JobActionMenuItems: View {
    let job: Job
    @Environment(JobStore.self) private var store

    var body: some View {
        if ActionPolicy.readOnlyReason(for: job) == nil {
            ForEach(ActionPolicy.actions(for: job)) { action in
                Button(action.needsConfirmation ? "\(action.title)…" : action.title, systemImage: action.systemImage) {
                    store.request(action, on: job)
                }
            }
            .disabled(store.isBusy(job))
            Divider()
        }
        if EditPolicy.editReadOnlyReason(for: job) == nil {
            Button("Edit…", systemImage: "pencil") { store.edit(job) }
        }
        if EditPolicy.canMoveToTrash(job) {
            Button("Move to Trash…", systemImage: "trash") { store.pendingTrash = job }
        }
        Button("Copy Label", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(job.label, forType: .string)
        }
        if let url = job.plist?.url {
            Button("Reveal Plist in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

/// Asks before disruptive actions, spelling out the consequence and the exact command.
struct ActionConfirmation: ViewModifier {
    @Environment(JobStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var store = store
        let pending = store.pendingConfirmation
        content.confirmationDialog(
            pending.map { "\($0.command.action.title) \($0.job.label)?" } ?? "",
            isPresented: Binding(
                get: { store.pendingConfirmation != nil },
                set: { if !$0 { store.pendingConfirmation = nil } }
            ),
            presenting: pending
        ) { pending in
            Button(pending.command.action.title, role: pending.command.action == .restart ? nil : .destructive) {
                guard !pending.isPreview else { return }
                Task { await store.perform(pending.command, on: pending.job) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(ActionPolicy.consequence(of: pending.command.action, for: pending.job)
                + (pending.job.isSystem ? " macOS will then ask for your administrator password." : "")
                + "\n\n" + pending.command.shellString)
        }
        .confirmationDialog(
            store.pendingTrash.map { "Move \($0.label) to the Trash?" } ?? "",
            isPresented: Binding(
                get: { store.pendingTrash != nil },
                set: { if !$0 { store.pendingTrash = nil } }
            ),
            presenting: store.pendingTrash
        ) { job in
            Button("Move to Trash", role: .destructive) {
                Task { await store.moveToTrash(job) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { job in
            Text((job.isLoaded ? "Unloads the job, then moves " : "Moves ") + (job.plist?.url.path ?? "the plist")
                + " to the Trash. It won't load at next login. You can put it back from the Trash.")
        }
    }
}

/// Everything the app changed this session.
struct ActivityView: View {
    @Environment(JobStore.self) private var store

    var body: some View {
        Group {
            if store.activity.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "clock",
                    description: Text("Commands the app runs on your behalf appear here.")
                )
            } else {
                List(store.activity) { record in
                    ActionRecordView(record: record, showsLabel: true)
                        .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 300)
    }
}
