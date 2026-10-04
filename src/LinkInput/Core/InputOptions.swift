import Foundation
import CryptoKit

public enum FuzzyPair: String, CaseIterable, Codable {
    case zZh, cCh, sSh, nL, fH, anAng, enEng, inIng
    public var title: String {
        switch self {
        case .zZh: return "z ↔ zh"; case .cCh: return "c ↔ ch"; case .sSh: return "s ↔ sh"
        case .nL: return "n ↔ l"; case .fH: return "f ↔ h"
        case .anAng: return "an ↔ ang"; case .enEng: return "en ↔ eng"; case .inIng: return "in ↔ ing"
        }
    }
    var rules: [String] {
        switch self {
        case .zZh: return ["derive/^z([^h])/zh$1/", "derive/^zh/z/"]
        case .cCh: return ["derive/^c([^h])/ch$1/", "derive/^ch/c/"]
        case .sSh: return ["derive/^s([^h])/sh$1/", "derive/^sh/s/"]
        case .nL: return ["derive/^n/l/", "derive/^l/n/"]
        case .fH: return ["derive/^f/h/", "derive/^h/f/"]
        case .anAng: return ["derive/an$/ang/", "derive/ang$/an/"]
        case .enEng: return ["derive/en$/eng/", "derive/eng$/en/"]
        case .inIng: return ["derive/in$/ing/", "derive/ing$/in/"]
        }
    }
}

public struct InputOptions: Codable, Equatable {
    public var fullPinyinInDoublePinyin = true
    public var showFullPinyin = false
    public var fuzzyPairs: Set<FuzzyPair> = []
    public var candidateCount = 5
    public var expandedCandidateRows = 5
    public var visibleCandidateRows: Int { min(10, max(3, expandedCandidateRows)) }
    public var pageSize: Int { min(10, max(5, candidateCount)) }
    public init() {}
    private enum CodingKeys: String, CodingKey { case fullPinyinInDoublePinyin, showFullPinyin, fuzzyPairs, candidateCount, expandedCandidateRows }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullPinyinInDoublePinyin = try c.decodeIfPresent(Bool.self, forKey: .fullPinyinInDoublePinyin) ?? true
        showFullPinyin = try c.decodeIfPresent(Bool.self, forKey: .showFullPinyin) ?? false
        fuzzyPairs = try c.decodeIfPresent(Set<FuzzyPair>.self, forKey: .fuzzyPairs) ?? []
        expandedCandidateRows = min(10, max(3, try c.decodeIfPresent(Int.self, forKey: .expandedCandidateRows) ?? 5))
        candidateCount = min(10, max(5, try c.decodeIfPresent(Int.self, forKey: .candidateCount) ?? 5))
    }

    // Separate app-owned schemas preserve existing Rime customizations and learned words.
    var schemaSuffix: String {
        let key = "v4-english|\(pageSize)|\(fullPinyinInDoublePinyin)|" + fuzzyPairs.map(\.rawValue).sorted().joined(separator: ",")
        return SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    func schema(source: String, scheme: InputScheme, id: String) throws -> String {
        let menu = "\nmenu:\n  page_size: \(pageSize)\n  alternative_select_keys: \"1234567890\"\n"
        if scheme == .english {
            return source.replacingOccurrences(of: "schema_id: linkinput_english", with: "schema_id: \(id)") + menu
        }
        // Keep hyphenated codes such as `c-d` literal; otherwise key_binder spends `-` on Page_Up and Enter commits `cd`.
        let recognizer = "recognizer:\n  import_preset: default\n  patterns:\n"
        guard source.contains(recognizer) else {
            throw NSError(domain: "LinkInput.Rime", code: 1, userInfo: [NSLocalizedDescriptionKey: "输入方案缺少识别规则。"])
        }
        var source = source.replacingOccurrences(of: recognizer, with: recognizer + "    uppercase: \"\"\n    linkinput_hyphen: \"^[a-z]+-[-a-z0-9]*$\"\n")
        // Compile the English prism independently of Chinese/flypy spelling algebra.
        source = source.replacingOccurrences(of: "  dependencies:\n", with: "  dependencies:\n    - linkinput_english\n")
        source = source.replacingOccurrences(of: "  translators:\n", with: "  translators:\n    - table_translator@linkinput_english\n")
        if source.contains("  alphabet:") {
            source = source.replacingOccurrences(of: "  alphabet: zyxwvutsrqponmlkjihgfedcba", with: "  alphabet: zyxwvutsrqponmlkjihgfedcbaABCDEFGHIJKLMNOPQRSTUVWXYZ")
        } else {
            source = source.replacingOccurrences(of: "speller:\n", with: "speller:\n  alphabet: abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\n")
        }
        source += """

        linkinput_english:
          dictionary: linkinput_english
          prism: linkinput_english
          enable_completion: true
          enable_sentence: false
          enable_user_dict: false
          initial_quality: -0.5
          comment_format:
            - xform/.*//

        """
        if scheme == .wubi {
            return source.replacingOccurrences(of: "schema_id: \(scheme.rawValue)", with: "schema_id: \(id)") + menu
        }
        guard let start = source.range(of: "  algebra:\n"),
              let end = source.range(of: "\ntranslator:", range: start.upperBound..<source.endIndex) else {
            throw NSError(domain: "LinkInput.Rime", code: 1, userInfo: [NSLocalizedDescriptionKey: "输入方案缺少拼写规则。"])
        }
        var algebra = String(source[start.upperBound..<end.lowerBound])
        if scheme == .flypy && fullPinyinInDoublePinyin {
            algebra = algebra.replacingOccurrences(of: "- xform/", with: "- derive/")
        }
        let fuzzy = FuzzyPair.allCases.filter { fuzzyPairs.contains($0) }.flatMap(\.rules)
            .map { "    - \($0)\n" }.joined()
        var result = source
        result.replaceSubrange(start.upperBound..<end.lowerBound, with: fuzzy + algebra)
        result = result.replacingOccurrences(of: "schema_id: \(scheme.rawValue)", with: "schema_id: \(id)")
        result = result.replacingOccurrences(of: "  prism: \(scheme.rawValue)\n", with: "")
        result = result.replacingOccurrences(of: "translator:\n  dictionary:", with: "translator:\n  prism: \(id)\n  dictionary:")
        return result + menu
    }
}
