# Development

Notes for working on OpenBoard. Most of the app talks to a physical keypad, so some of it
cannot be verified without one. Architecture and hardware gotchas are in
[CLAUDE.md](CLAUDE.md).

## Building

A SwiftPM package in `mac/`, built without Xcode — SwiftUI, AppKit and IOKit all compile
against the Command Line Tools SDK.

```sh
cd mac
swift build
swift run OpenBoardTests      # a plain executable, not XCTest — see below
tools/build-app.sh --install  # assemble, sign, install to /Applications
tools/reload.sh               # rebuild, reinstall and relaunch in one step
```

You need the **macOS 26 SDK**. The app draws with Liquid Glass, and while every call is
behind `if #available(macOS 26.0, *)` — so it runs correctly on macOS 14 without it —
availability gating is a runtime check, and the symbols still have to exist at compile
time.

The one dependency is [Sparkle](https://sparkle-project.org), embedded by hand in
`build-app.sh` and switched off: builds carry no feed or key. `OB_ENABLE_UPDATES=1` turns
it on only with an explicit `OB_FEED_URL` and `OB_SPARKLE_PUBLIC_KEY`.

There are no releases. `CFBundleVersion` is the commit count on `main`, so keep `main`
linear and never rewrite its history.

## Tests

A **plain executable**, not a `testTarget`. The Command Line Tools ship an incomplete
`Testing.framework` and no `xcodebuild`, so swift-testing and XCTest are both unavailable
without a full Xcode install. The harness in `Sources/OpenBoardTests/Harness.swift` prints
a pass/fail summary and exits non-zero on failure.

Nothing in the suite touches hardware. Everything that could — device I/O, synthetic
input, AppleScript — is either injected or lives in the app target, which the test
executable does not link.

**Some tests skip, and that is correct.** Anything asserting a fact about *this* Mac — a
paired Codex Micro, a running Claude Code — skips when the precondition is absent.

**The suite is not enough on its own.** The device acknowledges a malformed request with
`ok:1` and then ignores it, so a broken write looks identical to a working one. Verify
against the real pad with `mac/tools/reload.sh` before believing a change works.

Two harnesses cover what is otherwise invisible:

| | |
|---|---|
| `mac/tools/test-onboarding.sh` | rehearses a first install: revokes permissions and points the app at a scratch state directory. Costs a few minutes of re-granting afterwards |
| `mac/tools/test-update.sh` | a real Sparkle update against a localhost feed; needs your own Sparkle key pair |

## No pad on the desk

```sh
OPENBOARD_VIRTUAL_PAD=1 OPENBOARD_HOME=/tmp/openboard-scratch swift run OpenBoard
```

runs the whole app against a simulated pad and puts its face in a floating panel. The
panel is decoded from the bytes the app writes, so a paint bug shows up there as it would
on the desk, and clicking its keys presses them for real. `OPENBOARD_HOME` keeps the run
out of your real config; keep the path short, because the hook socket lives under it and
`sockaddr_un` caps paths at 104 bytes. It cannot show acknowledgement timing, firmware
quirks or Bluetooth behaviour.

## CI

Every push to `main` builds the app, runs the suite, assembles the `.app` bundle and
asserts things unit tests cannot catch: the framework embed, inside-out signing of
`openboard-hook`, updates being off, and the `apple-events` entitlement. That last one
once shipped missing, and macOS then denied Automation *without ever showing a consent
dialog*. CI uses no secrets.

## Things worth knowing before changing them

- **Never write the same ring configuration twice.** Re-sending it restarts the firmware
  animation, which turns a slow snake into a flicker.
- **The device acknowledges malformed requests with `ok:1` and then ignores them.**
- **Keep the pad on Layer 1.** Writes on other layers succeed and do nothing.
- **The bundle id and the signing certificate are effectively permanent.** macOS keys
  permission grants and the login item off them.
- **`~/Library/Logs/OpenBoard/app.log`** is where every diagnosis starts. It contains
  session names and working-directory paths.
