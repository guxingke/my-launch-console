import LaunchdKit
import SwiftUI

struct ContentView: View {
    @Environment(JobStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var scope: Scope? = .nonApple
    @State private var statusFilter: StatusFilter = .any
    @State private var search = ""
    @State private var selection: Job.ID?
    @State private var sortOrder = [KeyPathComparator(\Job.label, comparator: .localizedStandard)]

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $scope) {
                Section {
                    ForEach(Scope.overview) { scopeRow($0) }
                }
                Section("Agents · Your Login Session") {
                    ForEach(Scope.agents) { scopeRow($0) }
                }
                Section("Daemons · System") {
                    ForEach(Scope.daemons) { scopeRow($0) }
                    if let error = store.systemError {
                        Label("Couldn't read: \(error)", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } content: {
            JobTable(jobs: rows, selection: $selection, sortOrder: $sortOrder)
                .navigationSplitViewColumnWidth(min: 440, ideal: 640)
                .overlay { emptyState }
                .safeAreaInset(edge: .top) { filterBar }
                .safeAreaInset(edge: .bottom) { footer }
        } detail: {
            if let id = selection, let job = store.job(id) {
                JobInspector(job: job)
                    .navigationSplitViewColumnWidth(min: 380, ideal: 460)
            } else {
                ContentUnavailableView("No Job Selected", systemImage: "list.bullet.rectangle")
                    .navigationSplitViewColumnWidth(min: 380, ideal: 460)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Label, program or path")
        #if DEBUG
        .onAppear { selection = DebugSnapshot.selectedLabel.map(store.id(forKey:)) ?? selection }
        .task {
            guard let action = DebugSnapshot.confirmationPreview, let label = DebugSnapshot.selectedLabel else { return }
            while store.job(store.id(forKey: label)) == nil { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .seconds(1))
            // Never `store.request`: this dialog appears on the real screen, so it must not be able to run anything.
            if let job = store.job(store.id(forKey: label)), let command = store.command(for: action, on: job) {
                store.pendingConfirmation = PendingAction(job: job, command: command, isPreview: true)
            }
        }
        .onAppear {
            if let window = DebugSnapshot.environment["LAUNCHCONSOLE_WINDOW"] { openWindow(id: window) }
        }
        .task {
            // Opens the editor as an inert preview: `edit` for the selected job, or `new:<template>`.
            guard let edit = DebugSnapshot.environment["LAUNCHCONSOLE_EDIT"] else { return }
            while !store.hasLoaded { try? await Task.sleep(for: .milliseconds(200)) }
            if edit.hasPrefix("new:"), let template = JobTemplate(rawValue: String(edit.dropFirst(4))) {
                store.editorRequest = EditorRequest(job: nil, definition: template.definition(label: "local.\(NSUserName()).untitled"), isPreview: true)
            } else if let label = DebugSnapshot.selectedLabel, let job = store.job(store.id(forKey: label)), let url = job.plist?.url,
                      let definition = try? JobDefinition(contentsOf: url) {
                store.editorRequest = EditorRequest(job: job, definition: definition, isPreview: true)
            }
        }
        #endif
        .modifier(ActionConfirmation())
        .sheet(item: $store.editorRequest) { request in
            EditorView(request: request)
                .environment(store)
        }
        .onChange(of: store.lastCreatedLabel) { _, label in
            if let label { selection = store.id(forKey: label) }
        }
        .toolbar {
            ToolbarItem {
                Menu("New Agent", systemImage: "plus") {
                    ForEach(JobTemplate.allCases) { template in
                        Button(template.title, systemImage: template.systemImage) {
                            store.newAgent(from: template)
                        }
                    }
                }
                .help("Create a launch agent in ~/Library/LaunchAgents")
            }
            ToolbarItem {
                Button("Schedule", systemImage: "calendar") {
                    openWindow(id: "schedule")
                }
                .help("When scheduled jobs ran and will run next")
            }
            ToolbarItem {
                Button("Activity", systemImage: "clock.arrow.circlepath") {
                    openWindow(id: "activity")
                }
                .help("Commands the app has run this session")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
                .help("Refresh now (it also refreshes every 2 seconds)")
            }
        }
    }

    private func scopeRow(_ scope: Scope) -> some View {
        Label(scope.title, systemImage: scope.systemImage)
            .badge(store.jobs.count { scope.includes($0) && statusFilter.includes($0) })
            .tag(scope)
    }

    private var rows: [Job] {
        let scope = scope ?? .nonApple
        let needle = search.trimmingCharacters(in: .whitespaces)
        return store.jobs
            .filter { scope.includes($0) && statusFilter.includes($0) && matches($0, needle) }
            .sorted(using: sortOrder)
    }

    private func matches(_ job: Job, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        let haystack = [job.label, job.plist?.url.path, job.plist?.executable].compactMap { $0 }
        return haystack.contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    @ViewBuilder private var emptyState: some View {
        if !store.hasLoaded {
            ProgressView()
        } else if rows.isEmpty {
            if search.isEmpty {
                ContentUnavailableView("No Jobs", systemImage: "tray", description: Text("Nothing matches this scope and status."))
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    /// Lives above the table rather than in the toolbar, which collapses menus when space is tight.
    private var filterBar: some View {
        HStack {
            Text("Show")
                .foregroundStyle(.secondary)
            Menu {
                Picker("Status", selection: $statusFilter) {
                    ForEach(StatusFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(statusFilter.title)
            }
            .fixedSize()
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let error = store.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(1).truncationMode(.tail)
            } else {
                Text("\(rows.count) of \(store.jobs.count) jobs in \(store.domain) and system")
            }
            Spacer()
            if let updated = store.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct JobTable: View {
    @Environment(JobStore.self) private var store
    let jobs: [Job]
    @Binding var selection: Job.ID?
    @Binding var sortOrder: [KeyPathComparator<Job>]

    var body: some View {
        Table(jobs, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Status", value: \.status) { job in
                StatusBadge(status: job.status)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Label", value: \.label, comparator: .localizedStandard) { job in
                HStack(spacing: 4) {
                    Text(job.label).lineLimit(1).truncationMode(.middle)
                    if store.isWatched(job) {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .help("You'll be notified if this job starts failing")
                    }
                    if let severity = job.worstSeverity, severity >= .warning {
                        Image(systemName: severity.systemImage)
                            .foregroundStyle(severity.color)
                            .help(job.issues.map(\.message).joined(separator: "\n"))
                    }
                }
            }
            .width(min: 180, ideal: 300)

            TableColumn("Origin", value: \.origin) { job in
                Text(job.originTitle).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 150)

            TableColumn("PID", value: \.pidSortKey) { job in
                Text(job.pid.map(String.init) ?? "").monospacedDigit()
            }
            .width(min: 50, ideal: 60)

            TableColumn("Last Exit", value: \.exitSortKey) { job in
                let exit = job.service?.lastExit ?? .none
                Text(job.service == nil ? "" : exit.description)
                    .monospacedDigit()
                    .foregroundStyle(exit.isFailure ? .red : .secondary)
            }
            .width(min: 50, ideal: 70)

            TableColumn("Plist", value: \.plistPath) { job in
                Text(job.plist?.url.path ?? "—")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 260)
        }
        .contextMenu(forSelectionType: Job.ID.self) { ids in
            if let id = ids.first, ids.count == 1, let job = jobs.first(where: { $0.id == id }) {
                JobActionMenuItems(job: job)
            }
        }
    }
}
