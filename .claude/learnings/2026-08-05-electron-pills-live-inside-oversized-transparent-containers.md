# When a size-filtered window sweep misses an Electron overlay with zero log output at every layer, dump CGWindowList — the pill may be drawn inside an oversized transparent container window

**Problem shape:** a watcher that classifies windows by CG geometry (height
bounds) handles most apps' floating pills but one app's overlay never appears
in any code path — no candidate, no AX attempt, no OCR, no log — while the
overlay is plainly visible on screen.

**The procedure:**
1. While the overlay is (or was recently) visible, dump the owner's windows:
   `CGWindowListCopyWindowInfo([.optionAll], ...)` filtered by owner name,
   printing windowID, layer, alpha, onscreen, bounds. A one-file `swift`
   script needs no TCC permission for bounds/layer (only titles need Screen
   Recording).
2. If the visible ~50pt pill corresponds to a window hundreds of points tall
   at an elevated CG layer (floating=3 … screen-saver=1000), the app draws
   the pill inside a transparent container window. Any height cap tuned for
   pills silently discards it before every downstream layer.
3. Admit such windows as a distinct candidate kind: elevated layer (>0,
   excluding the popup-menu layer — tall context menus), height above the
   pill cap but below a sanity bound (~800pt).
4. Never act on the container's full frame: an opaque cover would black out a
   huge region, and AX-parking it can break other UI the same container hosts
   later (dictation bars). Instead OCR the window, take the union of Vision's
   text bounding boxes, convert to screen coords (Vision is normalized,
   origin bottom-left of the image; CG screen space is top-left), and cover
   only that padded rect. Remove the cover when a re-read finds no text.
5. Treat "capture succeeded, zero text" as a cached benign verdict distinct
   from "capture failed" (retry), and re-read containers on an interval
   during the active window — the pill appears *inside* an existing window,
   so window-set-change fast paths never fire for it.
6. Related coordinate trap: NSWindow/NSPanel frames are Cocoa
   (bottom-left-origin); CG window bounds are Quartz (top-left-origin).
   Placing a cover panel at raw CG coordinates puts it vertically mirrored.

**Why this works / the trap it avoids:** size filters encode "the pill IS the
window". Electron lets apps ship one big click-through transparent window and
render pills anywhere inside it; every geometry-keyed layer (candidates,
identity rules, per-window covers) then looks at the wrong rectangle. The
text region is the only truthful geometry, and pixels are the only reliable
sensor when Electron exposes no AX content.

**Evidence:** Quiet, HostOverlayWatcher.swift `candidateKind` /
`quartzRect(ofNormalized:inWindowFrame:)` / text-region covers (2026-08-05);
Wispr Flow's "Meeting detected · Start Notetaker" pill lived in a 480x570
layer-1000 window (win 116, pid 687) that a 260pt height cap discarded —
three meetings leaked with zero log lines before the CGWindowList dump.
