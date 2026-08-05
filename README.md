# Quiet

**One notetaker. Zero noise.**

Quiet is an open-source macOS menu bar app that takes meeting notes on your Mac — and on day zero, silences the pile of “Start Notetaker” prompts from tools you already installed.

Not the [Quiet](https://tryquiet.org/) p2p chat app. This Quiet is for meeting notes.

## What it does

1. **Scans** for installed competitors (Otter, Fireflies, Granola, …) and shows **We’ll handle: …**
2. **Hijacks day zero** — quits sidecar notetaker helpers during meetings, dismisses matching notification banners, shows **one** Quiet banner
3. **Captures** system audio + mic without joining the call as a bot
4. **Transcribes** on-device with Apple `SpeechAnalyzer`
5. **Summarizes** with Apple Intelligence / Foundation Models
6. Writes Markdown notes to `~/Documents/Quiet/`

## Requirements

- macOS 26+
- Apple Silicon (Apple Intelligence path)
- Xcode 26+

Non-sandboxed by design (needed to terminate competing helpers). Distributed via direct download / Homebrew later — not Mac App Store for v0.1.

## Build

```bash
cd quiet
xcodegen generate
open Quiet.xcodeproj
```

Or:

```bash
xcodegen generate
xcodebuild -scheme Quiet -configuration Debug build
```

First run: complete setup (scan → Quiet-only permissions → done). Grant Screen & System Audio, Microphone, and Accessibility to Quiet.

## Status

v0.1 scaffold — day-0 scan/hijack + capture/speech/summary pipeline wired. Expect iteration on SpeechAnalyzer input formats, notification AX matchers, and the competitor catalog.

## License

MIT
