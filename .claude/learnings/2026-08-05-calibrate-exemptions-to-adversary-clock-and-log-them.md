# When a watcher exempts pre-existing windows as "already there, not ours", calibrate the age threshold to the adversary's earliest trigger and log every exemption

**Problem shape:** a suppression layer works in testing but a target sits on
screen for a whole session in the field, with nothing in the logs. The code
has a carve-out ("windows older than N seconds at activation are persistent
HUDs, skip them") and N was calibrated to the fastest observed race, not the
slowest.

**The procedure:**
1. Find every exemption/carve-out in the suppression path (`persistent`,
   `skip`, `exempt`, early `continue`). For each, ask: what is the *maximum*
   head start the emitting app can have? Use its trigger (calendar time,
   lobby entry, mic activation), not your detector's, and account for your
   detector's own degraded modes (missing permissions make it slower).
2. Set the threshold between the adversary's worst-case head start and the
   legitimate object's typical age (a meeting pill: seconds-to-a-minute early;
   a real HUD: on screen for many minutes). Pin the number with a unit test
   on a pure function so the calibration is documented and locked.
3. Log every exemption once at classification time (window id, owner, age).
   A skip that can cost the product its core promise must never be silent —
   the field failure is otherwise indistinguishable from "watcher not running".
4. Check activation-time fast paths: if sweeps skip work when "nothing
   changed", activation must reset that cache, or objects that arrived before
   activation are never inspected at all.

**Why this works / the trap it avoids:** thresholds get calibrated to the
first race someone observed (Notion beating detection by ~1s → 3s window) and
silently misclassify the slower adversary (Wispr's pill lands a whole lobby
wait early → tagged "persistent HUD" → skipped forever, no log). Diagnosis
took unified-log spelunking because the skip was invisible.

**Evidence:** Quiet, HostOverlayWatcher.swift `preMeetingHUDAge` +
`logHUDExemptions` + `lastCandidateIDs = []` on meeting start (2026-08-05);
field repro: Wispr "Meeting detected · Now" pill on screen 18s into a Meet
call while Notion's pill was covered in the same log window.
