import AVFoundation
import Network
import OSLog
import YiliuCore

/// Audio hardware is owned by one serial queue. Cancelling gates samples immediately;
/// a slow device start/stop never holds the input method's main thread.
final class Recorder: @unchecked Sendable {
    private let audioQueue = DispatchQueue(label: "work.yiliu.audio", qos: .userInitiated)
    private let buffer = RecordingBuffer()
    private var engine: AVAudioEngine? // audioQueue only; reused without keeping the mic running
    private var engineRun: UUID?
    private var tapInstalled = false
    private var monitor: NWPathMonitor?
    private let log = Logger(subsystem: "work.yiliu.inputmethod.Yiliu", category: "voice-latency")
    var recording: Bool { buffer.recording }
    var level: Float { buffer.level }
    var onNetworkLoss: (() -> Void)?
    /// 16 kHz mono PCM16 chunks of the current run, delivered on the audio thread (for streaming ASR).
    var onAudioChunk: ((Data) -> Void)?
    static let outputRate = 16_000.0

    @MainActor func start(maxDuration: TimeInterval) async throws {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
        default: granted = false
        }
        guard granted else { throw NSError(domain: "Yiliu", code: 1, userInfo: [NSLocalizedDescriptionKey: "麦克风权限未开启。请在系统设置中允许 LinkInput 使用麦克风。"]) }
        try Task.checkCancellation()
        let id = buffer.begin()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                audioQueue.async { [self] in
                    let start = ProcessInfo.processInfo.systemUptime
                    do {
                        guard buffer.isCurrent(id) else { throw CancellationError() }
                        stopEngine()
                        if engine == nil { engine = AVAudioEngine() }
                        guard let engine else { throw CancellationError() }
                        engineRun = id
                        let node = engine.inputNode
                        let format = node.outputFormat(forBus: 0)
                        guard format.sampleRate > 0, format.channelCount > 0 else {
                            throw NSError(domain: "Yiliu", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风。"])
                        }
                        // Speech models need 16 kHz mono; converting here cuts upload size threefold versus 48 kHz.
                        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.outputRate, channels: 1, interleaved: true),
                              let converter = AVAudioConverter(from: format, to: output),
                              buffer.configure(id, rate: Self.outputRate, maxDuration: maxDuration) else { throw CancellationError() }
                        node.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] audio, _ in
                            guard let self, self.buffer.isCurrent(id), let channel = audio.floatChannelData?[0] else { return }
                            let count = Int(audio.frameLength)
                            var sum: Float = 0
                            for i in 0..<count where channel[i].isFinite { sum += channel[i] * channel[i] }
                            let capacity = AVAudioFrameCount(Double(count) * Self.outputRate / format.sampleRate) + 32
                            guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
                            var supplied = false
                            converter.convert(to: converted, error: nil) { _, status in
                                if supplied { status.pointee = .noDataNow; return nil }
                                supplied = true; status.pointee = .haveData; return audio
                            }
                            guard converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }
                            let pcm = Data(bytes: samples, count: Int(converted.frameLength) * 2)
                            self.onAudioChunk?(pcm)
                            if self.buffer.append(pcm, level: min(1, sqrt(sum / Float(max(1, count))) * 8), run: id) {
                                let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                                self.log.notice("first_audio_ms=\(ms, privacy: .public)")
                            }
                        }
                        tapInstalled = true
                        engine.prepare()
                        guard buffer.isCurrent(id) else { throw CancellationError() }
                        try engine.start()
                        guard buffer.didStart(id) else { throw CancellationError() }
                        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        log.notice("audio_start_ms=\(ms, privacy: .public)")
                        let monitor = NWPathMonitor()
                        monitor.pathUpdateHandler = { [weak self] path in
                            if path.status == .unsatisfied {
                                DispatchQueue.main.async { if self?.buffer.isCurrent(id) == true { self?.onNetworkLoss?() } }
                            }
                        }
                        self.monitor = monitor; monitor.start(queue: audioQueue)
                        done.resume()
                    } catch {
                        _ = buffer.finish(ifCurrent: id)
                        if engineRun == id { stopEngine() }
                        done.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: { self.cancel(run: id) }
    }
    /// Only called on audioQueue, never from the UI or from an audio callback.
    private func stopEngine() {
        if let engine {
            if engine.isRunning { engine.stop() }
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        }
        monitor?.cancel(); monitor = nil; engineRun = nil
    }
    private func releaseHardware(_ id: UUID?) {
        audioQueue.async { [self] in if engineRun == id { stopEngine() } }
    }
    func stop() -> Data {
        guard let capture = buffer.finish() else { return Data() }
        releaseHardware(capture.id)
        var wav = Data()
        func s(_ value: String) { wav.append(Data(value.utf8)) }
        func n<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        s("RIFF"); n(UInt32(capture.pcm.count + 36)); s("WAVEfmt "); n(UInt32(16)); n(UInt16(1)); n(UInt16(1)); n(UInt32(capture.rate)); n(UInt32(capture.rate * 2)); n(UInt16(2)); n(UInt16(16)); s("data"); n(UInt32(capture.pcm.count)); wav.append(capture.pcm)
        return wav
    }
    private func cancel(run: UUID) {
        if let capture = buffer.finish(ifCurrent: run) { releaseHardware(capture.id) }
    }
    func cancel() {
        if let capture = buffer.finish() { releaseHardware(capture.id) }
    }
}
