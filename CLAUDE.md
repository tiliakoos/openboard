# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu-bar app that drives the six Agent-key LEDs (and the outer ring) on a Work
Louder **Codex Micro** keypad from Claude Code sessions running on this Mac. One key per
session: blue working, orange awaiting a permission prompt, purple finished but still
running background work, green done, red error.

Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing anything structural — it is the
record of *why* several things are the way they are, and most of it was paid for by a
real bug.

## Repository and branches

This repo (`tiliakoos/openboard`) is Nick's standalone project. It began as a fork of Cam
Wilson's `camwilso/openboard` and left that fork network on 2026-11-22, after upstream's
0.3.0 (tagged `upstream-0.3.0`; Nick's history at the split is `pre-split`).

- **Work on `main`**, linearly. No release branches or tags. `CFBundleVersion` is the commit
  count, so never rewrite `main`'s history.
- `upstream` is still a remote, **fetch-only** (its push URL is `DISABLED`). Cherry-pick
  from it if something there is worth having; nothing is merged from it wholesale.
- Keep Cam's copyright line in LICENSE (MIT requires it) and the credit in README.

Daily loop: edit, `mac/tools/reload.sh`, `swift run OpenBoardTests`, commit, `git push`.

The fork's history and decisions are in the Obsidian vault at
`~/Documents/Obsidian_Vault/Projects/03_openboard/` (`status.md`, `decision-log.md`).

### Local signing, and why this build never auto-updates

`tools/bootstrap.sh` has already run on this Mac and created a self-signed
**"OpenBoard Local Signing"** certificate. It is what makes macOS treat every rebuild as
the *same* app, so the Input Monitoring / Accessibility / Automation / Bluetooth grants
survive `reload.sh`. Do not delete it, and do not re-run `bootstrap.sh`.

A self-signed cert carries no Team ID, and the hardened runtime's library validation
requires embedded frameworks to share one — so a local build used to die silently at
launch, before its first log line, on the embedded Sparkle framework. `build-app.sh` now
signs non-Developer-ID builds with `com.apple.security.cs.disable-library-validation`
merged in (via PlistBuddy — `plutil` misreads the dotted key). Developer ID builds are
untouched.

This app does not auto-update, by design: a build from this repo is the only update path.
`build-app.sh` leaves the feed and key empty, and `OB_ENABLE_UPDATES=1` needs both passed
explicitly (`OB_FEED_URL`, `OB_SPARKLE_PUBLIC_KEY`) — there is no default pointing at the
original project's feed. **Never install Cam's Homebrew cask or release zip**: it installs
to the same `/Applications/OpenBoard.app` and would replace this build.

## Commands

All builds run from `mac/`.

```sh
cd mac
swift build                     # or: swift build --product OpenBoard
swift run OpenBoardTests        # the whole suite
tools/build-app.sh --install    # assemble the .app, sign, install to /Applications
tools/reload.sh                 # build + install + relaunch — the inner loop
tools/reload.sh --log           # ...and tail ~/Library/Logs/OpenBoard/app.log
swift run openboard-probe       # hardware diagnostic against a real pad
tools/bootstrap.sh              # first-time setup on a fresh Mac
```

**No Xcode.** This is a SwiftPM package built against the Command Line Tools: there is no
`xcodebuild`, no XCTest/swift-testing, and no asset catalog (`actool` is Xcode-only —
which is why the keycap and icon artwork is compiled in as vector path data, see
`KeycapCatalog.swift` / `ProviderIcons.swift`). You do need the **macOS 26 SDK**: Liquid
Glass calls are behind `if #available(macOS 26.0, *)` but the symbols must exist at
compile time.

### Tests

`OpenBoardTests` is a plain executable target, not a `testTarget`. `Sources/OpenBoardTests/main.swift`
calls every suite by hand, and `runSuiteWiringTests` fails if a `run…Tests` function in
that directory is missing from the list — so a new suite must be added there.

There is **no single-test filter**; the binary takes no arguments. To run one suite
locally, comment out the others in `main.swift` (and don't commit that).

Tests that skip are correct, not broken: anything asserting a fact about *this* Mac (a
paired pad, a running Claude Code) skips when the precondition is absent.

**The suite is not sufficient.** Every historical bug here was invisible to a unit test —
the device acknowledges malformed requests with `ok:1` and then ignores them, so a broken
write looks identical to a working one. Verify against the real pad via `tools/reload.sh`.

Two extra harnesses for the otherwise-invisible: `tools/test-onboarding.sh` (rehearses a
first install with permissions revoked and a scratch state dir) and `tools/test-update.sh`
(a real Sparkle update against a local feed).

## Architecture

### The event path

```
Claude Code hook (settings.json)
  └─ openboard-hook          forwards stdin + a few env vars to a Unix socket, exits 0
       └─ HookServer         actor, one JSON object per connection
            └─ SessionRegistry   pure value type: who owns which of the six slots
                 └─ BoardController  paints the pad, publishes to BoardModel (UI)
                      └─ HIDDevice / CodexProtocol   the v.oai.* HID RPC

T3 Code's server (GET /api/orchestration/shell, polled ~1.5s, bearer token)
  └─ T3Client → T3Code.State   diffs threads, synthesizes t3_* events into BoardController.handle
```

Two invariants along that path:

- **Fail-open, always.** Hooks run inline with the user's session. `openboard-hook` exits
  0 no matter what, never blocks, and never writes to stderr. A status light must not be
  able to stall or break someone's prompt. Nothing slow (device I/O, the write lock) may
  move into the helper.
- **The registry is ephemeral and pure.** It is rebuilt from hooks, with time and
  identity injected, so every slot-assignment rule is testable without a device or a
  clock.

### Target layout (`mac/Sources/`)

| Target | Role |
|---|---|
| `OpenBoardKit` | Everything reasonable-about without a pad: states, registry, eligibility, hook parsing, board layout, calibration, protocol framing. The only target the tests link. |
| `OpenBoard` | The app: SwiftUI/AppKit surfaces, `BoardController`, and every side effect — synthetic input, AppleScript, focus. |
| `openboard-hook` | The shim hooks invoke. Its whole contract is its path. |
| `openboard-probe` | How the IOKit layer gets exercised, since it cannot be unit-tested. |
| `openboard-icon` | Renders the app icon at build time (no asset catalog). |
| `OpenBoardTests` | The suite plus a ~90-line harness in `Harness.swift`. |

If something can be decided without hardware, it belongs in `OpenBoardKit` — that split
is what makes the suite possible at all.

### Load-bearing decisions

- **Keys preserve session order, not recency rank.** Closing a CLI session or settling a
  T3 thread shifts later sessions up, skipping reserved action keys. Earlier sessions
  stay put; ordinary activity and turn completion do not reorder keys.
- **More sessions than keys wait, they are not dropped.** `SessionRegistry.waiting` holds
  every session that reported but has no key; the menu bar lists them ("Not on a key")
  with T3 threads and recent desktop/Cursor chats. A full board only lets a strictly
  more urgent session take a key: orange takes any non-orange key, working takes a
  finished one after 10 min (`finishedGrace`). A freed key is refilled from the waiting
  list (`rebalance`). Put on a key by hand = pinned, never taken automatically; taken
  off by hand = held off until it next asks for attention.
- **Eligibility is fail-closed.** `Eligibility.defaultEntrypoints` is an allowlist
  (`cli`, `claude-vscode`, `claude-desktop`). Subagents and embedded SDK clients get no key.
  An unrecognised surface gets nothing rather than stealing a slot. A `claude-desktop`
  session takes its key at its first real event, not `SessionStart` (the app fires that
  for hidden warm-ups), and gives it up when the chat is archived in the app.
- **`SessionState` colors are hardware values**, not a theme. The swatch in the settings
  window and the LED are the same number. Orange belongs to `awaiting` alone; `idle` must
  not be near-white (the pad's resting state is white).
- **The ring summarises, it does not duplicate** (`Ambient.swift`). Dark by default, fires
  on transitions. Failures get a different *shape*, not just a different hue — peripheral
  vision reads motion before colour.
- **Harnesses are described by one value** (`Harness.swift`): settings path, events,
  entrypoints, and honest `limitations`. Claude Code is wired end to end and its
  `settings.json` is merged (with a backup); T3 Code is read from its own server with a
  token, and its Claude threads' own hooks stay refused (`sdk-ts`) or each would hold two
  keys; Hermes and Pi are described, and the app hands over text rather than editing
  their config.
- **Paths: `AppPaths.swift` is the authority.** State, calibration, registry and the
  socket live in `~/Library/Application Support/OpenBoard/`; logs in
  `~/Library/Logs/OpenBoard/app.log`. `~/.claude/openboard/` is a legacy fallback only —
  some older docstrings still name it. `OPENBOARD_HOME` overrides everything, which is how
  tests and scratch runs stay self-contained.

### Vendored code

`CodexProtocol.swift`, `HIDDevice.swift` and `WriteLock.swift` derive from
pejmanjohn/codex-micro-light (MIT). See [VENDORED.md](VENDORED.md) and keep its
"local modifications" list current. Specifically: **the lock path is deliberately shared
with upstream** (`$TMPDIR/codex-micro-light-<uid>/hid-write.lock`) so both tools contend
for the same mutex — do not "fix" it to a project-specific path.

## Hardware gotchas

These read as arbitrary and are not:

- The device acknowledges malformed requests with `ok:1` and then ignores them. A clean
  ack proves nothing.
- **Never write the same ring configuration twice** — re-sending restarts the firmware
  animation, turning a slow snake into a flicker.
- **Layer 1 only.** Per-key status renders only there; writes on other layers succeed and
  do nothing.
- There is no lighting readback, and the ChatGPT app repaints these LEDs on its own
  schedule, so `BoardController` re-asserts on an interval (~2s while the pad is absent,
  ~10s while present). A paint sends only the keys that changed; every key is rewritten
  at least every 30s (`fullKeyInterval`), and on wake and reconnect.
- **Over Bluetooth, writes cost per report, not per message:** ~180ms to hand each
  64-byte report to IOKit (a key is 2 reports, the ring 3). That is why paints skip
  unchanged keys and laps run on the clock. The `paint stats` log line, once a minute,
  is where to look before guessing about lag.
- `ACT10`/`ACT11` are two switches under one wide keycap; `ACT10` owns the binding and
  `ACT11` is debounced into it. The joystick and touch sensor emit nothing at all.

## Permanent identifiers

The bundle id (`com.tiliakoos.openboard`, since 2026-11-22; `com.openboardapp.mac` is the
original project's) and the local signing certificate are effectively immutable: macOS keys TCC grants and login-item registration off them, so changing either
means re-granting every permission. CI asserts that builds have updates off, plus the
Sparkle embed, the inside-out signing of `openboard-hook`, and the `apple-events`
entitlement — that last one shipped missing once and made Automation ungrantable *with no
dialog at all*.

## Logs

`~/Library/Logs/OpenBoard/app.log` is where every diagnosis starts. It contains session
names (Claude Code's own summaries) and working directory paths — worth a glance before
pasting it anywhere.
