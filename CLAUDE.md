# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu-bar app that drives the six Agent-key LEDs (and the outer ring) on a Work
Louder **Codex Micro** keypad from Claude Code sessions running on this Mac. One key per
session: blue working, orange awaiting a permission prompt, green done, red error.

Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing anything structural — it is the
record of *why* several things are the way they are, and most of it was paid for by a
real bug.

## This checkout is a fork — where to commit

`origin` is Nick's fork (`tiliakoos/openboard`); `upstream` is the author's repo
(`camwilso/openboard`). **Which branch you work on is decided by where the change should
end up**, because a PR carries every commit on its branch.

| Branch | Purpose | Rule |
|---|---|---|
| `main` | Clean mirror of upstream | **Never commit here.** Only updated by `git merge upstream/main`. |
| `features/tiliakoos` | Nick's daily-driver tweaks and personal tooling (this file included) | Default place to edit. Never open a PR from it. |
| `fix/<name>` | One single change destined for an upstream PR | Cut fresh off `main`, one change only, delete after merge. |

If a personal tweak later turns out to be PR-worthy, `git cherry-pick` that commit onto a
clean branch off `main` rather than PRing the daily branch.

Daily loop: edit on `features/tiliakoos`, `mac/tools/reload.sh`, `swift run OpenBoardTests`,
commit, `git push` (backup to the fork). Syncing upstream is
`git fetch upstream && git switch main && git merge upstream/main`, then merge `main` into
`features/tiliakoos` — resolve conflicts in upstream's favour where the conflict is against
something that was merged there.

**Never open a PR or push to `upstream` without Nick's explicit go-ahead** — it is
outward-facing. Upstream also asks for an issue first on anything touching the *harness
model*; build-script and UI changes need none.

The full playbook, including the current PR status and the fork's history, lives in the
Obsidian vault at `~/Documents/Obsidian_Vault/Projects/03_openboard/Fork Workflow.md`.

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

This locally built app does not auto-update, which is deliberate: it protects the local
changes. Syncing from `upstream` *is* the update path. Do not reinstall the Homebrew cask
— it would clobber this build.

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

### Releases (upstream's, not this fork's)

Releases are the author's to cut, and nothing here should ever tag or run
`tools/release.sh`. Recorded because the constraint explains the repo's shape: a release is
a tag on `main`, and **never on a side branch** — `CFBundleVersion` is the commit count
reachable from the tag, Sparkle compares exactly that, and a lower number means the update
is silently never offered, permanently, for that version. `tools/release.sh` refuses a tag
that is not an ancestor of `main`.

## Architecture

### The event path

```
Claude Code hook (settings.json)
  └─ openboard-hook          forwards stdin + a few env vars to a Unix socket, exits 0
       └─ HookServer         actor, one JSON object per connection
            └─ SessionRegistry   pure value type: who owns which of the six slots
                 └─ BoardController  paints the pad, publishes to BoardModel (UI)
                      └─ HIDDevice / CodexProtocol   the v.oai.* HID RPC
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

- **Keys are sticky, not recency-ranked.** A session claims a slot and keeps it; slots are
  reused only after six newer sessions cycle through, and never one currently signalling
  `awaiting`. Deliberately unlike Codex's live recency sort — see `SessionRegistry`.
- **Eligibility is fail-closed.** `Eligibility.defaultEntrypoints` is an allowlist
  (`cli`, `claude-vscode`). Subagents and embedded SDK clients get no key. An unrecognised
  surface gets nothing rather than stealing a slot.
- **`SessionState` colors are hardware values**, not a theme. The swatch in the settings
  window and the LED are the same number. Orange belongs to `awaiting` alone; `idle` must
  not be near-white (the pad's resting state is white).
- **The ring summarises, it does not duplicate** (`Ambient.swift`). Dark by default, fires
  on transitions. Failures get a different *shape*, not just a different hue — peripheral
  vision reads motion before colour.
- **Harnesses are described by one value** (`Harness.swift`): settings path, events,
  entrypoints, and honest `limitations`. Claude Code is wired end to end and its
  `settings.json` is merged (with a backup); Hermes and Pi are described, and the app
  hands over text rather than editing their config.
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
  ~10s while present).
- `ACT10`/`ACT11` are two switches under one wide keycap; `ACT10` owns the binding and
  `ACT11` is debounced into it. The joystick and touch sensor emit nothing at all.

## Permanent identifiers

The bundle id (`com.openboardapp.mac`), the Sparkle feed URL
(`https://updates.openboardapp.com/appcast.xml`) and the signing team are effectively
immutable. macOS keys TCC grants and login-item registration off the bundle id, and
installed copies read the feed URL forever. CI asserts both, plus the Sparkle embed, the
inside-out signing of `openboard-hook`, and the `apple-events` entitlement — that last one
shipped missing once and made Automation ungrantable *with no dialog at all*.

## Logs

`~/Library/Logs/OpenBoard/app.log` is where every diagnosis starts. It contains session
names (Claude Code's own summaries) and working directory paths — worth a glance before
pasting it anywhere.
