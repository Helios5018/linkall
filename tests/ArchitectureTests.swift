import XCTest
import LinkAllShared
import LinkRecordCore

final class ArchitectureTests: XCTestCase {
    func testRenamePreservesPersistedIdentityAndHistoryLocation() {
        XCTAssertEqual(LinkAllIdentity.inputBundle, "work.yiliu.inputmethod.Yiliu")
        XCTAssertEqual(LinkAllIdentity.shellBundle, "work.yiliu.companion")
        XCTAssertEqual(LinkAllIdentity.keychainService, "work.yiliu.inputmethod.Yiliu")
        XCTAssertTrue(HistoryPaths.root.path.hasSuffix("Library/Application Support/Yiliu/History"))
        XCTAssertEqual(LinkAllIdentity.shellURL.lastPathComponent, "LinkAll.app")
    }
    func testControlEnvelopePreservesTargetAndRejectsUnknownActions() throws {
        for action in [InputAction.enhance, .voice, .activate] {
            let command = InputCommand(action, targetPID: 123)
            XCTAssertEqual(try JSONDecoder().decode(InputCommand.self, from: JSONEncoder().encode(command)), command)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(InputCommand.self, from: Data(#"{"version":1,"action":"executeShell","value":"anything"}"#.utf8)))
    }
    func testMetadataContainsModesAndNoRecordPayload() throws {
        let state = InputSnapshot(activity: "中", scheme: "flypy", schemes: [.init(id: "flypy", title: "小鹤双拼")], voiceMode: "raw", voiceModes: [.init(id: "raw", title: "原文")], manualMode: "polish", manualModes: [.init(id: "polish", title: "整理")])
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(InputSnapshot.self, from: data), state)
        let keys = Set((try JSONSerialization.jsonObject(with: data) as! [String: Any]).keys)
        XCTAssertTrue(keys.isDisjoint(with: ["token", "text", "audio", "records", "screenshots"]))
    }
}
