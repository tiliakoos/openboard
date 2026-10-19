import Foundation
import OpenBoardKit
import SQLite3

/**
 Six keys, more sessions.

 Written against the failure that built this: a T3 thread working for half an hour lost
 its key to one that ran for fifty seconds, and when that one was settled the key stayed
 empty — the working thread had no event left that could bring it back, and nothing
 listed it anywhere.
 */
func runWaitingTests() {
    let alwaysAlive: (Int?) -> Bool = { _ in true }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let minute: TimeInterval = 60

    /// Six working sessions, s1…s6, claimed in order at `start`.
    func busyBoard() -> SessionRegistry {
        var registry = SessionRegistry()
        for i in 1...6 {
            _ = registry.claim(sessionID: "s\(i)", state: .working, now: start, isAlive: alwaysAlive)
        }
        return registry
    }

    // MARK: - a full board

    test("a full board of working sessions parks a newcomer instead of taking a key") {
        var registry = busyBoard()
        let result = registry.claim(
            sessionID: "new", state: .working, now: start.addingTimeInterval(minute), isAlive: alwaysAlive
        )
        expectEqual(result.mode, .waiting)
        expect(result.entry == nil)
        expectEqual(registry.entries.map(\.sessionID).sorted(), ["s1", "s2", "s3", "s4", "s5", "s6"])
        expectEqual(registry.waitingEntry(forSession: "new")?.state, .working)
    }

    test("the regression: a short thread waits, and gets a key once one frees") {
        var registry = busyBoard()
        let later = start.addingTimeInterval(25 * minute)
        _ = registry.claim(sessionID: "short", state: .working, now: later, isAlive: alwaysAlive)
        expectEqual(registry.entry(forSession: "s1")?.slot, 1, "the long-running thread keeps its key")

        registry.release(sessionID: "s4")
        let placed = registry.rebalance(now: later, isAlive: alwaysAlive)
        expectEqual(placed.map(\.entry.sessionID), ["short"])
        expectEqual(registry.entry(forSession: "short")?.slot, 6, "the key after the last session")
        expect(registry.waiting.isEmpty)
    }

    test("a working newcomer takes a finished key only once its grace has run out") {
        var registry = busyBoard()
        registry.setState(sessionID: "s2", to: .done, now: start)

        let early = registry.claim(
            sessionID: "new", state: .working, now: start.addingTimeInterval(5 * minute), isAlive: alwaysAlive
        )
        expectEqual(early.mode, .waiting, "green for five minutes is still news")

        let placed = registry.rebalance(now: start.addingTimeInterval(11 * minute), isAlive: alwaysAlive)
        expectEqual(placed.first?.mode, .evicted)
        expectEqual(registry.entry(forSession: "new")?.slot, 2)
        expectEqual(registry.waitingEntry(forSession: "s2")?.state, .done, "the finished one waits, still green")
        expectEqual(registry.waitingEntry(forSession: "s2")?.held, false)
    }

    test("an orange newcomer takes the oldest working key, never an orange or pinned one") {
        var registry = busyBoard()
        registry.setState(sessionID: "s1", to: .awaiting, now: start)
        expect(registry.assign(sessionID: "s2", toSlot: 2, now: start) != nil)
        expectEqual(registry.entry(forSession: "s2")?.pinned, true)

        let result = registry.claim(sessionID: "asks", state: .awaiting, now: start, isAlive: alwaysAlive)
        expectEqual(result.mode, .evicted)
        expectEqual(result.entry?.slot, 3)
        expectEqual(result.displaced?.sessionID, "s3")
        expectEqual(registry.waitingEntry(forSession: "s3")?.state, .working)
    }

    test("an orange newcomer takes a finished key before a working one") {
        var registry = busyBoard()
        registry.setState(sessionID: "s4", to: .done, now: start)
        let result = registry.claim(sessionID: "asks", state: .awaiting, now: start, isAlive: alwaysAlive)
        expectEqual(result.displaced?.sessionID, "s4", "not s1, the oldest but still working")
    }

    test("an orange session waits when every other key is orange or pinned") {
        var registry = busyBoard()
        for i in 1...6 { _ = registry.assign(sessionID: "s\(i)", toSlot: i, now: start) }
        let result = registry.claim(sessionID: "asks", state: .awaiting, now: start, isAlive: alwaysAlive)
        expectEqual(result.mode, .waiting)
        expectEqual(registry.entries.count, 6)
    }

    test("two finished sessions never trade a key back and forth") {
        var registry = busyBoard()
        for i in 1...6 { registry.setState(sessionID: "s\(i)", to: .done, now: start) }
        _ = registry.claim(sessionID: "late", state: .done, now: start, isAlive: alwaysAlive)
        let hourLater = start.addingTimeInterval(60 * minute)
        expect(registry.rebalance(now: hourLater, isAlive: alwaysAlive).isEmpty)
        expect(registry.rebalance(now: hourLater, isAlive: alwaysAlive).isEmpty)
        expect(registry.entry(forSession: "late") == nil)
    }

    test("a waiting session that turns working takes a long-finished key") {
        var registry = busyBoard()
        registry.setState(sessionID: "s5", to: .done, now: start)
        _ = registry.claim(sessionID: "w", state: .done, now: start, isAlive: alwaysAlive)
        let later = start.addingTimeInterval(20 * minute)
        expect(registry.rebalance(now: later, isAlive: alwaysAlive).isEmpty, "green does not displace green")
        registry.setState(sessionID: "w", to: .working, now: later)
        let placed = registry.rebalance(now: later, isAlive: alwaysAlive)
        expectEqual(placed.map(\.entry.sessionID), ["w"])
        expectEqual(registry.entry(forSession: "w")?.slot, 5)
    }

    // MARK: - refilling a freed key

    test("a freed key goes to the most urgent waiting session, then the most recent") {
        var registry = busyBoard()
        _ = registry.claim(sessionID: "old-green", state: .done, now: start, isAlive: alwaysAlive)
        _ = registry.claim(
            sessionID: "new-green", state: .done, now: start.addingTimeInterval(minute), isAlive: alwaysAlive
        )
        _ = registry.claim(sessionID: "working", state: .working, now: start, isAlive: alwaysAlive)

        registry.release(sessionID: "s6")
        _ = registry.rebalance(now: start, isAlive: alwaysAlive)
        expectEqual(registry.entry(forSlot: 6)?.sessionID, "working")

        registry.release(sessionID: "s5")
        _ = registry.rebalance(now: start, isAlive: alwaysAlive)
        expectEqual(registry.entry(forSlot: 6)?.sessionID, "new-green", "keys still fill in order")
        expectEqual(registry.waiting.map(\.sessionID), ["old-green"])
    }

    test("the off-board order is urgency, then recency") {
        func entry(_ id: String, _ state: SessionState, _ at: TimeInterval) -> SessionRegistry.Entry {
            var registry = SessionRegistry()
            _ = registry.claim(sessionID: id, state: state, now: start.addingTimeInterval(at), isAlive: alwaysAlive)
            return registry.entries[0]
        }
        let rows = [
            entry("green", .done, 50), entry("orange", .awaiting, 0),
            entry("blue-old", .working, 0), entry("blue-new", .working, 10), entry("white", .idle, 99),
        ]
        // White and green share a standing, so the more recent one leads.
        expectEqual(
            rows.sorted(by: SessionRegistry.precedes).map(\.sessionID),
            ["orange", "blue-new", "blue-old", "white", "green"]
        )
    }

    // MARK: - by hand

    test("taking a session off by hand keeps it off, even with a key free") {
        var registry = busyBoard()
        expect(registry.bench(sessionID: "s2") != nil)
        expectEqual(registry.entries.map(\.slot).sorted(), [1, 2, 3, 4, 5], "the gap closed")
        expect(registry.rebalance(now: start, isAlive: alwaysAlive).isEmpty)
        expectEqual(registry.waitingEntry(forSession: "s2")?.held, true)

        registry.setState(sessionID: "s2", to: .done, now: start)
        registry.setState(sessionID: "s2", to: .working, now: start)
        expect(registry.rebalance(now: start, isAlive: alwaysAlive).isEmpty, "a new turn is not a reason to return")
    }

    test("a session taken off by hand comes back when it asks for you") {
        var registry = busyBoard()
        registry.bench(sessionID: "s2")
        registry.setState(sessionID: "s2", to: .awaiting, pendingTool: "Bash", now: start)
        expectEqual(registry.waitingEntry(forSession: "s2")?.held, false)
        let placed = registry.rebalance(now: start, isAlive: alwaysAlive)
        expectEqual(placed.map(\.entry.sessionID), ["s2"])
        expectEqual(registry.entry(forSession: "s2")?.slot, 6)
    }

    test("taking off an orange key sticks until it asks again") {
        var registry = busyBoard()
        registry.setState(sessionID: "s3", to: .awaiting, now: start)
        registry.bench(sessionID: "s3")
        expect(registry.rebalance(now: start, isAlive: alwaysAlive).isEmpty, "it does not bounce straight back")
        registry.setState(sessionID: "s3", to: .working, now: start)
        registry.setState(sessionID: "s3", to: .awaiting, now: start)
        expectEqual(registry.rebalance(now: start, isAlive: alwaysAlive).map(\.entry.sessionID), ["s3"])
    }

    test("swapping by hand: the chosen session is pinned, the replaced one stays off") {
        var registry = busyBoard()
        _ = registry.claim(sessionID: "seven", state: .working, now: start, isAlive: alwaysAlive)
        _ = registry.claim(sessionID: "eight", state: .working, now: start, isAlive: alwaysAlive)

        let first = try Harness.require(registry.assign(sessionID: "seven", toSlot: 5, now: start))
        let second = try Harness.require(registry.assign(sessionID: "eight", toSlot: 6, now: start))
        expectEqual(first.displaced?.sessionID, "s5")
        expectEqual(second.displaced?.sessionID, "s6")
        expectEqual(registry.entry(forSlot: 5)?.sessionID, "seven")
        expectEqual(registry.entry(forSlot: 6)?.sessionID, "eight")
        expectEqual(registry.entry(forSlot: 5)?.pinned, true)
        expectEqual(registry.waitingEntry(forSession: "s5")?.held, true)

        // A free key goes to someone else, never back to what was swapped out.
        registry.release(sessionID: "s1")
        expect(registry.rebalance(now: start, isAlive: alwaysAlive).isEmpty)
        expectEqual(registry.entry(forSession: "seven")?.slot, 4, "pinned sessions still slide up")
    }

    test("a pinned key is never taken automatically") {
        var registry = busyBoard()
        registry.setState(sessionID: "s1", to: .done, now: start)
        _ = registry.assign(sessionID: "s1", toSlot: 1, now: start)
        _ = registry.claim(sessionID: "w", state: .working, now: start, isAlive: alwaysAlive)
        expect(registry.rebalance(now: start.addingTimeInterval(60 * minute), isAlive: alwaysAlive).isEmpty)
        expectEqual(registry.entry(forSlot: 1)?.sessionID, "s1")
    }

    test("putting a session on a free key takes the lowest free one") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", now: start, isAlive: alwaysAlive)
        _ = registry.claim(sessionID: "b", now: start, isAlive: alwaysAlive)
        registry.bench(sessionID: "b")
        let placed = try Harness.require(registry.assign(sessionID: "b", toSlot: 6, now: start))
        expectEqual(placed.entry.slot, 2)
        expect(placed.displaced == nil)
    }

    test("assigning a session already on a key moves and pins it") {
        var registry = busyBoard()
        let placed = try Harness.require(registry.assign(sessionID: "s4", toSlot: 1, now: start))
        expectEqual(placed.entry.slot, 1)
        expectEqual(registry.entry(forSession: "s1")?.slot, 4, "a swap, as a move is")
        expectEqual(registry.entry(forSession: "s4")?.pinned, true)
        expect(registry.waiting.isEmpty)
    }

    test("an action key or an unknown session is refused") {
        var registry = busyBoard()
        registry.reserve([3])
        expect(registry.assign(sessionID: "s3", toSlot: 3, now: start) == nil)
        expect(registry.assign(sessionID: "ghost", toSlot: 1, now: start) == nil)
        expect(registry.assign(sessionID: "s1", toSlot: 7, now: start) == nil)
    }

    test("a session only seen listed waits, held, until put on a key") {
        var registry = busyBoard()
        registry.release(sessionID: "s6")
        expect(registry.enlist(sessionID: "t3:listed", cwd: "/repo", entrypoint: "t3code", state: .done, now: start))
        expect(!registry.enlist(sessionID: "t3:listed", now: start), "already known")
        expect(!registry.enlist(sessionID: "s1", now: start), "already on a key")
        expect(registry.rebalance(now: start, isAlive: alwaysAlive).isEmpty, "a listed session never places itself")
        let placed = try Harness.require(registry.assign(sessionID: "t3:listed", toSlot: 6, now: start))
        expectEqual(placed.entry.slot, 6)
        expectEqual(placed.entry.state, .done)
    }

    // MARK: - what is worth listing

    test("only running, orange, or recently finished sessions are worth listing") {
        let worth = { (state: SessionState, minutes: Double) in
            SessionRegistry.isWorthListing(state, since: start, now: start.addingTimeInterval(minutes * minute))
        }
        for state in [SessionState.working, .background, .awaiting, .stalled] {
            expect(worth(state, 600), "\(state) is listed however long it has been")
        }
        expect(worth(.done, 29))
        expect(!worth(.done, 31), "half an hour on, a finished session is history")
        expect(worth(.error, 29))
        expect(!worth(.idle, 0), "idle is not active")
    }

    test("a freed key is not given to a session that finished long ago") {
        var registry = busyBoard()
        _ = registry.claim(sessionID: "stale-green", state: .done, now: start, isAlive: alwaysAlive)
        registry.release(sessionID: "s6")
        expect(registry.rebalance(now: start.addingTimeInterval(45 * minute), isAlive: alwaysAlive).isEmpty)
        expect(registry.entry(forSlot: 6) == nil)
        expect(registry.isKnown("stale-green"), "still known, so a new turn lists it again")
        registry.setState(sessionID: "stale-green", to: .working, now: start.addingTimeInterval(46 * minute))
        expectEqual(
            registry.rebalance(now: start.addingTimeInterval(46 * minute), isAlive: alwaysAlive).map(\.entry.sessionID),
            ["stale-green"]
        )
    }

    test("a dismissed session stays hidden through its turn, and returns on the next") {
        var registry = busyBoard()
        _ = registry.claim(sessionID: "w", state: .working, now: start, isAlive: alwaysAlive)
        expect(registry.dismiss(sessionID: "w"))
        expect(!registry.dismiss(sessionID: "s1"), "a key is taken off with bench, not dismissed")

        registry.release(sessionID: "s6")
        expect(registry.rebalance(now: start, isAlive: alwaysAlive).isEmpty, "a dismissed session takes no key")
        registry.setState(sessionID: "w", to: .done, now: start)
        expectEqual(registry.waitingEntry(forSession: "w")?.dismissed, true, "finishing is not a new turn")
        registry.setState(sessionID: "w", to: .working, now: start)
        expectEqual(registry.waitingEntry(forSession: "w")?.dismissed, false)
        expectEqual(registry.rebalance(now: start, isAlive: alwaysAlive).map(\.entry.sessionID), ["w"])
    }

    test("a dismissed session that asks for you comes back at once") {
        var registry = busyBoard()
        _ = registry.claim(sessionID: "w", state: .working, now: start, isAlive: alwaysAlive)
        registry.dismiss(sessionID: "w")
        registry.setState(sessionID: "w", to: .awaiting, now: start)
        expectEqual(registry.waitingEntry(forSession: "w")?.dismissed, false)
    }

    // MARK: - waiting sessions stay current

    test("a waiting session's state, details and death are all tracked") {
        var registry = busyBoard()
        _ = registry.claim(sessionID: "w", pid: 77, state: .working, now: start, isAlive: alwaysAlive)
        expect(registry.setState(sessionID: "w", to: .done, now: start) != nil)
        expectEqual(registry.waitingEntry(forSession: "w")?.state, .done)
        expect(registry.enrich(sessionID: "w", cwd: "/later"))
        expectEqual(registry.waitingEntry(forSession: "w")?.cwd, "/later")
        registry.adjustDelegation(sessionID: "w", event: "SubagentStart", agentID: "x")
        expectEqual(registry.waitingEntry(forSession: "w")?.delegatingAgentIDs, ["x"])
        expect(registry.isKnown("w"))
        expectEqual(registry.prune(isAlive: { $0 != 77 }), 1)
        expect(!registry.isKnown("w"), "a dead process is not listed either")
    }

    test("releasing a waiting session leaves every key where it was") {
        var registry = busyBoard()
        _ = registry.claim(sessionID: "w", state: .working, now: start, isAlive: alwaysAlive)
        let before = registry.entries
        expect(registry.release(sessionID: "w"))
        expectEqual(registry.entries, before)
        expect(!registry.isKnown("w"))
    }

    test("reset forgets waiting sessions too") {
        var registry = busyBoard()
        _ = registry.claim(sessionID: "w", state: .working, now: start, isAlive: alwaysAlive)
        registry.reset()
        expect(registry.waiting.isEmpty)
    }

    test("a muted surface's waiting sessions go with its keys") {
        var registry = busyBoard()
        _ = registry.claim(sessionID: "w", state: .working, now: start, isAlive: alwaysAlive)
        _ = registry.releaseUnlistened { _ in false }
        expect(registry.allEntries.isEmpty)
    }

    // MARK: - discovery

    test("discovering more sessions than keys parks the rest, once") {
        var registry = SessionRegistry()
        let found = (1...8).map {
            Discovery.Found(pid: 100 + $0, tty: "/dev/ttys00\($0)", cwd: "/p\($0)")
        }
        expectEqual(registry.reconnect(found, isAlive: alwaysAlive), 8)
        expectEqual(registry.entries.count, 6)
        expectEqual(registry.waiting.count, 2)
        expectEqual(registry.reconnect(found, isAlive: alwaysAlive), 0, "a waiting host is known")

        expect(registry.adoptRealSessionID("real", pid: 108, tty: nil))
        expectEqual(registry.waitingEntry(forSession: "real")?.pid, 108, "renamed in place, off the board")
        expectEqual(registry.allEntries.count, 8)
    }

    // MARK: - across a restart

    test("waiting sessions, pins and holds survive a restart") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-waiting-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        var registry = SessionRegistry()
        for i in 1...6 {
            _ = registry.claim(sessionID: "s\(i)", pid: i, state: .done, now: now, isAlive: alwaysAlive)
        }
        _ = registry.claim(sessionID: "w", pid: 7, state: .idle, now: now, isAlive: alwaysAlive)
        _ = registry.assign(sessionID: "w", toSlot: 3, now: now)
        _ = registry.claim(sessionID: "d", pid: 8, state: .working, now: now, isAlive: alwaysAlive)
        registry.dismiss(sessionID: "d")
        RegistryStore.save(registry, url: url)

        let loaded = RegistryStore.load(url: url, now: now, isAlive: alwaysAlive)
        expectEqual(loaded.entry(forSession: "w")?.slot, 3)
        expectEqual(loaded.entry(forSession: "w")?.pinned, true)
        expectEqual(loaded.waitingEntry(forSession: "s3")?.held, true)
        expectEqual(loaded.waitingEntry(forSession: "s3")?.slot, 0)
        expectEqual(loaded.waitingEntry(forSession: "d")?.dismissed, true)
        expectEqual(loaded.entries.count, 6)

        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        expect(!text.contains("\"pinned\" : false"), "an ordinary entry is written as it always was")
    }

    test("a registry written before waiting existed still loads") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-waiting-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = ISO8601DateFormatter().string(from: Date())
        let old = """
        {"version":1,"cursor":1,"entries":[{"slot":1,"sessionID":"a","pid":1,"state":"idle",
        "claimSeq":1,"claimedAt":"\(now)","updatedAt":"\(now)"}]}
        """
        try old.write(to: url, atomically: true, encoding: .utf8)
        let loaded = RegistryStore.load(url: url, isAlive: alwaysAlive)
        expectEqual(loaded.entries.map(\.sessionID), ["a"])
        expect(loaded.waiting.isEmpty)
    }
}

