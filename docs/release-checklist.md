# Release Checklist — `localVoiceRec`

Run through this list before distributing a build internally or externally. Tick each item; do not skip.

## Build hygiene

- [ ] `swift build` clean (no warnings on `-Xswiftc -warnings-as-errors` if enabled)
- [ ] `swift test` all tests pass
- [ ] `xcodegen generate` reproduces a clean `.xcodeproj` from `project.yml`
- [ ] `xcodebuild ... -configuration Release build` succeeds
- [ ] No `TODO`/`FIXME` markers blocking release in changed files

## Code review

- [ ] PR has at least one approving review
- [ ] `/code-review` (or equivalent) run on the diff with no high-confidence findings
- [ ] CHANGELOG entry written (if applicable)

## Security audit

- [ ] `docs/security-audit.md` re-run for current commit (grep + codesign)
- [ ] `codesign --display --entitlements - <app>` contains **no** `com.apple.security.network.client`
- [ ] `codesign --display --entitlements - <app>` contains **no** `com.apple.security.network.server`
- [ ] `com.apple.security.get-task-allow` is **absent** (Release build only — Debug always adds it)
- [ ] `Info.plist` does **not** contain `NSAppTransportSecurity`, `NSLocalNetworkUsageDescription`, or `NSBonjourServices`
- [ ] No new `import Network`, `import WebKit`, `import CloudKit` in any source file
- [ ] SwiftData `ModelConfiguration.cloudKitDatabase` remains `.none`

## Signing & Notarization

- [ ] Developer ID Application certificate available in keychain
- [ ] `DEVELOPMENT_TEAM` set in `project.yml` (replace empty value before Release)
- [ ] Hardened Runtime enabled (`ENABLE_HARDENED_RUNTIME=YES` already in `project.yml`)
- [ ] `codesign --sign "Developer ID Application: <Team>" --options runtime --entitlements App/localVoiceRec.entitlements <app>` succeeds
- [ ] `codesign --verify --deep --strict --verbose=2 <app>` clean
- [ ] `xcrun notarytool submit <app>.zip --wait --apple-id ... --team-id ... --keychain-profile ...` returns `status: Accepted`
- [ ] `xcrun stapler staple <app>` and `xcrun stapler validate <app>` succeed
- [ ] Gatekeeper assessment: `spctl --assess --type execute --verbose=4 <app>` returns `accepted`

## Runtime / functional

- [ ] First-launch TCC dialogs appear for Microphone and System Audio Recording; both can be approved without crash
- [ ] If TCC is denied, app degrades gracefully (no crash)
- [ ] 1-hour continuous-recording stress test:
  - [ ] No memory growth above baseline budget
  - [ ] No dropped audio (`SystemAudioTap` overflow counter stays at 0 under normal load)
  - [ ] WAV file finalizes cleanly, transcription pipeline completes
- [ ] Summary generation runs offline (turn off Wi-Fi + Ethernet during test) — verifies on-device-only path
- [ ] App quits cleanly via menu-bar Quit; no zombie audio processes (`pgrep -fl coreaudiod`-adjacent processes)
- [ ] Inspect `Console.app` for unexpected XPC connection errors

## Privacy posture verification

- [ ] Run `nettop -p <pid>` (or `lsof -i -p <pid>`) for 5 minutes during active recording — zero network sockets opened
- [ ] Little Snitch / LuLu monitor (if available) — no outbound connection attempts during full record→transcribe→summarize flow
- [ ] `~/Library/Containers/com.example.localVoiceRec/` is the only data-bearing directory created

## Distribution

- [ ] MDM package (`.pkg`) built via `productbuild`/`pkgbuild` with the notarized `.app` inside
- [ ] `.pkg` itself notarized + stapled
- [ ] Internal release notes drafted with privacy bullet points
- [ ] Rollback plan: previous signed/notarized `.app` archived and retrievable

---

After every box is ticked, attach the `codesign --display --entitlements -` output and the `notarytool` submission UUID to the release record.
