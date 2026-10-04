import Foundation

public enum RecordMode: String, Codable, CaseIterable, Sendable {
    /// Short press toggles hands-free recording; holding past the threshold is push-to-talk.
    case hybrid, toggle, pushToTalk
    public var title: String {
        switch self {
        case .hybrid: return "混合：短按开关，长按说话"
        case .toggle: return "再次按键停止"
        case .pushToTalk: return "按住说话"
        }
    }
}
/// A dictation mode, after VoiceInk: one recording key, and the menu bar picks what happens to the transcript.
/// Raw inserts it as recognized; each polish mode can override the complete system prompt.
public struct DictationMode: Codable, Equatable, Identifiable, Sendable {
    public static let rawID = UUID(uuidString: "4C494E4B-0000-0000-0000-000000000001")!
    public static let polishID = UUID(uuidString: "4C494E4B-0000-0000-0000-000000000002")!
    public static let builtIns = [DictationMode(id: rawID, name: "原文", polish: false),
                                  DictationMode(id: polishID, name: "整理")]
    public var id: UUID
    public var name: String
    public var polish: Bool
    /// nil follows the bundled default, including future updates. Custom text replaces the whole template.
    public var systemPrompt: String?
    public var isBuiltIn: Bool { id == Self.rawID || id == Self.polishID }
    public init(id: UUID = UUID(), name: String, polish: Bool = true, systemPrompt: String? = nil) {
        self.id = id; self.name = name; self.polish = polish
        self.systemPrompt = systemPrompt
    }
    private enum CodingKeys: String, CodingKey { case id, name, polish, systemPrompt }
    private enum LegacyKeys: String, CodingKey { case instructions }
    /// Read-only compatibility for settings saved before the single-editor UI. Never encoded again.
    private static let legacyDefaultInstructions = "把 <TRANSCRIPT> 整理成通顺、可以直接使用的文字。口述的称呼、落款和标题保留，没说的不加。"
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "模式"
        polish = (try? c.decodeIfPresent(Bool.self, forKey: .polish)) ?? true
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if let instructions = try legacy.decodeIfPresent(String.self, forKey: .instructions) {
            let task = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            let effective = task.isEmpty ? Self.legacyDefaultInstructions : task
            if let saved = systemPrompt {
                // Preserve custom templates exactly except for resolving their old task placeholder once.
                systemPrompt = saved.replacingOccurrences(of: "{{TASK_INSTRUCTIONS}}", with: effective)
            } else if effective != Self.legacyDefaultInstructions {
                systemPrompt = ExpressionGuard.dictationTemplate.replacingOccurrences(of: Self.legacyDefaultInstructions, with: effective)
            }
        }
    }
}
public struct VoiceReplacement: Codable, Equatable, Sendable {
    public var from: String, to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}
