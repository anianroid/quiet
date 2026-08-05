# To dismiss macOS 26 Notification Center banners, perform the element's own named Close action — AXPress on close buttons and AXCancel silently fail

**Problem shape:** AX-based code that dismisses Notification Center banners matches the banner text correctly but the banner stays on screen; no error anywhere. Worked on older macOS.

**The procedure:**
1. Confirm the walk reaches the banner: dump the NC AX tree (roles, subroles, `AXUIElementCopyActionNames`) from a process that holds Accessibility. Banners live in windows with subrole `AXSystemDialog` under `com.apple.notificationcenterui`; the container element carries the combined title+body text in its own attributes.
2. Inspect the container's action names: they are opaque descriptor strings (multi-line, containing `Name:Close` / `Name:Show`), not `AXPress`/`AXCancel`.
3. Dismiss by passing the raw action string back verbatim: iterate `AXUIElementCopyActionNames`, pick any name containing "close" case-insensitively, call `AXUIElementPerformAction(element, action as CFString)`. Keep the legacy close-button/AXCancel paths only as fallbacks.
4. Scope the sweep to `AXSystemDialog` windows — walking the whole NC app element also traverses its entire menu tree (thousands of AXMenuItems) every tick.

**Why this works / the trap it avoids:** the naive code presses actions the modern banner element simply doesn't expose; every call returns an error nobody checks, so the failure is invisible. The banner's real close affordance is a custom named action whose name must be replayed exactly as returned.

**Evidence:** Quiet, NotificationWatcher.swift `performNamedCloseAction` (2026-08-05); live log "Notetaker banner dismissed: Note-taking is available, Chrome".
