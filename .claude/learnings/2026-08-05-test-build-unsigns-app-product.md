# Never install the app product after running xcodebuild test with signing disabled — the test action overwrites the signed Debug app with an unsigned one

**Problem shape:** an app that held TCC grants (Accessibility, Screen Recording) suddenly reports `AXIsProcessTrusted() == false` after a rebuild-and-reinstall cycle, even though the TCC database still shows the grant and the signing identity never changed.

**The procedure:**
1. Check whether `xcodebuild … test CODE_SIGNING_ALLOWED=NO` ran after the last signed `build` — the test action rebuilds the app target into the same Build/Products/Debug directory, replacing the signed .app with an unsigned one.
2. Verify with `codesign -dv <app>`: an unsigned or ad-hoc product no longer satisfies the TCC entry's designated-requirement, so macOS silently treats the grant as absent.
3. Fix the cycle order: run the plain signed `build` LAST (or give the test invocation its own `-derivedDataPath`), then install from Products.
4. When diagnosing "permission granted but API says no," log the permission check from inside the app (`AXIsProcessTrusted()`) at notice level — the TCC db alone cannot tell you whether the running binary matches the grant.

**Why this works / the trap it avoids:** TCC binds grants to the code signature's designated requirement, not the bundle path. A signing-disabled test build silently swaps the artifact under you; everything looks identical on disk and in System Settings while every AX call quietly no-ops.

**Evidence:** Quiet (2026-08-05) — banner dismissal worked at 15:02, dead at 15:07 after `xcodebuild test CODE_SIGNING_ALLOWED=NO`, alive again after a signed rebuild.
