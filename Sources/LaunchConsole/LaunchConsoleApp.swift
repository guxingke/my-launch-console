import AppKit
import LaunchdKit
import SwiftUI

@main
struct LaunchConsoleApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = JobStore()

    var body: some Scene {
        WindowGroup("launchd Console") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1100, minHeight: 560)
                .onAppear { store.startPolling() }
        }
        .defaultSize(width: 1400, height: 820)

        Window("Schedule", id: "schedule") {
            ScheduleView()
                .environment(store)
        }
        .defaultSize(width: 1000, height: 520)

        Window("Activity", id: "activity") {
            ActivityView()
                .environment(store)
        }
        .defaultSize(width: 640, height: 420)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
                Button("Load Login Item App Names…") { store.reloadLoginItems() }
                    .disabled(store.isLoadingLoginItems)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`); harmless inside the .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        UnifiedLog.terminateAllStreams()
    }
}
