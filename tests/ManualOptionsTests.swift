import XCTest
@testable import YiliuCore

final class ManualOptionsTests: XCTestCase {
    func testOldSettingsUseBuiltInModeAndBundledPrompt() throws {
        let options = try JSONDecoder().decode(ManualOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options.modes, [ManualMode.builtIn])
        XCTAssertEqual(options.selectedMode.effectivePrompt, ExpressionGuard.systemPrompt)
        XCTAssertTrue(options.selectedMode.effectivePrompt.contains("按表达需要重新分段"))
    }
    func testModesAndSelectionPersistWithIndependentPrompts() throws {
        var options = ManualOptions()
        let custom = ManualMode(name: "翻译", systemPrompt: "将草稿翻译成英文，以 JSON 返回 text 和 note。")
        options.modes[0].systemPrompt = "修改后的默认模式"
        options.modes.append(custom); options.selectedModeID = custom.id
        let loaded = try JSONDecoder().decode(ManualOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(loaded, options)
        XCTAssertEqual(loaded.selectedMode, custom)
        XCTAssertEqual(loaded.modes[0].effectivePrompt, "修改后的默认模式")
        var reset = loaded; reset.modes[0].systemPrompt = nil
        XCTAssertEqual(reset.modes[0].effectivePrompt, ExpressionGuard.systemPrompt)
        XCTAssertEqual(reset.selectedMode, custom)
        XCTAssertEqual(VoiceOptions().selectedMode.id, DictationMode.polishID)
    }
    func testBuiltInSurvivesDeletionAndMissingSelectionFallsBack() throws {
        var options = ManualOptions()
        let custom = ManualMode(name: "摘要")
        options.modes = [custom, ManualMode(id: ManualMode.defaultID, name: "改名", systemPrompt: "自定义规则")]
        XCTAssertEqual(options.modes.map(\.name), ["整理", "摘要"])
        XCTAssertEqual(options.modes[0].systemPrompt, "自定义规则")
        options.selectedModeID = custom.id; options.modes.removeAll { $0.id == custom.id }
        XCTAssertEqual(options.selectedMode.id, ManualMode.defaultID)
        options.modes = []; XCTAssertEqual(options.modes, [ManualMode.builtIn])
        let decoded = try JSONDecoder().decode(ManualOptions.self, from: Data("{\"modes\":[]}".utf8))
        XCTAssertEqual(decoded.selectedMode.id, ManualMode.defaultID)
    }
}
