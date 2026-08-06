# When swiftc crashes compiling a @convention(c) callback, look for `Self` inside the closure body and spell the concrete type instead

**Problem shape:** adding a line to a C-function-pointer callback (AXObserverCallback, CoreAudio listener, CFRunLoop callback) makes the compiler itself crash: "Failed frontend command: Command SwiftCompile failed with a nonzero exit code" plus a swift-frontend stack dump naming the enclosing function. Not a runtime crash, and no ordinary type error is reported.

**The procedure:**
1. Grep the diff for `Self.` inside the C closure body. `@convention(c)` closures cannot capture context, and `Self` requires an implicit metatype capture; the compiler should reject it but instead trips an assertion.
2. Replace `Self.x` with the concrete type name (`MyType.x`). Static members on a concrete type are not captures.
3. Better: move anything nontrivial out of the callback into a method on the instance you already recovered via `Unmanaged<MyType>.fromOpaque(refcon)`, and call that. The callback stays two lines: recover the instance, call the method.
4. Rebuild before running tests — `xcodebuild test` reports only "Testing cancelled because the build failed", so run `xcodebuild build` and grep for the source path plus line number to get the real message.

**Why this works / the trap it avoids:** the failure looks like a toolchain or framework bug, which invites shotgun changes (reordering code, deleting the whole feature). The actual cause is one identifier that cannot legally exist in a non-capturing closure. Keeping C callbacks down to "recover instance, delegate to method" makes the class of bug unreachable.

**Evidence:** Kamui, HostOverlayWatcher.swift `ensureObserver` / `noteWindowCreated` (2026-08-06) — a `Self.logger.notice(...)` line added inside the AXObserverCallback crashed swift-frontend; moving it into a method fixed it with no other change.
