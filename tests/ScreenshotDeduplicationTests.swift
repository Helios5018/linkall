import XCTest
@testable import LinkRecordCore

final class ScreenshotDeduplicationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LinkRecordDedup-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }
    private func frame(_ hash: String, at seconds: Double, app: String = "editor", window: String = "A") -> HistoryRecord {
        var record = HistoryRecord(kind: .screenshot, app: app, window: window, original: "OCR \(hash)")
        record.screenshotFingerprint = hash
        record.screenshotOCRComplete = true
        record.date = Date(timeIntervalSince1970: seconds); record.ended = record.date
        return record
    }
    func testExactPixelsPreserveSingleChannelEditsAndDimensions() {
        let pixels = Data(repeating: 255, count: 16)
        let hash = ScreenshotFingerprint.make(width: 2, height: 2, rgba: pixels)
        XCTAssertEqual(hash, ScreenshotFingerprint.make(width: 2, height: 2, rgba: pixels))
        var changed = pixels; changed[0] = 254
        XCTAssertNotEqual(hash, ScreenshotFingerprint.make(width: 2, height: 2, rgba: changed))
        XCTAssertNotEqual(hash, ScreenshotFingerprint.make(width: 4, height: 1, rgba: pixels))
    }
    func testLegacyRecordsDecodeWithoutFingerprint() throws {
        let record = HistoryRecord(kind: .screenshot, original: "旧记录")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json.removeValue(forKey: "screenshotFingerprint")
        let decoded = try JSONDecoder().decode(HistoryRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.screenshotFingerprint)
        let store = try HistoryStore(directory: root); try store.insert(decoded)
        XCTAssertEqual(try store.records().first, decoded)
    }
    func testContinuousFrameExtendsButReturnVisitRemainsSeparate() throws {
        let store = try HistoryStore(directory: root)
        let a = try XCTUnwrap(store.saveScreenshot(frame("a", at: 100), jpeg: Data([1, 2, 3])))
        try store.annotate(a.id, starred: true, note: "保留备注")
        let extended = try XCTUnwrap(store.saveScreenshot(frame("a", at: 130), jpeg: nil, continuing: a.id))
        XCTAssertEqual(extended.id, a.id); XCTAssertEqual(extended.date, a.date)
        XCTAssertEqual(extended.ended.timeIntervalSince1970, 130)
        XCTAssertTrue(extended.starred); XCTAssertEqual(extended.note, "保留备注")
        _ = try store.saveScreenshot(frame("b", at: 160, window: "B"), jpeg: Data([4, 5]))
        let returned = try XCTUnwrap(store.saveScreenshot(frame("a", at: 190), jpeg: nil))
        XCTAssertNotEqual(returned.id, a.id); XCTAssertEqual(returned.date.timeIntervalSince1970, 190)
        XCTAssertEqual(returned.image, a.image); XCTAssertFalse(returned.starred)
        XCTAssertEqual(try store.records().count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.imageDirectory.path).count, 2)
        var visit = HistoryRecord(kind: .activity, app: "editor", window: "A")
        visit.date = returned.date; visit.ended = returned.date
        XCTAssertEqual(try store.relatedScreenshots(to: visit).map(\.id), [returned.id])
    }
    func testDifferentContextAndExplicitBookmarkDoNotMerge() throws {
        let store = try HistoryStore(directory: root)
        let a = try XCTUnwrap(store.saveScreenshot(frame("a", at: 100), jpeg: Data([1])))
        let other = try XCTUnwrap(store.saveScreenshot(frame("a", at: 110, app: "browser"), jpeg: nil, continuing: a.id))
        XCTAssertNotEqual(other.id, a.id); XCTAssertEqual(other.image, a.image)
        var mark = frame("a", at: 120); mark.starred = true
        let bookmark = try XCTUnwrap(store.saveScreenshot(mark, jpeg: nil))
        XCTAssertTrue(bookmark.starred); XCTAssertNotEqual(bookmark.id, a.id)
        XCTAssertEqual(try store.records().count, 3)
    }
    func testReuseSurvivesReopeningAndDeletingOneReference() throws {
        let store = try HistoryStore(directory: root)
        let a = try XCTUnwrap(store.saveScreenshot(frame("a", at: 100), jpeg: Data([1, 2, 3])))
        let reopened = try HistoryStore(directory: root)
        XCTAssertEqual(try reopened.reusableScreenshot(fingerprint: "a")?.original, a.original)
        let b = try XCTUnwrap(reopened.saveScreenshot(frame("a", at: 200), jpeg: nil))
        let image = try XCTUnwrap(store.imageURL(a.image))
        try store.delete(a.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        XCTAssertEqual(try reopened.reusableScreenshot(fingerprint: "a")?.id, b.id)
        try reopened.delete(b.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
        XCTAssertNil(try store.reusableScreenshot(fingerprint: "a"))
    }
    func testRecentDeletionPreservesOlderSharedImage() throws {
        let store = try HistoryStore(directory: root)
        let a = try XCTUnwrap(store.saveScreenshot(frame("a", at: 100), jpeg: Data([1])))
        _ = try store.saveScreenshot(frame("a", at: 200), jpeg: nil)
        try store.deleteRecent(since: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(try store.records().map(\.id), [a.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(a.image)!.path))
    }
    func testQuotaCountsSharedImageOnceAndMissingImageIsNotReused() throws {
        let store = try HistoryStore(directory: root)
        let a = try XCTUnwrap(store.saveScreenshot(frame("a", at: 100), jpeg: Data(repeating: 1, count: 100)))
        _ = try store.saveScreenshot(frame("a", at: 200), jpeg: nil)
        XCTAssertEqual(try store.pruneImages(days: 30, maxBytes: 100), 100)
        XCTAssertEqual(try store.pruneImages(days: 30, maxBytes: 99), 0)
        XCTAssertEqual(try store.records().count, 2)
        XCTAssertNil(try store.reusableScreenshot(fingerprint: "a"))
        XCTAssertNil(try store.saveScreenshot(frame("a", at: 300), jpeg: nil))
        let fresh = try XCTUnwrap(store.saveScreenshot(frame("a", at: 400), jpeg: Data([2])))
        XCTAssertNotEqual(fresh.image, a.image, "Do not resurrect the image associated with expired records")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(a.image)!.path))
    }
    func testReusingImageDoesNotResetThirtyDayRetention() throws {
        let store = try HistoryStore(directory: root), now = Date()
        let a = try XCTUnwrap(store.saveScreenshot(frame("a", at: 100), jpeg: Data([1])))
        let image = try XCTUnwrap(store.imageURL(a.image))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 86400)], ofItemAtPath: image.path)
        _ = try store.saveScreenshot(frame("a", at: 200), jpeg: nil)
        XCTAssertEqual(try store.pruneImages(days: 30, maxBytes: 100, now: now), 0)
        XCTAssertEqual(try store.records().count, 2)
    }
    func testLateReuseCannotRestoreDeletedRecordOrImage() throws {
        let store = try HistoryStore(directory: root)
        let a = try XCTUnwrap(store.saveScreenshot(frame("a", at: 100), jpeg: Data([1])))
        _ = try store.saveScreenshot(frame("a", at: 200), jpeg: nil)
        try store.delete(a.id)
        XCTAssertNil(try store.saveScreenshot(frame("a", at: 300), jpeg: nil, continuing: a.id))
        XCTAssertEqual(try store.records().count, 1)
        try store.deleteRecent(since: .distantPast)
        XCTAssertNil(try store.saveScreenshot(frame("a", at: 400), jpeg: nil))
        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.imageDirectory.path).isEmpty)
    }
    func testFailedOCRIsRetriedWithoutDuplicatingImage() throws {
        let store = try HistoryStore(directory: root)
        var failed = frame("a", at: 100); failed.screenshotOCRComplete = false; failed.original = "OCR failed"
        let first = try XCTUnwrap(store.saveScreenshot(failed, jpeg: Data([1])))
        XCTAssertNil(try store.reusableScreenshot(fingerprint: "a"))
        let retried = try XCTUnwrap(store.saveScreenshot(frame("a", at: 200), jpeg: Data([1]), continuing: first.id))
        XCTAssertEqual(retried.id, first.id); XCTAssertEqual(retried.image, first.image)
        XCTAssertEqual(try store.reusableScreenshot(fingerprint: "a")?.original, "OCR a")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.imageDirectory.path).count, 1)
        var otherFailed = frame("b", at: 300); otherFailed.screenshotOCRComplete = false
        let b = try XCTUnwrap(store.saveScreenshot(otherFailed, jpeg: Data([2])))
        let returnVisit = try XCTUnwrap(store.saveScreenshot(frame("b", at: 400), jpeg: Data([2])))
        XCTAssertEqual(returnVisit.image, b.image)
    }
}
