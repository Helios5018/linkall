import Foundation

/// Tracks only the left-Command tap following an isolated V preedit. Other keys invalidate the tap.
public struct ReplyTrigger {
    private var pressedAt: TimeInterval?
    public init() {}
    public mutating func cancel() { pressedAt = nil }
    public mutating func flags(keyCode: UInt16, commandOnly: Bool, noModifiers: Bool, pendingV: Bool, now: TimeInterval) -> Bool {
        guard pendingV, keyCode == 55 else { cancel(); return false }
        if commandOnly { pressedAt = now; return false }
        defer { cancel() }
        guard noModifiers, let start = pressedAt else { return false }
        return now >= start && now - start <= 0.6
    }
}
