# launchd Console

A native macOS app for inspecting, controlling and authoring launchd jobs. *(Working name.)*

A launchd "job" really comes from three places that can disagree: the plist on disk, the service
loaded in launchd, and the enable/disable override database. launchd Console joins all three
and shows where they don't match: plist edited since load, plist deleted but still loaded, file
present but not loaded, disabled override, crash loops, KeepAlive job not running.

## Features

- **Inspector**: user agents (`gui/<uid>`), third-party agents (`/Library/LaunchAgents`),
  app-registered jobs, Apple jobs (hidden by default) and system daemons. Search, filter by
  status and source, refreshed every 2 s.
- **Detail**: parsed plist fields plus raw XML, runtime state (PID, last exit, run count,
  `launchctl blame`), code signature, owning app, Login Items status. The app and developer
  names from Login Items need an administrator password (`sfltool dumpbtm`), so they load only
  when you click the button on the Login Items row (or **View → Load Login Item App Names…**).
  The result is cached and shown on later launches.
- **Controls**: start, stop, restart, load, unload, enable, disable, using the modern
  `launchctl` verbs only (`kickstart`, `kill`, `bootstrap`, `bootout`, `enable`, `disable`).
  Each action shows the shell command it runs. Destructive actions ask for confirmation. The
  **Activity** window lists every command the app has run.
- **Logs**: launchd's own events for the job, the program's unified-log output, and live tails
  of `StandardOutPath` / `StandardErrorPath`.
- **Editor**: form and XML editing of plists in `~/Library/LaunchAgents`, and new agents from
  five templates (run at login, keep alive, every N seconds, calendar schedule, on file
  change). The editor validates before saving and keeps keys it doesn't recognize. Each save
  backs up the old file and offers to reload. Delete unloads the job and moves the plist to the
  Trash.
- **Schedule** window: runs from the past 24 h (read from launchd's log) and upcoming runs for
  `StartInterval` / `StartCalendarInterval` jobs.
- **Failure notifications**: opt in per job. There is a 15-minute cooldown, and notifications
  only arrive while the app is open.

### What you can change

| Jobs | Access |
|---|---|
| `~/Library/LaunchAgents` (regular files you own) | Control and edit |
| `/Library/LaunchAgents` (third party) | Control only |
| System daemons (`/Library/LaunchDaemons`) | Control through the admin password prompt; plist is read-only |
| Apple / `/System`, `application.*` entries, leftover overrides | Read-only |

Daemon actions don't use a persistent root helper. Each command goes through the standard
macOS administrator prompt, and only after it passes a strict allowlist (see
`Sources/LaunchdKit/Privileged.swift`). The script runs inside the app, so after one password
macOS doesn't ask again for about five minutes, for this app only.

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Xcode 16+ or matching command-line tools)

The app runs outside the App Sandbox, because launchctl can't be used from inside it.

## Build and run

```sh
swift run LaunchConsole               # run directly
scripts/build-app.sh                  # build/LaunchConsole.app (debug)
CONFIG=release scripts/build-app.sh   # release build
open build/LaunchConsole.app
```

### Code signing

`build-app.sh` signs with, in order:

1. `SIGN_IDENTITY` if set (`SIGN_IDENTITY=- scripts/build-app.sh` forces ad-hoc).
2. The first `Apple Development` identity in the keychain.
3. Ad-hoc.

A free Apple ID is enough for step 2. In Xcode, open **Settings → Accounts**, add the Apple ID,
then choose **Manage Certificates → + → Apple Development**. Check with
`security find-identity -v -p codesigning`. If the identity shows up but isn't listed as valid,
install Apple's
[WWDR G3 intermediate](https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer). A
development signature keeps the app's identity stable across rebuilds, so macOS permissions
stick. It can't be notarized, so the app is only for your own Mac.

`scripts/make-icon.sh` regenerates `Resources/AppIcon.icns` from `scripts/make-icon.swift`.

## Tests

```sh
swift test                            # unit tests against captured real output (Fixtures/)
LAUNCHD_INTEGRATION=1 swift test      # also runs tests that load, start and unload real agents
```

The integration tests change real launchd state in your GUI session, so they're off by default.

## Layout

| Path | Contents |
|---|---|
| `Sources/LaunchdKit` | Everything that talks to launchd or reads plists. No UI. |
| `Sources/LaunchConsole` | SwiftUI app: `JobStore` (state, polling, actions) and views |
| `Tests/LaunchdKitTests` | Swift Testing suites; `Fixtures/` holds real `launchctl`, `log`, `codesign` and `sfltool` output |
| `scripts/` | App bundle and icon builds |
| `REQUIREMENTS.md` | Requirements, decisions and milestone history |

Main LaunchdKit pieces:

- `Launchctl`, `PrintParser`: read-only `launchctl print` / `blame`. `launchctl print` output
  isn't a stable format, so the parser keeps every field it doesn't recognize.
- `PlistCatalog`, `PlistJob`, `Inventory`, `Diagnostics`: join plists, loaded services and
  overrides into `Job`, and compute status and issues.
- `JobAction`, `ActionPolicy`, `PrivilegedLaunchctl`: control verbs, what each job allows,
  and admin-prompt execution for daemons.
- `JobDefinition`, `Validator`, `PlistStore`, `EditPolicy`: editing, validation, backed-up
  saves.
- `UnifiedLog`, `LogFileTail`, `Schedule`, `BackgroundItems`, `Signature`: logs, timers,
  Login Items, code signing.

## Debug snapshots

Debug builds can render their own windows to PNG and then quit. This needs no screen-recording
permission:

```sh
LAUNCHCONSOLE_SNAPSHOT=/tmp/shot.png \
LAUNCHCONSOLE_SELECT=<label> \
swift run LaunchConsole
```

Optional variables:

- `LAUNCHCONSOLE_SNAPSHOT_DELAY`: seconds to wait before capturing (default 5).
- `LAUNCHCONSOLE_WINDOW`: also open the `schedule` or `activity` window.
- `LAUNCHCONSOLE_CONFIRM=<action>`: show that action's confirmation dialog.
- `LAUNCHCONSOLE_EDIT`: open the editor, either `edit` for the selected job or
  `new:<template>`.

Dialogs and editors opened this way are inert previews: their buttons do nothing.

## Data the app writes

- Plist backups: `~/Library/Application Support/LaunchConsole/Backups/<label>/`
- Login Items app names cache: `~/Library/Application Support/LaunchConsole/login-items.json`
- Deleted plists go to the Trash.
