import OpenBoardKit
import SwiftUI

/**
 The pad and its battery, at the top right of the popover.

 Shown rather than said. The header used to read "Connected to Codex Micro" beside a
 green light; a small drawing of the pad says the same thing in a fifth of the width,
 and its absence says the other half. When the pad is away this is simply not there —
 the popover is a list of sessions then, and has nothing to report about hardware.

 Neutral until there is something to act on: green only while charging, orange and red
 only when low. A green battery at 80% is decoration, an orange one at 15% is
 information.
 */
struct PadBadge: View {
    let percent: Int?
    /// Reported by the pad, or assumed from the cable until it reports.
    var isCharging: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            PadGlyph()
                .frame(width: 18, height: 18)
            BatteryGauge(percent: percent, isCharging: isCharging)
        }
        .foregroundStyle(BatteryGauge.neutral)
        .help(isCharging
            ? percent.map { "Charging · \($0)% battery" } ?? "Charging; battery level not reported."
            : percent == nil
                ? "Battery not read yet — the pad may be asleep."
                : "Codex Micro battery")
    }
}

/// The Codex Micro, at 18pt: the encoder top left, keys everywhere else.
struct PadGlyph: View {
    var body: some View {
        Canvas { context, size in
            // Drawn on an 18-unit grid and scaled, so the numbers below are the design's.
            let unit = size.width / 18
            context.scaleBy(x: unit, y: unit)

            let body = Path(roundedRect: CGRect(x: 1.1, y: 1.1, width: 15.8, height: 15.8), cornerRadius: 4)
            context.stroke(body, with: .foreground, lineWidth: 1.2)

            let knob = Path(ellipseIn: CGRect(x: 3.8, y: 3.8, width: 2.9, height: 2.9))
            context.stroke(knob, with: .foreground, lineWidth: 1)

            let columns: [CGFloat] = [4.1, 7.85, 11.6]
            for (row, y) in columns.enumerated() {
                for (column, x) in columns.enumerated() where !(row == 0 && column == 0) {
                    let key = Path(roundedRect: CGRect(x: x, y: y, width: 2.3, height: 2.3), cornerRadius: 0.6)
                    context.fill(key, with: .foreground)
                }
            }
        }
    }
}

/**
 A battery with its level written inside it.

 The number used to sit beside the outline, which made the badge three things in a row.
 Inside, it is one — and the digits are cut out of the fill rather than painted on it,
 so they are whatever is behind the popover and need no colour of their own. A low
 battery has almost no fill to cut from, so there the digits are drawn instead.
 */
struct BatteryGauge: View {
    let percent: Int?
    var isCharging: Bool = false

    static let neutral = Color.primary.opacity(0.7)
    private static let shell = CGSize(width: 30, height: 14)

    private var isLow: Bool {
        guard let percent, !isCharging else { return false }
        return percent <= 25
    }

    private var tint: Color {
        if isCharging { return Color(RGB(0x09B821)) }
        guard let percent, percent <= 25 else { return Self.neutral }
        return Color(RGB(percent <= 10 ? 0xD41145 : 0xFF6A00))
    }

    var body: some View {
        HStack(spacing: 1) {
            shell
                .frame(width: Self.shell.width, height: Self.shell.height)
            // The nub.
            RoundedRectangle(cornerRadius: 1)
                .fill(tint.opacity(0.5))
                .frame(width: 2, height: 5)
        }
    }

    @ViewBuilder
    private var shell: some View {
        let shape = RoundedRectangle(cornerRadius: 4.6, style: .continuous)
        if let percent {
            ZStack {
                shape.fill(tint.opacity(isLow ? 0.38 : 0.5))
                shape.fill(tint)
                    // Never wider than the shell, and never invisible at 1% — a fill
                    // that vanishes reads as "no reading" rather than "low".
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(2, Self.shell.width * Double(min(100, percent)) / 100))
                    }
                label(percent)
                    .foregroundStyle(isLow ? Color.primary : .black)
                    .blendMode(isLow ? .normal : .destinationOut)
            }
            // The cut-out must stop at the battery, not go through the window.
            .compositingGroup()
        } else {
            ZStack {
                shape.strokeBorder(tint.opacity(0.8), lineWidth: 1.2)
                Capsule().fill(tint.opacity(0.85)).frame(width: 7, height: 1.4)
            }
        }
    }

    private func label(_ percent: Int) -> some View {
        HStack(spacing: 1) {
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .bold))
            }
            Text("\(percent)")
                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
        }
        .fixedSize()
    }
}
