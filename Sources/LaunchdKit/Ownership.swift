import Foundation

public enum Ownership {
    /// A best-effort guess at what installed a job, from where its executable lives.
    public static func hint(executable: String?, bundleID: String? = nil, associatedBundleIDs: [String] = []) -> String? {
        if let executable {
            if let range = executable.range(of: ".app/") {
                let bundlePath = String(executable[..<range.lowerBound]) + ".app"
                return (bundlePath as NSString).lastPathComponent
            }
            if executable.hasPrefix("/opt/homebrew/") || executable.hasPrefix("/usr/local/Cellar/") || executable.hasPrefix("/usr/local/opt/") {
                return "Homebrew"
            }
            if executable.hasPrefix("/System/") || executable.hasPrefix("/usr/libexec/") || executable.hasPrefix("/usr/sbin/") {
                return "macOS"
            }
        }
        if !associatedBundleIDs.isEmpty {
            return associatedBundleIDs.joined(separator: ", ")
        }
        return bundleID
    }
}
