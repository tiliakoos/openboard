import Foundation

/**
 The surface the app drives a pad through, at the framed-report level.

 Deliberately `[Data]` rather than a semantic `paint(keys:ring:)`: everything above
 this line — the hand-built JSON field order, the 64-byte chunking, the one-lock-per-
 repaint batching — is exactly where this project's worst bugs lived, and a substitute
 transport that bypassed it would test a different program. A `VirtualPad` conforming
 here consumes the same bytes the hardware does.

 `HIDDevice.survey()` is not part of the contract: it is static, answers "is a pad on
 the bus" without opening anything, and `BoardController` takes it as a separate
 injected closure for the same reason.
 */
public protocol PadTransport: AnyObject, Sendable {
    func open() throws
    func close()
    func onLine(_ handler: @escaping HIDDevice.LineHandler)
    func prepare(threads: [CodexProtocol.ThreadState]) -> [Data]
    func prepare(lighting: CodexProtocol.LightingConfig) -> [Data]
    func write(batch: [[Data]]) async throws
    func write(batch: [[Data]], whileCurrent: @escaping @Sendable () async -> Bool) async throws
    func send(threads: [CodexProtocol.ThreadState]) async throws
    func send(lighting: CodexProtocol.LightingConfig) async throws
    /// Running totals since the transport was created. Diffed by the caller.
    var ackStats: AckStats { get }
}

/**
 How the pad has been answering. A timed-out acknowledgement is resumed as success, so
 without these a silent device and a healthy one log the same `paint: ok`.
 */
public struct AckStats: Sendable, Equatable {
    public var acked = 0
    public var timedOut = 0
    /// Replies for a request whose wait had already given up: the pad answered, slowly.
    public var late = 0
    /// Acknowledged round trips by message size in reports, so per-message cost can be
    /// told apart from per-report cost.
    public var ackCount: [Int: Int] = [:]
    public var ackMilliseconds: [Int: Int] = [:]
    /// Time spent handing reports to IOKit, before any reply — the transport's share.
    public var reportsWritten = 0
    public var writeMilliseconds = 0

    public init(acked: Int = 0, timedOut: Int = 0, late: Int = 0) {
        self.acked = acked
        self.timedOut = timedOut
        self.late = late
    }

    public mutating func record(reports: Int, milliseconds: Int) {
        acked += 1
        ackCount[reports, default: 0] += 1
        ackMilliseconds[reports, default: 0] += milliseconds
    }

    /// "2r 470ms×88, 3r 520ms×6": mean round trip per message size.
    public var latencySummary: String {
        ackCount.keys.sorted().compactMap { size in
            guard let count = ackCount[size], count > 0 else { return nil }
            return "\(size)r \((ackMilliseconds[size] ?? 0) / count)ms×\(count)"
        }.joined(separator: ", ")
    }

    public static func - (a: AckStats, b: AckStats) -> AckStats {
        var delta = AckStats(acked: a.acked - b.acked, timedOut: a.timedOut - b.timedOut, late: a.late - b.late)
        delta.reportsWritten = a.reportsWritten - b.reportsWritten
        delta.writeMilliseconds = a.writeMilliseconds - b.writeMilliseconds
        for (size, count) in a.ackCount {
            delta.ackCount[size] = count - (b.ackCount[size] ?? 0)
            delta.ackMilliseconds[size] = (a.ackMilliseconds[size] ?? 0) - (b.ackMilliseconds[size] ?? 0)
        }
        return delta
    }
}

extension HIDDevice: PadTransport {}

extension PadTransport {
    public var ackStats: AckStats { AckStats() }

    public func write(batch: [[Data]], whileCurrent: @escaping @Sendable () async -> Bool) async throws {
        for reports in batch {
            guard await whileCurrent() else { break }
            try await write(batch: [reports])
        }
    }
}
