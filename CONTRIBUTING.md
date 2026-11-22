# Contributing

Thanks for looking. This is a small project with an unusual constraint: most of it talks
to a physical keypad, so some of it cannot be verified without one.

## The shape of it

Work lands on `main`, linearly. There are no release tags or packaged builds — see
[Releases](#releases).

## Building

The app is a SwiftPM package in `mac/`, built without Xcode — SwiftUI, AppKit and IOKit
all compile against the Command Line Tools SDK.

```sh
cd mac
swift build
swift run OpenBoardTests      # a plain executable, not XCTest — see below
tools/build-app.sh --install  # assemble, sign, install to /Applications
tools/reload.sh               # rebuild, reinstall and relaunch in one step
```

Builds keep Sparkle updates off. `OB_ENABLE_UPDATES=1` turns them on only with an
explicit `OB_FEED_URL` and `OB_SPARKLE_PUBLIC_KEY`; `test-update.sh` uses that for its
localhost feed.

You need the **macOS 26 SDK**. The app draws with Liquid Glass, and while every call is
behind `if #available(macOS 26.0, *)` — so it runs correctly on macOS 14 without it —
availability gating is a runtime check, and the symbols still have to exist at compile
time.

The one dependency is [Sparkle](https://sparkle-project.org), for updates. Xcode would
embed it; `build-app.sh` does it by hand — copy the framework in, drop the XPC services
(they are for sandboxed apps, which this is not), and sign inside out.

## Tests

A **plain executable**, not a `testTarget`. The Command Line Tools ship an incomplete
`Testing.framework` and no `xcodebuild`, so swift-testing and XCTest are both unavailable
without a full Xcode install. The harness in `Sources/OpenBoardTests/Harness.swift` is
about forty lines, prints the same pass/fail summary, and exits non-zero on failure,
which is all CI needs.

Nothing in the suite touches hardware. Everything that could — device I/O, synthetic
input, AppleScript — is either injected or lives in the app target, which the test
executable does not link. A test that types into whatever window is focused is a test you
cannot run while working.

**Some tests will skip on your machine, and that is correct.** Anything asserting a fact
about *this* Mac — a paired Codex Micro, a running Claude Code — skips when the
precondition is absent rather than failing:

```
  — skipped: no Codex Micro in this machine's Bluetooth report — nothing to parse
```

**The suite is not enough on its own.** Every bug in this project's history was invisible
to a unit test: the device acknowledges a malformed request with `ok:1` and then ignores
it, so three separate bugs produced clean acknowledgements and a dark pad. Verify against
the real pad before believing a change works.

Two harnesses exist for the things that are otherwise invisible:

| | |
|---|---|
| `mac/tools/test-onboarding.sh` | rehearses a first install — revokes permissions and points the app at a scratch state directory, so the whole no-permissions path can be walked without a second Mac |
| `mac/tools/test-update.sh` | runs a real Sparkle update against a local feed, proving download, signature verification, in-place replacement and relaunch, without publishing anything |

Both are reversible. The onboarding one costs a few minutes re-granting permissions
afterwards, which is the point.

## No pad on the desk

```sh
OPENBOARD_VIRTUAL_PAD=1 OPENBOARD_HOME=/tmp/openboard-scratch swift run OpenBoard
```

runs the whole app against a simulated pad and puts its face in a floating panel: the
same framed bytes go out, the same JSON lines come back, and what the panel shows is
decoded from the writes rather than mirrored from app state — so a paint bug shows up
there the way it would on the desk. Clicking its keys presses them for real, setup's
key-order step is completable, and `OPENBOARD_HOME` keeps the run out of your real
config (keep the path short; the hook socket lives under it and `sockaddr_un` caps
paths at 104 bytes).

It does not replace the real pad — acknowledgement timing, firmware quirks and
Bluetooth behaviour are exactly the things it cannot show — but it removes the
hardware from every question that was never about hardware.

## What CI does

Every push and pull request builds the app, runs the suite, assembles the `.app` bundle
and asserts ten things about it. It uses no secrets, so it runs safely on a pull request
from a fork.

The bundle assertions exist because unit tests cannot catch them: a Sparkle framework that
fails to embed, inside-out signing that breaks when a path moves, a missing entitlement.
That last one shipped as a silent failure — the app was signed with the hardened runtime
and no `com.apple.security.automation.apple-events`, so macOS denied Apple events *without
ever showing a consent dialog*, and Automation could not be granted by anyone through any
route.

## Testing a change that touches the pad

Build and install locally rather than downloading a CI artifact:

```sh
mac/tools/reload.sh
```

Worth the extra step. A locally built bundle is signed with whatever identity is in your
keychain and keeps its Input Monitoring and Accessibility grants across rebuilds; a CI
artifact is ad-hoc signed, so macOS treats every download as a brand new application and
you re-grant everything by hand to test one change.

## Releases

There are none: this repo ships no signed, notarized build and no update feed. Install
from source with `mac/tools/reload.sh`. `CFBundleVersion` is the commit count on `main`,
so keep `main` linear and never rewrite its history.

## Where help is most wanted

Support for agents other than Claude Code. Hermes and Pi are wired from their
documentation rather than from use, and each has a gap the app declares openly: Hermes has
no completion event, so a key never turns green; Pi has no documented approval event, so a
key never turns amber — which is the state the board exists for.

If you use either daily, knowing whether those signals genuinely do not exist is worth
more than a patch. See [docs/harnesses.md](docs/harnesses.md) — the board's model constrains
what a harness has to provide.

## Things worth knowing before changing them

Several constants here look arbitrary and are not. The reasoning lives in comments beside
the code, and most of it was paid for once already:

- **Never write the same ring configuration twice.** Re-sending it restarts the firmware
  animation, which turns a slow snake into a flicker.
- **The device acknowledges malformed requests with `ok:1` and then ignores them.**
- **Keep the pad on Layer 1.** Writes on other layers succeed and do nothing.
- **The bundle id, the feed URL and the signing team are effectively permanent.** macOS
  keys permission grants off the first two, and installed copies read the feed URL forever.

## Reporting a bug

`~/Library/Logs/OpenBoard/app.log` is where every diagnosis has started. It contains
session names — Claude Code's own summaries of what you are working on — and working
directory paths. Worth a glance before pasting it anywhere.
