import Foundation
import OpenBoardKit

/**
 Warp as a named host, reached through the focus URL it gives every shell.

 Before this a Warp session was an unknown host with a tty, so it was labelled
 "Terminal", the press ran the Terminal and iTerm2 tty walk, and every jump logged
 `notFound`. The jump itself cannot run here without moving a real Warp window while
 someone is using the machine, so it was verified by hand; what is checked is the
 identification, the environment read, the switch, and the routing in the source.
 */
func runWarpTests() {
    test("the parent chain identifies Warp, whose executable name says nothing") {
        // The real chain from this machine, 2026-09-26.
        let chain: [Int: (parent: Int, path: String)] = [
            25005: (82234, "claude"),
            82234: (68575, "-zsh"),
            68575: (68554, "/Applications/Warp.app/Contents/MacOS/stable"),
            68554: (1, "/Applications/Warp.app/Contents/MacOS/stable"),
        ]
        expectEqual(ProcessAncestry.host(ofPID: 25005, parentOf: { chain[$0] }), .warp)
        expectEqual(
            SessionOrigin.from(entrypoint: "cli", tty: "/dev/ttys010", host: .warp), .warp
        )
        expectEqual(SessionOrigin.warp.rawValue, "Warp")
    }

    test("a Warp host survives a round trip through the registry file") {
        expectEqual(ProcessAncestry.Host(rawValue: "warp"), .warp)
    }

    // MARK: - reading the focus URL

    /// A `KERN_PROCARGS2` buffer: argc, the executable path, padding, argv, the
    /// environment, and the empty string that ends it.
    func procArgs(argv: [String], env: [String]) -> [UInt8] {
        var bytes: [UInt8] = withUnsafeBytes(of: Int32(argv.count)) { Array($0) }
        bytes += Array("/Users/x/.local/bin/claude".utf8) + [0, 0, 0, 0]
        for field in argv + env { bytes += Array(field.utf8) + [0] }
        return bytes + [0]
    }

    test("the variable is found in the environment, not in an argument shaped like it") {
        let bytes = procArgs(
            argv: ["claude", "WARP_FOCUS_URL=from-an-argument"],
            env: ["HOME=/Users/x", "WARP_FOCUS_URL=warp://session/abc"]
        )
        expectEqual(
            ProcessEnvironment.value(of: "WARP_FOCUS_URL", inProcArgs: bytes),
            "warp://session/abc"
        )
    }

    test("a missing variable, a prefix of one, or a truncated buffer is nil") {
        let bytes = procArgs(argv: ["claude"], env: ["WARP_FOCUS_URL=warp://session/abc"])
        expectEqual(ProcessEnvironment.value(of: "WARP_TERMINAL_SESSION_UUID", inProcArgs: bytes), nil)
        expectEqual(ProcessEnvironment.value(of: "WARP_FOCUS", inProcArgs: bytes), nil)
        expectEqual(ProcessEnvironment.value(of: "WARP_FOCUS_URL", inProcArgs: [1, 0]), nil)
    }

    test("the kernel read really returns this process's environment") {
        // The parser above is driven by a fixture, so nothing there would notice if the
        // sysctl half broke — which is the half that runs on a key press.
        guard let path = ProcessInfo.processInfo.environment["PATH"] else {
            skip("no PATH to compare against")
            return
        }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        expectEqual(ProcessEnvironment.value(of: "PATH", pid: pid), path)
        expectEqual(ProcessEnvironment.value(of: "PATH", pid: Int(Int32.max)), nil)
    }

    // MARK: - the switch

    test("session keys jump by default, and the switch round-trips") {
        // On by default: every other terminal already jumped before the switch existed.
        expect(Preferences.default.agentKeysJump)
        expectEqual(Preferences.merging(["agentKeysJump": false]).agentKeysJump, false)
        var prefs = Preferences.default
        prefs.agentKeysJump = false
        expectEqual(Preferences.merging(prefs.json).agentKeysJump, false)
    }

    // MARK: - the app's routing, read from source

    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("OpenBoard")

    func read(_ name: String) -> String {
        (try? String(contentsOf: sources.appendingPathComponent("\(name).swift"), encoding: .utf8)) ?? ""
    }

    test("a Warp session is routed before the tty walk") {
        // After it, the press would ask Terminal and iTerm2 for a tty neither owns.
        let focus = read("Focus")
        guard let warp = focus.range(of: "if slot.origin == .warp")?.lowerBound,
              let tty = focus.range(of: "if let tty = slot.surface")?.lowerBound
        else {
            expect(false, "Focus.swift did not read, or the routing moved")
            return
        }
        expect(warp < tty)
    }

    test("approve and reject refuse a Warp session before raising it") {
        // They must confirm the tab before typing, and Warp cannot be read. Raising
        // first would move you to the tab and then do nothing.
        let actions = read("Actions")
        guard let refuse = actions.range(of: "guard target.origin != .warp")?.lowerBound,
              let raise = actions.range(of: "let raised = Focus.raise(target)")?.lowerBound
        else {
            expect(false, "Actions.swift did not read, or the refusal moved")
            return
        }
        expect(refuse < raise)
    }

    test("the switch gates the pad's key press") {
        expect(read("BoardController").contains("guard model.preferences.agentKeysJump else"))
    }
}
