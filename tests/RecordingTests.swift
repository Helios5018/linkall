import XCTest
@testable import YiliuCore

final class RecordingTests: XCTestCase {
    func testCancelDuringDeviceStartupRejectsLateStartAndSamples() {
        let buffer = RecordingBuffer()
        let run = buffer.begin()
        XCTAssertTrue(buffer.configure(run, rate: 48_000))
        _ = buffer.finish()
        XCTAssertFalse(buffer.didStart(run))
        XCTAssertFalse(buffer.append(Data([1, 2]), level: 1, run: run))
        XCTAssertFalse(buffer.recording)
        XCTAssertEqual(buffer.level, 0)
        XCTAssertEqual(buffer.finish()?.pcm.count, 0)
    }
    func testOldCancellationCannotStopNewRecording() {
        let buffer = RecordingBuffer()
        let old = buffer.begin()
        let current = buffer.begin()
        XCTAssertTrue(buffer.configure(current, rate: 48_000))
        XCTAssertTrue(buffer.didStart(current))
        XCTAssertNil(buffer.finish(ifCurrent: old))
        XCTAssertFalse(buffer.append(Data([9, 9]), level: 1, run: old))
        XCTAssertTrue(buffer.append(Data([1, 2]), level: 0.5, run: current))
        XCTAssertTrue(buffer.recording)
        XCTAssertEqual(buffer.finish()?.pcm, Data([1, 2]))
    }
    func testRecordingLimitAndStopClearsLevelAndSamples() {
        let buffer = RecordingBuffer()
        let run = buffer.begin()
        XCTAssertTrue(buffer.configure(run, rate: 10, maxDuration: 60))
        XCTAssertTrue(buffer.didStart(run))
        XCTAssertTrue(buffer.append(Data(repeating: 7, count: 1300), level: 0.5, run: run))
        XCTAssertFalse(buffer.append(Data([8, 8]), level: 1, run: run))
        XCTAssertEqual(buffer.finish()?.pcm.count, 1200)
        XCTAssertFalse(buffer.recording)
        XCTAssertEqual(buffer.level, 0)
        XCTAssertFalse(buffer.append(Data([1, 2]), level: 1, run: run))
    }
    func testLongRecordingRetainsAudioPastOneMinuteAndClampsAtThirtyMinutes() {
        // Low sample rate exercises real byte boundaries without allocating large test buffers.
        for minutes in [10, 30, 60] {
            let buffer = RecordingBuffer(), rate = 10
            let run = buffer.begin()
            XCTAssertTrue(buffer.configure(run, rate: Double(rate), maxDuration: Double(minutes * 60)))
            XCTAssertTrue(buffer.didStart(run))
            for _ in 0..<min(minutes, 30) {
                _ = buffer.append(Data(repeating: 7, count: rate * 2 * 60), level: 0.5, run: run)
            }
            _ = buffer.append(Data([8, 8]), level: 1, run: run)
            let capture = buffer.finish()!
            XCTAssertEqual(capture.pcm.count, rate * 2 * 60 * min(minutes, 30))
            XCTAssertEqual(capture.pcm.last, 7)
        }
        let buffer = RecordingBuffer(), run = buffer.begin()
        XCTAssertTrue(buffer.configure(run, rate: 10))
        _ = buffer.append(Data(repeating: 7, count: 12002), level: 0.5, run: run)
        XCTAssertEqual(buffer.finish()?.pcm.count, 12000)
    }
}
