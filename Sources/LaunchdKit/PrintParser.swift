import Foundation

/// One `name = { ... }` block of `launchctl print` output.
///
/// The format is undocumented and changes between macOS releases, so the parser stays generic:
/// it records every field, nested block and raw line, and callers pick out what they recognise.
/// Unknown content is kept, never rejected.
public struct PrintBlock: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public var key: String
        public var value: String
    }

    public var name: String
    /// `key = value` and `key => value` lines, in order.
    public var fields: [Field] = []
    public var blocks: [PrintBlock] = []
    /// Every non-block line, in order, including the ones also parsed into `fields`.
    /// List-like blocks (`arguments`, `services`) are read from here.
    public var lines: [String] = []

    public init(name: String) {
        self.name = name
    }

    public subscript(key: String) -> String? {
        fields.first { $0.key == key }?.value
    }

    public func block(_ name: String) -> PrintBlock? {
        blocks.first { $0.name == name }
    }

    /// The fields of a dictionary-style block such as `environment`. Later duplicates win.
    public var dictionary: [String: String] {
        Dictionary(fields.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
    }
}

public enum PrintParser {
    /// Parses the outermost block. Returns nil when the text contains no block at all
    /// (for example an error message instead of output).
    public static func parse(_ text: String) -> PrintBlock? {
        var stack: [PrintBlock] = []
        var root: PrintBlock?

        func close() {
            guard let done = stack.popLast() else { return }
            if stack.isEmpty {
                root = done
            } else {
                stack[stack.count - 1].blocks.append(done)
            }
        }

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line == "}" {
                close()
                if root != nil { break }
                continue
            }
            if let name = blockName(line) {
                stack.append(PrintBlock(name: name))
                continue
            }
            guard !stack.isEmpty else { continue }
            stack[stack.count - 1].lines.append(line)
            if let field = field(line) {
                stack[stack.count - 1].fields.append(field)
            }
        }

        // Truncated output: fold whatever is still open into its parent.
        while root == nil, !stack.isEmpty { close() }
        return root
    }

    private static func blockName(_ line: String) -> String? {
        for opener in [" = {", " => {"] where line.hasSuffix(opener) {
            return unquote(String(line.dropLast(opener.count)))
        }
        return nil
    }

    private static func field(_ line: String) -> PrintBlock.Field? {
        let separators = [" = ", " => "].compactMap { line.range(of: $0) }
        guard let separator = separators.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let key = unquote(String(line[..<separator.lowerBound]))
        let value = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return PrintBlock.Field(key: key, value: value)
    }

    static func unquote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}
