import Foundation

/// Turning every light off after a stretch with no pad input and no status change.
public enum AutoOff {
    public static let range = 30...3600

    /// Never while a key is asking for you: that is the one light that must not go out.
    public static func isDark(idleFor idle: TimeInterval, after timeout: Int, states: [SessionState]) -> Bool {
        timeout > 0 && idle >= TimeInterval(timeout) && !states.contains(where: \.isAttention)
    }

    /// `3:30` or `10` (minutes), clamped to `range`. Nil when it is not a time.
    public static func seconds(from text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let minutes = Int(parts[0]) else { return nil }
        var seconds = minutes * 60
        if parts.count == 2 {
            guard parts[1].count == 2, let extra = Int(parts[1]), extra < 60 else { return nil }
            seconds += extra
        }
        return min(max(seconds, range.lowerBound), range.upperBound)
    }

    public static func label(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
