# Xcode Project Setup (`.app` bundle)

`localVoiceRec` is primarily a SwiftPM package, but `.app` bundling requires an `.xcodeproj` so that `Info.plist`, `entitlements`, and `LSUIElement` can be properly stamped. We use **XcodeGen** to keep the project file generated from a YAML manifest (`project.yml`) so it stays diff-friendly and review-able.

## Prerequisites

- macOS 26.0+ SDK (Xcode 26 or newer)
- Homebrew (user-level install is fine; sudo not required)

## One-time setup

```bash
brew install xcodegen
```

## Generate the project

From the repo root:

```bash
xcodegen generate
```

This (re)creates `localVoiceRec.xcodeproj/` from `project.yml`. The generated file is **not** committed to git — regenerate locally before opening in Xcode.

> If you prefer, you can commit the `.xcodeproj` for IDE users who don't have XcodeGen, but then any edit to dependencies/targets must be propagated by re-running `xcodegen generate` and committing both.

## Build via CLI

```bash
xcodebuild \
  -project localVoiceRec.xcodeproj \
  -scheme localVoiceRec \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

Output `.app`:

```
~/Library/Developer/Xcode/DerivedData/localVoiceRec-*/Build/Products/Debug/localVoiceRec.app
```

## Build via Xcode GUI

```bash
xed localVoiceRec.xcodeproj   # or: open localVoiceRec.xcodeproj
```

Pick the `localVoiceRec` scheme → Run.

## What `project.yml` does

- Declares a single macOS app target `localVoiceRec`
- Pulls the SwiftPM products (`AppUI`, `AudioCapture`, `DataStore`, `TranscriptionKit`, `SummaryKit`, `Contracts`) from the local package at `.`
- Wires in `App/Info.plist` and `App/localVoiceRec.entitlements`
- Enables Hardened Runtime
- Sets `MACOSX_DEPLOYMENT_TARGET=26.0` to match `Package.swift`
- Code signing defaults to ad-hoc (`CODE_SIGN_IDENTITY="-"`, empty `DEVELOPMENT_TEAM`). For Release/Notarization, override these via `xcconfig` or by editing `project.yml` to set your team ID before regenerating.

## Notes / caveats

- The `App/` folder contains only the `@main` entry point (`LocalVoiceRecApp.swift`) and bundle resources. All real code lives in the SwiftPM modules under `Sources/`.
- `swift build` will not produce a runnable `.app` — it builds the libraries only. Use `xcodebuild` (or Xcode) for `.app` output.
- The PoC CLI (`AudioTapPoC`) is still built via `swift build` / `swift run AudioTapPoC`; it is intentionally not part of this xcodeproj.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `xcodegen: command not found` | `brew install xcodegen` |
| Build fails: "deployment target 26.0 not supported" | Update to Xcode 26+; older Xcode can't target macOS 26 |
| Build fails: missing `MenuBarExtra` API | Same — macOS 26 SDK required |
| Code signing fails locally | Defaults are ad-hoc; for Developer ID set `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` in `project.yml` then regenerate |
