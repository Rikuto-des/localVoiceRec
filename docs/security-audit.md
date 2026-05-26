# Security Audit Report — `localVoiceRec` S5-A

- **Audit date**: 2026-05-27
- **Branch**: `feat/s5a-security`
- **Scope**: Verify on-device-only guarantee; confirm `.app` bundle ships without any network capability.
- **Outcome**: **PASS** — zero network code, zero network entitlements in the signed bundle.

---

## 1. Source-level network audit

Searched `Sources/` and `App/` for any symbol that could initiate network I/O.

### 1.1 Network API primitives

```
grep -rEn 'URLSession|URLRequest|WKWebView|NWConnection|NWListener|NWBrowser|NWEndpoint|NWPath|CFStream|CFSocket|BSDSocket|dnssd|Bonjour|NetService|WKWebsiteDataStore|Network\.framework|import Network|URLProtocol|URLDownload|Alamofire' Sources/ App/
```

- **Hits**: 0
- **Verdict**: No use of `URLSession`, `Network.framework`, WebKit, Bonjour, or any HTTP client.

### 1.2 URLs / socket BSD calls

```
grep -rEn 'http://|https://|ftp://|ws://|wss://|socket\(|connect\(|send\(|recv\(' Sources/ App/
```

- **Hits**: 0 in source.
- The only `http://` strings in the repo are the `!DOCTYPE plist PUBLIC "...apple.com/DTDs/..."` DTD references inside `App/Info.plist` and `App/localVoiceRec.entitlements`. These are static XML doctype declarations that are **never dereferenced at runtime** (Apple's plist parser does not fetch the DTD).
- **Verdict**: No outbound URL literals.

### 1.3 Network-adjacent symbols

```
grep -rEn 'getaddrinfo|gethostbyname|CFHTTPMessage|XPCConnection|XPCListener|MultipeerConnectivity|GameKit|CloudKit|CKContainer|UserNotifications|MFMessage|MFMail' Sources/ App/
```

- **Hits**: 1 — `Sources/DataStore/RecordingRepositoryImpl.swift:26`:
  > `/// CloudKit 同期は .none を明示（オンデバイス完結要件）。`
  Comment only; the SwiftData `ModelConfiguration` immediately following sets `cloudKitDatabase: .none`. This is a **positive** finding — the codebase explicitly disables CloudKit sync.
- **Verdict**: No active use of CloudKit, XPC, MultipeerConnectivity, or notifications.

### 1.4 Frameworks imported

The only imports observed across the codebase: `Foundation`, `SwiftUI`, `AVFAudio`/`AVFoundation`, `AudioToolbox`, `CoreAudio`, `SwiftData`, `Speech` / `SpeechAnalyzer`, `FoundationModels`, `os.log`, internal targets. No `Network`, `WebKit`, `CFNetwork`, `SystemConfiguration`, `CloudKit`.

---

## 2. Entitlements & Info.plist audit

### 2.1 `App/localVoiceRec.entitlements`

| Key | Value | Verdict |
|---|---|---|
| `com.apple.security.app-sandbox` | `true` | OK — required |
| `com.apple.security.device.audio-input` | `true` | OK — required for mic |
| `com.apple.security.network.client` | **absent** | OK — must NOT be present |
| `com.apple.security.network.server` | **absent** | OK — must NOT be present |
| `com.apple.security.files.user-selected.read-write` | absent | OK — not needed yet (future export feature) |

The file also contains an explicit comment documenting *why* network entitlements are omitted. No changes requested.

### 2.2 `App/Info.plist`

| Key | Value | Verdict |
|---|---|---|
| `LSUIElement` | `true` | OK — menu-bar only, no Dock icon |
| `NSMicrophoneUsageDescription` | localized JP string explicitly stating "外部に送信されません" | OK |
| `NSAudioCaptureUsageDescription` | localized JP string explicitly stating "外部に送信されません" | OK |
| `LSMinimumSystemVersion` | `26.0` | OK — matches Package.swift |
| `CFBundleDevelopmentRegion` | `ja_JP` | OK |
| `NSAppTransportSecurity` | absent | OK (no networking, so ATS is moot) |
| `NSLocalNetworkUsageDescription` | absent | OK |
| `NSBonjourServices` | absent | OK |

No over-privileged usage descriptions. The TCC prompt strings are user-friendly and align with the privacy promise.

**Recommendation**: none. Both files are minimal and correct.

---

## 3. xcodeproj generation

- **Tool**: XcodeGen 2.45.4 (installed via `brew install xcodegen`).
- **Config**: `project.yml` at repo root.
- **Generation**: `xcodegen generate` — **success**, produced `localVoiceRec.xcodeproj/`.
- **Build**: `xcodebuild -project localVoiceRec.xcodeproj -scheme localVoiceRec -configuration Debug -destination 'platform=macOS' build` — **`** BUILD SUCCEEDED **`**.
- **Output**: `~/Library/Developer/Xcode/DerivedData/localVoiceRec-*/Build/Products/Debug/localVoiceRec.app` (arm64, ad-hoc signed).

---

## 4. Built `.app` codesign audit

### 4.1 Embedded entitlements (`codesign --display --entitlements - --xml`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
  <dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.get-task-allow</key><true/>
  </dict>
</plist>
```

- `com.apple.security.network.client` — **NOT PRESENT** (target guarantee met).
- `com.apple.security.network.server` — **NOT PRESENT**.
- `com.apple.security.get-task-allow=true` is injected automatically by Xcode for **Debug** builds (allows the debugger to attach). It MUST be false/absent for Release/Notarization. See `docs/release-checklist.md`.

### 4.2 Signature verification

```
$ codesign --verify --verbose .../localVoiceRec.app
localVoiceRec.app: valid on disk
localVoiceRec.app: satisfies its Designated Requirement
```

### 4.3 Bundle metadata (`codesign -dvv`)

```
Executable=.../localVoiceRec.app/Contents/MacOS/localVoiceRec
Identifier=com.example.localVoiceRec
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20400 size=434 flags=0x2(adhoc) hashes=3+7 location=embedded
Signature=adhoc
TeamIdentifier=not set
```

Debug build is ad-hoc signed (no team). Release distribution will require a Developer ID identity (see release checklist).

### 4.4 Bundle contents

```
Contents/Info.plist
Contents/MacOS/localVoiceRec
Contents/PkgInfo
Contents/_CodeSignature/
```

- No `Contents/Frameworks/` — SwiftPM products were statically linked into the executable, so there are no embedded `.framework`s to re-audit individually.
- `Info.plist` correctly carries `LSUIElement`, `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`.

---

## 5. Summary

| Check | Result |
|---|---|
| Source contains zero network APIs | PASS |
| Entitlements file has no network keys | PASS |
| Info.plist has only required TCC strings | PASS |
| `.app` builds via `xcodebuild` | PASS |
| Signed `.app` entitlements free of network capabilities | PASS |
| CloudKit sync explicitly disabled in SwiftData config | PASS |

**No blockers. No required source changes.** Outstanding pre-release items are listed in `docs/release-checklist.md`.
