import Foundation

public struct ManualMode: Codable, Equatable, Identifiable, Sendable {
    public static let defaultID = UUID(uuidString: "4C494E4B-0000-0000-0000-000000000003")!
    public static let builtIn = ManualMode(id: defaultID, name: "整理")
    public var id: UUID
    public var name: String
    /// nil follows the bundled prompt; custom text replaces it in full.
    public var systemPrompt: String?
    public var isBuiltIn: Bool { id == Self.defaultID }
    public var effectivePrompt: String { systemPrompt ?? ExpressionGuard.systemPrompt }
    public init(id: UUID = UUID(), name: String, systemPrompt: String? = nil) {
        self.id = id; self.name = name; self.systemPrompt = systemPrompt
    }
}

/// Modes are independent of dictation; all use the existing text API and Keychain credential.
public struct ManualOptions: Codable, Equatable, Sendable {
    public var modes = [ManualMode.builtIn] { didSet { modes = Self.withBuiltIn(modes) } }
    public var selectedModeID = ManualMode.defaultID
    public var selectedMode: ManualMode { modes.first { $0.id == selectedModeID } ?? modes.first { $0.isBuiltIn } ?? ManualMode.builtIn }
    public init() {}
    private static func withBuiltIn(_ modes: [ManualMode]) -> [ManualMode] {
        var builtIn = ManualMode.builtIn
        builtIn.systemPrompt = modes.first { $0.isBuiltIn }?.systemPrompt
        return [builtIn] + modes.filter { !$0.isBuiltIn }
    }
    private enum CodingKeys: String, CodingKey { case modes, selectedModeID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modes = Self.withBuiltIn(try c.decodeIfPresent([ManualMode].self, forKey: .modes) ?? [])
        selectedModeID = try c.decodeIfPresent(UUID.self, forKey: .selectedModeID) ?? ManualMode.defaultID
    }
}
