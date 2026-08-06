# Never gate suppression rules on your own detector's state when the thing you suppress is fired by the adversary's detector — derive the rules from per-vendor data and apply them unconditionally

**Problem shape:** a watcher suppresses events (banners, pills, popups) that
third-party apps emit "when X starts", and it keeps leaking exactly at the
start of X even though matching works fine in tests. The relaxed/aggressive
matching branch is guarded by `if isXActive`, and `isXActive` comes from your
own detector.

**The procedure:**
1. Compare trigger clocks: list what signal the *emitting* apps key off
   (calendar time, their own process scan) vs what your detector keys off
   (a live call window, mic in use). If theirs can fire first, every
   state-gated rule has a leak window equal to the detection lag.
2. Remove the state gate from the matching decision. Make the *content* of
   the event carry the full evidence: vendor identity term AND that same
   vendor's own observed copy must co-occur in the text.
3. Move all vendor-specific strings (names, observed banner copy) into the
   data catalog (here Competitors.json). Derive per-vendor rules at init:
   drop entries whose name tokenizes to only generic words (grab-bag entries
   like "Browser meeting helpers" — relays, not vendors), and drop patterns
   whose tokens are a subset of the entry's identity tokens (they restate the
   name, so identity+pattern would degenerate to identity-alone).
4. Keep the detector state only for cadence (poll interval), never for
   whether a match counts.
5. Regression test both directions with the detector state OFF: the vendor's
   prompt copy must match, and the vendor's name next to unrelated copy
   ("Notion — Alice commented on your page") must not.

**Why this works / the trap it avoids:** the naive fix relaxes matching "while
a meeting is active", but the offending banners are fired by apps watching the
calendar, which beats a call-surface detector by seconds to a minute — the
relaxed rule is asleep precisely when the banners arrive. Requiring
identity+copy in the text itself makes the match safe enough to run always,
so detection lag stops mattering.

**Evidence:** Quiet, NotetakerPromptMatcher in NotetakerPhrases.swift +
Competitors.json `popsMeetingPills`/pattern data (2026-08-05); leak repro was
"Notion — Meeting starting soon" arriving before MeetingDetector fired.
