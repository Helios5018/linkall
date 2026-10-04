import XCTest
@testable import YiliuCore

final class DraftTests: XCTestCase {
    func testEditingRejectsLateResultEvenIfTextMatchesAgain() {
        let d = DraftSession(); let target = UUID(); d.begin(text: "不行 周五？", target: target)
        let request = d.startRequest()!
        d.edit("周六？"); d.edit("不行 周五？")
        XCTAssertFalse(d.receive("周五可以吗？", stamp: request))
    }
    func testSessionSwitchAndCancellationRejectResults() {
        let d = DraftSession(); d.begin(text: "明天", target: UUID()); let request = d.startRequest()!
        d.begin(text: "明天", target: UUID())
        XCTAssertFalse(d.receive("明天交付", stamp: request))
        let fresh = d.startRequest()!; d.cancelRequest()
        XCTAssertFalse(d.receive("明天交付", stamp: fresh))
    }
    func testCommitIsOneShotIncludingUncertainDelivery() {
        let d = DraftSession(), target = UUID(); d.begin(text: "你好👨‍👩‍👦", target: target)
        XCTAssertNil(d.beginCommit(target: UUID()))
        let ticket = d.beginCommit(target: target)!
        XCTAssertNil(d.beginCommit(target: target))
        d.finishCommit(ticket, verified: false)
        XCTAssertEqual(d.commitState, .unknown)
        XCTAssertNil(d.beginCommit(target: target))
        d.edit("重复写入"); XCTAssertEqual(d.text, "你好👨‍👩‍👦")
    }
    func testInflightRequestBlocksCommitAndReformattedResultCanBeAdopted() {
        let d = DraftSession(), target = UUID(); d.begin(text: "准备500g肉，煮熟后切条", target: target)
        let request = d.startRequest()!
        XCTAssertNil(d.beginCommit(target: target))
        let result = "1. 准备 500g 肉\n2. 煮熟后切条\n\n完成。"
        XCTAssertTrue(d.receive(result, stamp: request))
        d.acceptSuggestion(); XCTAssertEqual(d.text, result)
        XCTAssertNotNil(d.beginCommit(target: target))
    }
    func testSuspendExpiryAndLockClear() {
        let d = DraftSession(), target = UUID(); d.begin(text: "private", target: target)
        let date = Date(); let request = d.startRequest()!; d.suspend(now: date)
        XCTAssertFalse(d.receive("late", stamp: request)); XCTAssertNil(d.beginCommit(target: target))
        XCTAssertFalse(d.resume(target: UUID(), now: date))
        XCTAssertFalse(d.resume(target: target, now: date.addingTimeInterval(600)))
        XCTAssertEqual(d.text, ""); XCTAssertNil(d.target)
    }
    func testAcceptUndoRestore() {
        let d = DraftSession(); d.begin(text: "不行 周五？", target: UUID())
        let request = d.startRequest()!; XCTAssertTrue(d.receive("这个时间不方便，可以改到周五吗？", stamp: request))
        d.acceptSuggestion(); XCTAssertTrue(d.text.contains("不方便"))
        d.undo(); XCTAssertEqual(d.text, "不行 周五？")
        d.edit("another"); d.restoreOriginal(); XCTAssertEqual(d.text, "不行 周五？")
    }
}
