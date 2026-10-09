import Foundation
import OpenBoardKit
import SQLite3

/**
 Cursor's own chats: its hooks, translated, and its chat headers, diffed.

 Every rule here is one way the board could lie about a chat: a Cmd-K edit taking a key,
 a green turning blue because a flag was left behind, a chat deleted while nobody looked
 holding its key forever — or an unreadable database releasing all of them. Payloads are
 hand-written from Cursor's hook schema, never captured: a real one carries the prompt
 and the account's email.
 */
func runCursorTests() {
    let chat = "0b7c2f4e-1d3a-4c5b-9e8f-a1b2c3d4e5f6"
    let other = "9f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a"

    func hook(_ name: String, _ id: String = chat, _ fields: [String: Any] = [:]) -> [String: Any] {
        var raw: [String: Any] = [
            "hook_event_name": name,
            "conversation_id": id,
            "session_id": id,
            "generation_id": "gen-1",
            "cursor_version": "3.24.9",
            "workspace_roots": ["/repo"],
            "user_email": "someone@example.com",
        ]
        for (key, value) in fields { raw[key] = value }
        return raw
    }

    func header(pending: Bool = false, archived: Bool = false, subagent: Bool = false) -> Cursor.Header {
        Cursor.Header(name: "Fix the build", isArchived: archived, isSubagent: subagent, isPending: pending)
    }

    // MARK: - hooks

    test("a prompt in a chat claims a key, as a Cursor session the board admits") {
        var state = Cursor.State()
        let emission = try Harness.require(state.receive(hook("beforeSubmitPrompt", chat, ["composer_mode": "agent", "prompt": "secret"])))
        expect(emission.claims)
        let event = HookServer.Event(raw: emission.payload)
        expectEqual(event.name, "cursor_working")
        expectEqual(event.sessionID, "cursor:\(chat)")
        expectEqual(event.cwd, "/repo")
        expect(Eligibility.evaluate(
            env: event.environment, payload: event.eligibilityPayload, harness: event.harness
        ).eligible)
        expectEqual(SessionOrigin.from(entrypoint: event.entrypoint, tty: nil), .cursor)
        // Nothing of Cursor's payload rides along: not the prompt, not the email.
        expect(event.raw["user_email"] == nil && event.raw["prompt"] == nil)
    }

    test("Cmd-K, a non-Cursor payload and a malformed id claim nothing") {
        var state = Cursor.State()
        // Cmd-K's inline prompt fires the same event under its prompt bar's id.
        expect(state.receive(hook("beforeSubmitPrompt")) == nil)
        // Claude Code's own payload is not Cursor's to translate.
        expect(state.receive(["hook_event_name": "UserPromptSubmit", "session_id": chat]) == nil)
        expect(state.receive(hook("beforeSubmitPrompt", "not-a-uuid", ["composer_mode": "agent"])) == nil)
        // A chat loading is not a chat being used.
        expect(state.receive(hook("sessionStart", chat, ["composer_mode": "agent"])) == nil)
    }

    test("stop says done, error or stopped; only a change of tool activity is news") {
        var state = Cursor.State()
        expectEqual(state.receive(hook("stop", chat, ["status": "completed"]))?.event, "cursor_done")
        expectEqual(state.receive(hook("stop", chat, ["status": "error"]))?.event, "cursor_error")
        expectEqual(state.receive(hook("stop", chat, ["status": "aborted"]))?.event, "cursor_idle")
        expect(state.receive(hook("stop", chat, ["status": "something-new"])) == nil)

        let first = state.receive(hook("postToolUse"))
        expectEqual(first?.event, "cursor_working")
        expect(first?.claims == false, "a tool call never takes a key")
        expect(state.receive(hook("postToolUse")) == nil, "every tool call would repaint the pad")
    }

    test("closing a chat releases it") {
        var state = Cursor.State()
        expectEqual(state.receive(hook("sessionEnd", chat, ["reason": "user_close"]))?.event, Cursor.releasedEvent)
        expectEqual(EventMapper.state(for: Cursor.releasedEvent), .ended)
    }

    test("every Cursor event maps to the state its name says, apart from Claude's") {
        for phase in [Cursor.Phase.working, .awaiting, .done, .error, .idle] {
            expectEqual(EventMapper.state(for: phase.eventName)?.rawValue, phase.rawValue)
        }
        expectEqual(EventMapper.state(for: "cursor_done", enabledEvents: ["Stop": false]), .done)
        expect(SessionTranscript.locate(sessionID: "cursor:\(chat)") == nil)
    }

    // MARK: - headers

    test("a pending flag turns orange only when it rises, and clears back to working") {
        var state = Cursor.State()
        _ = state.receive(hook("beforeSubmitPrompt", chat, ["composer_mode": "agent"]))
        // The first read is a baseline: a flag left behind by an old turn is not a question.
        expect(state.apply([chat: header(pending: true)], onBoard: [chat]).emissions.isEmpty)

        var fresh = Cursor.State()
        expect(fresh.apply([chat: header()], onBoard: [chat]).emissions.isEmpty)
        expectEqual(fresh.apply([chat: header(pending: true)], onBoard: [chat]).emissions.map(\.event), ["cursor_awaiting"])
        expectEqual(fresh.apply([chat: header()], onBoard: [chat]).emissions.map(\.event), ["cursor_working"])
    }

    test("a plan dismissed after its turn ended goes back to green, not blue") {
        var state = Cursor.State()
        _ = state.apply([chat: header()], onBoard: [chat])
        _ = state.receive(hook("stop", chat, ["status": "completed"]))
        expectEqual(state.apply([chat: header(pending: true)], onBoard: [chat]).emissions.map(\.event), ["cursor_awaiting"])
        expectEqual(state.apply([chat: header()], onBoard: [chat]).emissions.map(\.event), ["cursor_done"])

        // Built instead: the new turn's prompt moved it on, so the flag falling is no news.
        _ = state.apply([chat: header(pending: true)], onBoard: [chat])
        _ = state.receive(hook("beforeSubmitPrompt", chat, ["composer_mode": "agent"]))
        expectEqual(state.apply([chat: header()], onBoard: [chat]).emissions.map(\.event), [])
    }

    test("archived, deleted and subagent chats are released; an unreadable list releases nothing") {
        var state = Cursor.State()
        let names = state.apply([chat: header(), other: header()], onBoard: [chat, other])
        expectEqual(names.titles["cursor:\(chat)"], "Fix the build")

        // Unreadable: every key stays where it is.
        expect(state.apply(nil, onBoard: [chat, other]).emissions.isEmpty)

        let gone = state.apply([chat: header(archived: true)], onBoard: [chat, other])
        expectEqual(Set(gone.emissions.map(\.chatID)), [chat, other], "archived, and deleted after being seen")
        expect(gone.emissions.allSatisfy { $0.event == Cursor.releasedEvent })

        var young = Cursor.State()
        // A brand-new chat may not have a row yet; that is not a deletion.
        expect(young.apply([:], onBoard: [chat]).emissions.isEmpty)
        expectEqual(young.apply([chat: header(subagent: true)], onBoard: [chat]).emissions.map(\.event), [Cursor.releasedEvent])
    }

    test("headers are read from Cursor's database, and a missing one is unknown") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-cursor-\(UUID().uuidString).vscdb")
        defer { try? FileManager.default.removeItem(at: url) }
        expect(Cursor.readHeaders(ids: [chat], at: url) == nil, "no file is unknown, not empty")

        var db: OpaquePointer?
        expectEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, isArchived INTEGER, isSubagent INTEGER, value TEXT);
            INSERT INTO composerHeaders VALUES ('\(chat)', 'w', 0, 0, '{"name":"Fix the build","hasPendingPlan":true,"hasBlockingPendingActions":false}');
            INSERT INTO composerHeaders VALUES ('\(other)', 'w', 1, 0, '{"name":"Old"}');
            """
        expectEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let headers = try Harness.require(Cursor.readHeaders(ids: [chat, other, "not-a-uuid"], at: url))
        expectEqual(headers[chat], Cursor.Header(name: "Fix the build", isArchived: false, isSubagent: false, isPending: true))
        expectEqual(headers[other]?.isArchived, true)
        expectEqual(headers.count, 2)
    }

    // MARK: - the Agents window

    test("a key opens its chat with Cursor's own link, and only for a real chat id") {
        expectEqual(
            Cursor.openURL(chatID: chat)?.absoluteString,
            "cursor://anysphere.cursor-deeplink/agent?id=\(chat)"
        )
        expect(Cursor.openURL(chatID: "x&id=other") == nil, "an id is never spliced into a link unchecked")
    }

    test("the chat on screen is the one the Agents window recorded") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-cursor-\(UUID().uuidString).vscdb")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        expectEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        expectEqual(sqlite3_exec(db, """
            CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
            INSERT INTO ItemTable VALUES ('cursor/glass.selectedAgent', '\(chat)');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        expectEqual(Cursor.readSelectedChat(at: url), chat)
    }

    /*
     `Focus` and `Actions` are in the executable target, and the real behaviour needs
     Cursor running with someone's chats in it. The contract is checked where it can be,
     as `runClaudeDesktopTests` does.
    */
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let actions = (try? String(contentsOf: sources.appendingPathComponent("OpenBoard/Actions.swift"), encoding: .utf8)) ?? ""

    test("approve and reject open a Cursor chat but never answer it") {
        guard let raise = actions.range(of: "let raised = Focus.raise(target)"),
              let refusal = actions.range(of: "if target.origin == .cursor {"),
              let keystroke = actions.range(of: "let code = decision == .approve ? keyReturn : keyEscape")
        else {
            expect(false, "Actions no longer has a raise, a Cursor refusal and a keystroke")
            return
        }
        expect(raise.lowerBound < refusal.lowerBound, "the chat is opened first, so you can answer it")
        expect(refusal.lowerBound < keystroke.lowerBound, "and refused before any key is sent")
    }
}