/**
 Where the off-board list comes from, beyond the registry: every T3 thread that may hold a
 key, and the desktop and Cursor chats touched recently. Listed, never placed by
 themselves — and a T3 thread put on a key by hand is tracked from then on.
 */
func runOffBoardSourceTests() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func thread(_ id: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var thread: [String: Any] = [
            "id": id, "projectId": "p1", "title": "Thread \(id)", "status": "idle",
            "latestRunId": "run-\(id)-1", "updatedAt": "2027-01-15T08:00:00.000Z",
        ]
        for (key, value) in fields { thread[key] = value }
        return thread
    }

    func snapshot(_ threads: [[String: Any]]) throws -> T3Code.ShellSnapshot {
        let object: [String: Any] = [
            "threads": threads,
            "projects": [["id": "p1", "title": "Repo", "workspaceRoot": "/repo"]],
        ]
        return try JSONDecoder().decode(
            T3Code.ShellSnapshot.self, from: try JSONSerialization.data(withJSONObject: object)
        )
    }

    test("every eligible T3 thread is listed, finished ones included") {
        var state = T3Code.State()
        let update = state.apply(try snapshot([
            thread("a", ["status": "running", "title": "Fix the ring"]),
            thread("b", ["status": "completed", "title": "Old work",
                         "latestRunCompletedAt": "2027-01-15T07:30:00.000Z"]),
            thread("c", ["settledOverride": "settled"]),
        ]), now: now)
        expectEqual(update.listed.map(\.threadID), ["a", "b"])
        expectEqual(update.listed.last?.phase, .done)
        expectEqual(update.listed.last?.project, "Repo")
        expectEqual(update.listed.last?.cwd, "/repo")
        expect(update.listed.last?.updatedAt != nil)
        expect(update.listed.last?.finishedAt != nil, "what half an hour counts from")
        expect(update.listed.first?.finishedAt == nil)
        expectEqual(update.emissions.map(\.threadID), ["a"], "listing claims nothing")
        expect(state.isPrimed)
        _ = state.reset()
        expect(!state.isPrimed, "given up on: nothing listed from it is still true")
    }

    test("a T3 thread put on a key by hand is tracked from its current phase") {
        var state = T3Code.State()
        _ = state.apply(try snapshot([thread("b", ["status": "completed"])]), now: now)
        expectEqual(state.track(sessionID: "t3:b"), .done)
        expect(state.track(sessionID: "t3:nope") == nil)
        let next = state.apply(try snapshot([thread("b", ["status": "running"])]), now: now)
        expectEqual(next.emissions.map(\.event), ["t3_working"], "its next change reaches the board")
        let settled = state.apply(try snapshot([thread("b", ["settledOverride": "settled"])]), now: now)
        expectEqual(settled.emissions.map(\.event), [T3Code.releasedEvent], "and settling frees its key")
    }

    test("recent Cursor chats are read newest first, without drafts or archived ones") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-cursor-\(UUID().uuidString).vscdb")
        defer { try? FileManager.default.removeItem(at: url) }
        expect(Cursor.readRecent(since: now, at: url) == nil, "no database is unknown")

        let fresh = "0b7c2f4e-1d3a-4c5b-9e8f-a1b2c3d4e5f6"
        let newer = "1b7c2f4e-1d3a-4c5b-9e8f-a1b2c3d4e5f6"
        let stale = "2b7c2f4e-1d3a-4c5b-9e8f-a1b2c3d4e5f6"
        let draft = "3b7c2f4e-1d3a-4c5b-9e8f-a1b2c3d4e5f6"
        let gone = "4b7c2f4e-1d3a-4c5b-9e8f-a1b2c3d4e5f6"
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        var db: OpaquePointer?
        expectEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let workspace = #"{"uri":{"fsPath":"/Users/x/repo"}}"#
        let sql = """
            CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, value TEXT, subagentTypeName TEXT);
            INSERT INTO composerHeaders VALUES ('\(fresh)', 'w', 0, \(ms + 1000), 0, 0, 0, 0, '{"name":"Fix the build","workspaceIdentifier":\(workspace)}', NULL);
            INSERT INTO composerHeaders VALUES ('\(newer)', 'w', 0, \(ms + 2000), 0, 0, 0, 0, '{"name":""}', NULL);
            INSERT INTO composerHeaders VALUES ('\(stale)', 'w', 0, \(ms - 1000), 0, 0, 0, 0, '{"name":"Old"}', NULL);
            INSERT INTO composerHeaders VALUES ('\(draft)', 'w', 0, \(ms + 3000), 0, 0, 0, 0, '{"name":"Draft","isDraft":true}', NULL);
            INSERT INTO composerHeaders VALUES ('\(gone)', 'w', 0, \(ms + 3000), 1, 0, 0, 0, '{"name":"Archived"}', NULL);
            """
        expectEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let recent = try Harness.require(Cursor.readRecent(since: now, at: url))
        expectEqual(recent.map(\.chatID), [newer, fresh])
        expect(recent.first?.name == nil, "an empty name is no name")
        expectEqual(recent.last?.name, "Fix the build")
        expectEqual(recent.last?.cwd, "/Users/x/repo")
    }

    test("recent desktop chats skip archived, old and unreadable records") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-desktop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let org = root.appendingPathComponent("account/org")
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        let since = Date().addingTimeInterval(-3600)
        let recentMs = Date().timeIntervalSince1970 * 1000
        func record(_ name: String, _ fields: [String: Any]) throws {
            var record: [String: Any] = [
                "sessionId": name, "cliSessionId": "cli-\(name)", "cwd": "/Users/x/repo",
                "title": "Chat \(name)", "isArchived": false, "lastActivityAt": recentMs,
            ]
            for (key, value) in fields { record[key] = value }
            try JSONSerialization.data(withJSONObject: record)
                .write(to: org.appendingPathComponent("\(name).json"))
        }
        try record("local_live", [:])
        try record("local_archived", ["isArchived": true])
        try record("local_quiet", ["lastActivityAt": since.timeIntervalSince1970 * 1000 - 1])
        try record("local_nocli", ["cliSessionId": ""])
        try "not json".write(to: org.appendingPathComponent("local_broken.json"), atomically: true, encoding: .utf8)

        let chats = ClaudeDesktop.recentChats(since: since, root: root)
        expectEqual(chats.map(\.hostSessionID), ["local_live"])
        expectEqual(chats.first?.sessionID, "cli-local_live", "keyed by the id its hooks report")
        expectEqual(chats.first?.title, "Chat local_live")
    }
}
