import XCTest
@testable import LinkRecordCore

final class HistoryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LinkInputHistoryTests-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }
    func testPersistenceSearchAndVersionedVoice() throws {
        let first = try HistoryStore(directory: root)
        var record = HistoryRecord(kind: .voice, app: "com.apple.TextEdit", original: "明天下午，啊不，后天下午。100%_ '中文'")
        try first.insert(record)
        record.result = "后天下午。"; record.delivered = record.result; record.status = "已复制 · 未写入"
        try first.update(record)
        let second = try HistoryStore(directory: root)
        XCTAssertEqual(try second.records(query: "中文").count, 1)
        XCTAssertEqual(try second.records(query: "100%_").count, 1)
        XCTAssertEqual(try second.records(query: "' OR 1=1").count, 0)
        XCTAssertEqual(try second.records().first, record)
        XCTAssertEqual(try second.records(kind: .typing).count, 0)
    }
    func testLateUpdateDoesNotResurrectDeletion() throws {
        let store = try HistoryStore(directory: root)
        var record = HistoryRecord(kind: .enhancement, original: "原文")
        try store.insert(record); try store.delete(record.id)
        record.result = "迟到的结果"; try store.update(record)
        XCTAssertTrue(try store.records().isEmpty)
    }
    func testDeletionRemovesImageAndRecentOnly() throws {
        let store = try HistoryStore(directory: root)
        var old = HistoryRecord(kind: .typing, original: "保留"); old.date = Date().addingTimeInterval(-600); try store.insert(old)
        var recent = HistoryRecord(kind: .screenshot, original: "删除"); recent.image = recent.id.uuidString + ".jpg"
        let url = try XCTUnwrap(store.imageURL(recent.image)); try Data([1,2,3]).write(to: url); try store.insert(recent)
        try store.deleteRecent(since: Date().addingTimeInterval(-300))
        XCTAssertEqual(try store.records().map(\.id), [old.id]); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(store.imageURL("../../secret"))
    }
    func testImageQuotaAndAgeKeepText() throws {
        let store = try HistoryStore(directory: root)
        for i in 0..<3 {
            var record = HistoryRecord(kind: .screenshot, original: "屏幕 \(i)"); record.image = "\(i).jpg"; record.starred = true
            let url = try XCTUnwrap(store.imageURL(record.image)); try Data(repeating: 1, count: 100).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(i - 3) * 100)], ofItemAtPath: url.path)
            try store.insert(record)
        }
        XCTAssertEqual(try store.pruneImages(days: 7, maxBytes: 150), 100)
        XCTAssertEqual(try store.records(starred: true).count, 3)
        XCTAssertEqual(try store.pruneImages(days: 1, maxBytes: 150, now: Date().addingTimeInterval(172800)), 0)
    }
    func testSettingsCrossConnectionAndSourceBoundaries() throws {
        let first = try HistoryStore(directory: root), second = try HistoryStore(directory: root)
        var settings = try first.settings(); XCTAssertTrue(settings.allows(.typing, app: "editor"))
        settings.paused = true; try first.saveSettings(settings)
        XCTAssertFalse(try second.settings().allows(.voice, app: "editor"))
        settings.paused = false; settings.input = false; settings.excludedApps = ["excluded"]
        XCTAssertFalse(settings.allows(.typing, app: "editor")); XCTAssertTrue(settings.allows(.activity, app: "editor"))
        XCTAssertFalse(settings.allows(.activity, app: "excluded"))
    }
    func testThirtyDayRetentionKeepsRecentImagesAndExpiredText() throws {
        let store = try HistoryStore(directory: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let settings = try store.settings()
        for age in [8, 29, 31] {
            var record = HistoryRecord(kind: .screenshot, original: "屏幕 \(age)")
            record.image = "\(age).jpg"
            let url = try XCTUnwrap(store.imageURL(record.image))
            try Data(repeating: 1, count: 100).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-Double(age) * 86400)], ofItemAtPath: url.path)
            try store.insert(record)
        }
        XCTAssertEqual(try store.pruneImages(days: settings.retentionDays, maxBytes: 1000, now: now), 200)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL("8.jpg")!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL("29.jpg")!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL("31.jpg")!.path))
        XCTAssertEqual(try store.records().count, 3)
    }
    func testContextResolvesByAppAndTime() throws {
        let store = try HistoryStore(directory: root)
        var event = HistoryRecord(kind: .activity, app: "editor", window: "项目 A"); event.date = Date().addingTimeInterval(-20); try store.insert(event)
        XCTAssertEqual(try store.contextualWindow(app: "editor", before: Date()), "项目 A")
        XCTAssertEqual(try store.contextualWindow(app: "other", before: Date()), "")
        XCTAssertEqual(try store.contextualWindow(app: "editor", before: event.date.addingTimeInterval(-1)), "")
    }
}

