import Foundation

/// A property-list value that is Sendable and Equatable, so a whole plist can live in a model.
public indirect enum PlistValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case real(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    public init?(_ any: Any) {
        switch any {
        // NSNumber bridges to Bool, Int and Double alike; check its real type first.
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let number as NSNumber where CFNumberIsFloatType(number):
            self = .real(number.doubleValue)
        case let number as NSNumber:
            self = .integer(number.intValue)
        case let string as String: self = .string(string)
        case let date as Date: self = .date(date)
        case let data as Data: self = .data(data)
        case let array as [Any]:
            self = .array(array.compactMap(PlistValue.init))
        case let dict as [String: Any]:
            self = .dictionary(dict.compactMapValues(PlistValue.init))
        default: return nil
        }
    }

    public var any: Any {
        switch self {
        case .string(let value): value
        case .integer(let value): value
        case .real(let value): value
        case .bool(let value): value
        case .date(let value): value
        case .data(let value): value
        case .array(let values): values.map(\.any)
        case .dictionary(let values): values.mapValues(\.any)
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var integer: Int? { if case .integer(let value) = self { value } else { nil } }
    public var array: [PlistValue]? { if case .array(let value) = self { value } else { nil } }
    public var dictionary: [String: PlistValue]? { if case .dictionary(let value) = self { value } else { nil } }
}

/// The KeepAlive choices the form offers. Anything else is kept as-is and shown as custom.
public enum KeepAliveMode: Sendable, Equatable, Hashable {
    case off
    case always
    /// `KeepAlive = { SuccessfulExit = false }`: restart only after a failing exit.
    case onFailure
    case custom

    public var title: String {
        switch self {
        case .off: "Never"
        case .always: "Always"
        case .onFailure: "After a failing exit"
        case .custom: "Custom (edit in XML)"
        }
    }
}

/// An editable launchd job definition. The dictionary is the source of truth, so keys the
/// form doesn't know about (Sockets, MachServices, ProcessType, …) survive an edit untouched.
public struct JobDefinition: Sendable, Equatable {
    public var dictionary: [String: PlistValue]

    public init(dictionary: [String: PlistValue] = [:]) {
        self.dictionary = dictionary
    }

    public init(label: String, arguments: [String]) {
        self.init()
        self.label = label
        self.arguments = arguments
    }

    // MARK: Reading and writing

    public init(xml data: Data) throws {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any] else {
            throw DefinitionError.notADictionary
        }
        self.init(dictionary: dict.compactMapValues(PlistValue.init))
    }

    public init(contentsOf url: URL) throws {
        try self.init(xml: try Data(contentsOf: url))
    }

    public func xmlData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary.mapValues(\.any), format: .xml, options: 0)
    }

    public func xmlString() throws -> String {
        String(decoding: try xmlData(), as: UTF8.self)
    }

    // MARK: Known keys

    private mutating func set(_ key: String, _ value: PlistValue?) {
        dictionary[key] = value
    }

    public var label: String {
        get { dictionary["Label"]?.string ?? "" }
        set { set("Label", .string(newValue)) }
    }

    /// `ProgramArguments`. Setting it also drops a separate `Program` key, which would
    /// otherwise silently override argv[0] and make the form misleading.
    public var arguments: [String] {
        get {
            let args = dictionary["ProgramArguments"]?.array?.compactMap(\.string) ?? []
            if args.isEmpty, let program = dictionary["Program"]?.string { return [program] }
            return args
        }
        set {
            set("Program", nil)
            set("ProgramArguments", newValue.isEmpty ? nil : .array(newValue.map(PlistValue.string)))
        }
    }

    public var runAtLoad: Bool {
        get { dictionary["RunAtLoad"]?.bool ?? false }
        set { set("RunAtLoad", newValue ? .bool(true) : nil) }
    }

    public var keepAlive: KeepAliveMode {
        get {
            switch dictionary["KeepAlive"] {
            case nil, .bool(false): .off
            case .bool(true): .always
            case .dictionary(let dict) where dict == ["SuccessfulExit": .bool(false)]: .onFailure
            default: .custom
            }
        }
        set {
            switch newValue {
            case .off: set("KeepAlive", nil)
            case .always: set("KeepAlive", .bool(true))
            case .onFailure: set("KeepAlive", .dictionary(["SuccessfulExit": .bool(false)]))
            case .custom: break
            }
        }
    }

    public var startInterval: Int? {
        get { dictionary["StartInterval"]?.integer }
        set { set("StartInterval", newValue.map(PlistValue.integer)) }
    }

    /// `StartCalendarInterval`, always as a list. Written back as a single dict when there's one.
    public var calendarIntervals: [[String: Int]] {
        get {
            switch dictionary["StartCalendarInterval"] {
            case .dictionary(let one): [one.compactMapValues(\.integer)]
            case .array(let many): many.compactMap { $0.dictionary?.compactMapValues(\.integer) }
            default: []
            }
        }
        set {
            let values = newValue.map { PlistValue.dictionary($0.mapValues(PlistValue.integer)) }
            set("StartCalendarInterval", values.isEmpty ? nil : values.count == 1 ? values[0] : .array(values))
        }
    }

    public var watchPaths: [String] {
        get { dictionary["WatchPaths"]?.array?.compactMap(\.string) ?? [] }
        set { set("WatchPaths", newValue.isEmpty ? nil : .array(newValue.map(PlistValue.string))) }
    }

    public var stdoutPath: String {
        get { dictionary["StandardOutPath"]?.string ?? "" }
        set { set("StandardOutPath", newValue.isEmpty ? nil : .string(newValue)) }
    }

    public var stderrPath: String {
        get { dictionary["StandardErrorPath"]?.string ?? "" }
        set { set("StandardErrorPath", newValue.isEmpty ? nil : .string(newValue)) }
    }

    public var workingDirectory: String {
        get { dictionary["WorkingDirectory"]?.string ?? "" }
        set { set("WorkingDirectory", newValue.isEmpty ? nil : .string(newValue)) }
    }

    public var environment: [String: String] {
        get { dictionary["EnvironmentVariables"]?.dictionary?.compactMapValues(\.string) ?? [:] }
        set { set("EnvironmentVariables", newValue.isEmpty ? nil : .dictionary(newValue.mapValues(PlistValue.string))) }
    }

    /// Keys the form doesn't edit, shown so nobody is surprised they're there.
    public var otherKeys: [String] {
        let known: Set<String> = [
            "Label", "Program", "ProgramArguments", "RunAtLoad", "KeepAlive", "StartInterval",
            "StartCalendarInterval", "WatchPaths", "StandardOutPath", "StandardErrorPath",
            "WorkingDirectory", "EnvironmentVariables",
        ]
        return dictionary.keys.filter { !known.contains($0) }.sorted()
    }
}

