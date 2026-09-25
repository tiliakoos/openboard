import Foundation
import OpenBoardKit

func runAutoOffTests() {
    test("the pad goes dark only after the timeout, and never when off") {
        expect(!AutoOff.isDark(idleFor: 599, after: 600, states: [.working]))
        expect(AutoOff.isDark(idleFor: 600, after: 600, states: [.working, .done]))
        expect(!AutoOff.isDark(idleFor: 99_999, after: 0, states: []))
    }

    test("a key waiting on you keeps the pad lit") {
        expect(!AutoOff.isDark(idleFor: 99_999, after: 600, states: [.done, .awaiting]))
        expect(!AutoOff.isDark(idleFor: 99_999, after: 600, states: [.stalled]))
    }

    test("a typed timeout reads as m:ss or minutes, clamped to reason") {
        expectEqual(AutoOff.seconds(from: "3:30"), 210)
        expectEqual(AutoOff.seconds(from: " 10 "), 600)
        expectEqual(AutoOff.seconds(from: "0:05"), 30)
        expectEqual(AutoOff.seconds(from: "90"), 3600)
        for junk in ["", "abc", "3:5", "3:75", "1:2:3", ":30"] {
            expect(AutoOff.seconds(from: junk) == nil, "\(junk) was read as a time")
        }
        expectEqual(AutoOff.label(210), "3:30")
    }
}
