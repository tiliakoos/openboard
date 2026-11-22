import AppKit
import OpenBoardKit

/**
 The status item: one mark per session inside a frame, drawn as an image.

 The dots are the sessions, not the pad. They keep their colours whether or not the pad
 is reachable, so the menu bar is still a status board away from the desk. Three things
 are read from it, each on its own channel:

 - **Colour** is a session's state, exactly as on its key. A hollow mark is a free slot.
 - **Shape** is the pad. Square marks in a squared frame mean the pad is live; round
   marks in a capsule mean it is away, asleep or refused. The pad sleeps dozens of times
   a day, so this is the one signal that must not change the item's width.
 - **One larger mark** means no session is running.

 **Why not just SwiftUI.** `MenuBarExtra`'s `label:` only reliably renders `Text` and
 `Image`. An `HStack` of `Circle` shapes builds and runs and produces a status item
 that is present, sized and clickable — and completely invisible. That is exactly how
 it failed: the popover opened from a blank patch of menu bar.

 So the marks are drawn with Core Graphics into an `NSImage` and handed over as an
 `Image`, which is the one shape the menu bar is guaranteed to draw.
 */
enum StatusItemImage {
    private static let dot: CGFloat = 6
    private static let gap: CGFloat = 3
    private static let height: CGFloat = 16
    /// Clear space between the frame and the marks, on every side.
    private static let inset: CGFloat = 4
    private static let frameHeight: CGFloat = 13
    /// Larger than a session mark: one alone at 6pt reads as a speck of dust.
    private static let foldedDot: CGFloat = 8

    /// One mark per slot, in board order, or the folded mark when nothing is running.
    static func make(slots: [SlotView], padLive: Bool) -> NSImage {
        guard slots.contains(where: \.isLive) else { return folded(padLive: padLive) }

        let count = slots.count
        let width = inset * 2 + CGFloat(count) * dot + CGFloat(count - 1) * gap

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.setLineWidth(1)
            context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            context.addPath(frame(width: width, padLive: padLive))
            context.strokePath()

            let y = (height - dot) / 2
            for (index, slot) in slots.enumerated() {
                let x = inset + CGFloat(index) * (dot + gap)
                let rect = CGRect(x: x, y: y, width: dot, height: dot)

                if let appearance = slot.appearance, appearance.effect != .off {
                    // Brightness reads as alpha: at 6pt a dim color and a bright one
                    // are otherwise indistinguishable.
                    let alpha = 0.45 + 0.55 * appearance.brightness
                    context.setFillColor(
                        red: appearance.color.red,
                        green: appearance.color.green,
                        blue: appearance.color.blue,
                        alpha: alpha
                    )
                    context.addPath(mark(in: rect, padLive: padLive))
                    context.fillPath()
                } else {
                    // A free or ended slot is an outline, not a filled mark — "nothing
                    // here" has to look different from "deliberately dark".
                    context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
                    context.addPath(mark(in: rect.insetBy(dx: 0.5, dy: 0.5), padLive: padLive))
                    context.strokePath()
                }
            }
            return true
        }
        // Deliberately not a template. A template image is recolored to match the menu
        // bar's appearance, which would throw away the only information here — these
        // are hardware colors and the whole point is that the mark matches the key.
        image.isTemplate = false
        image.accessibilityDescription = padLive ? "OpenBoard sessions" : "OpenBoard sessions — pad away"
        return image
    }

    /**
     No session is running, so six hollow marks would be six ways of saying nothing.
     One mark in a small frame instead: the board folded up, not replaced by a
     different kind of icon.

     A template, which the row is not, and that is not a contradiction. The row carries
     hardware colours and must never be recoloured. This carries no colour at all, so
     it should be the menu bar's own foreground — white on a dark menu bar, dark on a
     light one. Only the alpha of what is drawn here is kept.
     */
    private static func folded(padLive: Bool) -> NSImage {
        let width = foldedDot + 12
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.setLineWidth(1)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            context.addPath(frame(width: width, padLive: padLive))
            context.strokePath()

            let rect = CGRect(
                x: (width - foldedDot) / 2, y: (height - foldedDot) / 2,
                width: foldedDot, height: foldedDot
            )
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(mark(in: rect, padLive: padLive))
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = padLive ? "OpenBoard — no sessions" : "OpenBoard — no sessions, pad away"
        return image
    }

    /// The outline around the marks. Its corners follow them, so the pad is said twice.
    /// Inset half a point so the 1pt stroke is not clipped at the image's edge.
    private static func frame(width: CGFloat, padLive: Bool) -> CGPath {
        let rect = CGRect(x: 0.5, y: (height - frameHeight) / 2, width: width - 1, height: frameHeight)
        let radius = padLive ? 3 : frameHeight / 2
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// A keycap when the pad is live, a dot when it is not.
    private static func mark(in rect: CGRect, padLive: Bool) -> CGPath {
        guard padLive else { return CGPath(ellipseIn: rect, transform: nil) }
        let radius = rect.width / 4
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
