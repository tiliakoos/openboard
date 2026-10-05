# Other agents

[← back to the README](../README.md)

OpenBoard is built around Claude Code and knows about three other agents. They are not
equally supported, and the app says so rather than pretending otherwise — a harness that
can never turn a key green is not a harness with a small gap, it is a different product.

## Claude Code — what this was built for

Fully wired, and the only one tested at length. Every surface:

| | |
|---|---|
| **Terminal** | every state, and pressing a key finds the exact tab by its `tty` |
| **iTerm2** | every state, and a key finds the exact split — `tty` lives on the session there, one level deeper than Terminal's tabs |
| **cmux** | every state, and a key selects the exact tab or split by surface id, switching workspace if the session is in another one. Needs no Automation grant |
| **Warp** | every state, and a key opens the exact tab or split through the focus URL Warp gives every shell, in whichever window. Needs no Automation grant |
| **VS Code, extension-hosted** | every state, and a key reveals the panel already holding that conversation |
| **VS Code, integrated terminal** | every state; a key raises VS Code but cannot select a specific terminal — no API exposes that from outside |

Each of those five apps has a switch in **Settings → Agents → Where it works**. Turning
one off means sessions there get no key — and any key one of them is already holding is
given up immediately, because six keys is a scarce budget and a surface you have stopped
caring about should not be spending it. Switched on is the default, including for a
surface added by a later version.

The rows below the switches — subagents, embedded SDK clients, anything remote — have
none. They are never given a key by design, so there is nothing to turn off.

A "new tab" key is per-app too: **new Terminal tab** sends ⌘T to Terminal, and the two
cmux actions ask cmux directly — **new cmux tab** for a tab in the workspace you are in,
**new cmux workspace** for what cmux's own shortcut list calls a new tab. Bind whichever
matches the terminal you actually work in; a key bound to the Terminal one opens a
Terminal window behind cmux, which is the wrong app doing the right thing.

Hooks install automatically. Setup edits `~/.claude/settings.json`, preserving every
unrelated setting and any other tool's hooks on the same events, and backs the file up
first.

This is the one that has been used daily for months, against real work, on real hardware.
Every bug the project has fixed came from that.

## T3 Code

Wired, for every provider T3 runs — Claude, Codex and the rest — and read from T3's own
local server rather than from hooks. One key per thread, the same colours as a terminal
session, and keys that stick.

| | |
|---|---|
| **Status** | T3's thread status, polled about every 1.5s. Orange is a pending approval or question; `waiting` (checkpointing) and an auth refresh are not |
| **Key press** | opens that thread by its sidebar row, then brings T3 forward. A thread not in the sidebar (a collapsed project) only brings T3 forward |
| **Viewing** | the thread T3 is showing breathes, read from its window's route |
| **Approve / reject** | through T3's API, after opening the thread and confirming it is in front. Only when exactly one key is orange |

**Setup is a token.** Settings → Agents → T3 Code shows a command that mints one with
T3's own CLI and writes it straight into `~/Library/Application Support/OpenBoard/t3code.token`
(0600). Pasting a token there works too. To revoke it, list T3's sessions and revoke the
one labelled OpenBoard:

```sh
ELECTRON_RUN_AS_NODE=1 "/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)" "/Applications/T3 Code (Nightly).app/Contents/Resources/app.asar/apps/server/dist/bin.mjs" auth session list --base-dir "$HOME/.t3"
```

then the same command with `auth session revoke <id>`.

Limits:

> **A question is never answered from the pad.** Approve and reject open it in T3
> instead — T3 itself refuses to dismiss a live question from outside.
>
> **A thread already finished when OpenBoard starts stays off the board** until it runs
> again. Eighteen old greens are a history, not a board.

Delegated and subagent threads never take a key. T3 quitting keeps every key for a
minute, so an update's relaunch costs nothing; past that, its keys are given up. Jump and
viewing turn on T3's accessibility tree, which stays on until T3 relaunches — measured at
no cost to its CPU while a reply streams.

## Hermes Agent

Wired, and mostly works. One real gap:

> **No completion event.** Nothing in its shell hooks means "this turn ended", so a Hermes
> key never turns green.

Everything else lands — a key claims a slot, goes blue while working, amber when it needs
you. It simply never tells you it finished, which is half of what the board is for.

Setup is manual: OpenBoard shows you what to add rather than editing a file for you,
because its configuration is not a format that can be merged safely.

## Pi

Wired, with a bigger gap:

> **No approval event is documented**, so a Pi key never turns amber — the one state this
> board exists for.
>
> **In-process extensions only**, so setup is a file you add rather than a command
> OpenBoard can install.

A Pi key will show you that a session exists and that it is working. It will not tell you
when it is blocked on you, which is the question the whole thing was built to answer.

## This is where contributors would help most

Hermes and Pi were wired from their documentation, not from use. They are correct as far
as they go and barely exercised beyond that.

If you use either one daily, the useful contributions are:

**Tell us what actually happens.** The limitations above are read from docs. If Hermes has
a completion signal nobody noticed, or Pi surfaces approvals some other way, that changes
the product rather than patching it.

**A completion event for Hermes**, or evidence there genuinely is not one. Green holding
until you go back is the behaviour people notice most, and Hermes users do not have it.

**An approval signal for Pi.** Amber is the reason this exists.

**Another agent entirely.** Adding one is a `Harness` value: where its config lives, which
events it emits, which entry points may claim a key, and what it cannot do. See
`mac/Sources/OpenBoardKit/Harness.swift` — Claude Code's entry is the worked example, and
`limitations` is not optional decoration. A state that will never appear has to be
declared, because the alternative is a user waiting for a colour that is never coming.

Open an issue before writing much. The board's model — one key per session, keys that
never move, green that holds — constrains what a harness has to provide, and it is worth
checking the fit before building against it.

---

**Next:** [What it does](what-it-does.md) · [Setting up](setup.md) · [Settings](settings.md) · [Troubleshooting](troubleshooting.md)