/// Voice settings live apart from APIConfiguration so adding a field never resets endpoints or consents.
/// Every field decodes with a default.
public struct VoiceOptions: Codable, Equatable, Sendable {
    public static let recordingMinutesRange = 1...30
    public static let defaultRecordingMinutes = 10
    public var maxRecordingMinutes = Self.defaultRecordingMinutes {
        didSet { maxRecordingMinutes = Self.clampRecordingMinutes(maxRecordingMinutes) }
    }
    public var maxRecordingDuration: TimeInterval { TimeInterval(maxRecordingMinutes * 60) }
    private static func clampRecordingMinutes(_ value: Int) -> Int {
        min(recordingMinutesRange.upperBound, max(recordingMinutesRange.lowerBound, value))
    }
    public var recordMode: RecordMode = .hybrid
    /// ElevenLabs realtime over a single-use token; the batch upload stays as the fallback.
    public var streaming = true
    public var scenePrompts = ScenePrompts()
    /// Built-ins first, then the user's own. Polishing needs cloud text consent; without it the transcript is inserted as recognized.
    public var modes = DictationMode.builtIns { didSet { modes = Self.withBuiltIns(modes) } }
    public var selectedModeID = DictationMode.polishID
    public var selectedMode: DictationMode { modes.first { $0.id == selectedModeID } ?? modes.first { $0.id == DictationMode.polishID } ?? DictationMode.builtIns[1] }
    public var vocabulary: [String] = []
    public var replacements: [VoiceReplacement] = []
    public var fillerWords: [String] = []
    public var muteWhileRecording = false
    /// Paste through a transient clipboard item when the host has no LinkInput connection.
    public var pasteFallback = true
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VoiceOptions()
        maxRecordingMinutes = Self.clampRecordingMinutes((try? c.decodeIfPresent(Int.self, forKey: .maxRecordingMinutes)) ?? d.maxRecordingMinutes)
        recordMode = (try? c.decodeIfPresent(RecordMode.self, forKey: .recordMode)) ?? d.recordMode
        streaming = (try? c.decodeIfPresent(Bool.self, forKey: .streaming)) ?? d.streaming
        scenePrompts = (try? c.decodeIfPresent(ScenePrompts.self, forKey: .scenePrompts)) ?? d.scenePrompts
        modes = Self.withBuiltIns((try? c.decodeIfPresent([DictationMode].self, forKey: .modes)) ?? d.modes)
        selectedModeID = (try? c.decodeIfPresent(UUID.self, forKey: .selectedModeID)) ?? d.selectedModeID
        vocabulary = (try? c.decodeIfPresent([String].self, forKey: .vocabulary)) ?? d.vocabulary
        replacements = (try? c.decodeIfPresent([VoiceReplacement].self, forKey: .replacements)) ?? d.replacements
        fillerWords = (try? c.decodeIfPresent([String].self, forKey: .fillerWords)) ?? d.fillerWords
        muteWhileRecording = (try? c.decodeIfPresent(Bool.self, forKey: .muteWhileRecording)) ?? d.muteWhileRecording
        pasteFallback = (try? c.decodeIfPresent(Bool.self, forKey: .pasteFallback)) ?? d.pasteFallback
    }
    /// Built-ins keep their name and kind and always lead the list; prompts remain editable.
    private static func withBuiltIns(_ list: [DictationMode]) -> [DictationMode] {
        let builtIns = DictationMode.builtIns.map { builtIn -> DictationMode in
            guard let saved = list.first(where: { $0.id == builtIn.id }) else { return builtIn }
            var mode = builtIn
            mode.systemPrompt = saved.systemPrompt; return mode
        }
        return builtIns + list.filter { !$0.isBuiltIn }
    }
    /// "错=对" pairs separated by ；; or newlines.
    public static func parseReplacements(_ text: String) -> [VoiceReplacement] {
        text.split(whereSeparator: { "；;\n".contains($0) }).compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return VoiceReplacement(from: parts[0], to: parts[1])
        }
    }
    public static func parseList(_ text: String) -> [String] {
        text.split(whereSeparator: { "，,、\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Post-processing applied to every transcript before it reaches a draft or a field.
public enum TranscriptCleaner {
    /// Short bracketed spans are audio-event tags ([音乐], (笑声), 【噪音】), not speech.
    private static let tagPatterns = [#"\[[^\]\n]{0,16}\]"#, #"\([^)\n]{0,16}\)"#, #"\{[^}\n]{0,16}\}"#, #"【[^】\n]{0,16}】"#, #"（[^）\n]{0,16}）"#]
    public static func clean(_ text: String, options: VoiceOptions) -> String {
        var value = text
        for pattern in tagPatterns { value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
        for filler in options.fillerWords where !filler.isEmpty {
            // A filler plus the pause punctuation after it; Chinese has no word boundaries to anchor on.
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            value = value.replacingOccurrences(of: escaped + #"[，,、。.…]?"#, with: "", options: .regularExpression)
        }
        // Longest first so "Claude Code" wins over "Claude".
        for item in options.replacements.sorted(by: { $0.from.count > $1.from.count }) where !item.from.isEmpty {
            value = value.replacingOccurrences(of: item.from, with: item.to, options: .caseInsensitive)
        }
        value = value.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
