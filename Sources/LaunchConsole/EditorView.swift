import AppKit
import LaunchdKit
import SwiftUI

@MainActor @Observable
final class EditorModel {
    enum Mode: String, CaseIterable, Identifiable {
        case form = "Form"
        case xml = "XML"
        var id: Self { self }
    }

    let request: EditorRequest
    let original: JobDefinition
    var definition: JobDefinition
    var mode: Mode = .form
    var xmlText = ""
    var xmlError: String?
    var saveError: String?
    var isSaving = false

    init(request: EditorRequest) {
        self.request = request
        original = request.definition
        definition = request.definition
    }

    var isNew: Bool { request.job == nil }
    var isDirty: Bool { isNew || definition != original }

    /// The file the plist lives in, or will be created as.
    var fileName: String {
        request.job?.plist?.url.lastPathComponent ?? "\(definition.label).plist"
    }

    func setMode(_ new: Mode) {
        guard new != mode else { return }
        if new == .xml {
            xmlText = (try? definition.xmlString()) ?? ""
            xmlError = nil
            mode = .xml
        } else if applyXML() {
            mode = .form
        }
    }

    /// Parses the XML text into the definition. Returns false (and sets `xmlError`) if it's invalid.
    @discardableResult
    func applyXML() -> Bool {
        do {
            definition = try JobDefinition(xml: Data(xmlText.utf8))
            xmlError = nil
            return true
        } catch {
            xmlError = "The XML isn't a valid property list: \(error.localizedDescription)"
            return false
        }
    }
}

struct EditorView: View {
    @Environment(JobStore.self) private var store
    @State private var model: EditorModel
    @State private var confirmDiscard = false

    init(request: EditorRequest) {
        let model = EditorModel(request: request)
        #if DEBUG
        if DebugSnapshot.environment["LAUNCHCONSOLE_EDITOR_MODE"] == "xml" {
            model.setMode(.xml)
        }
        #endif
        _model = State(initialValue: model)
    }

    private var issues: [ValidationIssue] {
        Validator().validate(model.definition, fileName: model.fileName, takenLabels: store.takenLabels(excluding: model.request.job))
    }

    private var hasErrors: Bool {
        model.xmlError != nil || issues.contains { $0.severity == .error }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.mode {
            case .form: EditorForm(model: model)
            case .xml: xmlEditor
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 640, idealHeight: 760)
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { store.editorRequest = nil }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isNew ? "New Agent" : "Edit \(model.original.label)")
                    .font(.headline)
                Text(model.isNew ? store.plistStore.url(forLabel: model.definition.label).path : model.request.job?.plist?.url.path ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                ForEach(EditorModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(12)
    }

    private var xmlEditor: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            if let error = model.xmlError {
                Label(error, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            TextEditor(text: $model.xmlText)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .onChange(of: model.xmlText) { model.applyXML() }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.request.isPreview {
                Label("Preview only: saving is disabled.", systemImage: "eye")
                    .foregroundStyle(.secondary)
            }
            ForEach(EditPolicy.notes(for: model.definition.label), id: \.self) { note in
                Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
            }
            if !issues.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(issues, id: \.self) { issue in
                            Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == .error ? .red : .orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 96)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.saveError {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            HStack {
                if model.isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) {
                    if model.isDirty && !model.isNew && !model.request.isPreview {
                        confirmDiscard = true
                    } else {
                        store.editorRequest = nil
                    }
                }
                .keyboardShortcut(.cancelAction)
                ForEach(saveButtons, id: \.title) { button in
                    Button(button.title) { save(then: button.after) }
                        .help(button.help)
                        .modifier(DefaultAction(enabled: button.isDefault))
                }
                .disabled(hasErrors || !model.isDirty || model.isSaving || model.request.isPreview)
            }
        }
        .font(.callout)
        .padding(12)
    }

    private struct SaveButton {
        var title: String
        var after: JobStore.AfterSave
        var help: String
        var isDefault = false
    }

    /// What saving can be followed by depends on whether the job is loaded right now.
    private var saveButtons: [SaveButton] {
        guard let job = model.request.job else {
            return [
                SaveButton(title: "Create", after: .nothing, help: "Write the plist. It loads at next login."),
                SaveButton(title: "Create & Load", after: .load, help: "Write the plist and load it now.", isDefault: true),
            ]
        }
        if job.isLoaded {
            return [
                SaveButton(title: "Save", after: .nothing, help: "Write the plist. The running copy keeps its old settings until it's reloaded."),
                SaveButton(title: "Save & Reload", after: .reload, help: "Write the plist, unload the running copy and load the new one. If it's running, it restarts.", isDefault: true),
            ]
        }
        var buttons = [SaveButton(title: "Save", after: .nothing, help: "Write the plist.", isDefault: job.isDisabled)]
        if !job.isDisabled {
            buttons.append(SaveButton(title: "Save & Load", after: .load, help: "Write the plist and load it now.", isDefault: true))
        }
        return buttons
    }

    private func save(then after: JobStore.AfterSave) {
        if model.mode == .xml, !model.applyXML() { return }
        model.isSaving = true
        model.saveError = nil
        Task {
            if let error = await store.save(model.definition, for: model.request, then: after) {
                model.saveError = error
                model.isSaving = false
            } else {
                store.editorRequest = nil
            }
        }
    }
}

private struct DefaultAction: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}

