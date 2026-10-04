import Foundation

public struct RequestStamp: Equatable, Sendable {
    public let session: UUID
    public let target: UUID?
    public let revision: Int
    public let request: UUID
}
public enum CommitState: Equatable { case ready, writing(UUID), succeeded, unknown }

/// Owns the only AI draft and the one-shot commit transaction. Never persists content.
public final class DraftSession {
    public private(set) var id = UUID()
    public private(set) var target: UUID?
    public private(set) var original = ""
    public private(set) var text = ""
    public private(set) var background = ""
    public private(set) var revision = 0
    public private(set) var suggestion: String?
    public private(set) var history: [String] = []
    public private(set) var commitState: CommitState = .ready
    public private(set) var suspendedAt: Date?
    public private(set) var activeRequest: RequestStamp?
    public init() {}
    public func begin(text: String, target: UUID?) {
        clear(); self.target = target; original = text; self.text = text
    }
    public func edit(_ value: String) {
        guard value != text, commitState == .ready else { return }
        history.append(text); text = value; invalidate()
    }
    public func setBackground(_ value: String) { background = value; invalidate() }
    private func invalidate() { revision += 1; suggestion = nil; activeRequest = nil }
    public func startRequest() -> RequestStamp? {
        guard suspendedAt == nil, commitState == .ready else { return nil }
        if original.isEmpty { original = text }
        let stamp = RequestStamp(session: id, target: target, revision: revision, request: UUID())
        activeRequest = stamp; suggestion = nil; return stamp
    }
    @discardableResult public func receive(_ value: String, stamp: RequestStamp) -> Bool {
        guard stamp == activeRequest, stamp.session == id, stamp.target == target,
              stamp.revision == revision, suspendedAt == nil, commitState == .ready else { return false }
        activeRequest = nil; suggestion = value; return true
    }
    public func acceptSuggestion() {
        guard let value = suggestion else { return }
        edit(value)
    }
    public func undo() {
        guard commitState == .ready, let previous = history.popLast() else { return }
        text = previous; invalidate()
    }
    public func restoreOriginal() { edit(original) }
    public func cancelRequest() { activeRequest = nil; suggestion = nil }
    public func suspend(now: Date = Date()) { suspendedAt = now; cancelRequest() }
    public func resume(target: UUID?, now: Date = Date()) -> Bool {
        guard target == self.target else { return false }
        if let suspendedAt, now.timeIntervalSince(suspendedAt) >= 600 { clear(); return false }
        suspendedAt = nil; return true
    }
    public func beginCommit(target: UUID?) -> UUID? {
        guard target != nil, target == self.target, suspendedAt == nil, commitState == .ready,
              !text.isEmpty, activeRequest == nil else { return nil }
        let transaction = UUID(); commitState = .writing(transaction); return transaction
    }
    public func finishCommit(_ transaction: UUID, verified: Bool) {
        guard commitState == .writing(transaction) else { return }
        commitState = verified ? .succeeded : .unknown
    }
    public func clear() {
        id = UUID(); target = nil; original = ""; text = ""; background = ""; revision = 0
        suggestion = nil; history = []; commitState = .ready; suspendedAt = nil; activeRequest = nil
    }
}

public enum ExpressionGuard {
    public static let promptVersion = "p0-3"
    public static let systemPrompt = PromptResources.text("manual-system", extension: "txt").trimmingCharacters(in: .whitespacesAndNewlines)
    /// The app carries the same source resource as SwiftPM tests and command-line probes.
    public static let dictationTemplate = PromptResources.text("dictation-system", extension: "txt").trimmingCharacters(in: .whitespacesAndNewlines)
    /// Only replace explicit placeholders. Custom prompts receive no hidden prefix or suffix.
    public static func dictationSystem(scene: String, terms: [String], lineBreaks: Bool,
                                       systemPrompt: String? = nil, layoutPrompt: String? = nil) -> String {
        let entries = terms.prefix(50).map { $0.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "") }.filter { !$0.isEmpty }
        let layout = layoutPrompt ?? ScenePrompts().layout(lineBreaks: lineBreaks)
        let values = ["{{CUSTOM_VOCABULARY}}": entries.joined(separator: "\n"),
                      "{{SCENE}}": [scene, layout].filter { !$0.isEmpty }.joined(separator: "\n")]
        let template = systemPrompt ?? dictationTemplate
        let pattern = try! NSRegularExpression(pattern: #"\{\{(?:CUSTOM_VOCABULARY|SCENE)\}\}"#)
        let output = NSMutableString(string: template)
        // Reverse ranges from the original template: inserted values are never expanded as new placeholders.
        for match in pattern.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            let key = (template as NSString).substring(with: match.range)
            output.replaceCharacters(in: match.range, with: values[key]!)
        }
        return output as String
    }
    public static func dictationUser(_ transcript: String) -> String {
        "<TRANSCRIPT>\n" + transcript.replacingOccurrences(of: #"</?TRANSCRIPT>"#, with: "", options: [.regularExpression, .caseInsensitive]) + "\n</TRANSCRIPT>"
    }
    /// Drops reasoning blocks and echoed tags; the guard still has to accept what remains.
    public static func dictationOutput(_ output: String) -> String {
        var value = output
        for pattern in [#"(?s)<(think|thinking|reasoning)>.*?</\1>"#, #"</?TRANSCRIPT>"#] {
            value = value.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return value.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
