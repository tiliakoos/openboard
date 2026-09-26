import Foundation

/**
 Where the Back action goes: the places you jumped from, most recent last.

 Like a browser's history, one step per press, so a run of jumps — a video, then one
 session, then another — can be walked back to where it started.

 Generic over the place so the rules are testable without a window. A place is not
 recorded twice in a row, or Back would spend a press landing where you already are;
 and only the last `limit` are kept.
 */
public struct BackHistory<Place: Equatable> {
    private var places: [Place] = []
    private let limit: Int

    public init(limit: Int = 10) {
        self.limit = limit
    }

    public mutating func record(_ place: Place) {
        guard places.last != place else { return }
        places.append(place)
        if places.count > limit { places.removeFirst() }
    }

    /// The most recent place, removed.
    public mutating func takeLatest() -> Place? {
        places.popLast()
    }
}
