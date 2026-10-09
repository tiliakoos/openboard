import Foundation
import SQLite3

/**
 Cursor's own Agent chats — not Claude Code running inside Cursor, which reports as
 `claude-vscode` like any VS Code session.

 Their status arrives as hooks without anything being installed for it: Cursor imports
 the hooks in `~/.claude/settings.json`, so `openboard-hook` already runs for every chat.
 It runs with Cursor's payload rather than Claude's — `conversation_id`,
 `cursor_version`, lowercase event names, and no `CLAUDE_CODE_ENTRYPOINT`, which is why
 these were refused as an unknown entrypoint until now. The import has no counterpart
 for `PermissionRequest` or `Notification`, so the one state hooks cannot carry — a chat
 waiting on you — is read from Cursor's own chat headers instead.

 The same shape as `T3Code`: Cursor's events and headers go in, synthesized `cursor_*`
 events come out, and those go through `BoardController.handle` like any hook — so slots,
 stickiness and the "never steal an orange key" rule are the registry's. A chat id is
 Cursor's composer id, which is also what its transcript is named after, what its Agents
 window selects by, and what it records as the chat on screen.
 */
public enum Cursor {
    public static let bundleID = "com.todesktop.230313mzl4w4u92"
    public static let harnessID = "cursor"
    public static let entrypoint = "cursor"
    /// Prefixed so a chat id can never collide with a Claude session id or a T3 thread.
    public static let sessionPrefix = "cursor:"
    public static let releasedEvent = "cursor_released"

    public enum Phase: String, Sendable, Equatable {
        case working, awaiting, done, error, idle

        public var eventName: String { "cursor_\(rawValue)" }
    }

    /// Composer ids are UUIDs. Checked before one goes into a query or a link.
    public static func isChatID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// The chat behind a session id, or nil for a session that is not a Cursor chat.
    public static func chatID(fromSession sessionID: String) -> String? {
        guard sessionID.hasPrefix(sessionPrefix) else { return nil }
        return String(sessionID.dropFirst(sessionPrefix.count))
    }

    /// Whether a hook payload is Cursor's own rather than Claude Code's.
    public static func isHookPayload(_ raw: [String: Any]) -> Bool {
        raw["cursor_version"] is String
    }

    // MARK: - what the board is told

    /// One synthesized hook event.
    public struct Emission: Sendable, Equatable {
        public let chatID: String
        public let event: String
        public let cwd: String?
        /// Only a prompt typed into a chat takes a key. Everything else updates one that
        /// is already there, so a chat you only scroll past never lands on the board.
        public let claims: Bool

        public var sessionID: String { Cursor.sessionPrefix + chatID }

        /// The payload `HookServer.Event(raw:)` takes. Nothing of Cursor's own payload
        /// is carried over — not the prompt, and not the `user_email` every event has.
        public var payload: [String: Any] {
            var raw: [String: Any] = [
                "hook_event_name": event,
                "session_id": sessionID,
                "harness": Cursor.harnessID,
                "entrypoint": Cursor.entrypoint,
            ]
            if let cwd { raw["cwd"] = cwd }
            return raw
        }
    }

    /// The parts of a chat's header row the board reads.
    public struct Header: Sendable, Equatable {
        public let name: String?
        public let isArchived: Bool
        public let isSubagent: Bool
        /// Blocked on you: a pending action, or a plan waiting to be built.
        public let isPending: Bool

        public init(name: String?, isArchived: Bool, isSubagent: Bool, isPending: Bool) {
            self.name = name
            self.isArchived = isArchived
            self.isSubagent = isSubagent
            self.isPending = isPending
        }
    }

    public struct Update: Sendable, Equatable {
        public var emissions: [Emission] = []
        /// Chat names by session id, for every chat on the board that has one.
        public var titles: [String: String] = [:]
    }

    /**
     What the board knows about Cursor's chats between two events.

     Kept only for chats on the board — `apply` drops the rest — so a long day of Cmd-K
     prompts, which fire the same events under ids of their own, cannot grow it.
     */
    public struct State: Sendable, Equatable {
        /// The phase last told to the board, per chat.
        var phases: [String: Phase] = [:]
        /// The pending flag as last read, per chat. Absent until the first read after a
        /// claim, which only sets the baseline: a flag left behind by an old turn must not
        /// turn a key orange.
        var pending: [String: Bool] = [:]
        /// Chats whose header has been read at least once. A row missing after that was
        /// deleted; a row missing before it may simply not be written yet.
        var seen: Set<String> = []
        /// What an orange chat was before it asked, to go back to once it is answered.
        var beneath: [String: Phase] = [:]

        public init() {}

        /**
         One of Cursor's hook events, as the board's event — or nil when it is not
         Cursor's, is not about a chat, or changes nothing.

         Only the events Cursor's import of Claude's hooks actually forwards are read:
         `beforeSubmitPrompt`, `postToolUse`, `stop` and `sessionEnd`. `sessionStart`
         fires whenever a chat loads, including ones you only click past, so it claims
         nothing.
         */
        public mutating func receive(_ raw: [String: Any]) -> Emission? {
            guard Cursor.isHookPayload(raw),
                  let id = raw["conversation_id"] as? String, Cursor.isChatID(id)
            else { return nil }
            let cwd = (raw["workspace_roots"] as? [String])?.first

            let phase: Phase
            var claims = false
            switch raw["hook_event_name"] as? String {
            case "beforeSubmitPrompt":
                // Cmd-K's inline prompt fires this too, under its prompt bar's id. Only a
                // chat's carries its mode.
                guard raw["composer_mode"] != nil else { return nil }
                phase = .working
                claims = true
            case "postToolUse":
                // Every tool call fires this. Repeating "working" would repaint the pad on
                // each one; only a change is worth telling the board about.
                guard phases[id] != .working else { return nil }
                phase = .working
            case "stop":
                switch raw["status"] as? String {
                case "completed": phase = .done
                case "error": phase = .error
                // Stopped by you: neither a success nor a failure.
                case "aborted": phase = .idle
                default: return nil
                }
            case "sessionEnd":
                // The chat was closed — its tab, or the window. Archiving and deleting
                // are read from its header instead (`apply`).
                forget(id)
                return Emission(chatID: id, event: Cursor.releasedEvent, cwd: nil, claims: false)
            default:
                return nil
            }
            phases[id] = phase
            return Emission(chatID: id, event: phase.eventName, cwd: cwd, claims: claims)
        }

