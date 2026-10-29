import Foundation

/// Who signed a job's executable, from `codesign -dv --verbose=2`.
public struct Signature: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case unsigned
        case adhoc
        /// Leaf certificate, e.g. `Developer ID Application: Jane Doe (TEAMID)`.
        case certificate(String)
    }

    public var kind: Kind
    public var identifier: String?
    public var teamID: String?

    public init(kind: Kind, identifier: String? = nil, teamID: String? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.teamID = teamID
    }

    /// Parses codesign's stderr. nil when codesign couldn't read the file at all.
    public init?(codesignOutput text: String) {
        var values: [(String, String)] = []
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values.append((String(line[..<equals]), String(line[line.index(after: equals)...])))
        }
        func first(_ key: String) -> String? { values.first { $0.0 == key }?.1 }

        if text.contains("code object is not signed") {
            self.init(kind: .unsigned)
        } else if let authority = first("Authority") {
            self.init(kind: .certificate(authority), identifier: first("Identifier"), teamID: first("TeamIdentifier"))
        } else if first("Signature") == "adhoc" {
            self.init(kind: .adhoc, identifier: first("Identifier"))
        } else {
            return nil
        }
    }

    public var description: String {
        switch kind {
        case .unsigned: "Not signed"
        case .adhoc: "Ad-hoc signed (no identity)"
        case .certificate(let authority): authority
        }
    }

    public static func read(executable path: String) async -> Signature? {
        guard let result = try? await Command.run("/usr/bin/codesign", ["-dv", "--verbose=2", path]) else { return nil }
        return Signature(codesignOutput: result.stderr)
    }
}
