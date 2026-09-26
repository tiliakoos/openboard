import Foundation
import OpenBoardKit

/**
 The Back action: return to the window a jump left, one step per press.

 The window handling is Accessibility against real windows, so it was checked by hand
 (another app on another desktop, and two windows of one app on two desktops). What is
 checked here is the history's rules and that the controller records at the right time.
 */
func runBackTests() {
    test("back walks the jumps in reverse, like a browser") {
        // A video, then session 1, then session 2: Back goes to session 1, then the video.
        var history = BackHistory<String>()
        history.record("video")
        history.record("session 1")
        expectEqual(history.takeLatest(), "session 1")
        expectEqual(history.takeLatest(), "video")
        expectEqual(history.takeLatest(), nil)
    }

    test("the same place twice in a row is recorded once") {
        // Two jumps from one window would otherwise cost a press landing where you are.
        var history = BackHistory<String>()
        history.record("video")
        history.record("video")
        history.record("session")
        history.record("video")
        expectEqual(history.takeLatest(), "video")
        expectEqual(history.takeLatest(), "session")
        expectEqual(history.takeLatest(), "video")
        expectEqual(history.takeLatest(), nil)
    }

    test("only the most recent places are kept") {
        var history = BackHistory<Int>(limit: 3)
        for place in 1...5 { history.record(place) }
        expectEqual(history.takeLatest(), 5)
        expectEqual(history.takeLatest(), 4)
        expectEqual(history.takeLatest(), 3)
        expectEqual(history.takeLatest(), nil)
    }

    test("back is an action any key or stick direction can take, and it persists") {
        expectEqual(KeyAction(rawValue: "back"), .back)
        expect(KeyAction.forJoystick.contains(.back))
    }

    test("a jump reads the window in front before raising, and records only if it moved") {
        // After the raise, what is in front is the session, not where you came from.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenBoard/BoardController.swift")
        let controller = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let read = controller.range(of: "let here = Focus.here()")?.lowerBound,
              let raise = controller.range(of: "let outcome = Focus.raise(view)")?.lowerBound
        else {
            expect(false, "BoardController.swift did not read, or the jump moved")
            return
        }
        expect(read < raise)
        expect(controller.contains("if case .raised = outcome, let here { backHistory.record(here) }"))
    }
}
