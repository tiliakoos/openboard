import Foundation

/**
 T3 Code threads, read from T3's own server rather than from hooks.

 T3 runs Claude, Codex and others behind one thread model. Hooks would reach only its
 Claude threads — Codex runs as one shared `codex app-server` with no hooks at all — and
 a Claude thread's session id changes whenever T3 restarts `claude` after it has idled.
 T3's thread id survives all of that, and its server already knows every thread's status,
 so the board asks it: `GET /api/orchestration/shell` every second or two.

 T3's own Claude hooks still arrive and are still refused (`entrypoint-not-allowed
 sdk-ts`). Admitting them would count every Claude thread twice, and `sdk-ts` would admit
 every TypeScript SDK client on the Mac along with it.

 Everything here is pure: the snapshot goes in, synthesized hook events come out, and
 those go through `BoardController.handle` like any hook — so slots, stickiness and the
 "never steal an orange key" rule are the registry's, not reimplemented. The network
 lives in the app target.
 */
public enum T3Code {
    public static let bundleID = "com.t3tools.t3code"
    public static let harnessID = "t3code"
    public static let entrypoint = "t3code"
    /// The only orchestration protocol this was written against. Anything else stays dark.
    public static let protocolVersion = 2
    /// Prefixed so a thread id can never collide with a Claude session id or a
    /// discovered placeholder (`host:`).
    public static let sessionPrefix = "t3:"
    /// How long the server may be gone before its keys are given up. T3 quits and
    /// relaunches itself on every update, and that must not cost the greens.
    public static let serverGrace: TimeInterval = 60

    // MARK: - the wire

    /// `~/.t3/userdata/server-runtime.json`, written once T3 is listening and deleted on
    /// a clean shutdown. A crash leaves it behind, hence the pid.
    public struct Runtime: Decodable, Equatable, Sendable {
        public let pid: Int
        public let host: String
        public let port: Int
        public let origin: String
    }

