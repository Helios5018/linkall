import Foundation

public enum LLMFormat: String, Codable, CaseIterable, Sendable { case gemini, openAI }
/// Build-time endpoint defaults from the bundled `api-defaults.json` (copied from the gitignored
/// `scripts/api-defaults.local.json`). Public builds ship without it, so users enter their own API.
public struct APIDefaults: Codable, Sendable {
    public var llmURL: String?
    public var asrURL: String?
    public var authHeader: String?
    public init(llmURL: String? = nil, asrURL: String? = nil, authHeader: String? = nil) {
        self.llmURL = llmURL; self.asrURL = asrURL; self.authHeader = authHeader
    }
    public static let shared: APIDefaults = Bundle.main.url(forResource: "api-defaults", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(APIDefaults.self, from: $0) } ?? APIDefaults()
}
public struct APIConfiguration: Codable, Sendable {
    public var llmURL = APIDefaults.shared.llmURL ?? ""
    public var asrURL = APIDefaults.shared.asrURL ?? ""
    public var model = "gemini-3.7-flash"
    /// v2 is the only batch model that accepts keyterms, so the vocabulary survives a streaming fallback.
    public var asrModel = "scribe_v2"
    public var format: LLMFormat = .gemini
    public var authHeader = APIDefaults.shared.authHeader ?? "Authorization"
    public var textAllowed = false
    public var audioAllowed = false
    public var paused = false
    public var excludedApps = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.cmuxterm.app"]
    public var inputUSDPerMillion: Double?
    public var outputUSDPerMillion: Double?
    public var audioUSDPerMinute: Double?
    public init() {}
    public init(defaults: APIDefaults) {
        llmURL = defaults.llmURL ?? ""; asrURL = defaults.asrURL ?? ""; authHeader = defaults.authHeader ?? "Authorization"
    }
    /// Moves untouched earlier defaults to the current ones; anything the user typed in stays.
    public mutating func upgradeDefaults(defaults: APIDefaults = .shared) {
        if asrModel == "scribe_v1" { asrModel = "scribe_v2" }
        // The previous default endpoint differed from the current one only by model name.
        if model == "gemini-3.8-flash", let current = defaults.llmURL, !current.isEmpty,
           llmURL == current.replacingOccurrences(of: "gemini-3.7-flash", with: "gemini-3.8-flash") {
            model = APIConfiguration().model; llmURL = current
        }
    }
}
public struct ExpressionResult: Decodable, Sendable {
    public let text: String
    public let note: String
    public var usage: TokenUsage?
}
public enum AIError: Error, LocalizedError {
    case disabled, credentials, endpoint, response, http(Int), cancelled
    public var errorDescription: String? {
        switch self {
        case .disabled: return "AI 已暂停或尚未授权云端处理。普通输入仍可使用。"
        case .credentials: return "请先在设置中保存 API 凭据。"
        case .endpoint: return "API 地址必须使用 HTTPS，且不能包含账户信息。"
        case .response: return "服务返回格式不正确。"
        case .http(let code): return "API 请求失败（HTTP \(code)），不自动重试。"
        case .cancelled: return "请求已取消。"
        }
    }
}
/// Ephemeral URLSession avoids disk caches and cookies; no content is logged.
public final class AIClient: @unchecked Sendable {
    private let session: URLSession
    private let enhancementTimeout: TimeInterval
    private let transcriptionTimeout: TimeInterval
    public init(session: URLSession? = nil, enhancementTimeout: TimeInterval = 15, transcriptionTimeout: TimeInterval = 300) {
        // Thinking models behind the gateway occasionally pass 8 s; 15 s still ends a hung request.
        self.enhancementTimeout = enhancementTimeout.isFinite && enhancementTimeout > 0 ? min(15, enhancementTimeout) : 15
        self.transcriptionTimeout = transcriptionTimeout.isFinite && transcriptionTimeout > 0 ? min(300, transcriptionTimeout) : 300
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    private func request(url value: String, config: APIConfiguration, token: String, timeout: TimeInterval) throws -> URLRequest {
        guard !token.isEmpty else { throw AIError.credentials }
        guard let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw AIError.endpoint }
        let sensitiveNames = ["key", "api_key", "apikey", "token", "access_token"]
        guard !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains(where: { sensitiveNames.contains($0.name.lowercased()) }) else { throw AIError.endpoint }
        guard ["x-internal-token", "Authorization", "xi-api-key", "api-key"].contains(config.authHeader) else { throw AIError.endpoint }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = timeout
        request.setValue(config.authHeader == "Authorization" ? "Bearer \(token)" : token, forHTTPHeaderField: config.authHeader)
        return request
    }
    private func send(_ request: URLRequest) async throws -> Data {
        // URLRequest's timeout can reset when bytes arrive. Race an absolute deadline as well.
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [self] in
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw AIError.response }
                guard (200..<300).contains(http.statusCode) else { throw AIError.http(http.statusCode) }
                guard data.count <= 2_000_000 else { throw AIError.response }
                return data
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(request.timeoutInterval * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AIError.response }
            return result
        }
    }
    public func enhance(text: String, background: String, config: APIConfiguration, token: String, systemPrompt: String? = nil) async throws -> ExpressionResult {
        guard config.textAllowed, !config.paused else { throw AIError.disabled }
        let payload = try JSONSerialization.data(withJSONObject: ["draft": text, "background": background])
        let (output, usage) = try await generate(system: systemPrompt ?? ExpressionGuard.systemPrompt, user: String(decoding: payload, as: UTF8.self),
                                                 json: true, config: config, token: token, timeout: enhancementTimeout, temperature: 1)
        guard let json = output.data(using: .utf8), var result = try? JSONDecoder().decode(ExpressionResult.self, from: json) else { throw AIError.response }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.response }
        result.usage = usage
        return result
    }
    /// A polish mode: cleans a transcript with the mode's complete system prompt. `scene` sets register only; `lineBreaks` false keeps it
    /// on one line. `timeout` can only shorten the client limit.
    public func polishDictation(_ text: String, scene: String, terms: [String], lineBreaks: Bool, config: APIConfiguration,
                                token: String, timeout: TimeInterval, systemPrompt: String? = nil, layoutPrompt: String? = nil) async throws -> (text: String, usage: TokenUsage?) {
        guard config.textAllowed, !config.paused else { throw AIError.disabled }
        let (output, usage) = try await generate(system: ExpressionGuard.dictationSystem(scene: scene, terms: terms, lineBreaks: lineBreaks, systemPrompt: systemPrompt, layoutPrompt: layoutPrompt),
                                                 user: ExpressionGuard.dictationUser(text), json: false, config: config, token: token,
                                                 timeout: min(enhancementTimeout, timeout), temperature: 0.3,
                                                 outputTokenLimit: min(32768, max(2048, text.utf8.count + 1024)))
        let cleaned = ExpressionGuard.dictationOutput(output)
        guard !cleaned.isEmpty else { throw AIError.response }
        return (cleaned, usage)
    }
    /// Transport for explicitly requested Agent suggestions; consent is checked before any request.
    public func suggest(system: String, user: String, config: APIConfiguration, token: String) async throws -> (String, TokenUsage?) {
        guard config.textAllowed, !config.paused else { throw AIError.disabled }
        return try await generate(system: system, user: user, json: true, config: config, token: token,
                                  timeout: enhancementTimeout, temperature: 1, outputTokenLimit: 2048)
    }
    private func generate(system: String, user: String, json: Bool, config: APIConfiguration, token: String,
                          timeout: TimeInterval, temperature: Double, outputTokenLimit: Int? = nil) async throws -> (String, TokenUsage?) {
        var request = try request(url: config.llmURL, config: config, token: token, timeout: timeout)
        var body: [String: Any]
        if config.format == .gemini {
            var generation: [String: Any] = ["temperature": temperature, "maxOutputTokens": outputTokenLimit ?? 2048, "thinkingConfig": ["thinkingLevel": "LOW"]]
            if json { generation["responseMimeType"] = "application/json" }
            body = ["systemInstruction": ["parts": [["text": system]]], "contents": [["role": "user", "parts": [["text": user]]]], "generationConfig": generation]
        } else {
            body = ["model": config.model, "messages": [["role": "system", "content": system], ["role": "user", "content": user]], "temperature": temperature, "max_tokens": outputTokenLimit ?? 1000]
            if json { body["response_format"] = ["type": "json_object"] }
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.response }
        let output: String?
        if config.format == .gemini {
            let candidate = (root["candidates"] as? [[String: Any]])?.first
            // A provider-truncated response is incomplete; dictation falls back to the full transcript.
            guard candidate?["finishReason"] as? String != "MAX_TOKENS" else { throw AIError.response }
            let content = candidate?["content"] as? [String: Any]
            output = (content?["parts"] as? [[String: Any]])?.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        } else {
            let choice = (root["choices"] as? [[String: Any]])?.first
            guard choice?["finish_reason"] as? String != "length" else { throw AIError.response }
            output = (choice?["message"] as? [String: Any])?["content"] as? String
        }
        guard let output else { throw AIError.response }
        // Count only provider envelope metadata, never anything the model wrote.
        var usage: TokenUsage?
        if let meta = root["usageMetadata"] as? [String: Any], let input = meta["promptTokenCount"] as? Int {
            usage = TokenUsage(input: input, output: (meta["candidatesTokenCount"] as? Int ?? 0) + (meta["thoughtsTokenCount"] as? Int ?? 0))
        } else if let meta = root["usage"] as? [String: Any], let input = meta["prompt_tokens"] as? Int {
            usage = TokenUsage(input: input, output: meta["completion_tokens"] as? Int ?? 0)
        }
        return (output, usage)
    }
    public func transcribe(wav: Data, config: APIConfiguration, token: String, allowEmpty: Bool = false, vocabulary: [String] = [], audioDuration: TimeInterval = 0) async throws -> String {
        guard config.audioAllowed, !config.paused else { throw AIError.disabled }
        // Keep short dictation responsive; allow upload and batch processing time for longer audio.
        let duration = audioDuration.isFinite ? max(0, audioDuration) : 0
        let timeout = min(transcriptionTimeout, max(30, duration / 4))
        var request = try request(url: config.asrURL, config: config, token: token, timeout: timeout)
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        var fields = [("model_id", config.asrModel), ("language_code", "zh"), ("tag_audio_events", "false"), ("timestamps_granularity", "none")]
        // Keyterm biasing exists on Scribe v2 only; v1 would reject or ignore it.
        if config.asrModel.hasPrefix("scribe_v2") { fields += vocabulary.prefix(50).map { ("keyterms", $0) } }
        for (key, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav); append("\r\n--\(boundary)--\r\n"); request.httpBody = body
        let data = try await send(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = root["text"] as? String, allowEmpty || !text.isEmpty else { throw AIError.response }
        return text
    }
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
