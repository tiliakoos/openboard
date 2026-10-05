# What OpenBoard does

[← back to the README](../README.md)

You run several Claude Code sessions at once. One of them is blocked on a permission
prompt right now, and you do not know which. Finding out means checking tabs.

OpenBoard puts that one bit of information — *is this session waiting on me?* — on a
physical key you can see without looking at a screen.

<p align="center">
  <img src="../assets/hero.jpg" width="760"
       alt="A Codex Micro beside a MacBook, keys lit in different colours">
</p>

## One key per session

Each Claude Code session claims one of the six Agent keys when it starts. The key's
colour is that session's state.

| State | Colour | What it means |
|---|---|---|
| idle | dim blue | The session is open, nothing running |
| working | blue, breathing | A turn is in progress |
| **awaiting** | **amber, breathing** | **Blocked on a permission prompt — this one needs you** |
| stalled | amber, shallow | Sitting at an idle prompt |
| done | green | The turn finished, and you have not been back yet |
| error | red, breathing | The turn failed |

**Green holds.** A session that finished while you were elsewhere is still green when you
look. It clears when you go back and send that session something — not on a timer, and
not when you merely glance at it. Status that expires on its own is status you learn to
distrust.

## Closing a session closes the gap

Closing a CLI session or settling a T3 thread shifts the sessions on later keys up,
preserving their order and skipping keys bound to actions. Earlier keys stay put. Close
the session on key 2 and the one on key 3 moves to key 2; key 1 stays where it was.

Ordinary activity and turn completion do not reorder keys. A finished turn stays green
on the board until you return to it or dismiss the session. When every session key is
occupied, eviction never takes one that is currently signalling *awaiting*.

## The ring says it from across the room

<p align="center">
  <img src="../assets/ring.jpg" width="760"
       alt="The pad's outer ring lit green after a session finished">
</p>

Six small keys cannot be read from the other side of a room. The outer ring can.

It is **dark by default** and fires only when something changes:

| Event | Ring |
|---|---|
| a chat finishes | green, one slow lap |
| a chat stops to ask something | amber, one lap |
| a turn fails | red heartbeat |

A ring that is always lit is furniture. One that is dark until something happens is a
notification.

Failures get a different *shape*, not just a different colour. Peripheral vision reads
motion before hue, so a failure must never be mistakable for a completion — which is why
the error is a heartbeat and the completion is a lap.

## And in the menu bar

<p align="center">
  <img src="../assets/menubar.png" width="420"
       alt="Six coloured dots in the macOS menu bar mirroring the pad">
</p>

The same six states, as dots. Useful when the pad is out of sight, and the fastest way to
tell whether OpenBoard is running at all.

Click it for the full board:

<p align="center">
  <img src="../assets/popover.png" width="360"
       alt="The popover listing sessions with their states">
</p>

Each row is a session: what you asked it for, where it is running, how long it has been in
its current state. Anything blocked is called out at the top.

## Pressing a key goes there

Press an Agent key and OpenBoard brings that chat to the front. In Terminal and iTerm2 it
finds the exact tab; in cmux it selects the exact surface, switching workspace if the
session is in another one; in Warp it opens the exact tab through Warp's own focus URL;
in VS Code it reveals the panel already holding that conversation; in the Claude desktop
app it selects that session through the app's own `claude://code/continue` link.

Nothing is ever *opened* by a jump. The extension reveals a panel it already has, and the
integrated-terminal case raises the app rather than opening a folder — an approximate jump
beats an unrequested one that rearranges your editor.

Where OpenBoard cannot confirm which chat is in front of you, it **refuses to answer a
prompt** rather than sending ⏎ at whatever happens to be there. The Claude desktop app
never can — it has no way to say which chat it is showing — so a prompt there is always
answered by you.

## Which sessions get a key

Only sessions running as a local process on your Mac, because that is where the hooks
execute and only a local process can reach the hardware.

| | |
|---|---|
| Terminal, iTerm2 | yes |
| cmux | yes — any tab or split, in any workspace |
| Warp | yes — any tab or split, in any window |
| VS Code, integrated terminal | yes |
| VS Code, extension-hosted | yes |
| Claude desktop app, Code tab | yes |
| Subagents | no — six keys is a scarce budget |
| claude.ai/code in a browser, cloud, SSH | unreachable |

Terminal, iTerm2, cmux and VS Code can each be switched off on its own in **Settings →
Agents → Where it works**, and a surface you switch off gives up the keys it is holding straight away. An
unrecognised surface gets no key rather than quietly taking one.

---

**Next:** [Setting up](setup.md) · [Settings](settings.md) · [Troubleshooting](troubleshooting.md)
