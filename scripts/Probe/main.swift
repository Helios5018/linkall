import Foundation
import YiliuCore

@main struct Probe {
    static func main() async {
        let args = CommandLine.arguments
        guard let token = ProcessInfo.processInfo.environment["YILIU_TEST_TOKEN"], !token.isEmpty else {
            print("Missing test credential in environment"); exit(2)
        }
        var config = APIConfiguration(); config.textAllowed = true; config.audioAllowed = true
        let api = AIClient(); let start = Date()
        do {
            if args.contains("--asr"), let path = args.last {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let text = try await api.transcribe(wav: data, config: config, token: token)
                let result: [String: Any] = ["kind": "asr", "model": config.asrModel, "text": text, "seconds": Date().timeIntervalSince(start), "audio_bytes": data.count]
                print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            } else {
                let text = args.dropFirst().first ?? "这周能交，啊不，下周一能交，但还得等测试通过。"
                let background = ProcessInfo.processInfo.environment["YILIU_TEST_BACKGROUND"] ?? ""
                let value = try await api.enhance(text: text, background: background, config: config, token: token)
                let result: [String: Any] = ["kind": "llm", "model": config.model, "prompt": ExpressionGuard.promptVersion, "input": text, "text": value.text, "seconds": Date().timeIntervalSince(start), "input_tokens": value.usage?.input ?? 0, "output_tokens": value.usage?.output ?? 0]
                print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            }
        } catch {
            let description = (error as? AIError)?.localizedDescription ?? "Network/API failed: \((error as NSError).code)"
            print(description); exit(1)
        }
    }
}
