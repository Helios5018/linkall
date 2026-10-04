import XCTest
@testable import YiliuCore

private final class StubProtocol: URLProtocol {
    static var requests = 0
    static var status = 200
    static var data = Data()
    static var body = Data()
    static var timeout: TimeInterval = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Self.timeout = request.timeoutInterval
        Self.body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                Self.body.append(contentsOf: buffer.prefix(count))
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class APITests: XCTestCase {
    func testReplyConsentPauseAndBothTransportFormats() async throws {
        let api = client(); var c = APIConfiguration()
        do { _ = try await api.suggest(system: "rules", user: "private history", config: c, token: "test"); XCTFail() } catch {}
        c.textAllowed = true; c.paused = true
        do { _ = try await api.suggest(system: "rules", user: "private history", config: c, token: "test"); XCTFail() } catch {}
        XCTAssertEqual(StubProtocol.requests, 0)
        c.paused = false
        for format in LLMFormat.allCases {
            c.format = format
            let output = "{\"candidates\":[]}"
            StubProtocol.data = try JSONSerialization.data(withJSONObject: format == .gemini
                ? ["candidates": [["content": ["parts": [["text": output]]]]]]
                : ["choices": [["message": ["content": output]]]])
            let result = try await api.suggest(system: "rules", user: "bounded JSON evidence", config: c, token: "test")
            XCTAssertEqual(result.0, output)
        }
        XCTAssertEqual(StubProtocol.requests, 2)
    }
    func testDefaultModelMigrationPreservesCustomEndpoint() {
        let defaults = APIDefaults(llmURL: "https://gateway.example/v1/models/gemini-3.7-flash:generateContent")
        var config = APIConfiguration(defaults: defaults)
        config.model = "gemini-3.8-flash"
        config.llmURL = "https://gateway.example/v1/models/gemini-3.8-flash:generateContent"
        config.upgradeDefaults(defaults: defaults)
        XCTAssertEqual(config.model, "gemini-3.7-flash")
        XCTAssertEqual(config.llmURL, defaults.llmURL)
        config.model = "gemini-3.8-flash"; config.llmURL = "https://example.test/custom"
        config.upgradeDefaults(defaults: defaults)
        XCTAssertEqual(config.model, "gemini-3.8-flash"); XCTAssertEqual(config.llmURL, "https://example.test/custom")
    }
    func testPublicBuildHasNoDefaultEndpoint() {
        let config = APIConfiguration(defaults: APIDefaults())
        XCTAssertEqual(config.llmURL, ""); XCTAssertEqual(config.asrURL, ""); XCTAssertEqual(config.authHeader, "Authorization")
    }
    private func client() -> AIClient {
        StubProtocol.requests = 0; StubProtocol.status = 200; StubProtocol.data = Data()
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [StubProtocol.self]
        return AIClient(session: URLSession(configuration: c))
    }
    func testDefaultConsentPreventsAnyNetworkRequest() async throws {
        let api = client(); let c = APIConfiguration()
        do { _ = try await api.enhance(text: "private", background: "secret", config: c, token: "test"); XCTFail() } catch {}
        do { _ = try await api.transcribe(wav: Data([1,2]), config: c, token: "test"); XCTFail() } catch {}
        XCTAssertEqual(StubProtocol.requests, 0)
    }
    func testPauseOverridesConsentAndRejectsPlainHTTP() async throws {
        let api = client(); var c = APIConfiguration(); c.textAllowed = true; c.paused = true
        do { _ = try await api.enhance(text: "草稿", background: "", config: c, token: "test"); XCTFail() } catch {}
        c.paused = false; c.llmURL = "http://example.test"
        do { _ = try await api.enhance(text: "草稿", background: "", config: c, token: "test"); XCTFail() } catch {}
        XCTAssertEqual(StubProtocol.requests, 0)
    }
    func testFailureDoesNotRetryOrRevealResponseBody() async throws {
        for status in [401, 429, 500] {
            let api = client(); StubProtocol.status = status; StubProtocol.data = Data("secret-content".utf8)
            var c = APIConfiguration(); c.textAllowed = true
            do { _ = try await api.enhance(text: "草稿", background: "", config: c, token: "test"); XCTFail() }
            catch { XCTAssertFalse(error.localizedDescription.contains("secret-content")) }
            XCTAssertEqual(StubProtocol.requests, 1)
        }
    }
    func testGeminiParsesOnlyVisibleText() async throws {
        let api = client(); var c = APIConfiguration(); c.textAllowed = true
        let result = #"{"text":"周五可以吗？","missing":[],"note":"整理标点"}"#
        StubProtocol.data = try JSONSerialization.data(withJSONObject: ["candidates": [["content": ["parts": [["thought": true, "text": "internal"], ["text": result]]]]]])
        let value = try await api.enhance(text: "周五？", background: "", config: c, token: "test")
        XCTAssertEqual(value.text, "周五可以吗？")
    }
    func testDictationSendsCompleteOverrideInBothFormats() async throws {
        for format in LLMFormat.allCases {
            let api = client(); var config = APIConfiguration(); config.textAllowed = true; config.format = format
            let custom = "只按我的规则整理，保留语气。"
            StubProtocol.data = try JSONSerialization.data(withJSONObject: format == .gemini
                ? ["candidates": [["content": ["parts": [["text": "你好。"]]]]]]
                : ["choices": [["message": ["content": "你好。"]]]])
            _ = try await api.polishDictation("你好", scene: "不会追加", terms: [], lineBreaks: false,
                                              config: config, token: "test", timeout: 8, systemPrompt: custom)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubProtocol.body) as? [String: Any])
            if format == .gemini {
                let system = try XCTUnwrap(body["systemInstruction"] as? [String: Any])
                XCTAssertEqual((system["parts"] as? [[String: String]])?.first?["text"], custom)
                XCTAssertEqual((body["generationConfig"] as? [String: Any])?["temperature"] as? Double, 0.3)
            } else {
                XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], custom)
                XCTAssertEqual(body["temperature"] as? Double, 0.3)
            }
        }
    }
    func testManualUsesExactPromptAndTemperatureOneInBothFormats() async throws {
        for format in LLMFormat.allCases {
            for override in [nil, "只整理 JSON 草稿，返回 text 和 note，不追加其他规则。"] as [String?] {
                let api = client(); var config = APIConfiguration(); config.textAllowed = true; config.format = format
                let response = #"{"text":"整理后的文字","note":"整理"}"#
                StubProtocol.data = try JSONSerialization.data(withJSONObject: format == .gemini
                    ? ["candidates": [["content": ["parts": [["text": response]]]]]]
                    : ["choices": [["message": ["content": response]]]])
                _ = try await api.enhance(text: "我的原文", background: "", config: config, token: "test", systemPrompt: override)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubProtocol.body) as? [String: Any])
                let user: String
                if format == .gemini {
                    let system = try XCTUnwrap(body["systemInstruction"] as? [String: Any])
                    XCTAssertEqual((system["parts"] as? [[String: String]])?.first?["text"], override ?? ExpressionGuard.systemPrompt)
                    let generation = try XCTUnwrap(body["generationConfig"] as? [String: Any])
                    XCTAssertEqual(generation["temperature"] as? Double, 1)
                    XCTAssertEqual(generation["responseMimeType"] as? String, "application/json")
                    let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
                    user = try XCTUnwrap((contents.first?["parts"] as? [[String: String]])?.first?["text"])
                } else {
                    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
                    XCTAssertEqual(messages.first?["content"], override ?? ExpressionGuard.systemPrompt)
                    XCTAssertEqual(body["temperature"] as? Double, 1)
                    XCTAssertEqual(body["model"] as? String, config.model)
                    user = try XCTUnwrap(messages.last?["content"])
                }
                let payload = try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: String]
                XCTAssertEqual(payload, ["draft": "我的原文", "background": ""])
            }
        }
    }
    func testCredentialQueryNeverReachesNetwork() async {
        let api = client(); var config = APIConfiguration(); config.textAllowed = true
        config.llmURL = "https://example.test/generate?api_key=must-not-leave"
        do { _ = try await api.enhance(text: "草稿", background: "", config: config, token: "test"); XCTFail() } catch {}
        XCTAssertEqual(StubProtocol.requests, 0)
    }
    func testEnhancementAcceptsReformattingAndIgnoresLegacyMissingField() async throws {
        let api = client(); var config = APIConfiguration(); config.textAllowed = true
        let output = "1. 准备 500g 肉\n2. 煮熟后切条\n\n备注"
        let payload = try JSONSerialization.data(withJSONObject: ["text": output, "note": "整理", "missing": ["旧服务的提示"]])
        StubProtocol.data = try JSONSerialization.data(withJSONObject: ["candidates": [["content": ["parts": [["text": String(decoding: payload, as: UTF8.self)]]]]]])
        let value = try await api.enhance(text: "准备500g肉，煮熟切条", background: "", config: config, token: "test")
        let draft = DraftSession(), target = UUID(); draft.begin(text: "准备500g肉，煮熟切条", target: target)
        XCTAssertTrue(draft.receive(value.text, stamp: draft.startRequest()!))
        draft.acceptSuggestion()
        XCTAssertEqual(draft.text, output); XCTAssertNotNil(draft.beginCommit(target: target))
    }
    func testStructuredInputAndChangedOutputAreNotContentFiltered() async throws {
        let api = client(); var config = APIConfiguration(); config.textAllowed = true
        let output = String(repeating: "整理后的文字。", count: 100)
        let payload = try JSONSerialization.data(withJSONObject: ["text": output, "note": "整理"])
        StubProtocol.data = try JSONSerialization.data(withJSONObject: ["candidates": [["content": ["parts": [["text": String(decoding: payload, as: UTF8.self)]]]]]])
        let manual = try await api.enhance(text: "const value = 123", background: "", config: config, token: "test")
        XCTAssertEqual(manual.text, output)
        StubProtocol.data = try JSONSerialization.data(withJSONObject: ["candidates": [["content": ["parts": [["text": output]]]]]])
        let voice = try await api.polishDictation("const value = 123", scene: "", terms: [], lineBreaks: true, config: config, token: "test", timeout: 8)
        XCTAssertEqual(voice.text, output); XCTAssertEqual(StubProtocol.requests, 2)
    }
    func testAbsoluteDeadlineCancelsUnfinishedResponse() async {
        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [HangingProtocol.self]
        let api = AIClient(session: URLSession(configuration: sessionConfig), enhancementTimeout: 0.05)
        var config = APIConfiguration(); config.textAllowed = true
        let start = Date()
        do { _ = try await api.enhance(text: "草稿", background: "", config: config, token: "test"); XCTFail("Expected absolute timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
    func testLongAudioGetsBoundedBatchDeadline() async throws {
        for (duration, expected) in [(60.0, 30.0), (600, 150), (1800, 300)] {
            let api = client(); var config = APIConfiguration(); config.audioAllowed = true
            StubProtocol.data = Data(#"{"text":"完整转写"}"#.utf8)
            let result = try await api.transcribe(wav: Data([1, 2]), config: config, token: "test", audioDuration: duration)
            XCTAssertEqual(result, "完整转写")
            XCTAssertEqual(StubProtocol.timeout, expected)
        }
    }
    func testLongDictationBudgetAndProviderTruncationInBothFormats() async throws {
        for format in LLMFormat.allCases {
            let api = client(); var config = APIConfiguration(); config.textAllowed = true; config.format = format
            StubProtocol.data = try JSONSerialization.data(withJSONObject: format == .gemini
                ? ["candidates": [["content": ["parts": [["text": "不完整结果"]]], "finishReason": "MAX_TOKENS"]]]
                : ["choices": [["message": ["content": "不完整结果"], "finish_reason": "length"]]])
            do {
                _ = try await api.polishDictation(String(repeating: "长录音", count: 2000), scene: "", terms: [], lineBreaks: true,
                                                  config: config, token: "test", timeout: 8)
                XCTFail("Provider-truncated text must not replace the complete transcript")
            } catch { XCTAssertTrue(error is AIError) }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubProtocol.body) as? [String: Any])
            let limit = try XCTUnwrap(format == .gemini
                ? (body["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int
                : body["max_tokens"] as? Int)
            XCTAssertGreaterThan(limit, 6000); XCTAssertLessThanOrEqual(limit, 32768)
            XCTAssertEqual(StubProtocol.requests, 1)
        }
    }
}
private final class HangingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{".utf8))
        // Deliberately leave the body unfinished to exercise the absolute deadline.
    }
    override func stopLoading() {}
}
