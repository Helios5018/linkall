import Foundation

public enum LinkModule: String, CaseIterable, Identifiable, Sendable {
    case input, record, agent
    public var id: String { rawValue }
    public var title: String { switch self { case .input: return "LinkInput"; case .record: return "LinkRecord"; case .agent: return "LinkAgent" } }
    public var summary: String { switch self { case .input: return "打字 · 语音 · AI 整理"; case .record: return "记录 · 回看 · 桌宠"; case .agent: return "任务与行动 · 规划中" } }
    public var symbol: String { switch self { case .input: return "keyboard"; case .record: return "clock.arrow.circlepath"; case .agent: return "sparkles" } }
}
/// Display names can evolve independently of macOS registration, permissions and persisted data.
public enum LinkAllIdentity {
    public static let name = "LinkAll"
    public static let inputBundle = "work.yiliu.inputmethod.Yiliu"
    public static let shellBundle = "work.yiliu.companion"
    public static let inputSource = "work.yiliu.inputmethod.Yiliu.Hans"
    public static let keychainService = "work.yiliu.inputmethod.Yiliu"
    public static var dataRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Yiliu", isDirectory: true) }
    public static var shellURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/LinkAll.app") }
    public static var legacyShellURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/LinkInputCompanion.app") }
    public static var inputURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/Yiliu.app") }
}
/// Versioned, closed control vocabulary. No text, audio, screenshots or secrets pass through this channel.
public enum LinkAllIPC {
    public static let version = 1
    public static let inputPing = Notification.Name("work.linkall.input.ping")
    public static let inputState = Notification.Name("work.linkall.input.state")
    public static let inputCommand = Notification.Name("work.linkall.input.command")
    public static let inputQuit = Notification.Name("work.yiliu.quit")
    public static let shellShow = Notification.Name("work.linkall.show")
    public static let shellQuit = Notification.Name("work.yiliu.companion.quit")
}
public enum InputAction: String, Codable, Sendable {
    case settings, activate, scheme, voiceMode, manualMode, voice, enhance
}
public struct InputCommand: Codable, Equatable, Sendable {
    public var version = LinkAllIPC.version
    public var action: InputAction
    public var value: String?
    public var targetPID: Int32?
    public init(_ action: InputAction, value: String? = nil, targetPID: Int32? = nil) { self.action = action; self.value = value; self.targetPID = targetPID }
}
public struct InputChoice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}
public struct InputSnapshot: Codable, Equatable, Sendable {
    public var version = LinkAllIPC.version
    public var activity: String
    public var scheme: String
    public var schemes: [InputChoice]
    public var voiceMode: String
    public var voiceModes: [InputChoice]
    public var manualMode: String
    public var manualModes: [InputChoice]
    public init(activity: String, scheme: String, schemes: [InputChoice], voiceMode: String, voiceModes: [InputChoice], manualMode: String, manualModes: [InputChoice]) {
        self.activity = activity; self.scheme = scheme; self.schemes = schemes; self.voiceMode = voiceMode; self.voiceModes = voiceModes; self.manualMode = manualMode; self.manualModes = manualModes
    }
}
