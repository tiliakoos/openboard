import AppKit
import ApplicationServices
import OpenBoardKit

/**
 T3 Code's window, through its accessibility tree.

 T3 offers nothing outside itself that says which thread is open, or that opens one. Its
 UI does: Electron serves it at `t3code://app/` with hash routing, so the web area's URL
 names the thread in front (`T3Code.threadID(fromAppURL:)`), and every sidebar row is a
 button named "<title>, <project>" whose press navigates to it.

 Measured on this Mac before anything was built on it: reading the URL takes a tenth of
 a millisecond, a walk of the whole tree about a tenth of a second, and T3's renderer
 CPU while a reply streams was the same with the tree on as with it off.

 ## Unlike VSCodeWindows, this goes into the web contents

 Chromium builds that tree only when an assistive client asks — `AXManualAccessibility`
 on the app element — and it stays built until T3 relaunches. The first read after
 asking finds nothing, because the tree takes a moment to appear. So a nil on the first
 try is expected and the next poll answers; it is asked again only when the web area is
 missing.

 Fail quiet, as there: no grant, T3 not running, a row not in the sidebar — all nil or
 false, and the caller falls back to bringing T3 forward.
 */
enum T3Window {
    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == T3Code.bundleID
    }

    /// The thread T3 is showing, read off the main thread — the focus watcher asks once a
    /// second while T3 is in front.
    static func focusedThreadID() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: focusedThreadIDNow())
            }
        }
    }

    static func focusedThreadIDNow() -> String? {
        guard let application else { return nil }
        guard let webArea = webArea(in: application) else {
            enableTree(application)
            return nil
        }
        guard let url = attribute(webArea, "AXURL") as? URL else { return nil }
        return T3Code.threadID(fromAppURL: url.absoluteString)
    }

    /**
     Open a thread by pressing its sidebar row, and wait until T3 shows it.

     Confirmed by the URL rather than trusted from the press: two threads can share a
     title, and a row scrolled out of a collapsed project is not there to press. Either
     way this returns false and nothing else has moved.
     */
    static func open(title: String, threadID: String) -> Bool {
        guard !title.isEmpty, let application else { return false }
        if focusedThreadIDNow() == threadID { return true }

        // The tree may still be building if nothing has asked for it since T3 launched.
        var row = sidebarRow(in: application, title: title)
        let building = Date().addingTimeInterval(2)
        while row == nil, Date() < building {
            enableTree(application)
            Thread.sleep(forTimeInterval: 0.25)
            row = sidebarRow(in: application, title: title)
        }
        guard let row, AXUIElementPerformAction(row, kAXPressAction as CFString) == .success
        else { return false }

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if focusedThreadIDNow() == threadID { return true }
            Thread.sleep(forTimeInterval: 0.08)
        }
        return false
    }

    // MARK: - plumbing

    private static var application: AXUIElement? {
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: T3Code.bundleID)
            .first
        else { return nil }
        let element = AXUIElementCreateApplication(running.processIdentifier)
        // A bound on every message: a wedged T3 must not stall a key press.
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    private static func enableTree(_ application: AXUIElement) {
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// The web contents of the focused window. Found by a short walk that stops at the
    /// web area rather than descending into the page, which is where the size is.
    private static func webArea(in application: AXUIElement) -> AXUIElement? {
        let window = element(application, kAXFocusedWindowAttribute)
            ?? (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let window else { return nil }
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let next = queue.removeFirst()
            visited += 1
            if string(next, kAXRoleAttribute) == "AXWebArea" { return next }
            queue.append(contentsOf: children(next))
        }
        return nil
    }

    /// The sidebar button for a thread. Its name is "<title>, <project>", so the title
    /// alone or followed by a comma — never merely containing it, or "Fix" would press
    /// the first of every thread whose title starts with a verb.
    private static func sidebarRow(in application: AXUIElement, title: String) -> AXUIElement? {
        guard let webArea = webArea(in: application) else { return nil }
        var queue = [webArea]
        var visited = 0
        while !queue.isEmpty, visited < 5_000 {
            let next = queue.removeLast()
            visited += 1
            if string(next, kAXRoleAttribute) == "AXButton" {
                let name = string(next, kAXTitleAttribute) ?? string(next, kAXDescriptionAttribute) ?? ""
                if name == title || name.hasPrefix(title + ", ") { return next }
            }
            queue.append(contentsOf: children(next))
        }
        return nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }

    /// A child element, type-checked: an unchecked cast of a CF value is a crash.
    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) as? String, !value.isEmpty else { return nil }
        return value
    }
}
