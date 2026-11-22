# LifeBoard

> **Public mirror.** A sanitised copy of a private working repo, updated by a one-way sync. Fork it and experiment freely. Issues and pull requests are welcome: accepted changes are folded into the private repo by hand and reappear here on the next sync. MIT licensed.
>
> To run the web companion yourself, deploy `mobile/` to your own Vercel project with your own Postgres (Neon) `DATABASE_URL`, `LIFEBOARD_DEVICE_TOKEN`, `LIFEBOARD_COOKIE_SECRET` and `LIFEBOARD_ADMIN_TOKEN`. Nothing here points at the original deployment.

LifeBoard is a native SwiftUI macOS planner with an optional, installable iPhone web companion. The Mac keeps a local copy and works offline. Mobile sync is private and optional; there are no analytics or ads. `Package.swift` is the Xcode-openable project definition and also supports command-line builds where the full Xcode app is unavailable.

## Architecture

- `LifeBoardCore`: value models, versioned `LifeBoardData`, JSON persistence, backup/import and automation payload validation.
- `LifeBoardApp`: SwiftUI app shell, views, native menus, inspector, drag/drop and user workflows.
- `LifeBoardCLI`: bundled `lifeboard` automation helper.
- `LifeBoardWidget`: WidgetKit extension backed by the app's read-only Application Support snapshot, with live agenda and To Do titles.
- `mobile`: mobile PWA, local OCR, Vercel API and private Postgres snapshot store.

The local store is `~/Library/Application Support/LifeBoard/LifeBoard.json`. Writes are atomic. Human-readable backups are placed in `~/Library/Application Support/LifeBoard/Backups`. `schemaVersion` is the migration boundary; add explicit decoding/migration before changing required fields. A damaged existing data file pauses writes rather than reseeding it.

## Build and package

Run `scripts/build-release.sh`. It runs the core self-test, builds release executables, and packages the signed app as `dist/LifeBoard.app.zip` and `dist/LifeBoard.dmg`. It signs ad hoc by default. Set `LIFEBOARD_SIGN_IDENTITY` to an Apple-issued code-signing identity when one is available. A previous release had widget-gallery and simulator checks; the current audited candidate still requires a fresh installed widget check. The widget binary must keep the `_NSExtensionMain` entry point; without it, gallery discovery launched the extension and it crashed. The extension uses the real POSIX home path because its sandboxed Foundation home resolves to its own container. Check the rendered data and deep link in each installed release, because `pluginkit` registration alone does not prove them.

GitHub Actions runs the core self-test, release compilation, and mobile tests/build for every push.


## Import API

The app registers `lifeboard://task/create`, `lifeboard://import`, `lifeboard://todo`, `lifeboard://task/<id>` and `lifeboard://focus/<id>`. Pass a URL-encoded JSON `payload` matching `TaskImportPayload` to the import route. The helper supports the concise `lifeboard import '<json>'` and `lifeboard import --file batch.json` forms as well as the existing task, event, project, subject, milestone and calendar commands. Imports accept one payload object or an array and scheduling fields remain optional.

Example: `lifeboard import '[{"title":"Chemistry worksheet","estimatedMinutes":30,"subject":"Chemistry"}]'`.

Due day, scheduled day and scheduled start time are deliberately separate. Calendar-only scheduling must never be inferred from a due date.

## Photo-to-LifeBoard workflow

Inside LifeBoard, Command-N opens Capture. It accepts natural-language text, multiline lists, clipboard images, dragged images and files. Vision reads image text locally. On-device Apple Intelligence checks titles for both text and images. LifeBoard preserves the task wording and keeps parsed dates, times and durations in separate fields. Capture names the engine used for each editable preview and offers a fast local parser mode.

In Codex or another ChatGPT client with local Mac access, attach a photo and ask: “Read the tasks in this image, show me what you found, then add the confirmed items to LifeBoard.” The agent should write one temporary JSON array and invoke the bundled helper once:

`~/Applications/LifeBoard.app/Contents/Resources/lifeboard import --file /path/to/confirmed-batch.json`

LifeBoard watches its local file and refreshes while it is open. Capture does not call an AI service. When mobile sync is connected, LifeBoard records, including selected Google and iCloud calendar event caches, are sent to a private sync store over HTTPS. Phone OCR runs on the device.

## Mobile companion and sync

Vercel builds the `mobile` directory with `npm run build` and serves `public`. The API uses server-only `DATABASE_URL`, the existing owner `LIFEBOARD_DEVICE_TOKEN` and `LIFEBOARD_COOKIE_SECRET`, plus a distinct `LIFEBOARD_ADMIN_TOKEN` for provisioning. Keep secrets and live planner data out of Git, exported app bundles and browser assets. Apply `mobile/db/0001_snapshot.sql` for a new database and the transactional `0002_workspaces.sql` migration before deploying this version. Back up the cloud snapshot independently first; the migration retains and freezes the legacy table and preserves the owner's revision and document. An old deployment cannot safely receive writes after migration. Rollback requires deliberately restoring the latest owner workspace under maintenance, rather than simply promoting old code.

The Mac upgrades existing credentials into Keychain only after verified readback. Device-only notification, calendar-selection and iCloud-backup preferences live in a private sidecar and are excluded from cloud merge decisions. A fresh tester installation opens its own invitation file in Settings. The Mac generates a random, one-use, ten-minute pairing code for its phone; each phone receives a tracked, independently revocable 180-day HttpOnly cookie. Existing valid owner cookies migrate into tracked sessions. The old shared-code pairing route is disabled by default.

Browser data is scoped to the verified workspace and durably stored in IndexedDB before uploading. Independent field changes merge; same-field conflicts require explicit choices and retain private recovery copies. Logout revokes the session and clears cached planner data. Remote revocation prevents subsequent server access; cached data on a disconnected device remains until it reconnects or is cleared locally.

Run `scripts/test-audit.sh` for persistence/concurrency/recovery, real AppStore, native/server wire compatibility and mobile authenticated-handler tests. `mobile/scripts/verify-ui.mjs` exercises a disposable preview server with real browser storage, offline recovery, minute scheduling, Trash and responsive layouts.
