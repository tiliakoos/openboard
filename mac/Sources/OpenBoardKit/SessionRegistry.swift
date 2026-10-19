import Foundation

/**
 Which session owns which of the six keys.

 Ported from `lib/registry.cjs`, rule for rule. Deliberately a value type with pure
 transitions: every decision here is testable without a device, a session, or a clock,
 and each of these rules exists because of a specific way the board once lied.

 **Rebuilt from hooks.** `RegistryStore` saves it so keys survive a relaunch, but every
 entry is re-validated on load, and "Forget all sessions" is simply emptying it.

 **Six keys, more sessions.** A session that has reported but holds no key waits in
 `waiting` rather than being forgotten: a full board parks newcomers there, a freed key
 is filled from it, and the menu bar lists it so it can be put on a key by hand. Before
 this, a session that lost its key was dropped outright, and a T3 thread mid-run had no
 event left that could bring it back.
 */
public struct SessionRegistry: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var slot: Int
        public var sessionID: String
        public var cwd: String?
        public var pid: Int?
        /// Captured at claim time, not looked up later: the process may be gone when
        /// we want to raise its tab, and `ps` cannot resolve a tty for a dead pid.
        public var tty: String?
        /// Kept so a finished session's chat can still be named.
        public var transcriptPath: String?
        public var entrypoint: String?
        /// Which app owns the terminal this runs in. Captured once, because `ps` is not
        /// free and the answer cannot change for a live process.
        public var host: ProcessAncestry.Host = .unknown
        /// The Claude desktop app's own id for this session (`local_…`), which its
        /// `claude://code/continue` link takes. Persisted: a session restored after a
        /// relaunch could otherwise only raise the app until it next sent a hook.
        public var claudeDesktopSession: String? = nil
        public var state: SessionState
        /// Which tool is asking. The dialogs differ — an AskUserQuestion accepts
        /// Enter but ignores Escape — so "reject" is not universally possible and
        /// the caller needs to know rather than send a key into the void.
        public var pendingTool: String?
        /// Ids of this session's in-flight background work: subagents, tracked live by
        /// `SubagentStart`/`SubagentStop`, and every kind in `background_tasks`, set on
        /// each `Stop`. Non-empty at `Stop` paints `background`, not `done`. A *set*,
        /// not a bare count: a bare `Int` cannot distinguish "SubagentStop for an
        /// agent the last `Stop` reconcile already dropped" from "for one it still
        /// carries," which let a late-arriving `SubagentStop` decrement past a
        /// reconcile that had already removed that agent by other means — the
        /// hardware-observed race this field replaced a counter to fix.
        /// Removing an id that is not present is a documented no-op (`Set.remove`),
        /// which is exactly what kills that race. Not persisted (`RegistryStore.
        /// StoredEntry` omits it, same precedent as `pendingTool`) — on relaunch it
        /// starts empty and self-heals on the next `Stop`'s reconcile
        /// (`BoardController.handle`'s `Stop` branch). A resumed/forked CLI session
        /// can also leave the live set briefly stale; same self-heal applies.
        public var delegatingAgentIDs: Set<String> = []
        public var claimSeq: Int
        public var claimedAt: Date
        public var updatedAt: Date
        /// Put on its key by hand. Nothing automatic takes that key away, not even a
        /// session asking for you — you chose this one over the others.
        public var pinned: Bool = false
        /// Taken off the board by hand. Waits off it, and is never put back by itself,
        /// until it next asks for attention or you put it back.
        public var held: Bool = false
        /// Dismissed from the off-board list by hand: hidden, and never put on a key by
        /// itself, until it starts a new turn or asks for attention.
        public var dismissed: Bool = false

        public var id: String { sessionID }
    }

    /// `internal` setter, not `private`: Discovery extends this type from another
    /// file in the same module. Still closed to the app, which must go through the
    /// transitions rather than editing the board directly.
    public internal(set) var entries: [Entry] = []
    /// Sessions that have reported but hold no key. `slot` is 0 here.
    public internal(set) var waiting: [Entry] = []
    /// Monotonic, so "oldest claim" survives slots being reused.
    public private(set) var cursor = 0

    /// Restore the claim counter after loading from disk.
    ///
    /// Must never go backwards: `claimSeq` is what makes "oldest claim" meaningful, so
    /// a cursor behind the restored entries would hand the next session a sequence
    /// number that is already taken and make eviction pick the wrong key.
    mutating func restoreCursor(_ value: Int) {
        cursor = max(cursor, value)
    }
    public let slotCount: Int
    /// Agent keys bound to an action. Never given to a session.
    public private(set) var reserved: Set<Int> = []

    /// Silence long enough to assume a terminal was killed without SessionEnd firing.
    ///
    /// Configurable via `staleHours`; the default matches the Node version. Set on the
    /// instance rather than read globally so the pure transitions stay pure.
    public static let defaultStaleInterval: TimeInterval = 12 * 3600
    public var staleInterval: TimeInterval = SessionRegistry.defaultStaleInterval

    /**
     How long a finished key is left alone before a working session waiting for one
     may take it.

     Green means "this finished and you have not looked", so handing the key over the
     moment a turn ends would mean never seeing it. Ten minutes is long enough to notice
     and short enough that a finished chat does not hold a key a running one needs.
     */
    public static let finishedGrace: TimeInterval = 600

    /// How long a finished session stays worth listing off the board, and worth a freed
    /// key. Past this it is history, like the first T3 snapshot's old greens.
    public static let recentlyFinished: TimeInterval = 30 * 60

    /**
     Whether a session without a key is worth showing — and so worth a freed key: anything
     running or asking for you, or anything that finished or failed in the last
     `recentlyFinished`. Idle is not; neither is a turn that ended long ago.
     */
    public static func isWorthListing(_ state: SessionState, since: Date, now: Date) -> Bool {
        switch state {
        case .awaiting, .stalled, .working, .background: return true
        case .done, .error: return now.timeIntervalSince(since) < recentlyFinished
        case .idle, .viewing, .ended: return false
        }
    }

    /// Whether a change of state brings a dismissed session back: a new turn, or a
    /// question for you. Finishing the turn you dismissed it during does not.
    static func wakes(from old: SessionState, to new: SessionState) -> Bool {
        let (was, next) = (Standing(old), Standing(new))
        return next == .attention && was != .attention || next == .live && was < .live
    }

    public init(slotCount: Int = BoardLayout.slotCount) {
        self.slotCount = slotCount
    }

    // MARK: - lookup

    /// The session on a key. Nil for one that is waiting off the board.
    public func entry(forSession id: String) -> Entry? {
        entries.first { $0.sessionID == id }
    }

    public func waitingEntry(forSession id: String) -> Entry? {
        waiting.first { $0.sessionID == id }
    }

    /// On a key or waiting for one.
    public func known(forSession id: String) -> Entry? {
        entry(forSession: id) ?? waitingEntry(forSession: id)
    }

    public func isKnown(_ id: String) -> Bool { known(forSession: id) != nil }

    public var allEntries: [Entry] { entries + waiting }

    public func entry(forSlot slot: Int) -> Entry? {
        entries.first { $0.slot == slot }
    }

    /// All six slots in order, occupied or not.
    public func occupancy() -> [(slot: Int, entry: Entry?)] {
        (1...slotCount).map { ($0, entry(forSlot: $0)) }
    }

    // MARK: - liveness

    /// Does this pid still exist? `EPERM` counts as alive: the process is there, it
    /// just belongs to someone else.
    public static func processIsAlive(_ pid: Int?) -> Bool {
        guard let pid, pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /**
     A slot may be taken when its session has ended, its process is gone, or it has
     been silent long enough to assume a killed terminal.

     Liveness is checked independently of `SessionEnd` because that hook is not
     guaranteed to fire — closing a terminal window does not run it.
     */
    public func isReclaimable(
        _ entry: Entry,
        now: Date = Date(),
        isAlive: (Int?) -> Bool = SessionRegistry.processIsAlive
    ) -> Bool {
        if entry.state == .ended { return true }
        if let pid = entry.pid, !isAlive(pid) { return true }
        return now.timeIntervalSince(entry.updatedAt) > staleInterval
    }

    // MARK: - claiming

    public enum ClaimMode: String, Sendable {
        case kept          // already bound; state updated in place
        case sameHost      // same tab, new session id
        case unused
        case reclaimed
        case evicted       // took the key of a session that now waits off the board
        case waiting       // no key it may take; waits off the board
    }

    public struct ClaimResult: Sendable {
        /// The session on its key. Nil when it is waiting.
        public let entry: Entry?
        public let mode: ClaimMode
        /// Whoever gave the key up, now waiting off the board.
        public var displaced: Entry? = nil
    }

    /// A waiting session put on a key — by `rebalance`, or by hand.
    public struct Placement: Sendable, Equatable {
        public let entry: Entry
        public let mode: ClaimMode
        public let displaced: Entry?
    }

    /**
     How much a state is entitled to a key: asking for you, then running, then
     finished. A session only ever takes a key from one that ranks strictly lower, so two
     finished sessions can never trade a key back and forth.
     */
    public enum Standing: Int, Comparable, Sendable {
        case gone, finished, live, attention

        public init(_ state: SessionState) {
            switch state {
            case .awaiting, .stalled: self = .attention
            case .working, .background: self = .live
            case .idle, .viewing, .done, .error: self = .finished
            case .ended: self = .gone
            }
        }

        public static func < (a: Standing, b: Standing) -> Bool { a.rawValue < b.rawValue }
    }

    /// Off-board order, and the order a freed key is offered in: most urgent first, then
    /// the most recently active.
    public static func precedes(_ a: Entry, _ b: Entry) -> Bool {
        let (x, y) = (Standing(a.state), Standing(b.state))
        if x != y { return x > y }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.sessionID < b.sessionID
    }

    /**
     Whether `candidate` may take `occupant`'s key.

     Never a key put there by hand, and never one asking for attention — fail dark rather
     than steal the light you need in order to see. Otherwise only a strictly more urgent
     session may take it: one asking for you takes any other key, and a running one takes
     a finished key once that has been finished for `finishedGrace`.

     This replaced "evict the oldest key that is not orange", which let a thread that ran
     for fifty seconds take the key of one that had been working for half an hour.
     */
    public static func mayDisplace(_ occupant: Entry, for candidate: Entry, now: Date) -> Bool {
        guard !occupant.pinned, !occupant.state.isAttention else { return false }
        let mine = Standing(candidate.state), theirs = Standing(occupant.state)
        guard mine > theirs else { return false }
        if mine == .attention { return true }
        return theirs == .finished && now.timeIntervalSince(occupant.updatedAt) >= finishedGrace
    }

    /**
     Pick a key for `candidate`, in strict priority order:

     1. an unused slot number
     2. a reclaimable slot, oldest claim first
     3. a key it may displace (`mayDisplace`): the least urgent first — an orange takes a
        finished key before a working one — then the oldest claim

     Nil means it waits off the board.
     */
    private func pickSlot(
        for candidate: Entry, now: Date, isAlive: (Int?) -> Bool
    ) -> (slot: Int, mode: ClaimMode)? {
        for slot in 1...slotCount where entry(forSlot: slot) == nil && !reserved.contains(slot) {
            return (slot, .unused)
        }

        let byAge = { (a: Entry, b: Entry) in a.claimSeq < b.claimSeq }

        if let oldest = entries
            .filter({ isReclaimable($0, now: now, isAlive: isAlive) })
            .sorted(by: byAge).first {
            return (oldest.slot, .reclaimed)
        }

        if let victim = entries
            .filter({ Self.mayDisplace($0, for: candidate, now: now) })
            .sorted(by: { a, b in
                let (x, y) = (Standing(a.state), Standing(b.state))
                return x != y ? x < y : byAge(a, b)
            }).first {
            return (victim.slot, .evicted)
        }

        return nil
    }

    /// Put `entry` on `slot` as a fresh claim. An evicted occupant waits off the board; a
    /// reclaimed one is finished or gone, and is dropped as it always was.
    private mutating func seat(
        _ entry: Entry, at pick: (slot: Int, mode: ClaimMode), now: Date
    ) -> Placement {
        var entry = entry
        var displaced: Entry?
        if let index = entries.firstIndex(where: { $0.slot == pick.slot }) {
            let occupant = entries.remove(at: index)
            if pick.mode == .evicted {
                displaced = Self.parked(occupant)
                waiting.append(displaced!)
            }
        }
        cursor += 1
        entry.slot = pick.slot
        entry.claimSeq = cursor
        entry.claimedAt = now
        entries.append(entry)
        return Placement(entry: entry, mode: pick.mode, displaced: displaced)
    }

    private static func parked(_ entry: Entry, held: Bool = false) -> Entry {
        var entry = entry
        entry.slot = 0
        entry.pinned = false
        entry.held = held
        return entry
    }

    public mutating func claim(
        sessionID: String,
        cwd: String? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        transcriptPath: String? = nil,
        entrypoint: String? = nil,
        state: SessionState = .idle,
        now: Date = Date(),
        isAlive: (Int?) -> Bool = SessionRegistry.processIsAlive
    ) -> ClaimResult {
        // Already bound: keep the slot, refresh what may have moved. A resumed
        // session can live in a different tab than it started in.
        if let index = entries.firstIndex(where: { $0.sessionID == sessionID }) {
            entries[index].state = state
            entries[index].pid = pid ?? entries[index].pid
            entries[index].cwd = cwd ?? entries[index].cwd
            entries[index].tty = tty ?? entries[index].tty
            entries[index].transcriptPath = transcriptPath ?? entries[index].transcriptPath
            entries[index].updatedAt = now
            return ClaimResult(entry: entries[index], mode: .kept)
        }

        // Waiting: refresh it the same way, then see whether it may have a key now.
        if let index = waiting.firstIndex(where: { $0.sessionID == sessionID }) {
            if state.isAttention, !waiting[index].state.isAttention { waiting[index].held = false }
            if Self.wakes(from: waiting[index].state, to: state) { waiting[index].dismissed = false }
            waiting[index].state = state
            waiting[index].pid = pid ?? waiting[index].pid
            waiting[index].cwd = cwd ?? waiting[index].cwd
            waiting[index].tty = tty ?? waiting[index].tty
            waiting[index].transcriptPath = transcriptPath ?? waiting[index].transcriptPath
            waiting[index].updatedAt = now
            guard !waiting[index].held, !waiting[index].dismissed,
                  let pick = pickSlot(for: waiting[index], now: now, isAlive: isAlive)
            else { return ClaimResult(entry: nil, mode: .waiting) }
            let candidate = waiting.remove(at: index)
            let placed = seat(candidate, at: pick, now: now)
            return ClaimResult(entry: placed.entry, mode: placed.mode, displaced: placed.displaced)
        }

        /*
         One tab, one key.

         `/clear` mints a fresh session_id inside the same process, and so can a
         resume. Without this a single tab burns another key every time and the board
         fills with dead entries for a window you never left.

         Only a genuinely finished or gone session's slot is reused — otherwise this
         would steal a key from a live session sharing the tty.
         */
        let sameHost = entries.first { candidate in
            candidate.sessionID != sessionID
                && ((tty != nil && candidate.tty == tty) || (pid != nil && candidate.pid == pid))
                && isReclaimable(candidate, now: now, isAlive: isAlive)
        }

        let entry = Entry(
            slot: 0,
            sessionID: sessionID,
            cwd: cwd,
            pid: pid,
            tty: tty,
            transcriptPath: transcriptPath,
            entrypoint: entrypoint,
            state: state,
            pendingTool: nil,
            claimSeq: 0,
            claimedAt: now,
            updatedAt: now
        )

        let pick: (slot: Int, mode: ClaimMode)
        if let sameHost {
            pick = (sameHost.slot, .sameHost)
        } else if let chosen = pickSlot(for: entry, now: now, isAlive: isAlive) {
            pick = chosen
        } else {
            waiting.append(entry)
            return ClaimResult(entry: nil, mode: .waiting)
        }
        let placed = seat(entry, at: pick, now: now)
        return ClaimResult(entry: placed.entry, mode: placed.mode, displaced: placed.displaced)
    }

    /**
     Give waiting sessions the keys they may have, most urgent first.

     Run after anything that can free a key or change who is entitled to one: a release,
     a state change, and on the resident loop, which is what lets a finished key's grace
     run out. A session taken off (`held`) or dismissed by hand is skipped, and so is one
     not worth listing (`isWorthListing`): a freed key goes to something you would see.

     Terminates: every placement either fills a free key, drops a dead entry, or moves a
     strictly lower-standing session off the board.
     */
    @discardableResult
    public mutating func rebalance(
        now: Date = Date(),
        isAlive: (Int?) -> Bool = SessionRegistry.processIsAlive
    ) -> [Placement] {
        var placed: [Placement] = []
        for _ in 0..<(slotCount * 4 + waiting.count) {
            let order = waiting.indices
                .filter {
                    !waiting[$0].held && !waiting[$0].dismissed
                        && Self.isWorthListing(waiting[$0].state, since: waiting[$0].updatedAt, now: now)
                }
                .sorted { Self.precedes(waiting[$0], waiting[$1]) }
            var next: (index: Int, pick: (slot: Int, mode: ClaimMode))?
            for index in order {
                if let pick = pickSlot(for: waiting[index], now: now, isAlive: isAlive) {
                    next = (index, pick)
                    break
                }
            }
            guard let next else { break }
            let candidate = waiting.remove(at: next.index)
            placed.append(seat(candidate, at: next.pick, now: now))
        }
        return placed
    }

    // MARK: - transitions

    /// Edit a known session in place, on a key or waiting.
    private mutating func update<T>(_ sessionID: String, _ change: (inout Entry) -> T) -> T? {
        if let index = entries.firstIndex(where: { $0.sessionID == sessionID }) {
            return change(&entries[index])
        }
        if let index = waiting.firstIndex(where: { $0.sessionID == sessionID }) {
            return change(&waiting[index])
        }
        return nil
    }

    /// Update a known session, on a key or waiting. Never allocates — an unknown session
    /// is ignored rather than given a key, or every stray event would claim one.
    @discardableResult
    public mutating func setState(
        sessionID: String,
        to state: SessionState,
        pendingTool: String? = nil,
        now: Date = Date()
    ) -> Entry? {
        update(sessionID) { entry in
            guard SessionState.mayReplace(entry.state, with: state) else { return entry }
            // Asking for you again outranks having been taken off by hand.
            if state.isAttention, !entry.state.isAttention { entry.held = false }
            if Self.wakes(from: entry.state, to: state) { entry.dismissed = false }
            entry.state = state
            if let pendingTool { entry.pendingTool = pendingTool }
            // Leaving an attention state means nothing is pending any more.
            if !state.isAttention { entry.pendingTool = nil }
            entry.updatedAt = now
            return entry
        }
    }

    @discardableResult
    public mutating func markEnded(sessionID: String, now: Date = Date()) -> Entry? {
        setState(sessionID: sessionID, to: .ended, now: now)
    }

    /// Insert or remove `agentID` from `delegatingAgentIDs` for `SubagentStart`/
    /// `SubagentStop`. Never allocates — mirrors `setState`'s own rule: an unknown
    /// `sessionID` is ignored rather than given a key, so a subagent event can never
    /// claim a slot. Removing an id not currently in the set (a duplicate
    /// `SubagentStop`, or one for an agent a prior `Stop` reconcile already dropped)
    /// is a no-op, not an error — this is the fix for the hardware-observed race
    /// a bare counter could not express.
    ///
    /// **Missing `agent_id` degrade:** if `agentID` is `nil` or empty, the event is
    /// ignored for set purposes — deliberately, not a placeholder id. An unmatchable
    /// insert could never be removed by its own `SubagentStop` (there is no id to
    /// match), so it would only ever be cleaned up by the next `Stop`'s authoritative
    /// reconcile anyway; skipping the insert here changes nothing about correctness
    /// and avoids fabricating an id that was never observed.
    @discardableResult
    public mutating func adjustDelegation(
        sessionID: String, event: String, agentID: String?
    ) -> Entry? {
        update(sessionID) { entry in
            guard let agentID, !agentID.isEmpty else { return entry }
            switch event {
            case "SubagentStart":
                entry.delegatingAgentIDs.insert(agentID)
            case "SubagentStop":
                entry.delegatingAgentIDs.remove(agentID)
            default:
                break
            }
            return entry
        }
    }

    /// Authoritative reconcile of `delegatingAgentIDs`, called on every `Stop`.
    /// Replaces the set wholesale with `ids` — never trusted as a running total
    /// across `Stop`s (proven necessary by out-of-order-finish and non-head array
    /// removal, and by the late-`SubagentStop` race `adjustDelegation` alone cannot
    /// resolve). Never allocates, same rule as `setState`/`adjustDelegation`.
    @discardableResult
    public mutating func reconcileDelegation(sessionID: String, ids: [String]) -> Entry? {
        update(sessionID) { entry in
            entry.delegatingAgentIDs = Set(ids)
            return entry
        }
    }

    /// Drop entries whose process is gone, on a key or waiting. A dead session holding a
    /// key makes the board claim activity that does not exist — the exact failure this
    /// project is meant to avoid.
    @discardableResult
    public mutating func prune(
        now: Date = Date(),
        isAlive: (Int?) -> Bool = SessionRegistry.processIsAlive
    ) -> Int {
        let dead = allEntries.filter { $0.pid != nil && !isAlive($0.pid) }.map(\.sessionID)
        for sessionID in dead { release(sessionID: sessionID) }
        return dead.count
    }

    /**
     Age transient states back to rest.

     ## `done` does not expire by default

     Green means *this finished and you have not been back yet*. It is cleared by
     returning to the session and sending something — `UserPromptSubmit` moves it to
     `working` — not by a timer.

     An earlier version aged it out after 90s on the reasoning that green stops meaning
     anything if it is permanent. That reasoning was wrong about which failure costs
     more: a session that finished while you were elsewhere is exactly the one you need
     to be told about, and a timer means the board quietly forgets it before you look.
     The result was finished work becoming invisible, which is the opposite of the job.
     Six keys is a small enough board that "several are green" is information, not noise.

     Set `doneDecaySeconds` above zero to bring the timer back.

     `awaiting` is held by default and expires only when asked to. The hooks already
     clear it the moment the prompt is answered — `PostToolUse` arriving *is* the answer
     — so the timer was a safety net for a prompt answered somewhere OpenBoard cannot
     see. That is rare enough to be a choice rather than a permanent quiet deadline, and
     it was expressed as a duration in minutes, which is the wrong question to ask
     someone: nobody knows how long they want to wait for a thing that should not happen.

     `holdAttention: false` brings the net back, at a fixed 15 minutes. There is no
     slider, because the number never earned one.
     */
    public static let attentionTimeout: TimeInterval = 900

    @discardableResult
    public mutating func decay(
        doneAfter: TimeInterval = 0,
        holdAttention: Bool = true,
        now: Date = Date()
    ) -> Int {
        func age(_ entry: inout Entry) -> Bool {
            let age = now.timeIntervalSince(entry.updatedAt)
            switch entry.state {
            // Zero, or anything below it, means never — the key holds until you go back.
            case .done where doneAfter > 0 && age > doneAfter:
                entry.state = .idle
                return true
            case .awaiting, .stalled:
                guard !holdAttention, age > Self.attentionTimeout else { return false }
                entry.state = .idle
                entry.pendingTool = nil
                return true
            default:
                return false
            }
        }
        var changed = 0
        for index in entries.indices { if age(&entries[index]) { changed += 1 } }
        for index in waiting.indices { if age(&waiting[index]) { changed += 1 } }
        return changed
    }

    /**
     Fill in details the entry does not have yet.

     Only ever *adds*. An entry can reach the board without them — discovered from the
     process table, or restored from disk written before a field existed — and every
     later hook takes the ordinary state-change path, which never revisits them. So a
     session could stay permanently unnamed while hooks for it arrived normally.

     Existing values are never overwritten: a hook that omits a field must not blank
     what is already known, and a `cwd` captured at claim time is as good as a later one.
     */
    @discardableResult
    public mutating func enrich(
        sessionID: String,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        entrypoint: String? = nil,
        tty: String? = nil,
        pid: Int? = nil,
        claudeDesktopSession: String? = nil
    ) -> Bool {
        update(sessionID) { entry in
            var changed = false
            // Replaced rather than only filled: it is the app's to assign, and the newest
            // report is the one its link will accept.
            if let claudeDesktopSession, entry.claudeDesktopSession != claudeDesktopSession {
                entry.claudeDesktopSession = claudeDesktopSession
                changed = true
            }
            if entry.cwd == nil, let cwd { entry.cwd = cwd; changed = true }
            if entry.transcriptPath == nil, let transcriptPath {
                entry.transcriptPath = transcriptPath
                changed = true
            }
            if entry.entrypoint == nil, let entrypoint {
                entry.entrypoint = entrypoint
                changed = true
            }
            if entry.tty == nil, let tty { entry.tty = tty; changed = true }
            if entry.pid == nil, let pid { entry.pid = pid; changed = true }
            // Asked once, when the pid first arrives: `ps` is not free, and which app
            // owns a live process cannot change.
            if entry.host == .unknown, let pid = entry.pid {
                let host = ProcessAncestry.host(ofPID: pid)
                if host != .unknown { entry.host = host; changed = true }
            }
            return changed
        } ?? false
    }

    /**
     Give up the keys held by surfaces the board is no longer listening to.

     Needed because muting is retroactive. A switch that only stopped *future* sessions
     would leave the ones already on the board sitting there until they ended, which
     reads as the switch not working — and the keys are the whole point of muting, so
     leaving them occupied is the one outcome that makes the setting pointless.

     Only entries whose host is actually known are touched. `.unknown` is always
     listened to (see `Preferences.listens(to:)`), so a session whose owner could not be
     resolved is never silently swept off the board.

     - Returns: the slots freed, for the log — a key vanishing is worth being able to
       explain afterwards.
     */
    @discardableResult
    public mutating func releaseUnlistened(
        isListening: (ProcessAncestry.Host) -> Bool
    ) -> [Int] {
        waiting.removeAll { !isListening($0.host) }
        let doomed = entries.filter { !isListening($0.host) }
        guard !doomed.isEmpty else { return [] }
        let slots = doomed.map(\.slot).sorted()
        let ids = Set(doomed.map(\.sessionID))
        entries.removeAll { ids.contains($0.sessionID) }
        return slots
    }

    /**
     Forget one session, on a key or waiting. A key's gap closes with the sessions on
     later keys, in slot order. Earlier keys and reserved action keys stay put. Only slots
     change: session state, metadata, timestamps and claim order travel with their session.

     The cursor is deliberately not rewound: eviction still depends on claim age. Nothing
     is put on the freed key here — `rebalance` does that.
     */
    @discardableResult
    public mutating func release(sessionID: String) -> Bool {
        if let index = waiting.firstIndex(where: { $0.sessionID == sessionID }) {
            waiting.remove(at: index)
            return true
        }
        guard let index = entries.firstIndex(where: { $0.sessionID == sessionID }) else {
            return false
        }
        _ = removeFromBoard(at: index)
        return true
    }

    /// Take an entry off its key and close the gap behind it.
    private mutating func removeFromBoard(at index: Int) -> Entry {
        let removed = entries.remove(at: index)
        var nextSlot = removed.slot
        for index in entries.indices.sorted(by: { entries[$0].slot < entries[$1].slot })
            where entries[index].slot > removed.slot {
            while reserved.contains(nextSlot) { nextSlot += 1 }
            entries[index].slot = nextSlot
            nextSlot += 1
        }
        return removed
    }

    /**
     Take a session off the board by hand. It keeps running and stays listed, waiting,
     and is not put back by itself until it next asks for attention — the gap closes and
     `rebalance` offers the key to someone else.
     */
    @discardableResult
    public mutating func bench(sessionID: String) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.sessionID == sessionID }) else {
            return nil
        }
        let benched = Self.parked(removeFromBoard(at: index), held: true)
        waiting.append(benched)
        return benched
    }

    /**
     Put a waiting session on a key by hand, and pin it there.

     Onto an occupied key it is a swap with the board: whoever held it waits off the board
     and, being taken off by hand, stays off until put back. Onto a free key it takes the
     lowest free key instead, so keys still fill in order. A session already on a key is
     moved there (a swap, like `move`) and pinned.
     */
    @discardableResult
    public mutating func assign(sessionID: String, toSlot: Int, now: Date = Date()) -> Placement? {
        guard (1...slotCount).contains(toSlot), !reserved.contains(toSlot) else { return nil }
        if entry(forSession: sessionID) != nil {
            guard move(sessionID: sessionID, toSlot: toSlot),
                  let index = entries.firstIndex(where: { $0.sessionID == sessionID })
            else { return nil }
            entries[index].pinned = true
            return Placement(entry: entries[index], mode: .kept, displaced: nil)
        }
        guard let index = waiting.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        var entry = waiting.remove(at: index)
        let target = self.entry(forSlot: toSlot) != nil
            ? toSlot
            : (1...slotCount).first { self.entry(forSlot: $0) == nil && !reserved.contains($0) } ?? toSlot
        var displaced: Entry?
        if let occupant = entries.firstIndex(where: { $0.slot == target }) {
            displaced = Self.parked(entries.remove(at: occupant), held: true)
            waiting.append(displaced!)
        }
        cursor += 1
        entry.slot = target
        entry.pinned = true
        entry.held = false
        entry.dismissed = false
        entry.claimSeq = cursor
        entry.claimedAt = now
        entries.append(entry)
        return Placement(entry: entry, mode: displaced == nil ? .unused : .evicted, displaced: displaced)
    }

    /// Hide a waiting session from the off-board list until it starts a new turn or asks
    /// for attention. Only a waiting one: a session on a key is taken off with `bench`.
    @discardableResult
    public mutating func dismiss(sessionID: String) -> Bool {
        guard let index = waiting.firstIndex(where: { $0.sessionID == sessionID }) else { return false }
        waiting[index].dismissed = true
        return true
    }

    /**
     Make a session the board has only seen listed — a T3 thread, a desktop or Cursor chat
     — known, waiting, so it can be put on a key by hand. Held, so it goes nowhere by
     itself. False if it is already known.
     */
    @discardableResult
    public mutating func enlist(
        sessionID: String,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        entrypoint: String? = nil,
        claudeDesktopSession: String? = nil,
        state: SessionState = .idle,
        now: Date = Date()
    ) -> Bool {
        guard !isKnown(sessionID) else { return false }
        var entry = Entry(
            slot: 0, sessionID: sessionID, cwd: cwd, pid: nil, tty: nil,
            transcriptPath: transcriptPath, entrypoint: entrypoint,
            claudeDesktopSession: claudeDesktopSession,
            state: state, pendingTool: nil, claimSeq: 0, claimedAt: now, updatedAt: now
        )
        entry.held = true
        waiting.append(entry)
        return true
    }

    /**
     Put a session on a different key.

     Slots are sticky, which is right until two sessions in one project land either side
     of another project's key. This is the manual fix: the session takes `toSlot`, and
     whatever held `toSlot` takes the vacated key — a swap, so the other four keys keep
     their muscle memory. Moving onto a free key simply frees the old one, which the
     next new session then takes (`pickSlot` prefers an unused slot).

     Changes `slot` and nothing else. Not `updatedAt`: a move is not activity, and
     bumping it would reset done-decay and the stale window. Not `claimSeq`: eviction
     order is about age, not position. An `awaiting` session may be moved — the
     "never take an attention key" rule is about eviction, and a swap loses nothing.
     */
    @discardableResult
    public mutating func move(sessionID: String, toSlot: Int) -> Bool {
        guard (1...slotCount).contains(toSlot), !reserved.contains(toSlot),
              let index = entries.firstIndex(where: { $0.sessionID == sessionID })
        else { return false }
        let fromSlot = entries[index].slot
        if let other = entries.firstIndex(where: { $0.slot == toSlot }) {
            entries[other].slot = fromSlot
        }
        entries[index].slot = toSlot
        return true
    }

    /// Take `slots` away from sessions. One already on such a key moves to a free one,
    /// or waits off the board.
    public mutating func reserve(_ slots: Set<Int>) {
        reserved = slots
        for index in entries.indices where slots.contains(entries[index].slot) {
            if let free = (1...slotCount).first(where: {
                !slots.contains($0) && entry(forSlot: $0) == nil
            }) {
                entries[index].slot = free
            }
        }
        waiting += entries.filter { slots.contains($0.slot) }.map { Self.parked($0) }
        entries.removeAll { slots.contains($0.slot) }
    }

    /// Forget everything. The registry is rebuilt from hooks, so this is the whole operation.
    public mutating func reset() {
        entries.removeAll()
        waiting.removeAll()
        cursor = 0
    }
}