public enum DefinitionError: Error, LocalizedError, Equatable {
    case notADictionary

    public var errorDescription: String? {
        switch self {
        case .notADictionary: "The top level of the plist isn't a dictionary."
        }
    }
}

/// Starting points for a new agent.
public enum JobTemplate: String, Sendable, CaseIterable, Identifiable {
    case atLogin, keepAlive, interval, calendar, watchPath

    public var id: Self { self }

    public var title: String {
        switch self {
        case .atLogin: "Run Once at Login"
        case .keepAlive: "Keep Running"
        case .interval: "Run Every N Seconds"
        case .calendar: "Run on a Schedule"
        case .watchPath: "Run When a Path Changes"
        }
    }

    public var systemImage: String {
        switch self {
        case .atLogin: "person.crop.circle.badge.checkmark"
        case .keepAlive: "infinity"
        case .interval: "timer"
        case .calendar: "calendar"
        case .watchPath: "eye"
        }
    }

    /// A definition with logging to `~/Library/Logs/<label>.log` so output isn't lost.
    public func definition(label: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> JobDefinition {
        var definition = JobDefinition(label: label, arguments: [])
        let log = home.appending(path: "Library/Logs/\(label).log").path
        definition.stdoutPath = log
        definition.stderrPath = log
        switch self {
        case .atLogin:
            definition.runAtLoad = true
        case .keepAlive:
            definition.runAtLoad = true
            definition.keepAlive = .always
        case .interval:
            definition.startInterval = 3600
        case .calendar:
            definition.calendarIntervals = [["Hour": 9, "Minute": 0]]
        case .watchPath:
            definition.watchPaths = [home.appending(path: "Downloads").path]
        }
        return definition
    }
}