        /**
         The headers of the chats on the board, as read just now.

         Nil means they could not be read, which changes nothing: an unreadable database
         is not every chat deleted. A rising pending flag is orange; a falling one goes
         back to what the chat was before it asked — a plan waiting after its turn ended
         has a green underneath, not blue — unless a hook has moved it on since.
         */
        public mutating func apply(_ headers: [String: Header]?, onBoard: [String]) -> Update {
            let board = Set(onBoard)
            phases = phases.filter { board.contains($0.key) }
            pending = pending.filter { board.contains($0.key) }
            beneath = beneath.filter { board.contains($0.key) }
            seen = seen.intersection(board)

            var update = Update()
            guard let headers else { return update }
            for id in onBoard.sorted() {
                guard let header = headers[id] else {
                    if seen.contains(id) { update.emissions.append(release(id)) }
                    continue
                }
                seen.insert(id)
                // A subagent should never have claimed a key; if one did, it goes.
                if header.isArchived || header.isSubagent {
                    update.emissions.append(release(id))
                    continue
                }
                if let name = header.name, !name.isEmpty {
                    update.titles[Cursor.sessionPrefix + id] = name
                }
                let was = pending[id]
                pending[id] = header.isPending
                guard let was, was != header.isPending else { continue }
                let phase: Phase
                if header.isPending {
                    beneath[id] = phases[id] ?? .working
                    phase = .awaiting
                } else if phases[id] == .awaiting {
                    phase = beneath.removeValue(forKey: id) ?? .working
                } else {
                    continue
                }
                phases[id] = phase
                update.emissions.append(Emission(chatID: id, event: phase.eventName, cwd: nil, claims: false))
            }
            return update
        }

        private mutating func release(_ id: String) -> Emission {
            forget(id)
            return Emission(chatID: id, event: Cursor.releasedEvent, cwd: nil, claims: false)
        }

        private mutating func forget(_ id: String) {
            phases[id] = nil
            pending[id] = nil
            beneath[id] = nil
            seen.remove(id)
        }
    }

    // MARK: - the Agents window

    /**
     The link that opens a chat in Cursor's Agents window.

     Cursor's own deeplink rather than an extension of ours: `/agent` is routed to the
     Agents window, whose handler looks the id up among every agent it knows — local
     chats included, despite the command being named for cloud ones — and selects it.
     Not in Cursor's documented routes, so an update could change it; a link that stops
     working shows Cursor's own "can't find this agent" rather than anything wrong.
     */
    public static func openURL(chatID: String) -> URL? {
        guard isChatID(chatID) else { return nil }
        var components = URLComponents()
        components.scheme = "cursor"
        components.host = "anysphere.cursor-deeplink"
        components.path = "/agent"
        components.queryItems = [URLQueryItem(name: "id", value: chatID)]
        return components.url
    }

    /// Where the Agents window records the chat it is showing, on every change.
    static let selectedChatKey = "cursor/glass.selectedAgent"

    /**
     The chat the Agents window is showing — or last showed, since Cursor keeps it when
     the window closes, so it means "in front of you" only while Cursor is.
     */
    public static func readSelectedChat(at url: URL = databaseURL) -> String? {
        guard let db = openReadOnly(url) else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        sqlite3_bind_text(statement, 1, selectedChatKey, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              isChatID(id)
        else { return nil }
        return id
    }

    // MARK: - the chat headers

    /// Where Cursor keeps its chat headers, for the default profile.
    public static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Opened read-only, and briefly: a write in progress is waited on for 100 ms at most,
    /// and the database stays in WAL mode, so Cursor is never blocked by a read.
    private static func openReadOnly(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 100)
        return db
    }

    /// Swift strings are bridged to temporary C buffers, so SQLite must copy them.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /**
     The header rows of the given chats, read-only.

     The database is several gigabytes, so this asks the small `composerHeaders` table for
     at most the six chats on the board and nothing else. Nil for anything that went
     wrong — a missing file, a changed schema, a lock — which callers must treat as
     "unknown", never as "deleted".
     */
    public static func readHeaders(ids: [String], at url: URL = databaseURL) -> [String: Header]? {
        let ids = ids.filter(isChatID)
        guard !ids.isEmpty else { return [:] }
        guard let db = openReadOnly(url) else { return nil }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "SELECT composerId, isArchived, isSubagent, value FROM composerHeaders "
            + "WHERE composerId IN (\(placeholders))"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (index, id) in ids.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), id, -1, transient)
        }

        var headers: [String: Header] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            guard let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
            let value = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let json = value
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
            headers[id] = Header(
                name: json["name"] as? String,
                isArchived: sqlite3_column_int(statement, 1) != 0,
                isSubagent: sqlite3_column_int(statement, 2) != 0,
                isPending: (json["hasBlockingPendingActions"] as? Bool ?? false)
                    || (json["hasPendingPlan"] as? Bool ?? false)
            )
        }
        return headers
    }
}
