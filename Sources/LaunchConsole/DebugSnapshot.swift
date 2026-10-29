#if DEBUG
import AppKit
import LaunchdKit

/// Development aid: `LAUNCHCONSOLE_SNAPSHOT=/path/shot.png` makes the app render its visible
/// windows to PNGs (`shot.png`, `shot-1.png`, … for sheets) a few seconds after launch, then quit.
/// An app capturing itself needs no screen-recording permission.
/// `LAUNCHCONSOLE_SELECT=<label>` preselects a job; `LAUNCHCONSOLE_CONFIRM=<action>` then opens
/// that action's confirmation dialog as an inert preview.
///
/// These windows are real and appear on the user's screen while the snapshot runs. The preview
/// dialog's buttons do nothing: an earlier version ran the action when someone clicked it.
enum DebugSnapshot {
    static let environment = ProcessInfo.processInfo.environment
    static var selectedLabel: String? { environment["LAUNCHCONSOLE_SELECT"] }

    static var confirmationPreview: JobAction? {
        guard let action = environment["LAUNCHCONSOLE_CONFIRM"].flatMap(JobAction.init(rawValue:)),
              action.needsConfirmation else { return nil }
        return action
    }

    @MainActor static func scheduleIfRequested() {
        guard let path = environment["LAUNCHCONSOLE_SNAPSHOT"] else { return }
        let delay = Double(environment["LAUNCHCONSOLE_SNAPSHOT_DELAY"] ?? "") ?? 5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let base = URL(fileURLWithPath: path)
            let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
            for (index, window) in windows.enumerated() {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = index == 0 ? base : URL(fileURLWithPath: base.deletingPathExtension().path + "-\(index).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            // Not NSApp.terminate: that has to tear down any open dialog first, and a quit should
            // never be able to answer a confirmation. Exiting the process can't press a button.
            UnifiedLog.terminateAllStreams()
            exit(0)
        }
    }
}
#endif
