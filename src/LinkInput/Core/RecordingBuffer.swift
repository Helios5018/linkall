import Foundation

/// Invalidates a run synchronously, even while the audio queue is still opening the device.
/// Late starts and audio callbacks can never resurrect a cancelled recording.
public final class RecordingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var id: UUID?
    private var pcm = Data()
    private var rate = 48_000.0
    private var byteLimit = 0
    private var accepting = false
    private var running = false
    private var peak: Float = 0
    public init() {}
    public var recording: Bool { lock.withLock { running } }
    public var level: Float { lock.withLock { peak } }
    public func begin() -> UUID {
        lock.withLock {
            let next = UUID(); id = next; pcm = Data(); accepting = false; running = false; peak = 0
            return next
        }
    }
    public func isCurrent(_ run: UUID) -> Bool { lock.withLock { id == run } }
    public func configure(_ run: UUID, rate: Double, maxDuration: TimeInterval = TimeInterval(VoiceOptions.defaultRecordingMinutes * 60)) -> Bool {
        lock.withLock {
            guard id == run, rate.isFinite, rate > 0, rate <= 192_000,
                  maxDuration.isFinite, maxDuration > 0 else { return false }
            self.rate = rate; accepting = true
            byteLimit = Int(rate * min(maxDuration, TimeInterval(VoiceOptions.recordingMinutesRange.upperBound * 60))) * 2
            // Grow with the recording instead of reserving the full 30-minute budget at startup.
            pcm.reserveCapacity(min(byteLimit, Int(rate * 2 * 60)))
            return true
        }
    }
    public func didStart(_ run: UUID) -> Bool {
        lock.withLock {
            guard id == run, accepting else { return false }
            running = true; return true
        }
    }
    /// Returns true only for the first accepted audio buffer.
    public func append(_ data: Data, level: Float, run: UUID) -> Bool {
        lock.withLock {
            guard id == run, accepting else { return false }
            let remaining = max(0, byteLimit - pcm.count)
            guard remaining > 0, !data.isEmpty else { return false }
            let first = pcm.isEmpty
            pcm.append(data.prefix(remaining)); peak = level
            return first
        }
    }
    public func finish(ifCurrent expected: UUID? = nil) -> (id: UUID?, pcm: Data, rate: Double)? {
        lock.withLock {
            if let expected, id != expected { return nil }
            let result = (id, pcm, rate)
            id = nil; pcm = Data(); accepting = false; running = false; peak = 0
            return result
        }
    }
}
