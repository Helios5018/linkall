import Foundation

enum PromptResources {
    static func text(_ name: String, extension suffix: String) -> String {
        let url = Bundle.main.url(forResource: name, withExtension: suffix, subdirectory: "Prompts")
            ?? Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: "Prompts")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            preconditionFailure("Missing prompt resource: \(name).\(suffix)")
        }
        return text
    }
}

public enum ScenePromptKind: String, CaseIterable, Codable, Sendable {
    case terminal, chat, mail, other, singleLine, multiLine
    public var title: String {
        switch self {
        case .terminal: return "终端 / 编程助手"
        case .chat: return "即时聊天"
        case .mail: return "邮件"
        case .other: return "其他应用"
        case .singleLine: return "单行输入框"
        case .multiLine: return "多行输入框"
        }
    }
    public var detail: String {
        switch self {
        case .terminal: return "用于终端、cmux 等应用。"
        case .chat: return "用于飞书、微信、Slack、Telegram、Discord、钉钉和信息等应用。"
        case .mail: return "用于 Mail、Outlook、Spark 和 Mimestream。"
        case .other: return "用于未匹配到上述分类的应用，默认不附加场景文案。"
        case .singleLine: return "用于终端或识别为单行的输入框。修改提示词不改变实际写入时的单行限制。"
        case .multiLine: return "用于允许多行输入的编辑区域。"
        }
    }
}

/// User overrides only; missing entries follow the bundled text, and an empty override omits that hint.
public struct ScenePrompts: Codable, Equatable, Sendable {
    private var overrides: [String: String] = [:]
    public init() {}
    private static let defaults: [String: String] = {
        let data = Data(PromptResources.text("scenes", extension: "json").utf8)
        guard let values = try? JSONDecoder().decode([String: String].self, from: data),
              ScenePromptKind.allCases.allSatisfy({ values[$0.rawValue] != nil }) else {
            preconditionFailure("Invalid scenes.json")
        }
        return values
    }()
    public static func defaultText(for kind: ScenePromptKind) -> String { defaults[kind.rawValue]! }
    public subscript(_ kind: ScenePromptKind) -> String {
        get { overrides[kind.rawValue] ?? Self.defaultText(for: kind) }
        set { overrides[kind.rawValue] = newValue == Self.defaultText(for: kind) ? nil : newValue }
    }
    public mutating func reset(_ kind: ScenePromptKind) { overrides.removeValue(forKey: kind.rawValue) }
    /// Classification cannot change the input target's separate writeback restrictions.
    public func text(forApp bundle: String?, isTerminal: Bool) -> String {
        if isTerminal { return self[.terminal] }
        let id = (bundle ?? "").lowercased()
        if ["lark", "feishu", "slack", "wechat", "tencent.xin", "telegram", "discord", "dingtalk", "messages"].contains(where: id.contains) {
            return self[.chat]
        }
        if ["com.apple.mail", "outlook", "spark", "mimestream"].contains(where: id.contains) { return self[.mail] }
        return self[.other]
    }
    public func layout(lineBreaks: Bool) -> String { self[lineBreaks ? .multiLine : .singleLine] }
}
