# Building and Deployment

## Requirements

- Swift 6.2 toolchain (included with Xcode 16.3+ or via [swift.org](https://swift.org/download/))
- macOS 15.0 or later build machine
- A code signing identity (optional — ad-hoc signing works for local development)

## Package Structure

The project is a Swift Package Manager project with a single executable target:

```
Package.swift
├── target: LumiAgent
│   ├── sources: Lumi/
│   └── dependencies: SwiftAnthropic, OpenAI, GRDB.swift, swift-log
├── target: LumiAgentHelper
│   └── sources: LumiAgentHelper/
└── testTarget: LumiAgentTests
    └── sources: Tests/
```

Swift language mode is set to 5 (via `swiftSettings`) while using Swift tools version 6.2.

## Build Commands

**Debug build (fastest)**:
```bash
swift build
```
Binary at: `.build/debug/LumiAgent`

**Release build**:
```bash
swift build -c release
```
Binary at: `.build/release/LumiAgent`

**Run tests**:
```bash
swift test
```

## Scripts

Three shell scripts automate the build, bundle assembly, signing, and launch process.

### `run_app.sh`

Builds in debug mode, assembles the `.app` bundle, signs it, and launches it. Use this for day-to-day development.

```bash
./run_app.sh
```

Steps:
1. `swift build -c debug`
2. Creates `runable/LumiAgent.app/Contents/MacOS/` and copies the binary
3. Copies `icons/AppIcon.icns` into `Contents/Resources/` if present
4. Attempts to sign with the first available Apple Development certificate via `codesign`
5. Falls back to ad-hoc signing (`codesign --sign -`) if no certificate is found
6. Launches with `open -n runable/LumiAgent.app`

### `auto_update.sh`

Kills the running Lumi instance, rebuilds, reinstalls to `/Applications`, and relaunches. Use this when you want to update the installed copy.

```bash
./auto_update.sh
```

Steps:
1. Kill `LumiAgent` if running
2. Remove `runable/` and `/Applications/LumiAgent.app`
3. Build release
4. Assemble and sign the `.app` bundle
5. Copy to `/Applications/LumiAgent.app`
6. Launch from `/Applications`

### `build_unsigned_dmg.sh`

Builds a release `.dmg` for distribution without a Developer ID. The resulting DMG contains `LumiAgent.app` ad-hoc signed.

```bash
./build_unsigned_dmg.sh
```

Output: `dist/LumiAgent.dmg`

## App Bundle Layout

```
LumiAgent.app/
└── Contents/
    ├── MacOS/
    │   └── LumiAgent          (compiled executable)
    ├── Resources/
    │   ├── AppIcon.icns
    │   └── AppIcon.png
    └── Info.plist             (copied from Config/Lumi-Info.plist)
```

The `Info.plist` is built from `Config/Lumi-Info.plist`. Key entries:
- `LSMinimumSystemVersion`: `15.0`
- `CFBundleIdentifier`: `com.lumiagent.app`
- Bonjour service: `_lumiagent._tcp`
- All `NSUsageDescription` strings for privacy permissions

## Code Signing

**Developer certificate** (recommended for full feature access): `run_app.sh` finds the first identity matching `"Apple Development"` in the keychain and signs with the full `Config/LumiAgent.entitlements`.

**Ad-hoc signing** (local development without a certificate): signs with `-` identity and a minimal entitlements file containing only `get-task-allow`. HealthKit and some entitlements are not available under ad-hoc signing.

To sign manually:
```bash
codesign --force --deep --sign "Apple Development: You (XXXXXXXXXX)" \
         --entitlements Config/LumiAgent.entitlements \
         runable/LumiAgent.app
```

## Xcode

The repo includes `Lumi.xcodeproj` for use with Xcode. Open it and use the `LumiAgent` scheme to build and run. Xcode uses the same SPM package under the hood.

## iOS Build

The iOS companion app compiles from the same `Lumi/` source directory. Build for iOS by targeting an iOS device or simulator in Xcode. The `#if os(iOS)` / `#if os(macOS)` guards ensure the correct code paths compile on each platform.

There is also a standalone `LumiAgentIOS/` SPM package in the repo root that was used during an earlier development phase. The main `Lumi/` sources are the current implementation.

## Dependencies

| Package | Version | Used for |
|---|---|---|
| `SwiftAnthropic` (jamesrochabrun) | ≥ 1.0.0 | Anthropic type definitions (reference) |
| `OpenAI` (MacPaw) | ≥ 0.2.0 | OpenAI type definitions (reference) |
| `GRDB.swift` (groue) | ≥ 6.0.0 | Linked but data layer currently uses flat-file JSON |
| `swift-log` (apple) | ≥ 1.5.0 | Logging in `LumiAgentHelper` |

All network calls to AI providers are hand-rolled `URLSession` requests. The provider packages are present as references but the main HTTP implementation is in `AIProviderRepository.swift`.
