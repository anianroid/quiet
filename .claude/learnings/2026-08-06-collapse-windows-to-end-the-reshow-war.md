# To suppress another app's popup for good, collapse the window to 1x1 as well as moving it — hosts re-show by rewriting position, not size

**Problem shape:** you move an unwanted window off-screen and it works, but the host re-shows it every few seconds (or recreates it), so the user sees a flash on every cycle and your watcher swats forever. Tightening the poll interval reduces the flash but never removes it, and the vendor's own setting for the feature is server-side, so there is no local flag to flip.

**The procedure:**
1. Establish that the fight is a re-show loop, not a detection failure: count your own suppression log lines per minute for one window owner. Steady repetition at the host's interval (not yours) means the host is re-showing.
2. Check whether the window ID is stable across cycles. If it changes, the host destroys and recreates the window — any per-window backoff or counter resets every cycle and re-serves the delay. Key such state to the **pid**, never the window id.
3. When suppressing, set `kAXSizeAttribute` to 1x1 in addition to writing `kAXPositionAttribute` off-screen. Verify by re-reading the size (Electron reports success on writes it ignored) and treat either write landing as success.
4. Record the original position AND size on the FIRST park only, so a later re-park cannot overwrite the real geometry with the collapsed geometry. Restore both when your feature deactivates, on teardown, and on app termination.
5. Confirm the win: a collapsed window falls below your own minimum-size candidate filter, so it should disappear from your candidate set entirely and your suppression log should go quiet. Quiet logs are the proof the loop ended.

**Why this works / the trap it avoids:** a host re-showing a popup calls `show()` or `setPosition()`; almost nothing calls `setSize()` on a re-show, because the size is baked into its layout. So position is contested and size is not. Collapsing converts an endless per-cycle fight into one action, with no per-vendor config knowledge, and without drawing anything over the user's screen (cover panels are the wrong answer: they are visible artifacts, they can render *under* a higher-CG-layer window, and they can outlive the thing they cover).

**Evidence:** Kamui, HostOverlayWatcher.swift `park`/`collapse`/`restoreSuppressed` (2026-08-06). Notion re-showed its "Start AI Meeting Note" pill every ~3s under a fresh CGWindowID (90 suppression log lines in 20 minutes) and its meeting-notes setting is server-side, unlike Wispr Flow's local config.json flag.
