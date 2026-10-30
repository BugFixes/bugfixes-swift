# Bugfixes Swift SDK

Sends an iOS app's crashes, hangs, errors and logs to [Bugfixes](https://bugfix.es), which groups them into reports and raises tickets (GitHub, Jira, TrackLin.es, …).

- **Uncaught `NSException`s:** written to disk as the app dies and sent on the next launch, with their name and reason. Any handler already set is still called.
- **Fatal signals, Swift traps and hangs:** from MetricKit (`MXCrashDiagnostic`, `MXHangDiagnostic`), which usually delivers them on the next launch.
- **Errors and logs** you report yourself.
- **Offline-safe:** reports wait in a queue (at most 50, oldest dropped first) until they're sent.
- **No dependencies** beyond Foundation and MetricKit; it never crashes your app.

## Installation

In Xcode, add the package `https://github.com/BugFixes/bugfixes-swift`, or in `Package.swift`:

```swift
.package(url: "https://github.com/BugFixes/bugfixes-swift", from: "0.1.0")
```

iOS and iPadOS 15+, Mac Catalyst 15+.

## Setup

Create a **mobile key** for your project's agent in the Bugfixes dashboard, with your app's bundle identifier as an allowed app ID. A mobile key (`bfm_…`) is public, so it's safe to ship in the app. **Never put an agent secret in an app**; the SDK refuses to use one.

Start it once, as early as you can:

```swift
import Bugfixes

@main
struct MyApp: App {
    init() {
        Bugfixes.start(key: "bfm_…", environment: "production")
    }
    // …
}
```

With no key, `start` does nothing, so debug builds without a key just work.

## Reporting

```swift
do {
    try checkout()
} catch {
    Bugfixes.report(error) // an error report, with the stack at this call
}

Bugfixes.log(.error, "payment declined", error: error) // sent: error is the default level
Bugfixes.log(.info, "screen opened")                    // not sent unless level: .info
```

## Options

| `start` | Default | |
|---|---|---|
| `key` | required | The `bfm_…` mobile key. Empty: off. |
| `environment` | `""` | e.g. `debug` or `production`. |
| `release` | `CFBundleShortVersionString (CFBundleVersion)` | Groups reports by app version. |
| `level` | `.error` | The lowest `log` level sent. Crashes and `report` are always sent. |
| `server` | `https://api.bugfix.es/v1` | Must be https; plain http only to `localhost` for local development, which also needs `NSAllowsLocalNetworking` in the app's Info.plist. |

Every report carries the device context: OS version, device model, app version and build.

## Limits

- **Stacks:** frames show the binary and symbol, not source files and lines, until dSYM upload exists (BF-54). MetricKit frames aren't symbolicated at all.
- **MetricKit:** it needs a real device, not the simulator, and iOS decides when to deliver, usually the next launch. Those reports carry the release running when they arrive, not the one that crashed.
- **Retries:** reports that couldn't be sent are retried with the next report or when the app becomes active, not when the network returns.
- **App Store privacy:** your privacy label should declare crash data and diagnostics.

## Development

```sh
swift test   # on a Mac, or on Linux for everything except the crash capture
```

Releases are git tags (`v*`); Swift Package Manager reads them directly from this repository.
