import Foundation

/// The pad's `device.status` reply: firmware, active layer, battery.
public struct PadStatus: Equatable, Sendable, Decodable {
    public static let method = "device.status"

    public let firmware: String
    public let layer: Int?
    public let battery: Int?
    public let isCharging: Bool?

    enum CodingKeys: String, CodingKey {
        case firmware = "version", layer = "layer_index", battery, isCharging = "is_charging"
    }

    private struct Reply: Decodable { let result: PadStatus }

    /// Nil for any line that is not a status reply. Only that reply carries `version`;
    /// newer firmware no longer echoes the method.
    public static func parse(_ line: Data) -> PadStatus? {
        try? JSONDecoder().decode(Reply.self, from: line).result
    }
}