// MARK: - event mapping

/**
 Which state a hook event means.

 Ported from `lib/render.cjs`. A muted event returns nil exactly like an unrecognised
 one — muting is a supported configuration, not a failure.
 */
public enum EventMapper {
    /// Notification subtypes that mean a human is being asked for something.
    ///
    /// `idle_prompt` is deliberately unmapped: it fires when a session has merely been
    /// sitting there, and mapping it lights the attention color with nothing to act
    /// on — which teaches you to ignore the one color that must never be ignored.
    public static let defaultNotifications: [String: SessionState] = [
        "permission_prompt": .awaiting,
        "agent_needs_input": .awaiting,
        "elicitation_dialog": .awaiting,
    ]

    /// Events that only mean anything as an attention-clear. Repainting on every one
    /// would write to the device on every tool call in every session.
    public static let clearsAttention: Set<String> = ["PostToolUse", "PostToolUseFailure"]

    public static func state(
        for event: String,
        matcher: String? = nil,
        enabledEvents: [String: Bool] = [:],
        notifications: [String: SessionState] = defaultNotifications
    ) -> SessionState? {
        if enabledEvents[event] == false { return nil }

        switch event {
        case "SessionStart":
            return .idle
        // Fires the instant a prompt appears. The Notification that also means
        // "awaiting" arrives ~6s later, measured — so this is what turns the key
        // orange promptly rather than after a visible lag.
        case "PermissionRequest":
            return .awaiting
        case "UserPromptSubmit":
            return .working
        case "Stop":
            return .done
        case "StopFailure":
            return .error
        case "SessionEnd":
            return .ended
        case "PostToolUse", "PostToolUseFailure":
            return .working

        /*
         Hermes Agent.

         Its shell hooks pipe JSON to stdin with `hook_event_name`, `session_id`, `cwd`
         and `tool_name` — the same four fields Claude Code sends, which is why the
         socket and the helper needed no changes at all. Only the names differ, and
         names are what this function is for.

         `pre_approval_request` is the one that matters. It is the whole product: the
         moment a session stops and waits for a human. Hermes fires it "before an
         approval decision is requested", and `post_approval_response` afterwards, which
         is the clear.
        */
        case "on_session_start":
            return .idle
        case "pre_tool_call", "post_tool_call", "post_approval_response":
            return .working
        case "pre_approval_request":
            return .awaiting
        case "on_session_end", "on_session_finalize":
            return .ended

        /*
         Pi.

         In-process TypeScript rather than shell hooks, so the extension does the
         forwarding — but it forwards the same shape, and these are its event names.
         `turn_end` is the one Claude calls `Stop`: a turn finished and nobody has been
         back to look at it yet.
        */
        case "turn_start", "agent_start":
            return .working
        case "turn_end", "agent_settled":
            return .done
        case "session_start":
            return .idle
        case "session_shutdown":
            return .ended

        /*
         T3 Code.

         Not hooks: `T3Code` reads T3's server and synthesizes these, one per change in
         a thread's phase. Named apart from Claude's so muting one harness's event in
         the pane never mutes the other's.
        */
        case "t3_working":
            return .working
        case "t3_awaiting":
            return .awaiting
        case "t3_done":
            return .done
        case "t3_background":
            return .background
        case "t3_error":
            return .error
        case "t3_idle":
            return .idle
        case "t3_released":
            return .ended

        /*
         Cursor.

         Cursor's own hook names, translated by `Cursor` — its `stop` alone can mean done,
         error or stopped-by-you — and its pending state read from its chat headers. Named
         apart from Claude's for the same reason as T3's.
        */
        case "cursor_working":
            return .working
        case "cursor_awaiting":
            return .awaiting
        case "cursor_done":
            return .done
        case "cursor_error":
            return .error
        case "cursor_idle":
            return .idle
        case "cursor_released":
            return .ended
        case "Notification":
            guard let matcher else { return nil }
            // Anything absent is not per-session status — agent_completed and
            // auth_success are about the app, not about a key.
            return notifications[matcher]
        default:
            return nil
        }
    }

