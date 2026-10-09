import AppKit
import ApplicationServices
import Foundation
import OpenBoardKit

/**
 Raise the window hosting a session.

 Ported from `lib/focus.cjs`, including the mistake it made. Three strategies, chosen by
 how the session runs:

 - **Terminal or iTerm2: exact.** Both apps' AppleScript dictionaries expose `tty` —
   Terminal per tab, iTerm2 per session — and a CLI session's process owns a tty, so
   the precise tab (or session) can be selected. A session known to be in iTerm2 goes
   straight there; one whose host could not be resolved tries Terminal first and then
   iTerm2, since an exact-match miss cannot mis-raise anything.
 - **cmux: exact, and not by tty.** cmux has no AppleScript and its surfaces expose no
   tty, so the tty branch cannot reach one — it would select nothing and, before
   `origin` knew about cmux, fell through to opening the folder in an editor. Its own
   socket addresses a surface by id instead, which is exact and needs no Automation
   grant. See `Cmux`.
 - **Warp: exact, by URL.** No AppleScript and no tabs in the accessibility tree, but
   Warp gives every shell a URL that focuses its pane. See `focusWarp`.
 - **VS Code: approximate.** An extension-hosted session has no tty, so the window for
   the workspace folder is raised. That focuses the right window, not the specific
   Claude panel inside it — an honest limit rather than a bug to chase.

 **A `cli` session with no tty gets nothing.** That is a detached background job: it
 was never hosted in a window, so there is nothing to raise. The earlier version read
 "no tty" as evidence of VS Code and opened the project as a *folder* in an editor
 unrelated to the session — a confident wrong answer to "jump to that chat", which is
 worse than admitting there is nowhere to go.

 - **Claude desktop app: exact.** No tty and no AppleScript, but the app registers
   `claude://` and opens one Code session by its own id — see
   `openClaudeDesktopSession`.

 Needs Automation permission for Terminal and, separately, for iTerm2. Granted per
 app, and only after a restart.
 */
enum Focus {
    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    enum Outcome: Equatable {
        case raised(method: String)
        case noWindow
        case notFound
        case failed(String)
    }

    @discardableResult
    static func raise(_ slot: SlotView) -> Outcome {
        /*
         A session running in VS Code's integrated terminal has a real pty, so it used
         to take the Terminal branch, fail to find a matching tab — Terminal.app does
         not own that pty — and fall through to opening the session's *folder* in VS
         Code. Pressing "jump to this chat" opened an editor on a directory.

         Two things were wrong. It guessed at the host from the presence of a tty, and
         its fallback did something visible and unrelated rather than reporting that it
         could not get there. It now asks `origin`, which knows who owns the process.
         */
        if slot.origin == .claudeDesktop {
            return openClaudeDesktopSession(slot.claudeDesktopSession)
        }

        if slot.origin == .vscode {
            if let session = slot.sessionID, slot.entrypoint == "claude-vscode" {
                return revealVSCodeSession(session)
            }
            return activateVSCode()
        }

        // Before the tty branch, not after it: a cmux session *has* a tty, so falling
        // through would run the Terminal walk, match nothing, and then try iTerm2 —
        // two Apple events and two possible permission prompts to reach a wrong answer.
        if slot.origin == .cmux {
            return focusCmux(slot)
        }
        // Same reason: a Warp session has a tty that neither Terminal nor iTerm2 owns.
        if slot.origin == .warp {
            return focusWarp(slot)
        }
        if slot.origin == .t3code {
            return focusT3(slot)
        }
        if slot.origin == .cursor {
            return openCursorChat(slot.sessionID)
        }

        if let tty = slot.surface, tty.hasPrefix("ttys") || tty.hasPrefix("/dev/") {
            let path = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

            /*
             Known to be iTerm2: ask iTerm2, and nothing else.

             The fallthrough below exists because a tty alone cannot say which of the two
             owns it. Now that the host can, trying Terminal first is not a harmless
             extra step — for someone who only uses iTerm2 it is an Apple event to an app
             the session is not in, and therefore a consent prompt for Terminal they have
             no reason to grant.
            */
            if slot.origin == .iterm2 { return focusITerm2(tty: path) }

            switch focusTerminal(tty: path) {
            case .notFound:
                // The tty is exact-match-or-nothing, so a miss here cannot mis-raise
                // Terminal — it is safe to try iTerm2 next. A `.raised` or `.failed`
                // (e.g. Automation refused) returns as-is: chaining a second app onto a
                // permission refusal would just stack a second prompt or refusal on top
                // of one the user already needs to resolve for Terminal.
                return focusITerm2(tty: path)
            case let outcome:
                return outcome
            }
        }

        return .noWindow
    }

