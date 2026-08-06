# Before building suppression machinery for a third-party app's popup, check its Application Support config for a feature flag — turning the feature off at the source beats any cover/dismiss layer

**Problem shape:** an app pops unwanted UI (pills, prompts, notifications)
that your watcher can only imperfectly suppress — cover panels look wrong,
AX is blind (Electron), and the process can't be quit or suspended because
the user needs its other features.

**The procedure:**
1. Look in `~/Library/Application Support/<App>/` for `config.json`,
   `settings.json`, or `Local State` (Electron apps keep user prefs in
   plain JSON).
2. Walk the JSON for keys matching the feature (`meeting`, `detect`,
   `notetaker`, `autoStart`, `notification`) and find the boolean that gates
   it (Wispr Flow: `prefs.user.autoDetectMeetingsEnabled` and
   `notetakerCalendarNotificationsEnabled`).
3. Edit ONLY with the app quit: Electron rewrites the config on exit, so a
   live edit gets clobbered. Order: back up the file, quit (terminate →
   poll → forceTerminate), re-read, patch, write atomically, relaunch only
   if it was running.
4. Verify by re-reading the file after the app relaunches — if the value
   held, the app respects it; if it flipped back, the pref is server-synced
   and this path is out.
5. Productize as a one-click host-setup step with an Undo (restore flags or
   the backup); derive the "done" state by reading the config, not from a
   stored flag, so it survives reinstalls and reflects in-app changes.

**Why this works / the trap it avoids:** suppression layers fight the
symptom every meeting and degrade to ugly compromises (a black cover panel
sitting on a pill the host never dismisses). The vendor's own feature flag
kills the popup permanently, keeps the rest of the app (dictation) working,
and needs no permissions beyond file access.

**Evidence:** Quiet, WisprSilencer.swift + HostOwnsNotesView wisprCard
(2026-08-06); flipped flags survived a Wispr relaunch, pill gone at source
after three meetings of cover/OCR whack-a-mole.
