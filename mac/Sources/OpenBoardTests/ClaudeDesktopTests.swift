import Foundation
import OpenBoardKit

/**
 The Claude desktop app: admitted by default, labelled as itself, reached by its own
 `claude://` link, and never answered blind.
 */
func runClaudeDesktopTests() {
    let desktopEnv = ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]
    let payload = Eligibility.Payload(sessionID: "abc-123")

    // MARK: - eligibility

    test("a Claude desktop session gets a key by default") {
        let verdict = Eligibility.evaluate(env: desktopEnv, payload: payload)
        expect(verdict.eligible)
        expect(verdict.reason == .ok)
    }

    test("a configured list is honoured, including one without the desktop app") {
        // The setting existed and was saved, but the app never passed it in — so it
        // changed nothing. Passing it must actually narrow the allowlist.
        let verdict = Eligibility.evaluate(
            env: desktopEnv, payload: payload, configured: ["cli", "claude-vscode"]
        )
        expect(!verdict.eligible)
        expect(verdict.reason == .entrypointNotAllowed)
    }

    test("the environment override still beats the configured list") {
        let verdict = Eligibility.evaluate(
            env: desktopEnv.merging(["OPENBOARD_ENTRYPOINTS": "claude-desktop"]) { $1 },
            payload: payload,
            configured: ["cli"]
        )
        expect(verdict.eligible)
    }

    // MARK: - stored configuration

    test("the old default stored by every install becomes the new default") {
        // Written by the app on every save, never chosen by anyone.
        let merged = Preferences.merging(["entrypoints": ["claude-vscode", "cli"]])
        expectEqual(Set(merged.entrypoints), Eligibility.defaultEntrypoints)
    }

    test("a list someone actually chose is kept") {
        let merged = Preferences.merging(["entrypoints": ["cli"]])
        expectEqual(merged.entrypoints, ["cli"])
    }

    // MARK: - the app's id for the session

    test("an event teaches the entry the app's id, and a newer one replaces it") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "s1", pid: 4242, entrypoint: "claude-desktop", isAlive: { _ in true })
        expect(registry.enrich(sessionID: "s1", claudeDesktopSession: "local_a"))
        expectEqual(registry.entry(forSession: "s1")?.claudeDesktopSession, "local_a")
        expect(!registry.enrich(sessionID: "s1", claudeDesktopSession: "local_a"), "unchanged is not a change")
        expect(registry.enrich(sessionID: "s1", claudeDesktopSession: "local_b"))
        expectEqual(registry.entry(forSession: "s1")?.claudeDesktopSession, "local_b")
    }

    test("the app's id survives a relaunch") {
        // Kept in memory only, a session restored from disk could raise the app but
        // not open its chat until it next sent a hook — which a finished one never does.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openboard-desktop-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "s1", pid: 4242, entrypoint: "claude-desktop", isAlive: { _ in true })
        registry.enrich(sessionID: "s1", claudeDesktopSession: "local_86b88d36-b11c")
        RegistryStore.save(registry, url: url)

        let loaded = RegistryStore.load(url: url, isAlive: { _ in true })
        expectEqual(loaded.entry(forSession: "s1")?.claudeDesktopSession, "local_86b88d36-b11c")
    }

    test("a registry written before the field existed still loads") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openboard-desktop-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "s1", pid: 4242, entrypoint: "cli", isAlive: { _ in true })
        RegistryStore.save(registry, url: url)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        expect(!text.contains("claudeDesktopSession"), "an absent id is not written")

        let loaded = RegistryStore.load(url: url, isAlive: { _ in true })
        expect(loaded.entry(forSession: "s1") != nil)
        expect(loaded.entry(forSession: "s1")?.claudeDesktopSession == nil)
    }

    // MARK: - origin

    test("the desktop app is its own origin, not a CLI") {
        expectEqual(SessionOrigin.from(entrypoint: "claude-desktop", tty: nil), .claudeDesktop)
        expectEqual(SessionOrigin.claudeDesktop.rawValue, "Claude")
    }

    // MARK: - the app target, read as source

    /*
     For the reason `runCmuxTests` gives: `Focus`, `Actions` and `BoardController` are in
     the executable target, and the real behaviour needs the desktop app running with
     someone's sessions in it. The contract is checked where it can be.
    */
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func read(_ path: String) -> String {
        (try? String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    let hook = read("openboard-hook/main.swift")
    let focus = read("OpenBoard/Focus.swift")
    let actions = read("OpenBoard/Actions.swift")
    let controller = read("OpenBoard/BoardController.swift")

    test("the sources were read at all") {
        for (name, text) in [("hook", hook), ("Focus", focus), ("Actions", actions), ("BoardController", controller)] {
            expect(!text.isEmpty, "\(name) did not read — the scan is checking nothing")
        }
    }

    test("the hook forwards the desktop app's own session id") {
        expect(hook.contains("\"CLAUDE_CODE_HOST_SESSION_ID\""))
    }

    test("the controller passes the configured allowlist to eligibility") {
        expect(controller.contains("configured: model.preferences.entrypoints"))
    }

    test("raise routes the desktop app to its own link, before the tty branch") {
        guard let desktopBranch = focus.range(of: "if slot.origin == .claudeDesktop {"),
              let ttyBranch = focus.range(of: "if let tty = slot.surface")
        else {
            expect(false, "raise no longer has a desktop branch and a tty branch")
            return
        }
        expect(desktopBranch.lowerBound < ttyBranch.lowerBound)
        expect(focus.contains("components.scheme = \"claude\""))
        expect(focus.contains("components.path = \"/continue\""))
        // The app's own rule for the id; anything else it drops without a word.
        expect(focus.contains(#"^local_[A-Za-z0-9-]{1,64}$"#))
    }

    test("a prompt in the desktop app is never answered from the pad") {
        // No way to ask the app which chat is showing, so nothing to confirm against.
        expect(actions.contains("if target.origin == .claudeDesktop { return false }"))
        guard let refusal = actions.range(of: "if target.origin == .claudeDesktop {\n"),
              let keystroke = actions.range(of: "let code = decision == .approve ? keyReturn : keyEscape")
        else {
            expect(false, "respond no longer refuses the desktop app before typing")
            return
        }
        expect(refusal.lowerBound < keystroke.lowerBound, "refuse before any key is sent")
    }
}
