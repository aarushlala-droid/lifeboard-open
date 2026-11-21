# Native calendar refresh and checklist correction

5 October 2026, LifeBoard 4.1/build 16.

Apple Calendar had received the missing 7 October event, but LifeBoard had no subscription to EventKit changes. A manual refresh restored it. LifeBoard now debounces calendar-store notifications, refreshes on return to the app, and checks every five minutes as a fallback. Background paths never request permission. Temporarily unavailable selected accounts retain their cached events; cache and device-local refresh date save together without replacing task Undo.

The checklist input previously appeared as a borderless label, with Add disabled for an empty entry. It now has a visible entry box. Add focuses an empty field, and entered text can be submitted with Add or Return. Unsubmitted text clears when changing tasks.

The complete native audit and 59 mobile tests pass. Eight additional calendar assertions cover notification-driven import, durable events, refresh-date advancement, preserved task Undo, throttled polling, app-return refresh, fallback refresh and unavailable-account preservation. A separate validation app using synthetic records verified empty Add focus, button submission, Return submission and durable completion toggles. The installed personal app was visually checked with the restored event at 16:15–20:30, without creating test tasks in the personal planner.

The existing app was replaced with a privately backed-up build 16 while preserving the planner bytes during installation. A read-only follow-up checked the personal task/project/subject and other non-calendar records. The previously shared build 15 DMG was not rebuilt or modified; its SHA256 remains `23a0046b89667560cd4d245619fca80171ed32eb18231e33bf969ac2df814d29`. The new build is installed locally and archived separately as `dist/calendar-checklist-fix/LifeBoard.app.zip`.
