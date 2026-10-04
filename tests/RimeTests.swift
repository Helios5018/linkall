import XCTest
@testable import YiliuCore

final class RimeTests: XCTestCase {
    static var user: URL!
    override class func setUp() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        user = root.appendingPathComponent("scratch/test-rime-\(UUID().uuidString)")
        try! RimeEngine.start(shared: root.appendingPathComponent("Vendor/Rime").path, user: user.path)
    }
    override class func tearDown() { RimeEngine.shutdown(); try? FileManager.default.removeItem(at: user) }
    func testEnglishCompletionCaseSelectionAndLiteralInput() throws {
        try RimeEngine.configure(InputOptions())
        let engine = RimeEngine()
        for (code, expected) in [("hel", "hello"), ("Hel", "Hello"), ("HEL", "HELLO"), ("git", "GitHub"), ("HELL", "HE'LL")] {
            XCTAssertTrue(engine.setScheme(.english))
            for key in code.utf8 { XCTAssertTrue(engine.process(key: Int(key))) }
            let candidates = engine.candidateSlice(start: 0, count: 100).candidates
            let index = try XCTUnwrap(candidates.firstIndex(of: expected), "\(code): \(candidates)")
            XCTAssertTrue(engine.highlightCandidate(index))
            let highlighted = engine.state()
            XCTAssertEqual(highlighted.candidates[highlighted.highlighted], expected)
            engine.selectAbsolute(index)
            XCTAssertEqual(engine.state().commit, expected)
        }
        for code in ["hello", "Hello", "HELLO"] {
            XCTAssertTrue(engine.setScheme(.english))
            for key in code.utf8 { _ = engine.process(key: Int(key)); _ = engine.state() }
            XCTAssertEqual(engine.state().candidates.first, code)
            XCTAssertTrue(engine.process(key: 32))
            XCTAssertEqual(engine.state().commit, code + " ")
            XCTAssertTrue(engine.state().preedit.isEmpty)
        }
        // Enter preserves an arbitrary identifier and is consumed instead of reaching the host.
        for code in ["UnKnOwNxqz", "c-d", "/Users/test-123"] {
            XCTAssertTrue(engine.setScheme(.english))
            var output = ""
            for key in code.utf8 {
                let handled = engine.process(key: Int(key))
                output += engine.state().commit
                if !handled { output.append(Character(UnicodeScalar(key))) }
            }
            if !engine.state().preedit.isEmpty {
                XCTAssertTrue(engine.process(key: 0xff0d))
                output += engine.state().commit
            }
            XCTAssertEqual(output, code)
        }
        for key in "hel".utf8 { _ = engine.process(key: Int(key)) }
        XCTAssertTrue(engine.process(key: 0xff1b))
        XCTAssertTrue(engine.state().preedit.isEmpty)
        XCTAssertTrue(engine.state().commit.isEmpty)
    }
    func testMixedEnglishAndChineseRanking() throws {
        try RimeEngine.configure(InputOptions())
        let engine = RimeEngine()
        for scheme in [InputScheme.flypy, .pinyin, .wubi] {
            for code in ["hello", "github"] {
                XCTAssertTrue(engine.setScheme(scheme))
                for key in code.utf8 { _ = engine.process(key: Int(key)) }
                let candidates = engine.candidateSlice(start: 0, count: 100).candidates
                let expected = code == "github" ? "GitHub" : "hello"
                let index = try XCTUnwrap(candidates.firstIndex(of: expected), "\(scheme) \(code): \(candidates)")
                engine.selectAbsolute(index)
                XCTAssertEqual(engine.state().commit, expected)
            }
        }
        for (scheme, code, expected) in [(InputScheme.flypy, "nihc", "你好"), (.pinyin, "nihao", "你好"), (.wubi, "wq", "你")] {
            XCTAssertTrue(engine.setScheme(scheme))
            for key in code.utf8 { _ = engine.process(key: Int(key)) }
            XCTAssertEqual(engine.state().candidates.first, expected)
        }
        XCTAssertTrue(engine.setScheme(.flypy))
        for key in "ui".utf8 { _ = engine.process(key: Int(key)) }
        XCTAssertTrue(try XCTUnwrap(engine.state().candidates.first).unicodeScalars.contains { $0.value > 127 })
    }
    func testShiftModeSwitchPreservesRawCodeAndReturnsToChinese() throws {
        try RimeEngine.configure(InputOptions())
        let engine = RimeEngine()
        for scheme in [InputScheme.flypy, .pinyin, .wubi] {
            XCTAssertTrue(engine.setScheme(scheme))
            for key in "ni".utf8 { _ = engine.process(key: Int(key)) }
            XCTAssertEqual(engine.toggleEnglish(), "ni")
            XCTAssertEqual(engine.scheme, scheme)
            XCTAssertEqual(engine.activeScheme, .englishDirect)
            XCTAssertTrue(engine.state().preedit.isEmpty)
            for key in "hel".utf8 { XCTAssertFalse(engine.process(key: Int(key))) }
            XCTAssertTrue(engine.state().candidates.isEmpty)
            XCTAssertEqual(engine.toggleEnglish(), "")
            XCTAssertEqual(engine.activeScheme, scheme)
            XCTAssertFalse(engine.isEnglishMode)
            XCTAssertTrue(engine.state().preedit.isEmpty)
        }
        XCTAssertTrue(engine.setScheme(.englishDirect))
        for key in "AbC/Users/test-123!?".utf8 { XCTAssertFalse(engine.process(key: Int(key))) }
        XCTAssertEqual(engine.toggleEnglish(), "")
        XCTAssertEqual(engine.activeScheme, .wubi)
        for key in "wqiy".utf8 { XCTAssertTrue(engine.process(key: Int(key))) }
        XCTAssertEqual(engine.state().candidates.first, "你")
    }
    func testIceDictionaryInBothPinyinSchemes() throws {
        try RimeEngine.configure(InputOptions())
        let engine = RimeEngine()
        for (scheme, code, expected) in [
            (InputScheme.pinyin, "wusongpinyin", "雾凇拼音"),
            (.flypy, "wusspbyb", "雾凇拼音"),
            (.pinyin, "rengongzhinengdamoxing", "人工智能大模型"),
            (.flypy, "rfgsvingdamoxk", "人工智能大模型"),
            (.pinyin, "ziyanchanpin", "自研产品")
        ] {
            XCTAssertTrue(engine.setScheme(scheme))
            for key in code.utf8 { _ = engine.process(key: Int(key)) }
            XCTAssertTrue(engine.candidateSlice(start: 0, count: 10).candidates.contains(expected), "\(scheme): \(code)")
        }
        engine.clear()
    }
    func testLegacyLearningSurvivesIceUpgradeAndRestart() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shared = root.appendingPathComponent("Vendor/Rime")
        let migration = root.appendingPathComponent("scratch/test-ice-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: migration, withIntermediateDirectories: true)
        RimeEngine.shutdown()
        defer {
            RimeEngine.shutdown()
            try? FileManager.default.removeItem(at: migration)
            try? RimeEngine.start(shared: shared.path, user: Self.user.path)
        }
        // Model the previous release using its original dictionary and implicit userdb name.
        let legacy = migration.appendingPathComponent("pinyin_simp.schema.yaml")
        let source = try String(contentsOf: shared.appendingPathComponent("pinyin_simp.schema.yaml"), encoding: .utf8)
        try source.replacingOccurrences(of: "dictionary: linkinput_ice\n  user_dict: pinyin_simp", with: "dictionary: pinyin_simp")
            .write(to: legacy, atomically: true, encoding: .utf8)
        try RimeEngine.start(shared: shared.path, user: migration.path)
        var learned = ""
        do {
            let engine = RimeEngine(); XCTAssertTrue(engine.setScheme(.pinyin))
            for key in "shishi".utf8 { _ = engine.process(key: Int(key)) }
            let candidates = engine.candidateSlice(start: 0, count: 20).candidates
            let index = try XCTUnwrap(candidates.indices.dropFirst().first { candidates[$0].count == 2 })
            learned = candidates[index]
            engine.selectAbsolute(index)
            XCTAssertEqual(engine.state().commit, learned)
        }
        RimeEngine.sync(); RimeEngine.shutdown()
        try FileManager.default.removeItem(at: legacy)
        for _ in 0..<2 {
            try RimeEngine.start(shared: shared.path, user: migration.path)
            try RimeEngine.configure(InputOptions())
            do {
                let engine = RimeEngine()
                for (scheme, code) in [(InputScheme.pinyin, "shishi"), (.flypy, "uiui")] {
                    XCTAssertTrue(engine.setScheme(scheme))
                    for key in code.utf8 { _ = engine.process(key: Int(key)) }
                    XCTAssertEqual(engine.state().candidates.first, learned, "\(scheme): learned ranking must survive")
                    engine.clear()
                }
            }
            RimeEngine.shutdown()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: migration.appendingPathComponent("pinyin_simp.userdb").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: migration.appendingPathComponent("linkinput_ice.userdb").path))
    }
    func testInputPreferencesWithRealRime() throws {
        defer { try? RimeEngine.configure(InputOptions()) }
        var options = InputOptions()
        try RimeEngine.configure(options)
        let engine = RimeEngine()
        func type(_ scheme: InputScheme, _ code: String) -> RimeState {
            XCTAssertTrue(engine.setScheme(scheme)); engine.clear()
            for key in code.utf8 { XCTAssertTrue(engine.process(key: Int(key)), code) }
            return engine.state()
        }
        for (code, expected) in [("nihc", "你好"), ("nihao", "你好"), ("vsgo", "中国"), ("zhongguo", "中国"), ("wsm", "为什么")] {
            let state = type(.flypy, code)
            XCTAssertEqual(state.candidates.first, expected, "\(code): \(state.candidates)")
            XCTAssertEqual(state.preedit, code)
        }
        _ = type(.flypy, "nihc")
        _ = engine.process(key: 0xff51)
        // Rime navigator moves by syllable; the raw cursor must follow it.
        XCTAssertEqual(engine.state().cursorUTF16, 2)
        _ = engine.process(key: 0xff08)
        XCTAssertEqual(engine.state().preedit, "nhc")
        _ = engine.process(key: 0xff1b)
        XCTAssertEqual(engine.state().preedit, "")
        options.fullPinyinInDoublePinyin = false; options.showFullPinyin = true
        try RimeEngine.configure(options)
        XCTAssertEqual(type(.flypy, "nihc").preedit, "ni hao")
        options.showFullPinyin = false
        options.fuzzyPairs = [.zZh, .cCh, .sSh, .nL, .fH, .anAng, .enEng, .inIng]
        try RimeEngine.configure(options)
        for (scheme, code, expected) in [(InputScheme.pinyin, "zongguo", "中国"), (.flypy, "zsgo", "中国"), (.pinyin, "nin", "您"), (.pinyin, "nihao", "你好")] {
            _ = type(scheme, code)
            XCTAssertTrue(engine.candidateSlice(start: 0, count: 100).candidates.contains(expected), "\(scheme) \(code)")
        }
        options.fuzzyPairs = []
        try RimeEngine.configure(options)
        XCTAssertFalse(type(.pinyin, "zongguo").candidates.contains("中国"))
        XCTAssertEqual(type(.flypy, "nihc").candidates.first, "你好")
    }
    func testCandidatePageSizesAndTenthSelection() throws {
        defer { try? RimeEngine.configure(InputOptions()) }
        let engine = RimeEngine()
        for size in [5, 7, 10] {
            var options = InputOptions(); options.candidateCount = size
            try RimeEngine.configure(options)
            for (scheme, code) in [(InputScheme.pinyin, "shi"), (.flypy, "ui"), (.wubi, "a")] {
                XCTAssertTrue(engine.setScheme(scheme))
                for key in code.utf8 { _ = engine.process(key: Int(key)) }
                let first = engine.state()
                XCTAssertEqual(first.candidates.count, size, "\(scheme) size=\(size)")
                _ = engine.process(key: 0xff56)
                XCTAssertEqual(engine.state().page, 1)
                _ = engine.process(key: 0xff55)
                let expected = engine.state().candidates[size - 1]
                _ = engine.process(key: size == 10 ? 48 : 48 + size)
                XCTAssertEqual(engine.state().commit, expected, "\(scheme) size=\(size)")
            }
        }
    }
    func testHyphenStaysInRawInputAndEnterCommitsIt() throws {
        try RimeEngine.configure(InputOptions())
        let engine = RimeEngine()
        for scheme in [InputScheme.flypy, .pinyin, .wubi] {
            XCTAssertTrue(engine.setScheme(scheme))
            for key in "c-d".utf8 { _ = engine.process(key: Int(key)) }
            XCTAssertEqual(engine.state().preedit, "c-d", "\(scheme)")
            _ = engine.process(key: 0xff0d)
            XCTAssertEqual(engine.state().commit, "c-d", "\(scheme)")
        }
    }
    func testExistingInputOptionsKeepPreferencesAndDefaultToFive() throws {
        let data = Data(#"{"fullPinyinInDoublePinyin":false,"showFullPinyin":true,"fuzzyPairs":["nL"]}"#.utf8)
        let options = try JSONDecoder().decode(InputOptions.self, from: data)
        XCTAssertFalse(options.fullPinyinInDoublePinyin)
        XCTAssertTrue(options.showFullPinyin)
        XCTAssertEqual(options.fuzzyPairs, [.nL])
        XCTAssertEqual(options.pageSize, 5)
        XCTAssertEqual(options.visibleCandidateRows, 5)
        for (stored, expected) in [(0, 5), (99, 10), (8, 8)] {
            let decoded = try JSONDecoder().decode(InputOptions.self, from: Data("{\"candidateCount\":\(stored)}".utf8))
            XCTAssertEqual(decoded.pageSize, expected)
        }
    }
    func testExpandedCandidateWindowScrollsAcrossRimePages() throws {
        try RimeEngine.configure(InputOptions())
        let engine = RimeEngine()
        for (scheme, code) in [(InputScheme.flypy, "ui"), (.pinyin, "shi"), (.wubi, "a")] {
            XCTAssertTrue(engine.setScheme(scheme))
            for key in code.utf8 { _ = engine.process(key: Int(key)) }
            let before = engine.state()
            let first = engine.candidateSlice(start: 0, count: 5)
            XCTAssertEqual(first.candidates.count, 5); XCTAssertTrue(first.hasMore)
            var viewport = CandidateViewport(); viewport.expanded = true
            for index in 0...12 {
                if index > 0 { XCTAssertTrue(engine.highlightCandidate(index)) }
                viewport.reveal(index, rows: 5)
                XCTAssertEqual(viewport.start, max(0, index - 4))
                let slice = engine.candidateSlice(start: viewport.start, count: 5)
                XCTAssertEqual(slice.candidates.count, 5)
                let state = engine.state()
                XCTAssertEqual(state.page * RimeEngine.options.pageSize + state.highlighted, index)
                XCTAssertEqual(state.preedit, before.preedit)
                XCTAssertTrue(state.commit.isEmpty)
            }
            for index in stride(from: 11, through: 0, by: -1) {
                XCTAssertTrue(engine.highlightCandidate(index)); viewport.reveal(index, rows: 5)
                XCTAssertTrue((viewport.start..<(viewport.start + 5)).contains(index))
            }
            XCTAssertEqual(viewport.start, 0)
            XCTAssertEqual(engine.candidateSlice(start: 0, count: 5).candidates, first.candidates)
            let expected = engine.candidateSlice(start: 8, count: 5).candidates[2]
            engine.selectAbsolute(10)
            XCTAssertEqual(engine.state().commit, expected)
            viewport.reset(); XCTAssertFalse(viewport.expanded); XCTAssertEqual(viewport.start, 0)
        }
        XCTAssertTrue(engine.setScheme(.pinyin))
        for key in "dia".utf8 { _ = engine.process(key: Int(key)) }
        let tailBefore = engine.state().preedit
        var index = 0
        while index < 1000 && engine.highlightCandidate(index + 1) { index += 1 }
        XCTAssertLessThan(index, 1000)
        let final = engine.candidateSlice(start: index, count: 5)
        XCTAssertEqual(final.candidates.count, 1); XCTAssertFalse(final.hasMore)
        let lastState = engine.state()
        XCTAssertEqual(lastState.page * RimeEngine.options.pageSize + lastState.highlighted, index)
        XCTAssertEqual(lastState.preedit, tailBefore)
        XCTAssertTrue(lastState.commit.isEmpty)
        engine.clear()
        XCTAssertTrue(engine.candidateSlice(start: 0, count: 5).candidates.isEmpty)
    }
    func testExpandedGridKeepsFiveRowsAndScrollsWholeRows() throws {
        defer { try? RimeEngine.configure(InputOptions()) }
        var options = InputOptions(); options.candidateCount = 8
        try RimeEngine.configure(options)
        let engine = RimeEngine(); XCTAssertTrue(engine.setScheme(.pinyin))
        for key in "shi".utf8 { _ = engine.process(key: Int(key)) }
        var viewport = CandidateViewport(); viewport.expanded = true
        for selected in stride(from: 0, through: 48, by: 8) {
            _ = engine.highlightCandidate(selected)
            viewport.reveal(selected, rows: 5, columns: 8)
            XCTAssertEqual(viewport.start % 8, 0)
            XCTAssertEqual(viewport.start, max(0, selected - 32))
            XCTAssertEqual(engine.candidateSlice(start: viewport.start, count: 40).candidates.count, 40)
            XCTAssertEqual(engine.state().page * 8, selected)
        }
        for selected in stride(from: 40, through: 0, by: -8) {
            _ = engine.highlightCandidate(selected); viewport.reveal(selected, rows: 5, columns: 8)
            XCTAssertTrue((viewport.start..<(viewport.start + 40)).contains(selected))
        }
        XCTAssertEqual(viewport.start, 0)
        _ = engine.highlightCandidate(45)
        let state = engine.state()
        let numberedChoice = state.page * 8 + 2 // key 3 in the highlighted row
        XCTAssertEqual(numberedChoice, 42)
        let expected = engine.candidateSlice(start: numberedChoice, count: 1).candidates[0]
        engine.selectAbsolute(numberedChoice)
        XCTAssertEqual(engine.state().commit, expected)
    }
    func testFourSchemesWithoutAI() {
        let engine = RimeEngine()
        for (scheme, code, expected) in [(InputScheme.flypy, "nihc", "你好"), (.pinyin, "nihao", "你好"), (.wubi, "wq", "你")] {
            XCTAssertTrue(engine.setScheme(scheme))
            for c in code.utf8 { XCTAssertTrue(engine.process(key: Int(c))) }
            let state = engine.state(); XCTAssertTrue(state.candidates.contains(expected), "\(scheme): \(state.candidates)")
            engine.select(state.candidates.firstIndex(of: expected) ?? 0)
            XCTAssertEqual(engine.state().commit, expected)
        }
        XCTAssertTrue(engine.setScheme(.englishDirect))
        for c in "AbC/Users/test-123!?".utf8 { XCTAssertFalse(engine.process(key: Int(c))) }
        XCTAssertEqual(engine.state().preedit, "")
    }
    func testInitialsAbbreviation() {
        let engine = RimeEngine()
        // Full-pinyin initials (sh → s) work in both pinyin schemes.
        for (scheme, code) in [(InputScheme.pinyin, "wsm"), (.flypy, "wsm")] {
            XCTAssertTrue(engine.setScheme(scheme)); engine.clear()
            for c in code.utf8 { _ = engine.process(key: Int(c)) }
            let state = engine.state()
            XCTAssertEqual(state.candidates.first, "为什么", "\(scheme) \(code): \(state.candidates)")
        }
        engine.clear()
        // Abbreviations must not displace ordinary flypy syllables.
        XCTAssertTrue(engine.setScheme(.flypy))
        for c in "nihc".utf8 { _ = engine.process(key: Int(c)) }
        XCTAssertEqual(engine.state().candidates.first, "你好")
    }
    func testWubiFullCodeAfterEnglish() {
        let engine = RimeEngine()
        XCTAssertTrue(engine.setScheme(.english))
        XCTAssertTrue(engine.setScheme(.wubi))
        var handled: [Bool] = []
        for c in "wqiy".utf8 { handled.append(engine.process(key: Int(c))) }
        let state = engine.state()
        XCTAssertEqual(handled, [true, true, true, true])
        XCTAssertTrue(state.commit == "你" || state.candidates.first == "你", "commit=\(state.commit) preedit=\(state.preedit) candidates=\(state.candidates)")
    }
    func testEscapePagingAndSchemeSwitch() {
        let engine = RimeEngine()
        _ = engine.setScheme(.pinyin)
        for c in "shi".utf8 { _ = engine.process(key: Int(c)) }
        XCTAssertFalse(engine.state().candidates.isEmpty)
        _ = engine.process(key: 0xff56); XCTAssertGreaterThan(engine.state().page, 0)
        _ = engine.process(key: 0xff1b); XCTAssertEqual(engine.state().preedit, "")
        _ = engine.process(key: 110); _ = engine.setScheme(.wubi)
        XCTAssertEqual(engine.state().preedit, "")
    }
}