/// The structured editor. Everything binds straight into `model.definition`.
struct EditorForm: View {
    @Bindable var model: EditorModel

    var body: some View {
        Form {
            Section("Job") {
                TextField("Label", text: $model.definition.label, prompt: Text("local.yourname.task"))
            }

            Section("Program") {
                LabeledContent("Program") {
                    HStack {
                        TextField("Program", text: program, prompt: Text("/full/path/to/executable"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                        Button("Choose…") { chooseProgram() }
                    }
                }
                StringListEditor(title: "Arguments", items: arguments, placeholder: "Argument", addTitle: "Add Argument")
            }

            Section("When to Run") {
                Toggle("Run when loaded (and at every login)", isOn: $model.definition.runAtLoad)
                Picker("Keep running", selection: $model.definition.keepAlive) {
                    Text(KeepAliveMode.off.title).tag(KeepAliveMode.off)
                    Text(KeepAliveMode.always.title).tag(KeepAliveMode.always)
                    Text(KeepAliveMode.onFailure.title).tag(KeepAliveMode.onFailure)
                    if model.original.keepAlive == .custom {
                        Text(KeepAliveMode.custom.title).tag(KeepAliveMode.custom)
                    }
                }
                Toggle("Repeat at an interval", isOn: Binding(
                    get: { model.definition.startInterval != nil },
                    set: { model.definition.startInterval = $0 ? 3600 : nil }
                ))
                if let seconds = model.definition.startInterval {
                    LabeledContent("Every") {
                        HStack {
                            TextField("Seconds", value: $model.definition.startInterval, format: .number)
                                .labelsHidden()
                                .frame(width: 90)
                            Text(seconds > 0 ? "seconds (\(Format.seconds(seconds)))" : "seconds")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                CalendarEditor(intervals: $model.definition.calendarIntervals)
                StringListEditor(title: "Watch paths", items: $model.definition.watchPaths, placeholder: "/path/to/watch", addTitle: "Add Watch Path")
            }

            Section {
                TextField("Standard output", text: $model.definition.stdoutPath, prompt: Text("Discarded"))
                TextField("Standard error", text: $model.definition.stderrPath, prompt: Text("Discarded"))
                Button("Log Both to ~/Library/Logs/\(model.definition.label.isEmpty ? "label" : model.definition.label).log") {
                    let path = FileManager.default.homeDirectoryForCurrentUser
                        .appending(path: "Library/Logs/\(model.definition.label).log").path
                    model.definition.stdoutPath = path
                    model.definition.stderrPath = path
                }
                .disabled(model.definition.label.isEmpty)
            } header: {
                Text("Output")
            } footer: {
                Text("Without these, anything the program prints is thrown away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Environment") {
                TextField("Working directory", text: $model.definition.workingDirectory, prompt: Text("/"))
                EnvironmentEditor(environment: $model.definition.environment)
            }

            if !model.definition.otherKeys.isEmpty {
                Section("Other Keys") {
                    Text(model.definition.otherKeys.joined(separator: ", "))
                        .font(.system(.body, design: .monospaced))
                    Text("Kept as they are. Switch to XML to change them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// `ProgramArguments[0]`.
    private var program: Binding<String> {
        Binding(
            get: { model.definition.arguments.first ?? "" },
            set: { newValue in
                var arguments = model.definition.arguments
                if arguments.isEmpty { arguments = [newValue] } else { arguments[0] = newValue }
                model.definition.arguments = arguments == [""] ? [] : arguments
            }
        )
    }

    /// `ProgramArguments[1...]`.
    private var arguments: Binding<[String]> {
        Binding(
            get: { Array(model.definition.arguments.dropFirst()) },
            set: { model.definition.arguments = [model.definition.arguments.first ?? ""] + $0 }
        )
    }

    private func chooseProgram() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the executable launchd should run"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // Choosing an .app means its executable, which is what launchd needs.
        if url.pathExtension == "app", let executable = Bundle(url: url)?.executableURL {
            url = executable
        }
        program.wrappedValue = url.path
    }
}

/// An editable list of strings with add/remove buttons.
struct StringListEditor: View {
    let title: String
    @Binding var items: [String]
    let placeholder: String
    let addTitle: String

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing) {
                ForEach(items.indices, id: \.self) { index in
                    HStack {
                        TextField(placeholder, text: Binding(
                            get: { index < items.count ? items[index] : "" },
                            set: { if index < items.count { items[index] = $0 } }
                        ))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        Button("Remove", systemImage: "minus.circle") {
                            if index < items.count { items.remove(at: index) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                Button(addTitle, systemImage: "plus") { items.append("") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// `StartCalendarInterval` rows. An empty field means "any".
struct CalendarEditor: View {
    @Binding var intervals: [[String: Int]]

    var body: some View {
        LabeledContent("Schedule") {
            VStack(alignment: .trailing) {
                ForEach(intervals.indices, id: \.self) { index in
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack {
                            Picker("Weekday", selection: field(index, "Weekday")) {
                                Text("Any day").tag(Int?.none)
                                ForEach(0..<7, id: \.self) { day in
                                    Text(Calendar.current.weekdaySymbols[day]).tag(Int?.some(day))
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Text("at").foregroundStyle(.secondary)
                            TextField("Hour", value: field(index, "Hour"), format: .number, prompt: Text("hh"))
                                .labelsHidden()
                                .frame(width: 44)
                            Text(":").foregroundStyle(.secondary)
                            TextField("Minute", value: field(index, "Minute"), format: .number, prompt: Text("mm"))
                                .labelsHidden()
                                .frame(width: 44)
                            Button("Remove", systemImage: "minus.circle") {
                                if index < intervals.count { intervals.remove(at: index) }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                        if index < intervals.count {
                            Text(Format.calendarInterval(intervals[index]))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Add Schedule", systemImage: "plus") { intervals.append(["Hour": 9, "Minute": 0]) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func field(_ index: Int, _ key: String) -> Binding<Int?> {
        Binding(
            get: { index < intervals.count ? intervals[index][key] : nil },
            set: { if index < intervals.count { intervals[index][key] = $0 } }
        )
    }
}

/// Environment variables as editable rows. Rows keep their order while you type.
struct EnvironmentEditor: View {
    @Binding var environment: [String: String]
    @State private var rows: [Row] = []

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var value: String
    }

    var body: some View {
        LabeledContent("Variables") {
            VStack(alignment: .trailing) {
                ForEach($rows) { $row in
                    HStack {
                        TextField("NAME", text: $row.name)
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 140)
                        Text("=").foregroundStyle(.secondary)
                        TextField("value", text: $row.value)
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                        Button("Remove", systemImage: "minus.circle") {
                            rows.removeAll { $0.id == row.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Variable", systemImage: "plus") { rows.append(Row(name: "", value: "")) }
                    .buttonStyle(.borderless)
            }
        }
        .onAppear {
            rows = environment.sorted { $0.key < $1.key }.map { Row(name: $0.key, value: $0.value) }
        }
        .onChange(of: rows) {
            var result: [String: String] = [:]
            // A row that's still completely empty isn't a variable yet.
            for row in rows where !(row.name.isEmpty && row.value.isEmpty) {
                result[row.name] = row.value
            }
            environment = result
        }
    }
}