    /**
     Reveal the tab holding one specific conversation.

     The Claude Code extension registers a URI handler, and `/open?session=` routes
     through `claude-vscode.primaryEditor.open` to a panel map keyed by session id: an
     id already on screen is `reveal()`ed rather than reopened. So the exact chat is
     reachable from outside VS Code, which no public API offers — the extension's own
     commands are the only thing that knows which panel is which.

     **Only for extension-hosted sessions.** A session in VS Code's integrated terminal
     is also `origin == .vscode` and has no panel, so this would miss the map and *create*
     one — a second, resumed view of a conversation that is already running in a terminal
     three feet away. That is the class of confident wrong answer this file exists to
     avoid, so the caller gates on the entry point rather than on the origin.

     A closed panel is reopened rather than revealed, which is the same thing the user
     asked for: the board only lists live sessions, so the conversation is still running.

     Undocumented, and therefore treated like the rest of this app's private
     dependencies: if the handoff fails, fall back to raising the app rather than
     leaving the press with nothing to show for it.
     */
    private static func revealVSCodeSession(_ sessionID: String) -> Outcome {
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "anthropic.claude-code"
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            return activateVSCode()
        }
        return .raised(method: "vscode-session")
    }

    /**
     Bring VS Code forward, without opening anything.

     Deliberately not `code -r <folder>`. VS Code exposes no way to select a particular
     integrated terminal, so the best available is the app itself — and opening a folder
     is *not* a worse version of that, it is a different action that rearranges the
     user's editor. Given the choice between an approximate jump and an unrequested one,
     approximate wins.
     */
    private static func activateVSCode() -> Outcome {
        switch run("tell application \"Visual Studio Code\" to activate") {
        case .success:
            return .raised(method: "vscode-app")
        case let .failure(message):
            return .failed(message)
        }
    }

    /**
     Open one Code session in the Claude desktop app.

     The app registers `claude://`, and `code/continue?session=` routes to the session
     whose id matches — the link its own Dock menu and Spotlight entries are built from.
     The id is the *app's* (`local_…`, from `CLAUDE_CODE_HOST_SESSION_ID`), not Claude
     Code's `session_id`; the hook helper forwards it for exactly this.

     The app drops any id that does not match `^local_[A-Za-z0-9-]{1,64}$`, silently. The
     same rule is applied here so that a link it would ignore is never sent, and the
     press raises the app instead of appearing to do nothing.

     Undocumented, like the VS Code handoff: a failed link falls back to bringing the
     app forward rather than leaving the press with nothing to show for it.
     */
    private static func openClaudeDesktopSession(_ hostSessionID: String?) -> Outcome {
        if let id = hostSessionID, ClaudeDesktop.isHostSessionID(id) {
            var components = URLComponents()
            components.scheme = "claude"
            components.host = "code"
            components.path = "/continue"
            components.queryItems = [URLQueryItem(name: "session", value: id)]
            if let url = components.url, NSWorkspace.shared.open(url) {
                return .raised(method: "claude-desktop-session")
            }
        }
        return activateClaudeDesktop()
    }

    /**
     Open a Cursor chat in its Agents window, with Cursor's own link — see
     `Cursor.openURL`.

     A closed Agents window opens on the link and then drops it, measured: the chat is not
     selected. So if the chat Cursor records as shown is still a different one a moment
     later, and Cursor is still in front, the link goes once more.
     */
    private static func openCursorChat(_ sessionID: String?) -> Outcome {
        guard let chat = sessionID.flatMap(Cursor.chatID(fromSession:)),
              let url = Cursor.openURL(chatID: chat)
        else { return .noWindow }
        guard NSWorkspace.shared.open(url) else { return .failed("Cursor did not take its link") }
        Task {
            try? await Task.sleep(for: .milliseconds(2500))
            let shown = await Task.detached { Cursor.readSelectedChat() }.value
            guard shown != chat,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Cursor.bundleID
            else { return }
            Log.write("jump: Cursor opened without the chat — sending its link again")
            NSWorkspace.shared.open(url)
        }
        return .raised(method: "cursor-agent-link")
    }

    /// Bring the Claude desktop app forward, without opening anything. Only if it is
    /// running: a session from it cannot outlive it, so launching it would find nothing.
    private static func activateClaudeDesktop() -> Outcome {
        guard let claude = NSRunningApplication
            .runningApplications(withBundleIdentifier: claudeDesktopBundleID).first
        else { return .notFound }
        return claude.activate() ? .raised(method: "claude-desktop-app") : .failed("Claude did not activate")
    }

    /// Select the Terminal tab whose tty matches, and bring it forward.
    private static func focusTerminal(tty: String) -> Outcome {
        // "tell application" launches the app if it is not running. A user who never
        // opens Terminal should not have this key start it for them just to discover
        // there is nothing to find — so skip the attempt entirely, the same way a miss
        // inside the AppleScript itself is reported: `.notFound`.
        guard isRunning(bundleID: "com.apple.Terminal") else { return .notFound }
        let escaped = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
          repeat with w from 1 to count of windows
            repeat with t from 1 to count of tabs of window w
              if tty of tab t of window w is "\(escaped)" then
                set selected tab of window w to tab t of window w
                set index of window w to 1
                activate
                return "focused"
              end if
            end repeat
          end repeat
          return "not-found"
        end tell
        """
        let result = run(script)
        switch result {
        case let .success(output):
            return output == "focused" ? .raised(method: "terminal-tty") : .notFound
        case let .failure(message):
            return .failed(message)
        }
    }

    /**
     Select the iTerm2 session whose tty matches, and bring it forward.

     iTerm2's AppleScript dictionary is one level deeper than Terminal's: a window
     holds tabs, and a tab holds one or more sessions (its splits), so the tty lives on
     the session, not the tab. The walk is otherwise the same exact-match idea as
     `focusTerminal` — windows, then tabs, then (here) sessions — and a match selects
     the session, then its tab, then raises the window, so a session buried in a split
     among several tabs in one window is reached the same way a session in its own
     window is.

     Ported from the go/no-go spike (`docs/discovery/iterm2-spike.md`), which proved
     the walk against a live rig before this was written.
     */
    private static func focusITerm2(tty: String) -> Outcome {
        // Same reasoning as `focusTerminal`: never launch iTerm2 just to look for a
        // session that cannot be in it because it is not running.
        guard isRunning(bundleID: "com.googlecode.iterm2") else { return .notFound }
        let escaped = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (tty of s) is equal to "\(escaped)" then
                  select t
                  tell t to select s
                  select w
                  activate
                  return "focused"
                end if
              end repeat
            end repeat
          end repeat
          return "not-found"
        end tell
        """
        let result = run(script, forApp: "iTerm2")
        switch result {
        case let .success(output):
            return output == "focused" ? .raised(method: "iterm-tty") : .notFound
        case let .failure(message):
            return .failed(message)
        }
    }

    /**
     Select the cmux surface holding this session, and bring cmux forward.

     Two calls, and neither is an Apple event: cmux's socket selects the surface and
     the workspace around it, then `NSRunningApplication` raises the app. So this is the
     one exact jump that works with no permission granted at all — the tty walk needs
     Automation for Terminal, and separately for iTerm2, before it can do anything.

     The outcomes are the same contract as the tty path, and each says something
     different: `.notFound` for cmux not running or a surface that has since closed,
     `.noWindow` for a session cmux does not place in one — a `claude` under `ssh`
     inside a cmux terminal is real and is not reachable this way — and `.failed` only
     for a cmux whose CLI cannot be located, which is the one case a user can act on.
     */
    private static func focusCmux(_ slot: SlotView) -> Outcome {
        // Never launch cmux to look for a session that cannot be in it, the same
        // reasoning as `focusTerminal` and `focusITerm2`.
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Cmux.bundleID).first
        else { return .notFound }
        guard let cli = cmuxCLI else {
            return .failed("cmux is running but its CLI is not in the bundle")
        }
        guard let surface = cmuxSurface(for: slot, cli: cli) else { return .noWindow }
        guard Cmux.focus(surface, cli: cli) else { return .notFound }
        // Raised last, so the window that comes forward is already showing the right
        // surface rather than switching workspaces in front of you.
        app.activate()
        return .raised(method: "cmux-surface")
    }

    /**
     Open the thread in T3 Code, and bring T3 forward.

     By its sidebar row, through T3's accessibility tree — see `T3Window`. The thread is
     opened before T3 is raised, so the window that comes forward is already showing it.
     A row that cannot be found or pressed still brings T3 forward, and says so in the
     method: the app is the next best place, and the log can tell the two apart.

     Never launches T3. A key cannot hold a thread from a server that is not running.
     */
    private static func focusT3(_ slot: SlotView) -> Outcome {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: T3Code.bundleID).first
        else { return .notFound }
        let threadID = slot.sessionID.flatMap(T3Code.threadID(fromSession:))
        let opened = slot.isNamed && T3Window.open(title: slot.title ?? "", threadID: threadID ?? "")
        /*
         Through LaunchServices, as `open -a` does, rather than `activate()`.

         Since macOS 14 activation is cooperative: a request from an app that is not in
         front — which OpenBoard never is — may simply be ignored, and was, from an action
         key on the pad. Opening the app is a request the system honours, the same way the
         Warp jump's URL is.
        */
        if let bundle = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        } else {
            app.activate()
        }
        return .raised(method: opened ? "t3 thread" : "t3 app")
    }

    /**
     Bring the Warp pane holding this session forward.

     Opening `WARP_FOCUS_URL` (`warp://session/<pane>`) raises the pane's window, selects
     its tab and pane, and activates Warp — the same from inside Warp as from any other
     app. No Apple event, so no Automation grant.

     Only for a session `ProcessAncestry` places in Warp. The variable is inherited like
     any other: VS Code launched from a Warp shell hands it to every integrated terminal,
     and opening it there would raise the Warp tab that launched the editor.
     */
    private static func focusWarp(_ slot: SlotView) -> Outcome {
        // Never launch Warp to look for a session that cannot be in it, the same
        // reasoning as `focusTerminal`: opening the URL would start it.
        guard isRunning(bundleID: "dev.warp.Warp-Stable") else { return .notFound }
        guard let pid = slot.pid,
              let value = ProcessEnvironment.value(of: "WARP_FOCUS_URL", pid: pid),
              let url = URL(string: value)
        else { return .failed("no WARP_FOCUS_URL in the session's environment") }
        guard NSWorkspace.shared.open(url) else { return .failed("Warp refused \(value)") }
        return .raised(method: "warp-session")
    }

    /// The `cmux` binary belonging to the copy of cmux that is actually running.
    static var cmuxCLI: String? {
        Cmux.cliPath(
            inBundle: NSRunningApplication
                .runningApplications(withBundleIdentifier: Cmux.bundleID)
                .first?.bundleURL?.path
        )
    }

    /**
     Which cmux surface a session is in.

     The cached id first — it is read once per presence cycle for every session at once,
     and a surface id does not change while the surface exists. A session claimed since
     that read has none yet, and asking cmux by pid costs one call rather than costing
     the press: a jump that does nothing for the first few seconds of a session's life
     is exactly the kind of intermittent nothing this app is built to avoid.
     */
    static func cmuxSurface(for slot: SlotView, cli: String) -> Cmux.Surface? {
        if let cached = slot.cmuxSurface { return cached }
        guard let pid = slot.pid else { return nil }
        return Cmux.surfaces(cli: cli)[pid]
    }

    // MARK: - going back

    /// A window you were in, for the Back action. The window is nil for an app that had
    /// none open.
    struct Place: Equatable {
        let pid: pid_t
        let window: AXUIElement?
    }

    /**
     The window in front right now.

     The menu-bar popover can make OpenBoard itself the front app, and going back to
     that is going nowhere — so the place is the app whose window is just behind it.
     */
    static func here() -> Place? {
        guard var pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        if pid == ProcessInfo.processInfo.processIdentifier {
            // Front to back; layer 0 is ordinary windows, not the menu bar or the Dock.
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] ?? []
            guard let behind = windows.lazy
                .filter({ $0[kCGWindowLayer as String] as? Int == 0 })
                .compactMap({ $0[kCGWindowOwnerPID as String] as? pid_t })
                .first(where: { $0 != pid })
            else { return nil }
            pid = behind
        }
        var window: CFTypeRef?
        AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &window
        )
        return Place(pid: pid, window: window.map { $0 as! AXUIElement })
    }

    /**
     Bring a place back: its window, on whichever desktop it is, and its app.

     Raising the window and making it main before activating is what makes macOS
     switch to *that* window's desktop rather than to another window of the same app.
     A window closed since is skipped, and the app comes forward on its own.

     - Returns: the app, or nil when it has quit.
     */
    static func restore(_ place: Place) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: place.pid) else { return nil }
        if let window = place.window,
           AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        app.activate()
        return app
    }

    /// Whether an app with this bundle ID is already running, without launching it.
    /// `NSRunningApplication` is in-process — no `osascript` spawn just to ask.
    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// osascript's stdout, or the reason it failed. A plain pair rather than
    /// `Result`, whose failure type must be an `Error`.
    private enum ScriptResult {
        case success(String)
        case failure(String)
    }

    private static func run(_ script: String, forApp app: String = "Terminal") -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return .failure(error.localizedDescription) }
        process.waitUntilExit()

        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            // -1743 is a refused Apple event: Automation has not been granted. Named
            // rather than passed through as a number, because the fix is specific —
            // and named for whichever app refused it, not hardcoded to Terminal, now
            // that `run` drives more than one.
            if detail.contains("-1743") {
                return .failure("not authorised to control \(app) — grant Automation")
            }
            return .failure(detail)
        }
        return .success(text)
    }
}
