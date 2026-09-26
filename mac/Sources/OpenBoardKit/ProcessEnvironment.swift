import Foundation

/**
 One variable from another process's environment.

 Warp gives every shell `WARP_FOCUS_URL`, and a `claude` started there inherits it. Read
 from the session's own process at press time rather than forwarded by the hook, so a
 session that was already running before this build — or before a relaunch — can be
 reached without waiting for its next hook, and nothing has to be stored.

 The kernel hands over the whole environment, secrets included. Only the one named
 value leaves this type, and nothing here logs.
 */
public enum ProcessEnvironment {
    /// `name`'s value in `pid`'s environment, or nil when the process is gone, is not
    /// ours to read, or does not have it.
    public static func value(of name: String, pid: Int) -> String? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: Int(argmax))
        size = bytes.count
        mib = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        return value(of: name, inProcArgs: Array(bytes.prefix(size)))
    }

    /**
     Find `name` in a `KERN_PROCARGS2` buffer.

     The layout is `argc`, the executable path, NUL padding, `argc` arguments, then the
     environment, each NUL-terminated and ended by an empty string. The arguments are
     skipped by count, not by shape: `claude "WARP_FOCUS_URL=x"` has an argument that
     looks exactly like a variable.
     */
    public static func value(of name: String, inProcArgs bytes: [UInt8]) -> String? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0 else { return nil }

        let fields = bytes.dropFirst(4).split(separator: 0, omittingEmptySubsequences: false)
        let prefix = name + "="
        // Past the executable path, its padding, and the arguments.
        for field in fields.dropFirst().drop(while: \.isEmpty).dropFirst(argc) {
            if field.isEmpty { break }  // the end of the environment
            let entry = String(decoding: field, as: UTF8.self)
            if entry.hasPrefix(prefix) { return String(entry.dropFirst(prefix.count)) }
        }
        return nil
    }
}