    public static var runtimeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata/server-runtime.json")
    }

    public static func readRuntime(url: URL = runtimeURL) -> Runtime? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Runtime.self, from: data)
    }

    /// `/.well-known/t3/environment`, the one endpoint that needs no token.
    public struct Environment: Decodable, Sendable {
        /// Absent on hosts older than protocol negotiation.
        public let orchestrationProtocolVersion: Int?
    }

    /*
     Only the fields the board reads, and every literal as a plain `String`.

     T3 ships nightly. A new status or request kind in an enum here would fail the whole
     decode and blank the board; as a string it maps to idle and gets logged once.
    */
    public struct ShellSnapshot: Decodable, Sendable {
        public let threads: [ThreadShell]
        public let projects: [ProjectShell]
    }

    public struct ProjectShell: Decodable, Sendable {
        public let id: String
        public let title: String?
        public let workspaceRoot: String?
    }

    public struct ThreadShell: Decodable, Sendable {
        public struct Request: Decodable, Sendable, Equatable {
            public let id: String
            public let kind: String
        }

        /// Only whether there are any is read: no kind tells a CI watch from a dev server.
        public struct BackgroundTask: Decodable, Sendable {}

        public struct Lineage: Decodable, Sendable {
            public let relationshipToParent: String?
        }

        public let id: String
        public let projectId: String?
        public let title: String?
        public let status: String?
        public let activityRunStatus: String?
        public let pendingRuntimeRequest: Request?
        public let pendingBackgroundTasks: [BackgroundTask]?
        public let lineage: Lineage?
        public let archivedAt: String?
        public let deletedAt: String?
        public let settledOverride: String?
        public let snoozedUntil: String?
        public let latestRunId: String?
        public let latestUserAuthoredMessageAt: String?
        public let worktreePath: String?
    }

    // MARK: - what a thread is doing

    public enum Phase: String, Sendable, Equatable {
        case working, awaiting, background, done, error, idle

        public var eventName: String { "t3_\(rawValue)" }
    }

    public static let releasedEvent = "t3_released"

    /// The thread behind a session id, or nil for a session that is not a thread.
    public static func threadID(fromSession sessionID: String) -> String? {
        guard sessionID.hasPrefix(sessionPrefix) else { return nil }
        return String(sessionID.dropFirst(sessionPrefix.count))
    }

    /// Every value of `status` and `activityRunStatus` this was written against. Anything
    /// else is idle, and worth one log line: it means a nightly changed the model.
    public static let knownStatuses: Set<String> = [
        "idle", "preparing", "queued", "starting", "running", "waiting",
        "completed", "interrupted", "failed", "cancelled", "rolled_back",
    ]

    /**
     Ported from T3's own `resolveThreadAwarenessPhaseV2` (`packages/shared/src/
     agentAwareness.ts`), first match wins.

     Three deliberate differences. `queued` is working: T3's notifier ignores it, but its
     sidebar shows it as "Connecting", and a key that stays white while you wait for a
     turn to start reads as broken. `waiting` — the turn is over and checkpointing is
     still running — is working, never orange: it waits on T3, not on you. And a
     completed run with background work still pending is `background`, whatever the
     kind: T3 lets a command count as finished, but a command can be a CI watch the
     agent will wake for, and nothing in the kind tells it from a dev server.
     */
    public static func phase(of thread: ThreadShell) -> Phase {
        if let request = thread.pendingRuntimeRequest, request.kind != "auth_refresh" {
            return .awaiting
        }
        switch thread.activityRunStatus ?? thread.status {
        case "preparing", "starting", "queued", "running", "waiting":
            return .working
        case "completed":
            return (thread.pendingBackgroundTasks ?? []).isEmpty ? .done : .background
        case "failed":
            return .error
        default:
            return .idle
        }
    }

    /**
     Whether a thread may hold a key at all.

     Subagent children are excluded for the reason Claude's are: one fan-out would take
     all six keys. Forks are real threads and stay. Settled, archived, snoozed and deleted
     are T3's ways of saying "not now", and a key for one would be a key you have already
     dismissed.
     */
    public static func isEligible(_ thread: ThreadShell, now: Date) -> Bool {
        guard thread.lineage?.relationshipToParent != "subagent",
              thread.archivedAt == nil,
              thread.deletedAt == nil,
              thread.settledOverride != "settled"
        else { return false }
        if let until = thread.snoozedUntil.flatMap(date(from:)), until > now { return false }
        return true
    }

    private static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    // MARK: - what the board is told

    /// One synthesized hook event.
    public struct Emission: Sendable, Equatable {
        public let threadID: String
        public let event: String
        public let cwd: String?
        /// The pending request's kind, on `t3_awaiting` only. It lands in `pendingTool`,
        /// which is how approve knows a question from an approval.
        public let requestKind: String?

        public var sessionID: String { T3Code.sessionPrefix + threadID }

        /**
         The payload `HookServer.Event(raw:)` takes.

         No `env` key: `Event` drops the whole environment if any value in it is not a
         string, and none of the rules that read it apply to a thread. No pid either —
         T3's server pid is shared by every thread, and a shared pid would make
         `claim`'s same-host reuse hand one thread's key to the next.
         */
        public var payload: [String: Any] {
            var raw: [String: Any] = [
                "hook_event_name": event,
                "session_id": sessionID,
                "harness": T3Code.harnessID,
                "entrypoint": T3Code.entrypoint,
            ]
            if let cwd { raw["cwd"] = cwd }
            if let requestKind { raw["tool_name"] = requestKind }
            return raw
        }
    }

    public struct Update: Sendable, Equatable {
        public var emissions: [Emission] = []
        /// Thread titles by session id, for every thread holding a key. T3 regenerates
        /// titles, so the row's name comes from here rather than from a transcript.
        public var titles: [String: String] = [:]
        /// Project titles by session id, as T3's sidebar names them. A worktree thread's
        /// folder is named for its branch, so the path cannot say which project it is.
        public var projects: [String: String] = [:]
        /// A message was sent in some thread since the last snapshot. Ends dictation, as
        /// `UserPromptSubmit` does for a terminal session.
        public var promptSubmitted = false
    }

    /**
     What the board knows about T3 between two snapshots.

     A thread is *tracked* once it has been given an event, and keeps that until it stops
     being eligible. Only tracked threads emit on change, which is what makes this a diff
     rather than a repaint: a thread that sits green for an hour produces nothing.
     */
    public struct State: Sendable, Equatable {
        struct Tracked: Sendable, Equatable {
            var phase: Phase
            var requestID: String?
        }

        struct Seen: Sendable, Equatable {
            var runID: String?
            var userMessageAt: String?
        }

        var tracked: [String: Tracked] = [:]
        /// Every thread in the last snapshot, eligible or not — the baseline a run or a
        /// sent message is detected against.
        var seen: [String: Seen] = [:]
        /// False until the first snapshot after a (re)start. That snapshot claims only
        /// threads that are working, waiting on you, or still running something in the
        /// background: eighteen historical greens are a history, not a board.
        var primed = false
        var lostAt: Date?

        public init() {}

        public var trackedCount: Int { tracked.count }

        /// The request an orange thread is showing, as of the last snapshot. Nil once it
        /// has been answered — in T3 or anywhere else.
        public func pendingRequestID(forSession sessionID: String) -> String? {
            T3Code.threadID(fromSession: sessionID).flatMap { tracked[$0]?.requestID }
        }

        public mutating func apply(_ snapshot: ShellSnapshot, now: Date) -> Update {
            lostAt = nil
            let projects = Dictionary(
                snapshot.projects.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var update = Update()
            var eligible = Set<String>()

            for thread in snapshot.threads {
                let previous = seen[thread.id]
                seen[thread.id] = Seen(
                    runID: thread.latestRunId,
                    userMessageAt: thread.latestUserAuthoredMessageAt
                )
                if primed, let sent = thread.latestUserAuthoredMessageAt,
                   sent != previous?.userMessageAt {
                    update.promptSubmitted = true
                }

                guard T3Code.isEligible(thread, now: now) else { continue }
                eligible.insert(thread.id)

                let phase = T3Code.phase(of: thread)
                let requestID = phase == .awaiting ? thread.pendingRuntimeRequest?.id : nil
                let emit: Bool
                if let old = tracked[thread.id] {
                    // A second request on a thread already orange is a different prompt.
                    emit = old.phase != phase || old.requestID != requestID
                } else {
                    switch phase {
                    // Background is still going, so it is live, not history.
                    case .working, .awaiting, .background:
                        emit = true
                    case .done, .error:
                        // Only a whole run that started and ended between two polls —
                        // never a thread that was already finished when we looked.
                        emit = primed && thread.latestRunId != nil
                            && thread.latestRunId != previous?.runID
                    case .idle:
                        emit = false
                    }
                }
                guard emit else { continue }

                tracked[thread.id] = Tracked(phase: phase, requestID: requestID)
                update.emissions.append(Emission(
                    threadID: thread.id,
                    event: phase.eventName,
                    cwd: thread.worktreePath ?? thread.projectId.flatMap { projects[$0]?.workspaceRoot },
                    requestKind: phase == .awaiting ? thread.pendingRuntimeRequest?.kind : nil
                ))
            }

            // Settled, archived, snoozed, deleted, or gone: the key goes.
            for id in tracked.keys.sorted() where !eligible.contains(id) {
                tracked[id] = nil
                update.emissions.append(Emission(
                    threadID: id, event: T3Code.releasedEvent, cwd: nil, requestKind: nil
                ))
            }

            for thread in snapshot.threads where tracked[thread.id] != nil {
                if let title = thread.title, !title.isEmpty {
                    update.titles[T3Code.sessionPrefix + thread.id] = title
                }
                if let project = thread.projectId.flatMap({ projects[$0]?.title }) {
                    update.projects[T3Code.sessionPrefix + thread.id] = project
                }
            }
            primed = true
            return update
        }

        /**
         The server could not be read: not running, refused, or a body that did not
         decode.

         Nothing changes for `serverGrace`. T3 relaunches itself on every update and
         thread ids survive that, so a server back within the minute carries on diffing
         against the same state and every key — green included — stays where it was.
         Past the grace it is gone, and holding keys for it would be the board claiming
         activity that does not exist.
         */
        public mutating func serverLost(now: Date) -> [Emission] {
            guard let since = lostAt else {
                lostAt = now
                return []
            }
            guard now.timeIntervalSince(since) >= T3Code.serverGrace else { return [] }
            return reset()
        }

        /// Give up every T3 key at once. For a token that was rejected or removed, or a
        /// protocol this does not speak: waiting would not change the answer.
        public mutating func reset() -> [Emission] {
            let released = tracked.keys.sorted().map {
                Emission(threadID: $0, event: T3Code.releasedEvent, cwd: nil, requestKind: nil)
            }
            self = State()
            return released
        }
    }

    // MARK: - the window

    /**
     The thread T3's window is showing, from its web area's URL.

     Electron serves the UI at `t3code://app/` with hash routing, and a thread's route is
     `#/<environment>/<thread>`. Other pages have two segments too — `#/settings/general`,
     `#/projects/<key>`, `#/draft/<id>` — so the first must be an environment id, which
     is a UUID, before the second is read as a thread.
     */
    public static func threadID(fromAppURL url: String) -> String? {
        guard let hash = url.firstIndex(of: "#") else { return nil }
        let route = url[url.index(after: hash)...].split(separator: "?").first ?? ""
        let segments = route.split(separator: "/").map(String.init)
        guard segments.count == 2, UUID(uuidString: segments[0]) != nil else { return nil }
        return segments[1]
    }

    // MARK: - the token

    /**
     The bearer token, in a 0600 file beside the config rather than in the Keychain.

     T3's own key for minting these already sits unencrypted in `~/.t3/userdata/secrets/`,
     so the Keychain would protect the copy and not the original. A file also honours
     `OPENBOARD_HOME`, which keeps tests and scratch runs away from the real one.

     Read on every poll, so a token pasted or minted while the app runs is picked up
     without a relaunch.
     */
    public static func readToken(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let data = try? Data(contentsOf: AppPaths.t3Token(env: env)),
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return token
    }

    public static func saveToken(
        _ token: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let url = AppPaths.t3Token(env: env)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Created 0600 rather than chmodded after: a world-readable file, however briefly,
        // is a token anyone on the Mac could have copied.
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(trimmed.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        // `createFile` keeps an existing file's mode.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func removeToken(env: [String: String] = ProcessInfo.processInfo.environment) {
        try? FileManager.default.removeItem(at: AppPaths.t3Token(env: env))
    }

    /**
     How to mint a token, with T3's own CLI from the installed app.

     The bundle's CLI rather than the repo's: it is the same version as the server that is
     running, and an `auth` command from a different build migrates the live database.
     `TOKEN_FILE` is substituted with the real path by whoever shows it.
     */
    public static let mintCommand = """
        (umask 077 && ELECTRON_RUN_AS_NODE=1 "/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)" "/Applications/T3 Code (Nightly).app/Contents/Resources/app.asar/apps/server/dist/bin.mjs" auth session issue --base-dir "$HOME/.t3" --label OpenBoard --ttl 365d --token-only > "TOKEN_FILE")
        """

    /// What the pane and the log say about the connection.
    public enum Status: Sendable, Equatable {
        case noToken
        case serverDown
        case protocolMismatch(Int?)
        case tokenRejected
        case connected(threads: Int)

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        public var summary: String {
            switch self {
            case .noToken: "no token"
            case .serverDown: "T3 Code is not running"
            case let .protocolMismatch(version):
                "T3 speaks protocol \(version.map(String.init) ?? "unknown"), not \(T3Code.protocolVersion) — staying dark"
            case .tokenRejected: "token rejected — mint a new one"
            case let .connected(threads): "connected, \(threads) thread\(threads == 1 ? "" : "s")"
            }
        }
    }

    // MARK: - approve and reject

    /**
     One Effect-RPC request: `orchestration.dispatchCommand` with a
     `runtime-request.respond`, sent as a single WebSocket text frame.

     Through T3's API rather than ⏎/⎋, because its approval UI is buttons with no
     keyboard shortcut. `headers` is required even empty, or the server rejects the frame.
     */
    public static func respondRequest(
        threadID: String,
        requestID: String,
        decision: String,
        commandID: String
    ) -> Data {
        let request: [String: Any] = [
            "_tag": "Request",
            "id": rpcID,
            "tag": "orchestration.dispatchCommand",
            "headers": [Any](),
            "payload": [
                "type": "runtime-request.respond",
                "commandId": commandID,
                "threadId": threadID,
                "requestId": requestID,
                "decision": decision,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data()
    }

    /// A respond connection sends one request, so it waits for one answer.
    private static let rpcID = "1"

    public enum RespondResult: Sendable, Equatable {
        case sent
        case failed(String)
    }

    /**
     Whether a frame from the server finishes our request.

     Nil means keep reading: a frame can be a `Pong`, a `Chunk`, or the answer to someone
     else's request, and the server may batch several messages into one JSON array.
     */
    public static func exitOutcome(fromFrame data: Data) -> RespondResult? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let messages = (object as? [[String: Any]]) ?? [(object as? [String: Any])].compactMap { $0 }
        for message in messages {
            switch message["_tag"] as? String {
            case "Exit":
                guard "\(message["requestId"] ?? "")" == rpcID else { continue }
                let exit = message["exit"] as? [String: Any]
                if exit?["_tag"] as? String == "Success" { return .sent }
                return .failed(describe(exit?["cause"]))
            case "Defect", "ClientProtocolError":
                return .failed(describe(message["defect"] ?? message["error"]))
            default:
                continue
            }
        }
        return nil
    }

    /// Truncated for the log. Checked before serialising: `JSONSerialization` raises an
    /// Objective-C exception, not a Swift error, on anything that is not JSON.
    private static func describe(_ value: Any?) -> String {
        guard let value else { return "no detail" }
        var text = (value as? String) ?? "\(value)"
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let json = String(data: data, encoding: .utf8) {
            text = json
        }
        return String(text.prefix(200))
    }
}
