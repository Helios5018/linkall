import Foundation

/// Context switches get their own first frame; a short shared floor still bounds rapid switching.
public struct CaptureCadence: Sendable {
    public private(set) var lastAttempt = Date.distantPast
    public private(set) var savedContext: String?
    public private(set) var attemptedContext: String?
    public init() {}
    public func shouldCapture(context: String, interval: TimeInterval, now: Date = Date(), explicit: Bool = false) -> Bool {
        if explicit { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        if context != savedContext { return context != attemptedContext || elapsed >= 1 }
        return elapsed >= max(3, interval)
    }
    public func needsFirstFrame(context: String) -> Bool { context != savedContext }
    public mutating func attempted(context: String, at date: Date = Date()) { lastAttempt = date; attemptedContext = context }
    public mutating func saved(context: String) { savedContext = context }
    public mutating func reset() { savedContext = nil; attemptedContext = nil }
}

public enum ScreenChangeDetector {
    /// Preserve small text edits, while ignoring a handful of blinking-caret pixels.
    public static func changed(previous: [UInt8]?, current: [UInt8]) -> Bool {
        guard let previous, previous.count == current.count, !current.isEmpty else { return true }
        var total = 0, significant = 0
        for (a, b) in zip(previous, current) {
            let delta = abs(Int(a) - Int(b)); total += delta
            if delta >= 12 { significant += 1 }
        }
        return significant >= max(12, current.count / 4000) || Double(total) / Double(current.count) >= 0.5
    }
}
