# LifeBoard web appearance

The web companion uses the existing Mac app artwork, with midnight navy, slate blue and the cream light from the icon. Light mode uses warm paper and white working surfaces; dark mode uses navy surfaces with pale blue actions. The system font follows the device, with no external fonts, decorative textures or new dependencies.

Navigation stays at the bottom on phones and becomes a sidebar at 960px. Today places the next time block alongside quick actions on desktop. Forms, tasks and recovery views share restrained borders and spacing, consistent outline icons, visible keyboard focus and 44px primary touch targets. One-time connection shows the actual LifeBoard icon and the Mac settings path.

Verification: nine browser acceptance flows passed, including 320/390/768px layouts, dark/high contrast/reduced motion, 960/1440px sidebar placement and visible branding, connection page fit, editing, offline IndexedDB recovery, restore and quota recovery. The five independent two-browser conflict flows also passed after the redesign. Screenshots and machine-readable results are in ignored output/playwright/. Physical iPhone and VoiceOver checks remain on the final device checklist.

The service-worker shell version is incremented so installed web companions refresh the changed artwork and styles. This change does not alter workspace/session credentials or planner data.