    /**
     Whether a mapped state must be dropped rather than applied, because it descends
     from an `idle_prompt` Notification while the session is delegating.

     `idle_prompt` fires on an idle *timer* (Claude Code's own ~60s "still there?"
     check), not a real user-idle signal — the same reason `defaultNotifications`
     deliberately omits it above. Left unmapped in a fresh config it is harmless, but a
     user who remaps it to *any* state (commonly `.idle`) turns that timer into a false
     demotion: it fires well inside a delegating session's `.background` window and,
     since `mayReplace` guards only against `idle`, a remap to any other state repaints
     the purple key with no warning.

     Keyed on the **subtype**, not the mapped state, because the remap is
     user-controlled — suppressing only when the mapped state happens to equal `.idle`
     would miss a user who remapped `idle_prompt` to some other color, and the false
     signal is the subtype firing at all, not which color it happened to land on this
     machine.

     Scoped to `idle_prompt` alone: `permission_prompt`/`agent_needs_input`/
     `elicitation_dialog` are real attention signals and must keep winning their orange
     precedence over a delegating `.background`, delegating or not.
     */
    public static func suppressesDelegating(
        eventName: String,
        matcher: String?,
        delegatedCount: Int
    ) -> Bool {
        eventName == "Notification" && matcher == "idle_prompt" && delegatedCount > 0
    }
}
