import Foundation
import OSLog

/// ElevenLabs realtime transcription for one recording. The gateway only mints a single-use token, so the
/// long-lived key never leaves it; audio goes to ElevenLabs directly, the same processor as batch uploads.
/// Any failure leaves `finish` returning nil and the caller uploads the recorded WAV instead.
final class StreamingTranscriber: @unchecked Sendable {
    private let queue = DispatchQueue(label: "work.yiliu.stream")
    private let log = Logger(subsystem: "work.yiliu.inputmethod.Yiliu", category: "voice-latency")
    private var socket: URLSessionWebSocketTask? // queue only
    private var backlog = Data(), outgoing = Data()
    private var connected = false, failed = false, finishing = false
    private var committed: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    /// Latest partial transcript, on the main queue.
    var onPartial: ((String) -> Void)?

    /// Token endpoint beside the batch endpoint, or nil for non-ElevenLabs speech APIs.
    static func tokenURL(for asrURL: String) -> URL? {
        guard asrURL.hasPrefix("https://"), asrURL.hasSuffix("/v1/speech-to-text") else { return nil }
        return URL(string: String(asrURL.dropLast("/v1/speech-to-text".count)) + "/v1/single-use-token/realtime_scribe")
    }
    init?(asrURL: String, authHeader: String, token: String, vocabulary: [String]) {
        guard let tokenURL = Self.tokenURL(for: asrURL) else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            do {
                var request = URLRequest(url: tokenURL, timeoutInterval: 5); request.httpMethod = "POST"
                request.setValue(authHeader == "Authorization" ? "Bearer \(token)" : token, forHTTPHeaderField: authHeader)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let single = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? String else { throw URLError(.userAuthenticationRequired) }
                var parts = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
                parts.queryItems = [URLQueryItem(name: "model_id", value: "scribe_v2_realtime"), URLQueryItem(name: "audio_format", value: "pcm_16000"),
                                    URLQueryItem(name: "language_code", value: "zh"), URLQueryItem(name: "commit_strategy", value: "manual")]
                    + vocabulary.prefix(50).map { URLQueryItem(name: "keyterms", value: $0) } + [URLQueryItem(name: "token", value: single)]
                guard let url = parts.url else { throw URLError(.badURL) }
                self?.queue.async { self?.open(url, started: started) }
            } catch { self?.queue.async { self?.fail("token") } }
        }
    }
    private func open(_ url: URL, started: TimeInterval) {
        guard !failed else { return }
        let socket = URLSession.shared.webSocketTask(with: url)
        self.socket = socket; socket.resume(); receive()
        connected = true; outgoing = backlog; backlog = Data()
        log.notice("stream_ready_ms=\((ProcessInfo.processInfo.systemUptime - started) * 1000, privacy: .public)")
        flush(force: true)
        if finishing { sendCommit() }
    }
    /// Called from the audio thread with 16 kHz mono PCM16.
    func append(_ pcm: Data) {
        queue.async { [self] in
            guard !failed, !finishing else { return }
            if !connected {
                // Never silently drop a prefix of a long recording; use the complete batch fallback.
                guard backlog.count + pcm.count <= 16_000 * 2 * 60 else { fail("backlog"); return }
                backlog.append(pcm); return
            }
            outgoing.append(pcm); flush(force: false)
        }
    }
    /// Roughly 100 ms per message instead of one message per tap buffer.
    private func flush(force: Bool) {
        while outgoing.count >= 3_200 || (force && !outgoing.isEmpty) {
            let chunk = outgoing.prefix(3_200 * 4); outgoing.removeFirst(chunk.count)
            send(audio: chunk, commit: false)
        }
    }
    private func send(audio: Data, commit: Bool) {
        let message: [String: Any] = ["message_type": "input_audio_chunk", "audio_base_64": audio.base64EncodedString(), "commit": commit, "sample_rate": 16_000]
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in if error != nil { self?.queue.async { self?.fail("send") } } }
    }
    private func sendCommit() { flush(force: true); send(audio: Data(), commit: true) }
    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure: self.fail("receive")
                case .success(let message):
                    if case .string(let text) = message, let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                        self.handle(json)
                    }
                    if !self.failed { self.receive() }
                }
            }
        }
    }
    private func handle(_ json: [String: Any]) {
        let type = json["message_type"] as? String ?? ""
        let text = json["text"] as? String ?? ""
        switch type {
        case "partial_transcript":
            let shown = committed.joined() + text
            DispatchQueue.main.async { [weak self] in self?.onPartial?(shown) }
        case let t where t.hasPrefix("committed_transcript"):
            committed.append(text)
            if finishing { resolve(committed.joined()) }
        case "session_started": break
        default: if type.contains("error") || type.contains("exceeded") { fail(type) }
        }
    }
    private func fail(_ reason: String) {
        guard !failed else { return }
        failed = true; log.notice("stream_failed reason=\(reason, privacy: .public)")
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        resolve(nil)
    }
    private func resolve(_ value: String?) { waiter?.resume(returning: value); waiter = nil }
    /// Commits the remaining audio and waits briefly for the final text; nil means use the batch upload.
    func finish(timeout: TimeInterval = 4) async -> String? {
        let result: String? = await withCheckedContinuation { done in
            queue.async { [self] in
                guard !failed else { done.resume(returning: nil); return }
                waiter = done; finishing = true
                if connected { sendCommit() }
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, self.waiter != nil else { return }
                    self.fail("timeout")
                }
            }
        }
        cancel()
        return result
    }
    func cancel() {
        queue.async { [self] in
            failed = true; socket?.cancel(with: .normalClosure, reason: nil); socket = nil
            backlog = Data(); outgoing = Data(); resolve(nil)
        }
    }
}
