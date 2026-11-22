# LifeBoard 5 (5.0.0, build 23)

The redesign of the Mac app, built from `589805a` (the source of LifeBoard 4.2.3, build 21) on branch `preview/overhaul`. It was first delivered as a separate app, LifeBoard Preview; LifeBoard 5 is the same code built as the real LifeBoard, so it uses the installed app's data folder, widget, URL scheme, notifications and mobile sync. The iPhone companion is described in `docs/mobile-redesign.md`.

## Build and run

    scripts/build-release.sh            # LifeBoard 5: dist/LifeBoard.dmg and dist/LifeBoard.app.zip
    scripts/build-preview.sh            # LifeBoard Preview: dist/preview/LifeBoard Preview.app.zip
    scripts/build-preview.sh --install  # also installs ~/Applications/LifeBoard Preview.app

Both scripts fail on any compiler error (the SDK compatibility flag otherwise lets SwiftPM report success) and assemble and sign outside synced folders. In the Preview, File › Load Sample Student Week… and File › Clear Preview Planner… replace only the Preview planner, after saving a copy in its Backups folder; the bundled helper offers the same (`lifeboard sample load`).

## Preview isolation

Everything is selected at compile time by `-D LIFEBOARD_PREVIEW` in `Sources/LifeBoardCore/LifeBoardEnvironment.swift`, so the app, widget and helper cannot disagree.

| | LifeBoard | LifeBoard Preview |
|---|---|---|
| Bundle IDs | app.lifeboard.mac, .widget | app.lifeboard.preview, .widget |
| Planner and backups | ~/Library/Application Support/LifeBoard | ~/Library/Application Support/LifeBoard Preview |
| Automatic backups | iCloud Drive | the Preview folder only (never iCloud) |
| URL scheme | lifeboard:// | lifeboard-preview:// |
| Keychain service | app.lifeboard.mac.sync | app.lifeboard.preview.sync (unused) |
| Mobile sync | as configured | compiled off; every network entry point refuses |
| Widget kind and drag type | LifeBoardAgendaWidget, app.lifeboard.calendar-item | LifeBoardPreviewAgendaWidget, app.lifeboard.preview.calendar-item |

## What changed

- **Today is the hub.** It lists every open To Do: Overdue (including missed plans), Today, Anytime and Upcoming, then Done today. Anytime, Upcoming and Done fold away. The day's timeline sits beside the list on wide windows. Typing in Today's field plans the To Do for today; typing "anytime" leaves it undated.
- **Menu bar.** A LifeBoard item in the menu bar shows how many To Dos are due or planned for today (icon only when none). Its panel has Now/Next, a New To Do field and every open To Do with its check and progress slider, plus Open LifeBoard and Capture. Settings › General › Show LifeBoard in the menu bar turns it off.
- **Structure.** Sidebar: Today, To Do, Calendar, Focus, Subjects, Projects, Important Dates, Completed. Command-1 to Command-8 keep their meanings. The separate Upcoming page is gone; To Do keeps its Upcoming section as in 4.2.3. Settings uses the standard Settings window (Command-comma), and Help is in the Help menu.
- **Tasks.** The progress slider is on every open row again, as in 4.2.3; it saves on release in 5% steps and 100% completes the To Do. The inline New To Do field parses dates, times, durations, subjects and priorities as you type, abbreviations included (tmr, fri, 45m, chem, p1), shows exactly what will be saved and blocks anything ambiguous. Completed rows stay put for a moment so the list never jumps.
- **Capture and Apple Intelligence.** The parser recognises common abbreviations for days, weeks, times, durations, priorities and subjects. With Apple Intelligence on, the on-device model may also expand abbreviated words in titles (hw to homework, ws to worksheet); every suggestion is checked word by word against what you typed, and anything else keeps your wording.
- **Keyboard.** Arrows select, Space completes, Return or double-click opens details and Delete moves to Trash. The Task menu adds Mark as Done (Command-K), Do Today (Command-T), Do Tomorrow (Option-Command-T), Anytime (Command-R), Choose Date (Shift-Command-S), Start Focus (Shift-Command-F) and Duplicate (Command-D). The Go menu has Calendar Today (Shift-Command-T), Previous and Next (Command-[ and Command-]) and Day, Week and Month (Control-Command-1, 2, 3).
- **Calendar.** The grid is one drawing, and per-day layouts come from a memoised index. Weeks follow the Week starts Monday setting. Drag a task's or event's bottom edge to resize it. Connected events use their calendar's own colour, as in Calendar, and open a read-only details popover. The time zone is re-read on change. The view opens near the current time.
- **Colour.** The system palette throughout: your accent colour for actions, selection and your To Dos; Apple's accessible red for overdue and destructive; orange for the present moment (now line, Now/Next, Focus), with a darker orange for text so it keeps 4.5:1. Light, dark and Increase Contrast are covered.
- **Speed.** Undo patches skip identical records and apply only to touched records (proven identical by `Tests/PatchEquivalence`). Saves skip re-decoding a file this process just wrote; no-op changes write nothing; inspector typing saves after a pause, as one Undo step. The 1-second timer is gone: a folder watcher picks up helper writes, focus ends on a one-shot timer, and housekeeping runs each minute.

## Verification

- `scripts/test-audit.sh`: native safety suite, planning, capture, Apple Intelligence validation, topic import, wire format, patch equivalence, daylight-saving and time-zone tests, mobile tests and mobile build.
- Mobile browser verifiers against the disposable server: UI, two-browser conflict and workspace recovery.
- `Tests/Compatibility/check.py`: a legacy (pre-schema-3) document opens and saves as schema 3 with every record and ID, and the 4.2.3 helper reads files LifeBoard 5 writes, so going back is always safe.

Measured on synthetic data against the 4.2.3 source:

| | 4.2.3 | 5 |
|---|---|---|
| Save one completion (266 KB planner) | 28.6 ms | 6.6 ms |
| Save one completion (824 KB planner) | 84.8 ms | 18.7 ms |
| Inspector draft apply (266 KB) | 20.1 ms per keystroke | 0.75 ms per pause |
| Week view data per redraw | 10.1 ms | 5.9 ms on change, about 0 otherwise |
| Idle CPU | 0.09 s per minute | 0.02 s per minute |
| Idle memory | 91 MB | 72 MB |

## Limits

- Clicking and typing in the packaged app were not automated, because that needs Accessibility permission. Keyboard and selection behaviour rely on standard SwiftUI list behaviour plus the store-level tests.
- Builds are for Apple silicon unless `LIFEBOARD_UNIVERSAL=1` is set.
- The app is signed ad hoc, so after each update macOS may ask again for calendar access and for the sync key in the keychain.
