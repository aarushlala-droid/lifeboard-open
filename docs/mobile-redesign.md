# LifeBoard for iPhone

The phone companion is an installable iOS web app (standalone PWA). It is built from iOS's own patterns so a native SwiftUI app can replace the view layer later without changing sync, storage or the server.

## Design

- **iOS structure.** Large titles that hand over to an inline title in a translucent navigation bar; inset grouped lists; a floating glass tab bar (Today, To Do, Calendar, Browse) with Search as its own round button, as in iOS 26; sheets with a grabber, Cancel and the confirming action in the header, swipe-down, Escape and backdrop dismissal (guarded when the form has edits); 44pt targets throughout.
- **Today is the hub.** Now/Next, then every open To Do: Overdue, Carry over, To do today (with a Reminders-style New To Do row), Anytime and Upcoming, then the day's schedule and upcoming important dates. Adding from Today plans the To Do for today, as on the Mac.
- **The progress slider is back** on every open To Do, as in LifeBoard on the Mac. It saves when released; 100% completes the To Do (Undo in the toast).
- **New To Do** is a grouped form. The title is parsed as you type, abbreviations included ("chem ws tmr 45m"), fills only the rows you haven't changed, and says exactly what will be saved. "Capture several, or from a photo" opens Capture.
- **Browse** replaces More: a settings-style list with coloured tiles for Focus, Capture, Important Dates, Revision, Subjects, Projects, Completed, Trash, Sync Centre, Backups, Settings and About.
- **Focus** is a timer face in the spirit of Clock: an orange ring and round Stop, Start, Pause and Resume buttons.
- **Colour is the iOS palette.** Grouped backgrounds, label colours, one accent for actions and selection, orange for the present moment, red for overdue and destructive, purple for LifeBoard events and teal for connected calendars. Every text colour keeps 4.5:1 or better in light, dark and both Increase Contrast variants (checked numerically from `tokens.css`). Reduce Motion and Reduce Transparency each have an answer.
- **One token source.** `mobile/web/tokens.css`; `node mobile/scripts/export-tokens.mjs` writes `tokens.json`; `tests/redesign.test.mjs` fails if they drift or if `app.css` uses any literal colour or font.

Unchanged: `api/`, `lib/`, `db/`, `middleware.js`, `sync.js`, `scheduling.js`, `task-groups.js`, `task-features.js`, `ocr.js` and the schema 3 document. `capture.js` gained abbreviation recognition only.

## Screen mapping for a future SwiftUI app

| Web view (`app.js`) | SwiftUI equivalent | Data source to reuse |
| --- | --- | --- |
| Shell: navigation bar, tab bar, Search tab | `TabView` with a `Tab(role: .search)`, `NavigationStack` per tab | — |
| `todayView` | `List(.insetGrouped)` with sections; Now/Next as a custom row | `groupTasks`, `scheduleFor`, `nowAndNext` |
| `todoView` filter chips | `List` with a scope `Picker` | `groupTasks().filters` |
| `calendarView` day grid | `ScrollView` + `Canvas` grid, lanes from `intervalLanes` | `taskSegment`, `calendarSegments`, `intervalLanes` |
| `captureView` | `TextEditor` + `PhotosPicker`; Vision instead of Tesseract | `interpretText`, `previewPhotoWithTypedText` |
| `focusView` | `TimelineView(.periodic)` + `Circle().trim` ring | `activeFocus` record shape |
| `moreView` (Browse) and children | `NavigationStack` with `List` rows and `Label` tiles | collections as named |
| `openSheet` / `taskFields` | `.sheet` with `.presentationDetents`, `Form`, `Slider` | `patchDraft` merge rules |
| `actionSheet` (task menu) | `.contextMenu` and `.confirmationDialog` | — |
| `syncCentreView` | `Form` with two `Text` panes per conflict | `LifeBoardSync.conflicts`, `resolveConflicts` |

## Verification

Run from `mobile/`: `npm test`, `npm run build`, `node scripts/export-tokens.mjs --check`, then the browser verifiers with `LIFEBOARD_PLAYWRIGHT_MODULE` set against a disposable `scripts/preview-server.mjs` (`LIFEBOARD_UI_BASE=http://127.0.0.1:<port>`), which serves a synthetic student week.

Not yet verified: iOS Safari or WebKit rendering, the iOS Simulator (needs full Xcode), a physical iPhone, Home Screen install, and VoiceOver.
