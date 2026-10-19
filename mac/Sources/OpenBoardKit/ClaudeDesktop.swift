import Foundation

/**
 The Claude desktop app's own record of its Code-tab chats.

 Archiving a chat there sends no `SessionEnd`, and the app keeps that session's `claude`
 process running, so neither the hooks nor `prune` ever see it go — its key would sit on a
 chat that is gone, and pressing it would land on an empty Code tab. The app writes one
 record per chat, `claude-code-sessions/<account>/<org>/<local id>.json`, and its
 `isArchived` is the only place that says so.
 */
public enum ClaudeDesktop {
    public static let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

    /// The app's own id for a chat (`local_…`), which its `claude://code/continue` link
    /// takes. The app drops anything else without a word.
    public static func isHostSessionID(_ id: String) -> Bool {
        id.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil
    }

    /// Whether the app has archived this chat. A record that cannot be found or read says
    /// no: a key freed on a guess is worse than one held a little too long.
    public static func isArchived(hostSessionID id: String, root: URL = sessionsRoot) -> Bool {
        guard isHostSessionID(id) else { return false }
        let files = FileManager.default
        for account in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? files.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                guard let data = try? Data(contentsOf: org.appendingPathComponent("\(id).json")) else {
                    continue
                }
                let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                return record?["isArchived"] as? Bool ?? false
            }
        }
        return false
    }

    /// A chat for the off-board list.
    public struct Chat: Sendable, Equatable {
        /// The app's id (`local_…`), which its link opens the chat by.
        public let hostSessionID: String
        /// The `claude` session behind it — the id its hooks report, and so the board's.
        public let sessionID: String
        public let title: String?
        public let cwd: String?
        public let lastActivity: Date
    }

    /**
     Chats active since `since` and not archived, newest first.

     The app has no "running" flag on disk, so recency is what makes a chat worth listing.
     Only records written since then are opened — the file is rewritten as the chat is
     used — so a few hundred old chats cost a directory listing, not a few hundred reads.
     */
    public static func recentChats(since: Date, root: URL = sessionsRoot) -> [Chat] {
        let files = FileManager.default
        var chats: [Chat] = []
        for account in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? files.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                let records = (try? files.contentsOfDirectory(
                    at: org, includingPropertiesForKeys: [.contentModificationDateKey]
                )) ?? []
                for file in records where file.lastPathComponent.hasPrefix("local_")
                    && file.pathExtension == "json" {
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                    guard let modified, modified >= since,
                          let data = try? Data(contentsOf: file),
                          let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          record["isArchived"] as? Bool != true,
                          let host = record["sessionId"] as? String, isHostSessionID(host),
                          let session = record["cliSessionId"] as? String, !session.isEmpty,
                          let active = (record["lastActivityAt"] as? NSNumber)?.doubleValue
                    else { continue }
                    let lastActivity = Date(timeIntervalSince1970: active / 1000)
                    guard lastActivity >= since else { continue }
                    chats.append(Chat(
                        hostSessionID: host,
                        sessionID: session,
                        title: (record["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                        cwd: record["cwd"] as? String,
                        lastActivity: lastActivity
                    ))
                }
            }
        }
        return chats.sorted { $0.lastActivity > $1.lastActivity }
    }
}
