import Foundation
import CRime

public enum InputScheme: String, CaseIterable, Codable {
    case flypy = "double_pinyin_flypy", pinyin = "pinyin_simp", wubi = "wubi86", english = "ascii"
    case englishDirect = "ascii_direct"
    public var isEnglish: Bool { self == .english || self == .englishDirect }
    var resourceID: String { self == .english ? "linkinput_english" : rawValue }
    public var title: String {
        switch self { case .flypy: return "小鹤双拼"; case .pinyin: return "全拼"; case .wubi: return "五笔 86"; case .english: return "English 补全"; case .englishDirect: return "英文直通" }
    }
}
public struct RimeState {
    public var preedit: String = ""
    public var commit: String = ""
    public var candidates: [String] = []
    public var highlighted = 0
    public var page = 0
    public var lastPage = true
    public var cursorUTF16 = 0
    public init(preedit: String = "", commit: String = "", candidates: [String] = [], highlighted: Int = 0, page: Int = 0, lastPage: Bool = true, cursorUTF16: Int = 0) {
        self.preedit = preedit; self.commit = commit; self.candidates = candidates; self.highlighted = highlighted
        self.page = page; self.lastPage = lastPage; self.cursorUTF16 = cursorUTF16
    }
}
/// All calls are serialized on the IME's main thread; initialization happens before accepting clients.
public final class RimeEngine {
    private static var sharedDirectory = ""
    private static var userDirectory = ""
    public private(set) static var options = InputOptions()
    private static var schemaIDs: [InputScheme: String] = [:]
    public private(set) static var revision = 0
    public private(set) var revision = -1
    public static func configure(_ options: InputOptions) throws {
        var ids: [InputScheme: String] = [:]
        for scheme in [InputScheme.english, .flypy, .pinyin, .wubi] {
            let id = "linkinput_\(scheme.rawValue)_\(options.schemaSuffix)"
            let source = try String(contentsOfFile: sharedDirectory + "/" + scheme.resourceID + ".schema.yaml", encoding: .utf8)
            let path = userDirectory + "/" + id + ".schema.yaml"
            let contents = try options.schema(source: source, scheme: scheme, id: id)
            if (try? String(contentsOfFile: path, encoding: .utf8)) != contents {
                try contents.write(toFile: path, atomically: true, encoding: .utf8)
            }
            guard yl_deploy(path) != 0 else {
                throw NSError(domain: "LinkInput.Rime", code: 2, userInfo: [NSLocalizedDescriptionKey: "输入方案编译失败，原设置仍然有效。"])
            }
            ids[scheme] = id
        }
        Self.options = options; schemaIDs = ids; revision += 1
    }
    public static func start(shared: String, user: String, deploy: Bool = true) throws {
        try FileManager.default.createDirectory(atPath: user, withIntermediateDirectories: true)
        sharedDirectory = shared; userDirectory = user
        _ = yl_start(shared, user, deploy ? 1 : 0)
    }
    public static func shutdown() { yl_stop(); schemaIDs = [:]; options = InputOptions(); revision = 0 }
    public static func sync() { yl_sync() }
    private let session: UInt
    public private(set) var scheme: InputScheme = .flypy
    public private(set) var activeScheme: InputScheme = .flypy
    private var lastChinese: InputScheme = .flypy
    private var commitInput = ""
    private var appendCommitSpace = false
    public init() { session = yl_session(); _ = setScheme(.flypy) }
    deinit { yl_destroy(session) }
    @discardableResult public func setScheme(_ scheme: InputScheme) -> Bool {
        guard activate(scheme) else { return false }
        self.scheme = scheme; revision = Self.revision
        return true
    }
    private func activate(_ target: InputScheme) -> Bool {
        let base: InputScheme = target == .englishDirect ? lastChinese : target
        guard yl_schema(session, Self.schemaIDs[base] ?? base.resourceID) != 0 else { return false }
        yl_ascii(session, target == .englishDirect ? 1 : 0)
        activeScheme = target
        if !target.isEnglish { lastChinese = target }
        commitInput = ""; appendCommitSpace = false
        return true
    }
    /// Shift goes to plain keyboard English (not completion) and back; returns the composition for the host to insert first.
    public func toggleEnglish() -> String {
        let input = rawInput
        let target: InputScheme = activeScheme.isEnglish ? lastChinese : .englishDirect
        guard activate(target) else { return "" }
        return input
    }
    private var rawInput: String { yl_input(session).map { String(cString: $0) } ?? "" }
    public var isEnglishMode: Bool { activeScheme.isEnglish }
    public var isEnglishCompletion: Bool { activeScheme == .english }
    public func process(key: Int, modifiers: Int = 0) -> Bool {
        commitInput = rawInput
        appendCommitSpace = isEnglishCompletion && key == 32 && modifiers == 0 && !commitInput.isEmpty
        return yl_key(session, Int32(key), Int32(modifiers)) != 0
    }
    @discardableResult public func highlightCandidate(_ index: Int) -> Bool {
        guard index >= 0, index <= Int(Int32.max), !candidateSlice(start: index, count: 1).candidates.isEmpty else { return false }
        return yl_highlight(session, Int32(index)) != 0
    }
    public func selectAbsolute(_ index: Int, appendSpace: Bool = false) {
        guard index >= 0, index <= Int(Int32.max) else { return }
        commitInput = rawInput; appendCommitSpace = isEnglishCompletion && appendSpace
        _ = yl_select_absolute(session, Int32(index))
    }
    /// A bounded slice of the complete candidate list, independent of Rime's internal pages.
    public func candidateSlice(start: Int, count: Int) -> (candidates: [String], hasMore: Bool) {
        guard start >= 0, start <= Int(Int32.max), let pointer = yl_candidates(session, Int32(start), Int32(min(100, max(1, count)))) else { return ([], false) }
        defer { yl_free_state(pointer) }
        let raw = pointer.pointee
        let input = rawInput
        return ((0..<Int(raw.count)).map { englishCase(String(cString: raw.candidates[$0]!), input: input) }, raw.last_page == 0)
    }
    public func clear() { yl_clear(session); commitInput = ""; appendCommitSpace = false }
    public func select(_ index: Int) {
        commitInput = rawInput; appendCommitSpace = false
        _ = yl_select(session, Int32(index))
    }
    private func englishCase(_ text: String, input: String) -> String {
        let letters = String(text.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) })
        guard !input.isEmpty, input.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
              letters.lowercased().hasPrefix(input.lowercased()) else { return text }
        if input.count > 1 && input == input.uppercased() { return text.uppercased() }
        if input.first?.isUppercase == true, let first = text.firstIndex(where: { $0.isLetter }) {
            return String(text[..<first]) + String(text[first]).uppercased() + text[text.index(after: first)...]
        }
        return text
    }
    public func state() -> RimeState {
        guard let pointer = yl_state(session) else { return RimeState() }
        defer { yl_free_state(pointer) }
        let raw = pointer.pointee
        let showRaw = isEnglishCompletion || (activeScheme == .flypy && !Self.options.showFullPinyin)
        let preedit = (showRaw ? raw.input : raw.preedit).map { String(cString: $0) } ?? ""
        let bytes = Array(preedit.utf8.prefix(Int(showRaw ? raw.input_cursor_bytes : raw.cursor_bytes)))
        var commit = englishCase(raw.commit.map { String(cString: $0) } ?? "", input: commitInput)
        if !commit.isEmpty && appendCommitSpace { commit += " " }
        appendCommitSpace = false
        let input = raw.input.map { String(cString: $0) } ?? ""
        return RimeState(preedit: preedit, commit: commit,
                         candidates: (0..<Int(raw.count)).map { englishCase(String(cString: raw.candidates[$0]!), input: input) },
                         highlighted: Int(raw.highlighted), page: Int(raw.page), lastPage: raw.last_page != 0,
                         cursorUTF16: String(decoding: bytes, as: UTF8.self).utf16.count)
    }
}
