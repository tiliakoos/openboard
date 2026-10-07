import Foundation
import OpenBoardKit

/**
 T3 Code threads, read from T3's server and turned into hook events.

 Every rule here is one way the board could lie about a thread: a green from last week
 claiming a key, a key that never clears after a thread is settled, a restart of T3
 wiping the greens it was supposed to keep. Fixtures are hand-written from T3's schema
 (`OrchestrationV2ThreadShell`), never captured — a real snapshot carries thread titles,
 paths and message text.
 */
func runT3CodeTests() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func thread(_ id: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var thread: [String: Any] = [
            "id": id,
            "projectId": "p1",
            "title": "Thread \(id)",
            "status": "idle",
            "lineage": ["parentThreadId": NSNull(), "relationshipToParent": NSNull(), "rootThreadId": id],
            "archivedAt": NSNull(),
            "deletedAt": NSNull(),
            "settledOverride": NSNull(),
            "settledAt": NSNull(),
            "pendingRuntimeRequest": NSNull(),
            "latestRunId": "run-\(id)-1",
            "worktreePath": NSNull(),
            // Fields this does not read, as a nightly adds them.
            "providerInstanceId": "claude",
            "someFutureField": ["nested": true],
        ]
        for (key, value) in fields { thread[key] = value }
        return thread
    }

    func snapshot(
        _ threads: [[String: Any]],
        projects: [[String: Any]] = [["id": "p1", "title": "Repo", "workspaceRoot": "/repo"]]
    ) throws -> T3Code.ShellSnapshot {
        let object: [String: Any] = [
            "schemaVersion": 1, "snapshotSequence": 7,
            "threads": threads, "archivedThreads": [], "projects": projects,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(T3Code.ShellSnapshot.self, from: data)
    }

    func events(_ update: T3Code.Update) -> [String] {
        update.emissions.map { "\($0.threadID):\($0.event)" }
    }

    func phase(_ fields: [String: Any]) throws -> T3Code.Phase {
        let parsed = try snapshot([thread("t", fields)])
        return T3Code.phase(of: try Harness.require(parsed.threads.first))
    }

    // MARK: - decoding

    test("a snapshot decodes past fields and values it has never seen") {
        // A nightly adds fields and enum values. Neither may blank the board.
        let parsed = try snapshot([
            thread("a", ["status": "teleporting", "activityRunStatus": NSNull()]),
            thread("b", ["pendingBackgroundTasks": [["kind": "hologram", "taskId": "x"]]]),
        ])
        expectEqual(parsed.threads.count, 2)
        expectEqual(parsed.threads[0].status, "teleporting")
    }

    test("a thread missing optional fields still decodes") {
        let parsed = try snapshot([["id": "bare"]])
        expectEqual(parsed.threads.first?.id, "bare")
        expectEqual(T3Code.phase(of: parsed.threads[0]), .idle)
    }

    test("the runtime file gives the pid and where to connect") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-t3-runtime-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version":1,"pid":23803,"host":"127.0.0.1","port":3773,"origin":"http://127.0.0.1:3773","startedAt":"2026-10-05T13:11:44.369Z"}"#.utf8)
            .write(to: url)
        let runtime = try Harness.require(T3Code.readRuntime(url: url))
        expectEqual(runtime.pid, 23803)
        expectEqual(runtime.port, 3773)
        expectEqual(runtime.origin, "http://127.0.0.1:3773")
        expect(T3Code.readRuntime(url: url.appendingPathExtension("gone")) == nil)
    }

    // MARK: - phase

    test("each status maps to the color T3's own awareness rule gives it") {
        for status in ["preparing", "queued", "starting", "running", "waiting"] {
            expectEqual(try phase(["status": status]), .working, status)
        }
        expectEqual(try phase(["status": "completed"]), .done)
        expectEqual(try phase(["status": "failed"]), .error)
        for status in ["idle", "interrupted", "cancelled", "rolled_back", "something-new"] {
            expectEqual(try phase(["status": status]), .idle, status)
        }
    }

    test("the activity status wins over the thread status") {
        // A run woken by a subagent is running even though its thread reads completed.
        expectEqual(try phase(["status": "completed", "activityRunStatus": "running"]), .working)
        expectEqual(try phase(["status": "completed", "activityRunStatus": NSNull()]), .done)
    }

    test("a pending request is orange, except an auth refresh") {
        let request = { (kind: String) -> [String: Any] in
            ["id": "r1", "kind": kind, "createdAt": "2026-10-05T13:11:44.369Z"]
        }
        expectEqual(try phase(["status": "running", "pendingRuntimeRequest": request("command")]), .awaiting)
        expectEqual(try phase(["status": "running", "pendingRuntimeRequest": request("user_input")]), .awaiting)
        expectEqual(try phase(["status": "running", "pendingRuntimeRequest": request("auth_refresh")]), .working)
    }

    test("background work holds a completion, except a command left running") {
        let tasks = { (kind: String) -> [String: Any] in
            ["status": "completed", "pendingBackgroundTasks": [["kind": kind, "taskId": "x"]]]
        }
        expectEqual(try phase(tasks("command")), .done, "a dev server is not the agent working")
        expectEqual(try phase(tasks("subagent")), .working)
        expectEqual(try phase(tasks("monitor")), .working)
        expectEqual(try phase(tasks("background_task")), .working)
        expectEqual(try phase(tasks("unknown-kind")), .working, "unknown work holds, as T3's does")
    }

    // MARK: - eligibility

    test("only a thread you have not dismissed may hold a key") {
        let parsed = try snapshot([
            thread("plain"),
            thread("fork", ["lineage": ["relationshipToParent": "fork", "rootThreadId": "plain"]]),
            thread("child", ["lineage": ["relationshipToParent": "subagent", "rootThreadId": "plain"]]),
            thread("archived", ["archivedAt": "2026-10-01T00:00:00Z"]),
            thread("deleted", ["deletedAt": "2026-10-01T00:00:00Z"]),
            thread("settled", ["settledOverride": "settled"]),
            thread("reopened", ["settledOverride": "active"]),
            thread("snoozed", ["snoozedUntil": "2030-01-15T08:00:00.000Z"]),
            thread("woke", ["snoozedUntil": "2020-01-01T00:00:00Z"]),
        ])
        let eligible = parsed.threads.filter { T3Code.isEligible($0, now: now) }.map(\.id)
        expectEqual(eligible, ["plain", "fork", "reopened", "woke"])
    }

    // MARK: - the diff

    test("the first snapshot claims only threads that are working or waiting on you") {
        var state = T3Code.State()
        let update = state.apply(try snapshot([
            thread("run", ["status": "running"]),
            thread("ask", ["status": "running", "pendingRuntimeRequest": ["id": "r1", "kind": "command"]]),
            thread("green", ["status": "completed"]),
            thread("red", ["status": "failed"]),
            thread("rest", ["status": "idle"]),
        ]), now: now)
        expectEqual(events(update), ["run:t3_working", "ask:t3_awaiting"])
        expectEqual(state.trackedCount, 2)
    }

    test("an unchanged thread says nothing") {
        var state = T3Code.State()
        let threads = [thread("run", ["status": "running"])]
        _ = state.apply(try snapshot(threads), now: now)
        expectEqual(events(state.apply(try snapshot(threads), now: now)), [])
    }

    test("a tracked thread reports each change, and stays tracked through idle") {
        var state = T3Code.State()
        _ = state.apply(try snapshot([thread("a", ["status": "running"])]), now: now)
        expectEqual(events(state.apply(try snapshot([thread("a", ["status": "completed"])]), now: now)), ["a:t3_done"])
        expectEqual(events(state.apply(try snapshot([thread("a", ["status": "rolled_back"])]), now: now)), ["a:t3_idle"])
        expectEqual(events(state.apply(try snapshot([thread("a", ["status": "failed"])]), now: now)), ["a:t3_error"])
        expectEqual(state.trackedCount, 1)
    }

    test("a second request on an orange thread is a new prompt") {
        var state = T3Code.State()
        let asking = { (id: String, kind: String) in
            thread("a", ["status": "running", "pendingRuntimeRequest": ["id": id, "kind": kind]])
        }
        let first = state.apply(try snapshot([asking("r1", "command")]), now: now)
        expectEqual(first.emissions.first?.requestKind, "command")
        let second = state.apply(try snapshot([asking("r2", "user_input")]), now: now)
        expectEqual(events(second), ["a:t3_awaiting"])
        expectEqual(second.emissions.first?.requestKind, "user_input")
        expectEqual(events(state.apply(try snapshot([asking("r2", "user_input")]), now: now)), [])
    }

    test("a whole run between two polls still lands, once primed") {
        var state = T3Code.State()
        _ = state.apply(try snapshot([thread("a", ["status": "completed", "latestRunId": "run-1"])]), now: now)
        // Same run: the green that was already there stays off the board.
        expectEqual(events(state.apply(try snapshot([
            thread("a", ["status": "completed", "latestRunId": "run-1"]),
        ]), now: now)), [])
        // A new run that started and finished in under a poll.
        expectEqual(events(state.apply(try snapshot([
            thread("a", ["status": "completed", "latestRunId": "run-2"]),
        ]), now: now)), ["a:t3_done"])
        expectEqual(events(state.apply(try snapshot([
            thread("a", ["status": "failed", "latestRunId": "run-2"]),
        ]), now: now)), ["a:t3_error"])
    }

    test("settling, archiving, snoozing or removing a thread releases its key") {
        var state = T3Code.State()
        let running = ["status": "running"]
        _ = state.apply(try snapshot([
            thread("settle", running), thread("archive", running),
            thread("snooze", running), thread("vanish", running), thread("stay", running),
        ]), now: now)
        let update = state.apply(try snapshot([
            thread("settle", ["status": "running", "settledOverride": "settled"]),
            thread("archive", ["status": "running", "archivedAt": "2026-10-05T00:00:00Z"]),
            thread("snooze", ["status": "running", "snoozedUntil": "2030-01-01T00:00:00Z"]),
            thread("stay", running),
        ]), now: now)
        expectEqual(
            events(update).sorted(),
            ["archive:t3_released", "settle:t3_released", "snooze:t3_released", "vanish:t3_released"]
        )
        expectEqual(state.trackedCount, 1)
    }

    test("a sent message is noticed in any thread, but not on the first look") {
        var state = T3Code.State()
        let first = state.apply(try snapshot([
            thread("a", ["latestUserAuthoredMessageAt": "2026-10-05T10:00:00Z"]),
        ]), now: now)
        expect(!first.promptSubmitted, "the first snapshot is history, not a submit")
        let same = state.apply(try snapshot([
            thread("a", ["latestUserAuthoredMessageAt": "2026-10-05T10:00:00Z"]),
        ]), now: now)
        expect(!same.promptSubmitted)
        // In a thread that was idle and untracked: dictation into it must still end.
        let sent = state.apply(try snapshot([
            thread("a", ["latestUserAuthoredMessageAt": "2026-10-05T10:05:00Z"]),
        ]), now: now)
        expect(sent.promptSubmitted)
    }

    test("titles are kept for the threads holding a key") {
        var state = T3Code.State()
        let update = state.apply(try snapshot([
            thread("a", ["status": "running", "title": "Fix the ring"]),
            thread("b", ["status": "idle", "title": "Old work"]),
        ]), now: now)
        expectEqual(update.titles, ["t3:a": "Fix the ring"])
    }

    test("a thread's project is named as T3 names it, worktree or not") {
        var state = T3Code.State()
        let update = state.apply(try snapshot([
            thread("a", ["status": "running", "worktreePath": "/repo/.t3/worktrees/fix-ring"]),
            thread("b", ["status": "idle"]),
        ]), now: now)
        expectEqual(update.projects, ["t3:a": "Repo"])
    }

    // MARK: - losing the server

    test("a server back within the grace keeps every key, green included") {
        var state = T3Code.State()
        _ = state.apply(try snapshot([thread("a", ["status": "running"])]), now: now)
        _ = state.apply(try snapshot([thread("a", ["status": "completed"])]), now: now)

        expectEqual(state.serverLost(now: now), [])
        expectEqual(state.serverLost(now: now.addingTimeInterval(T3Code.serverGrace - 1)), [])
        // T3 relaunched: same threads, nothing to say.
        expectEqual(events(state.apply(try snapshot([thread("a", ["status": "completed"])]), now: now)), [])
        expectEqual(state.trackedCount, 1)
        // And the grace restarts from the next loss, not the first.
        expectEqual(state.serverLost(now: now.addingTimeInterval(T3Code.serverGrace + 5)), [])
    }

    test("a server gone past the grace gives up its keys, and starts again strict") {
        var state = T3Code.State()
        _ = state.apply(try snapshot([thread("a", ["status": "running"])]), now: now)
        _ = state.apply(try snapshot([thread("a", ["status": "completed"])]), now: now)
        _ = state.serverLost(now: now)
        let released = state.serverLost(now: now.addingTimeInterval(T3Code.serverGrace))
        expectEqual(released.map(\.event), ["t3_released"])
        expectEqual(state.trackedCount, 0)
        // Back later: the green is history now, like any first snapshot.
        expectEqual(events(state.apply(try snapshot([thread("a", ["status": "completed"])]), now: now)), [])
    }

    test("a rejected token releases at once") {
        var state = T3Code.State()
        _ = state.apply(try snapshot([thread("a", ["status": "running"]), thread("b", ["status": "running"])]), now: now)
        expectEqual(state.reset().map(\.threadID), ["a", "b"])
        expectEqual(state.reset(), [])
    }

    // MARK: - into the board

    test("an emission is a hook event the board admits") {
        var state = T3Code.State()
        let update = state.apply(try snapshot([
            thread("a", ["status": "running", "pendingRuntimeRequest": ["id": "r1", "kind": "command"]]),
            thread("b", ["status": "running", "worktreePath": "/repo/.t3/worktrees/b"]),
        ]), now: now)
        let asking = try Harness.require(update.emissions.first { $0.threadID == "a" })
        let event = HookServer.Event(raw: asking.payload)
        expectEqual(event.name, "t3_awaiting")
        expectEqual(event.sessionID, "t3:a")
        expectEqual(event.harness, "t3code")
        expectEqual(event.entrypoint, "t3code")
        expectEqual(event.toolName, "command")
        expectEqual(event.cwd, "/repo", "falls back to the project root")
        expect(event.environment.isEmpty)
        expect(event.hookPPID == nil, "a shared server pid would let one thread take another's key")
        expect(Eligibility.evaluate(
            env: event.environment, payload: event.eligibilityPayload, harness: event.harness
        ).eligible)
        expectEqual(EventMapper.state(for: event.name), .awaiting)

        let working = try Harness.require(update.emissions.first { $0.threadID == "b" })
        expectEqual(HookServer.Event(raw: working.payload).cwd, "/repo/.t3/worktrees/b")
        expect(HookServer.Event(raw: working.payload).toolName == nil)
    }

    test("every T3 event maps to the state its name says") {
        expectEqual(EventMapper.state(for: "t3_working"), .working)
        expectEqual(EventMapper.state(for: "t3_awaiting"), .awaiting)
        expectEqual(EventMapper.state(for: "t3_done"), .done)
        expectEqual(EventMapper.state(for: "t3_error"), .error)
        expectEqual(EventMapper.state(for: "t3_idle"), .idle)
        expectEqual(EventMapper.state(for: "t3_released"), .ended)
        // Muting Claude's Stop must not mute a T3 thread's green.
        expectEqual(EventMapper.state(for: "t3_done", enabledEvents: ["Stop": false]), .done)
    }

    test("a T3 thread is labelled T3 Code and has no transcript to look for") {
        expectEqual(SessionOrigin.from(entrypoint: "t3code", tty: nil), .t3code)
        expectEqual(SessionOrigin.t3code.rawValue, "T3 Code")
        expect(SessionTranscript.locate(sessionID: "t3:abc") == nil)
    }

    // MARK: - the window

    test("the thread in front is read from T3's route, and only from a thread's") {
        let env = "6d5d27a1-e325-4f41-8d8d-792103e98b19"
        expectEqual(T3Code.threadID(fromAppURL: "t3code://app/#/\(env)/67cc5868-7850"), "67cc5868-7850")
        expectEqual(T3Code.threadID(fromAppURL: "t3code://app/#/\(env)/abc?panel=diff"), "abc")
        expect(T3Code.threadID(fromAppURL: "t3code://app/#/settings/general") == nil)
        expect(T3Code.threadID(fromAppURL: "t3code://app/#/projects/repo") == nil)
        expect(T3Code.threadID(fromAppURL: "t3code://app/#/draft/d1") == nil)
        expect(T3Code.threadID(fromAppURL: "t3code://app/#/") == nil)
        expect(T3Code.threadID(fromAppURL: "t3code://app/") == nil)
    }

    // MARK: - the token

    test("the token lives in its own 0600 file, read back trimmed") {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-t3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["OPENBOARD_HOME": home.path]

        expect(T3Code.readToken(env: env) == nil)
        // A fresh state directory: saving must create it.
        try T3Code.saveToken("  secret-token\n", env: env)
        expectEqual(T3Code.readToken(env: env), "secret-token")
        let mode = try FileManager.default.attributesOfItem(atPath: AppPaths.t3Token(env: env).path)[.posixPermissions] as? Int
        expectEqual(mode, 0o600)

        try T3Code.saveToken("replaced", env: env)
        expectEqual(T3Code.readToken(env: env), "replaced")
        T3Code.removeToken(env: env)
        expect(T3Code.readToken(env: env) == nil)
    }

    // MARK: - approve and reject

    test("a respond request is one RPC frame T3 accepts") {
        let data = T3Code.respondRequest(
            threadID: "t1", requestID: "r9", decision: "accept", commandID: "openboard:abc"
        )
        let object = try Harness.require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        expectEqual(object["_tag"] as? String, "Request")
        expectEqual(object["id"] as? String, "1")
        expectEqual(object["tag"] as? String, "orchestration.dispatchCommand")
        expect((object["headers"] as? [Any])?.isEmpty == true, "headers is required, even empty")
        let payload = try Harness.require(object["payload"] as? [String: Any])
        expectEqual(payload["type"] as? String, "runtime-request.respond")
        expectEqual(payload["threadId"] as? String, "t1")
        expectEqual(payload["requestId"] as? String, "r9")
        expectEqual(payload["decision"] as? String, "accept")
        expectEqual(payload["commandId"] as? String, "openboard:abc")
    }

    test("the answer is found in single, batched and foreign frames") {
        let frame = { (json: String) in T3Code.exitOutcome(fromFrame: Data(json.utf8)) }
        expectEqual(frame(#"{"_tag":"Exit","requestId":"1","exit":{"_tag":"Success","value":{"sequence":42}}}"#), .sent)
        expectEqual(
            frame(#"[{"_tag":"Pong"},{"_tag":"Exit","requestId":"1","exit":{"_tag":"Success","value":{}}}]"#),
            .sent
        )
        // Someone else's answer, and chatter, are not ours.
        expect(frame(#"{"_tag":"Exit","requestId":"2","exit":{"_tag":"Success","value":{}}}"#) == nil)
        expect(frame(#"{"_tag":"Pong"}"#) == nil)
        expect(frame("not json") == nil)

        guard case let .failed(detail)? = frame(
            #"{"_tag":"Exit","requestId":"1","exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"message":"already answered"}}]}}"#
        ) else {
            expect(false, "a Failure exit must fail")
            return
        }
        expect(detail.contains("already answered"), detail)
        guard case .failed? = frame(#"{"_tag":"Defect","defect":"boom"}"#) else {
            expect(false, "a connection defect must fail")
            return
        }
    }
}
