# When an Apple framework SIGTRAPs at runtime, verify your usage against the SDK swiftinterface before reaching for process isolation

**Problem shape:** an Apple framework (Speech, AVFoundation, CoreAudio…) crashes with EXC_BREAKPOINT/SIGTRAP inside framework code the moment your feature activates, with no thrown error. The tempting conclusion is "framework is flaky, isolate it in an XPC helper."

**The procedure:**
1. Read the framework's actual interface: grep the `.swiftinterface` under
   `/Applications/Xcode.app/.../SDKs/<sdk>/System/Library/Frameworks/<F>.framework/Modules/<F>.swiftmodule/`.
   Confirm every symbol, actor annotation, and `Sendable`/`sending` marker you rely on.
2. Check for isolation violations first: `dispatch_assert_queue_fail` surfaces as SIGTRAP.
   Any MainActor-isolated closure or state reachable from a framework callback thread
   (HAL IO, AVAudioEngine tap, results streams) is a candidate. Fix: confine all framework
   objects inside one actor; hand results out only as Sendable value types.
3. Check input preconditions the framework asserts instead of throwing: audio must match
   the format the framework reports (e.g. `SpeechAnalyzer.bestAvailableAudioFormat` — convert
   with AVAudioConverter, never feed the capture-native format), and required model/locale
   assets must be preflighted (`AssetInventory.status == .installed`) before construction.
4. Only if crashes persist after 1–3 does process isolation earn its cost. Keep all framework
   usage behind one actor with a narrow async API so an XPC helper can slot into that seam later.

**Why this works / the trap it avoids:** the naive move ships a second target, IPC marshaling, and helper lifecycle code to contain what was actually a caller-side bug. Every SIGTRAP cause found here (MainActor closure on a framework queue, unconverted tap format, missing locale assets) was our code; the SDK interface check settled in minutes what speculation couldn't.

**Evidence:** Quiet PR #1 (2026-08-05) — `SpeechTranscriberService` stub replaced by working `TranscriptionEngine` actor; old SIGTRAP not reproduced.
