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
}
