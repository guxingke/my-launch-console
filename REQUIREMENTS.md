# launchd Console — Requirements

A native macOS app for inspecting, controlling and authoring launchd jobs.
Status: milestones M1–M6 built (2026-10-29). See [README.md](README.md) for building and running.
Working name only — avoid "Console" in the final name (clashes with Apple's Console.app).

## Decisions so far

| Topic | Decision |
|---|---|
| Form factor | Native macOS app, SwiftUI, non-sandboxed (launchctl access is impossible from the App Sandbox) |
| Scope | Full manager: inspect + control + create/edit plists |
| Domains | v1: user domain (`gui/<uid>`, `~/Library/LaunchAgents`). Data layer designed so system domain can be added later |
| Extras | No preference given; prioritized below (logs + failure status in v1, schedule view + Login Items later) |

## Background: what the app is dealing with

Measured on the dev machine (macOS 27.0.1):

- Plist locations: `~/Library/LaunchAgents` (10), `/Library/LaunchAgents` (9), `/Library/LaunchDaemons` (14), `/System/Library/LaunchAgents` (486), `/System/Library/LaunchDaemons` (425).
- `gui/501` has ~470 registered services, ~260 active.
- Many loaded services have **no plist on disk** (e.g. `application.com.mitchellh.ghostty.*`, XPC services inside app bundles).
- Enable/disable state lives in a separate override database (`launchctl print-disabled gui/<uid>`), not in the plist.

So a "job" is the join of three sources, and they can disagree:

1. **Plist file on disk** (may be absent)
2. **Loaded service in launchd** (may be absent; may differ from the file if the file was edited after loading)
3. **Override entry** (enabled / disabled / none)

Surfacing these mismatches is one of the main things a GUI can do better than `launchctl`.

## Functional requirements

### F1. Job list (v1)
- F1.1 List all jobs in the user domain: union of loaded services + plists in the user-visible directories.
- F1.2 Columns: label, status (running / idle / not loaded / disabled / failing), PID, last exit code, source (user / 3rd-party global / Apple), plist path.
- F1.3 Search by label, program path and plist path; filter by status and source.
- F1.4 Apple (`com.apple.*`, `/System/...`) jobs hidden by default and toggleable — they are ~90% of the list.
- F1.5 Live refresh: poll launchd state (target ≤2 s); watch the LaunchAgents dirs with FSEvents for file changes.
- F1.6 Flag mismatches: "plist changed since load", "plist deleted but still loaded", "file present but not loaded", "disabled override present".

### F2. Job detail (v1)
- F2.1 Parsed plist shown as structured fields (Program/Arguments, RunAtLoad, KeepAlive, StartInterval, StartCalendarInterval, WatchPaths, EnvironmentVariables, StandardOut/ErrorPath, WorkingDirectory, etc.) plus a raw XML tab.
- F2.2 Runtime state from launchd: state, PID, last exit code/signal, run count, spawn type, why it was last started (`launchctl blame`).
- F2.3 Code-signing / owning app where it can be found (e.g. "installed by Google Chrome").

### F3. Control actions (v1)
Use the modern verbs only; never the deprecated `load`/`unload`.

| Action | launchctl |
|---|---|
| Start / restart | `kickstart [-k] gui/<uid>/<label>` |
| Stop | `kill SIGTERM gui/<uid>/<label>` |
| Load | `bootstrap gui/<uid> <plist>` |
| Unload | `bootout gui/<uid>/<label>` |
| Enable / disable (persistent) | `enable` / `disable gui/<uid>/<label>` |

- F3.1 Every action shows the equivalent shell command (transparency; copy-to-clipboard).
- F3.2 Destructive actions (unload, disable, delete) need confirmation.
- F3.3 Apple and `/System` jobs are read-only in the UI (SIP-protected and dangerous anyway).
- F3.4 Report failures with launchctl's actual error text/code, not a generic message.

### F4. Plist editor (v1.x)
- F4.1 Create a new agent from a form with templates: "run at login", "keep alive", "every N seconds", "calendar schedule", "on file change".
- F4.2 Edit existing user-owned plists via the same form + raw XML mode.
- F4.3 Validate before saving: `plutil -lint`, label matches filename, program exists and is executable, log paths' directories exist.
- F4.4 Save = back up the old file, write, then offer "reload now" (bootout + bootstrap).
- F4.5 Delete = bootout + move the plist to the Trash (not hard delete).

### F5. Logs and health (v1)
- F5.1 Tail the job's `StandardOutPath` / `StandardErrorPath` files.
- F5.2 Stream the unified log for the job's process (`log stream --predicate ...`).
- F5.3 Health signals: non-zero last exit, crash-looping (high run count / throttled respawn), "KeepAlive but not running".
- F5.4 (later) Optional user notification when a watched job starts failing.

### F6. Later
- F6.1 Schedule view: next run time for StartInterval / StartCalendarInterval jobs, as a timeline.
- F6.2 Login Items / Background Task Management cross-reference (what System Settings shows vs what launchd has).
- F6.3 System domain: `/Library/LaunchDaemons` + `system` domain, through a privileged helper (`SMAppService.daemon` + XPC); read-only system view could come first using `launchctl print system`, which works without root for most fields.

## Non-functional requirements
- N1 No root needed for anything in v1.
- N2 Never mutate anything without an explicit user action; no silent background changes.
- N3 Stays responsive with ~1,000 jobs: list from one `launchctl print gui/<uid>` call; per-job detail fetched lazily on selection.
- N4 Tolerant parsing: `launchctl print` output is not a stable API and changes between macOS releases. Isolate it behind one parser module with fixtures captured from real output; degrade gracefully on unknown fields.
- N5 Edits are reversible (backups / Trash).

## Architecture
Planned as `LaunchdClient` / `PlistStore` / `JobModel`; as built:
- **LaunchdKit** (library, no UI, unit-tested against captured output in `Tests/LaunchdKitTests/Fixtures`)
  - `Launchctl` + `PrintParser` — runs `launchctl print`/`blame` via `Command`, parses into `DomainSnapshot` / `ServiceDetail` (N4: generic block parser, unknown fields kept).
  - `PlistCatalog` / `PlistJob` — scans the agent/daemon directories, re-reads changed files by modification date.
  - `Inventory` / `Diagnostics` — join file + loaded state + override into `Job`, compute `JobStatus` and `Issue`s.
  - `JobAction` / `ActionPolicy` / `PrivilegedLaunchctl` — control verbs, per-job permissions, admin-prompt execution for `system`.
  - `JobDefinition` / `Validator` / `PlistStore` / `EditPolicy` — editor model, validation, backed-up saves.
  - `UnifiedLog` / `LogFileTail` / `Schedule` / `BackgroundItems` / `FailureWatcher` / `Signature` / `Ownership` — logs, timers, Login Items, notifications, signing.
- **LaunchConsole** (SwiftUI app) — `JobStore` holds state and polls every 2 s; `NavigationSplitView` (sidebar scopes/filters → job table → detail), plus Schedule and Activity windows.
- Domain is a parameter throughout (`gui/<uid>` and `system`).

## Milestones
1. **M1 Read-only inspector** — F1, F2 (user domain). ✅ Built 2026-10-28. Deviation: F1.5 polls file modification dates every 2 s instead of FSEvents (≈500 stats, negligible), and leftover override entries are hidden unless filtered for.
2. **M2 Control** — F3. ✅ Built 2026-10-28. Third-party agents in `/Library/LaunchAgents` are controllable (not editable), per open question 4. Apple jobs, leftover overrides and `application.*` app entries are read-only. Every command the app runs is listed in the Activity window. Real-launchd lifecycle test: `LAUNCHD_INTEGRATION=1 swift test`.
3. **M3 Logs & health** — F5.1–F5.3. ✅ Built 2026-10-28. Logs tab per job: launchd's own events for the job (incl. `bootout initiated by` attribution), the program's unified-log output, and live tails of StandardOut/ErrorPath files. New check: KeepAlive job not running.
4. **M4 Editor** — F4. ✅ Built 2026-10-28. Form + XML editor for plists in `~/Library/LaunchAgents` (regular files only; symlinks and root-owned plists are read-only). Unknown keys are preserved. New agents from 5 templates. Saves go through a linted temp file with the previous version kept in `~/Library/Application Support/LaunchConsole/Backups/<label>/`. Delete = unload + move to Trash.
5. **M5 Extras** — F6.1, F6.2, F5.4. ✅ Built 2026-10-29. Schedule window (past 24 h of runs from launchd's log, upcoming runs computed; cron-style Day/Weekday OR). Login Items status per job via `SMAppService.statusForLegacyPlist` (fast, every refresh) plus parent app/developer from `sfltool dumpbtm` (~20 s, once per launch). Per-job "Notify me if it starts failing", with a 15-minute cooldown so crash loops don't spam. Notifications only fire while the app is open.
6. **M6 System domain** — F6.3. ✅ Built 2026-10-29. LaunchDaemons (`system` domain) are listed, inspected, logged and scheduled without root. **Changed from the plan:** no privileged helper. This Mac has no code-signing identity, so a root helper couldn't verify its caller and any local process could use it to run code as root. Instead each daemon action goes through the macOS admin password prompt (`osascript … with administrator privileges`), restricted to an allowlist (7 verbs, `system/` targets, bootstrap only from `/Library/LaunchDaemons`). Daemon plists stay read-only. A persistent helper is possible later with an Apple Development certificate.

## Open questions
1. ~~Minimum macOS version?~~ macOS 14 (`Package.swift`, `LSMinimumSystemVersion`).
2. Distribution: personal local build only, or a signed + notarized app for others? (Currently ad-hoc signed by `scripts/build-app.sh`.) A signing identity would also allow a persistent privileged helper (M6).
3. App name. (Still a working name; avoid "Console".)
4. ~~Should 3rd-party global agents in `/Library/LaunchAgents` be controllable in v1?~~ Resolved in M2: control yes, edit no.