extension HistoryTests {
    func testContentUpdatesPreserveUserAnnotations() throws {
        let writer = try HistoryStore(directory: root), reader = try HistoryStore(directory: root)
        var record = HistoryRecord(kind: .voice, original: "语音原文")
        try writer.insert(record)
        try reader.annotate(record.id, starred: true, note: "这是重要决定")
        record.result = "整理结果"; record.status = "已请求上屏"
        XCTAssertTrue(try writer.updateContent(record))
        let saved = try XCTUnwrap(reader.records().first)
        XCTAssertEqual(saved.result, "整理结果"); XCTAssertEqual(saved.note, "这是重要决定"); XCTAssertTrue(saved.starred)
        try reader.delete(record.id)
        XCTAssertFalse(try writer.updateContent(record)); XCTAssertTrue(try reader.records().isEmpty)
    }
}

extension HistoryTests {
    func testOldContextIsNotAttachedAfterDesktopRecordingStops() throws {
        let store = try HistoryStore(directory: root)
        var record = HistoryRecord(kind: .activity, app: "editor", window: "过期窗口")
        record.date = Date().addingTimeInterval(-600); record.ended = Date().addingTimeInterval(-300)
        try store.insert(record)
        XCTAssertEqual(try store.contextualWindow(app: "editor", before: Date()), "")
    }
}

extension HistoryTests {
    func testWakeDoesNotResumeCaptureUntilUnlockAndLateResultsAreInvalidated() {
        var lifecycle = CaptureLifecycle()
        let initial = lifecycle.revision
        XCTAssertTrue(lifecycle.accepts(initial))
        lifecycle.setLocked(true); lifecycle.setSleeping(true); lifecycle.setSleeping(false)
        XCTAssertFalse(lifecycle.isActive)
        XCTAssertFalse(lifecycle.accepts(initial))
        lifecycle.setLocked(false)
        XCTAssertTrue(lifecycle.isActive)
        XCTAssertFalse(lifecycle.accepts(initial))
        let resumed = lifecycle.revision
        XCTAssertTrue(lifecycle.accepts(resumed))
        lifecycle.invalidate()
        XCTAssertFalse(lifecycle.accepts(resumed))
    }
}

extension HistoryTests {
    func testContextSwitchGetsFirstFrameBeforeRegularInterval() {
        var cadence = CaptureCadence(); let now = Date()
        cadence.attempted(context: "terminal", at: now); cadence.saved(context: "terminal")
        XCTAssertFalse(cadence.shouldCapture(context: "terminal", interval: 20, now: now.addingTimeInterval(4)))
        XCTAssertTrue(cadence.shouldCapture(context: "lark", interval: 20, now: now.addingTimeInterval(4)))
        XCTAssertTrue(cadence.needsFirstFrame(context: "lark"))
        XCTAssertTrue(cadence.shouldCapture(context: "lark", interval: 20, now: now.addingTimeInterval(1)), "A new app must not wait for the preceding app cooldown")
        cadence.attempted(context: "lark", at: now.addingTimeInterval(4))
        XCTAssertFalse(cadence.shouldCapture(context: "lark", interval: 20, now: now.addingTimeInterval(4.5)))
        XCTAssertTrue(cadence.needsFirstFrame(context: "lark"), "An abandoned capture must not suppress the next first frame")
        cadence.saved(context: "lark")
        XCTAssertFalse(cadence.needsFirstFrame(context: "lark"))
    }
    func testActivityScreenshotsAreMatchedByAppWindowAndVisit() throws {
        let store = try HistoryStore(directory: root)
        var activity = HistoryRecord(kind: .activity, app: "lark", window: "chat")
        activity.date = Date().addingTimeInterval(-30); activity.ended = Date()
        var photo = HistoryRecord(kind: .screenshot, app: "lark", window: "chat", original: "可见消息")
        photo.date = activity.date.addingTimeInterval(2); try store.insert(photo)
        var other = HistoryRecord(kind: .screenshot, app: "other", window: "chat"); other.date = photo.date; try store.insert(other)
        var old = HistoryRecord(kind: .screenshot, app: "lark", window: "chat"); old.date = activity.date.addingTimeInterval(-100); try store.insert(old)
        var different = HistoryRecord(kind: .screenshot, app: "lark", window: "different"); different.date = photo.date; try store.insert(different)
        XCTAssertEqual(try store.relatedScreenshots(to: activity).map(\.id), [photo.id])
    }
}

extension HistoryTests {
    func testSmallMessageChangeIsRetainedButCaretBlinkIsIgnored() {
        let before = [UInt8](repeating: 255, count: 256 * 256)
        var caret = before; for i in 0..<3 { caret[i] = 0 }
        var message = before; for i in 0..<30 { message[1000 + i] = 80 }
        XCTAssertFalse(ScreenChangeDetector.changed(previous: before, current: before))
        XCTAssertFalse(ScreenChangeDetector.changed(previous: before, current: caret))
        XCTAssertTrue(ScreenChangeDetector.changed(previous: before, current: message))
    }
}
