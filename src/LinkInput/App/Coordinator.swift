import AppKit
import InputMethodKit
import AVFoundation
import YiliuCore
import OSLog
import LinkRecordCore

/// UI callbacks, timers and task completions are confined to the main queue.
/// There is no separate draft window: the host field is the draft. Whatever cannot be written in place
/// is copied and reported in the bottom HUD.
final class Coordinator: @unchecked Sendable {
    static let shared = Coordinator()
    let draft = DraftSession()
    private var historyRecord: HistoryRecord?
    private func saveHistory(status: String, result: String? = nil, delivered: String? = nil) {
        guard var record = historyRecord else { return }
        record.status = status; record.ended = Date()
        if let result { record.result = result }; if let delivered { record.delivered = delivered }
        historyRecord = record; HistoryBridge.shared.submit(record)
    }
    let recorder = Recorder()
    private let api = AIClient()
    let usage = UsageLedger(file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Yiliu/usage.json"))
    private lazy var hud = DictationHUD()
    private lazy var inline = InlineSuggestion()
    /// In-place enhancement: the host field is the draft and the result bubble sits beside its caret.
    private(set) var isInline = false
    private(set) var target: InputTarget?
    private weak var writer: YiliuInputController?
    private var work: Task<Void, Never>?
    private var recordTimer: Timer?
    private var recordingStarted: Date?
    private var recordingAttempt: UUID?
    private var observers: [NSObjectProtocol] = []
    private var targetActivityMonitor: Any?
    var statusChanged: ((String) -> Void)?
    private var pendingUsage: (started: Date, audioSeconds: Double)?
    /// A recording is under way: the transcript goes straight into the editor it started in.
    private(set) var isDictating = false
    /// Captured when recording starts, so switching modes mid-recording never changes this transcript.
    private var dictationMode: DictationMode?
    private var streamer: StreamingTranscriber?
    private let audioMute = SystemAudioMute()
    private lazy var startSound = DictationStartSound()
    var isVoiceBusy: Bool { recorder.recording || recordingAttempt != nil }
    private var dictationApp: NSRunningApplication?
    private let focusQueue = DispatchQueue(label: "work.yiliu.dictation-focus", qos: .userInitiated)
    private var focusAttempt: UUID?
    private var focusPending = false
    private var focusChangedDuringCapture = false
    private let latencyLog = Logger(subsystem: "work.yiliu.inputmethod.Yiliu", category: "voice-latency")
    /// Build lightweight views ahead of the first hotkey, without opening the microphone.
    func prepareVoiceUI() { _ = hud; _ = startSound }
    func notifyTargetChanged() { hud.notice("输入窗口已切换", detail: "请回到需要的位置，再次使用语音或 AI 整理。") }
    /// Decisions only (app, roles, outcomes); never transcript text.
    private let dictationLog = Logger(subsystem: "work.yiliu.inputmethod.Yiliu", category: "dictation")
    init() {
        targetActivityMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return }
            if self.isDictating, self.focusPending { self.focusChangedDuringCapture = true }
            // Keys reach the bubble through the input method; a click elsewhere invalidates it.
            if self.isInline, event.type != .keyDown { self.dismissInline() }
        }
        recorder.onNetworkLoss = { [weak self] in self?.cancel(); self?.hud.notice("网络已断开", detail: "录音已停止，音频已清除。") }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            // Dictation keeps recording across app switches; the write-time focus check decides where text goes.
            if self.isDictating { if self.focusPending { self.focusChangedDuringCapture = true }; return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self.dismissInline()
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Preferences.shared.forgetCachedToken(); self?.clear() })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in Preferences.shared.forgetCachedToken(); self?.clear() })
    }
    private func startInlineEnhancement() {
        let manual = Preferences.shared.manualOptions
        let config = Preferences.shared.config
        guard let stamp = draft.startRequest() else { return }
        isInline = true
        let input = draft.text
        historyRecord = HistoryBridge.shared.record(kind: .enhancement, app: target?.bundleID ?? "", text: input, status: "整理中")
        statusChanged?("整理…")
        pendingUsage = (Date(), 0)
        work = Task { @MainActor in
            let start = Date()
            do {
                let token = await Preferences.shared.token()
                guard !Task.isCancelled else { return }
                guard !token.isEmpty else { throw AIError.credentials }
                let result = try await api.enhance(text: input, background: "", config: config, token: token, systemPrompt: manual.selectedMode.effectivePrompt)
                guard !Task.isCancelled else { return }
                if draft.receive(result.text, stamp: stamp) {
                    pendingUsage = nil
                    var cost: Double?
                    if let units = result.usage, let inputRate = config.inputUSDPerMillion, let outputRate = config.outputUSDPerMillion {
                        cost = (Double(units.input) * inputRate + Double(units.output) * outputRate) / 1_000_000
                    }
                    usage.record(tokens: result.usage, latency: Date().timeIntervalSince(start), failed: false, estimatedUSD: cost)
                    // The field itself is the draft: a result for text that has since changed is discarded.
                    if target?.isCurrent() == true { saveHistory(status: "待采用", result: result.text); self.inline.show(result: result.text, note: result.note) }
                    else { saveHistory(status: "原文已变化 · 未采用", result: result.text); draft.cancelRequest(); self.inline.failed("原文或输入位置已变化，结果已丢弃。Esc 关闭") }
                }
            } catch {
                guard !Task.isCancelled, draft.activeRequest == stamp else { return }
                pendingUsage = nil; draft.cancelRequest()
                saveHistory(status: "整理失败")
                self.inline.failed(safeError(error) + " Esc 关闭")
                usage.record(latency: Date().timeIntervalSince(start), failed: true)
            }
            statusChanged?("意")
        }
    }
    /// Reads the credential before the microphone opens, so an unreadable Keychain item fails before the user speaks.
    private func startRecording(triggeredAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let attempt = UUID(); recordingAttempt = attempt
        work = Task { @MainActor in
            do {
                let token = await Preferences.shared.token()
                try Task.checkCancellation()
                guard recordingAttempt == attempt else { return }
                guard !token.isEmpty else { throw AIError.credentials }
                YiliuInputController.latest(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)?.finishForDraft()
                let voice = Preferences.shared.voiceOptions
                if voice.streaming {
                    // Opens alongside the microphone; audio recorded before the socket is ready is replayed to it.
                    let config = Preferences.shared.config
                    if let stream = StreamingTranscriber(asrURL: config.asrURL, authHeader: config.authHeader, token: token, vocabulary: voice.vocabulary) {
                        stream.onPartial = { [weak self] text in self?.hud.show(partial: text) }
                        streamer = stream; recorder.onAudioChunk = { [weak stream] pcm in stream?.append(pcm) }
                    }
                }
                let maxDuration = voice.maxRecordingDuration
                try await recorder.start(maxDuration: maxDuration); try Task.checkCancellation()
                guard recordingAttempt == attempt else { return }
                recordingStarted = Date(); statusChanged?("● 录音")
                let readyMS = (ProcessInfo.processInfo.systemUptime - triggeredAt) * 1000
                latencyLog.notice("trigger_to_listening_ms=\(readyMS, privacy: .public)")
                hud.listening { [recorder] in recorder.level }
                let cueDuration = startSound.play()
                recordTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    guard let self, let start = self.recordingStarted else { return }
                    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                        self.cancel(); self.hud.notice("麦克风授权已撤回", detail: "音频已清除。"); return
                    }
                    if Date().timeIntervalSince(start) >= maxDuration { self.finishRecord() }
                }
                if voice.muteWhileRecording {
                    // Keep recording immediately; only defer output muting until the cue finishes.
                    if cueDuration > 0 { try await Task.sleep(for: .seconds(cueDuration)) }
                    guard recordingAttempt == attempt, recorder.recording else { return }
                    audioMute.mute()
                }
            } catch {
                guard recordingAttempt == attempt else { return }
                recorder.cancel(); recordingAttempt = nil; isDictating = false; audioMute.restore(); statusChanged?("意")
                hud.notice("无法开始语音输入", detail: safeError(error))
            }
        }
    }
    func voiceHotkey(triggeredAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        ReplyCoordinator.shared.cancel()
        if recorder.recording { finishRecord(); return }
        if recordingAttempt != nil { cancel(); return }
        // A transcript is still on its way into the field; a new recording would cancel it.
        if isDictating, work != nil { return }
        cancel()
        let c = Preferences.shared.config
        guard c.audioAllowed, !c.paused else { hud.notice("语音输入未开启", detail: AIError.disabled.localizedDescription); return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        isDictating = true; dictationMode = Preferences.shared.voiceOptions.selectedMode; hud.preparing()
        let hudMS = (ProcessInfo.processInfo.systemUptime - triggeredAt) * 1000
        latencyLog.notice("trigger_to_hud_ms=\(hudMS, privacy: .public)")
        bindDictationTarget(app, excludedApps: c.excludedApps)
        startRecording(triggeredAt: triggeredAt)
    }
    /// Capture focus identity only, on a bounded background AX queue. No editor text is needed for dictation.
    /// Do not request AXManualAccessibility here: unsupported hosts can block that call for seconds.
    private func bindDictationTarget(_ app: NSRunningApplication, excludedApps: [String]) {
        dictationApp = app; target = nil
        writer = YiliuInputController.latest(for: app.bundleIdentifier)
        draft.begin(text: "", target: UUID())
        let attempt = UUID(); focusAttempt = attempt; focusPending = true; focusChangedDuringCapture = false
        focusQueue.async { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            let captured = InputTarget(app: app, allowTerminal: true, captureText: false, excludedApps: excludedApps)
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            DispatchQueue.main.async {
                guard let self, self.focusAttempt == attempt else { return }
                self.focusPending = false
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier { self.focusChangedDuringCapture = true }
                if !self.focusChangedDuringCapture { self.target = captured }
                self.latencyLog.notice("focus_capture_ms=\(ms, privacy: .public)")
            }
        }
    }
    /// Terminals turn a newline into Return, and AX single-line fields drop it; everywhere else paragraphs survive a paste.
    private var dictationAllowsLineBreaks: Bool {
        !InputTarget.isTerminal(dictationApp?.bundleIdentifier ?? "") && !["AXTextField", "AXComboBox"].contains(target?.role ?? "")
    }
    /// Commits like typing into the app dictation started in; anything else is copied for the user to paste.
    /// Multi-line text is pasted: a paste inserts line breaks as text, while typed newlines could act as Return.
    private func insertDictation() {
        isDictating = false; hud.dismiss()
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { clear(); statusChanged?("意"); return }
        let front = NSWorkspace.shared.frontmostApplication
        let sameApp = front != nil && front?.processIdentifier == dictationApp?.processIdentifier
        let sameEditor = target.map { $0.focusedRange() != nil } ?? true
        // The client that has focus now; with no AX editor pinned, that is wherever the user is typing in this app.
        let writer = YiliuInputController.latest(for: front?.bundleIdentifier)
        let allowed = !IsSecureEventInputEnabled() && !Preferences.shared.config.excludedApps.contains(front?.bundleIdentifier ?? "")
        // Typed text never carries a control character: a newline could send a message or run a command.
        let line = String(String.UnicodeScalarView(draft.text.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : $0 }))
        let paragraphs = Self.paragraphs(draft.text)
        let multiline = dictationAllowsLineBreaks && paragraphs.contains("\n")
        let placeKnown = sameApp && sameEditor && !focusPending && !focusChangedDuringCapture && allowed
        let pasteAllowed = Preferences.shared.voiceOptions.pasteFallback
        if placeKnown, pasteAllowed, writer == nil || multiline, let ticket = draft.beginCommit(target: draft.target) {
            // Multi-line text, or a host with no LinkInput connection (another input method, or not reconnected after an update).
            ClipboardPaster.paste(multiline ? paragraphs : line)
            saveHistory(status: "已请求粘贴 · 宿主未确认", delivered: multiline ? paragraphs : line)
            draft.finishCommit(ticket, verified: true)
            dictationLog.notice("write paste app=\(front?.bundleIdentifier ?? "-", privacy: .public) multiline=\(multiline, privacy: .public)")
            clear(); statusChanged?("意"); return
        }
        guard placeKnown, let writer, writer.hostBundleID == front?.bundleIdentifier,
              let ticket = draft.beginCommit(target: draft.target) else {
            dictationLog.notice("fallback sameApp=\(sameApp, privacy: .public) sameEditor=\(sameEditor, privacy: .public) allowed=\(allowed, privacy: .public) writer=\(writer != nil, privacy: .public) front=\(front?.bundleIdentifier ?? "-", privacy: .public)")
            copy(multiline ? paragraphs : line)
            saveHistory(status: "已复制 · 未写入", delivered: multiline ? paragraphs : line)
            clear(); statusChanged?("意")
            if writer == nil { hud.notice("LinkInput 未连上当前应用，转写已复制", detail: "请 ⌘V 粘贴；切到其他应用再切回可恢复直接上屏。") }
            else { hud.notice("输入位置已变化，转写已复制", detail: "请在需要的位置 ⌘V 粘贴。") }
            return
        }
        writer.insertTyped(line)
        saveHistory(status: "已请求上屏 · 不代表发送", delivered: line)
        draft.finishCommit(ticket, verified: true)
        dictationLog.notice("write app=\(front?.bundleIdentifier ?? "-", privacy: .public) editor=\(self.target != nil, privacy: .public)")
        clear(); statusChanged?("意")
    }
    /// Keeps line breaks (at most one blank line in a row); every other control character becomes a space.
    private static func paragraphs(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let spaced = String(String.UnicodeScalarView(unified.unicodeScalars.map { $0 != "\n" && $0.properties.generalCategory == .control ? " " : $0 }))
        return spaced.replacingOccurrences(of: #"\n[ \t]*\n(?:[ \t]*\n)+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func stopHeldRecording() { if recorder.recording { finishRecord() } else { cancel() } }
    private func finishRecord() {
        recordingAttempt = nil
        startSound.stop(); audioMute.restore()
        let seconds = recordingStarted.map { Date().timeIntervalSince($0) } ?? 0
        recordTimer?.invalidate(); recordTimer = nil
        recordingStarted = nil
        let wav = recorder.stop()
        guard wav.count > 44, let stamp = draft.startRequest() else {
            isDictating = false; statusChanged?("意"); hud.notice("未录到音频"); return
        }
        let config = Preferences.shared.config, voice = Preferences.shared.voiceOptions
        let stream = streamer; streamer = nil; recorder.onAudioChunk = nil
        let mode = dictationMode, app = dictationApp?.bundleIdentifier
        pendingUsage = (Date(), seconds); statusChanged?("转写…")
        hud.transcribing()
        work = Task { @MainActor in
            let start = Date()
            do {
                let token = await Preferences.shared.token()
                guard !Task.isCancelled else { return }
                guard !token.isEmpty else { throw AIError.credentials }
                var text: String
                if let streamed = await stream?.finish(), !streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = streamed; dictationLog.notice("transcript source=stream")
                } else {
                    text = try await api.transcribe(wav: wav, config: config, token: token, vocabulary: voice.vocabulary,
                                                    audioDuration: Double(max(0, wav.count - 44)) / (Recorder.outputRate * 2))
                    dictationLog.notice("transcript source=batch streamed=\(stream != nil, privacy: .public)")
                }
                guard !Task.isCancelled else { return }
                historyRecord = HistoryBridge.shared.record(kind: .voice, app: app ?? "", text: text, status: "转写完成")
                text = TranscriptCleaner.clean(text, options: voice)
                if let mode, mode.polish {
                    text = await enhanceDictation(text, mode: mode, app: app, terms: voice.vocabulary, lineBreaks: dictationAllowsLineBreaks, scenes: voice.scenePrompts, config: config, token: token)
                }
                guard !Task.isCancelled else { return }
                saveHistory(status: "待写入", result: text)
                if draft.receive(text, stamp: stamp) {
                    pendingUsage = nil
                    usage.record(audioSeconds: seconds, latency: Date().timeIntervalSince(start), failed: false, estimatedUSD: config.audioUSDPerMinute.map { seconds / 60 * $0 })
                    draft.acceptSuggestion()
                    insertDictation(); return
                }
            } catch {
                guard !Task.isCancelled, draft.activeRequest == stamp else { return }
                pendingUsage = nil; draft.cancelRequest(); isDictating = false
                hud.notice("转写失败", detail: safeError(error))
                usage.record(audioSeconds: seconds, latency: Date().timeIntervalSince(start), failed: true)
            }
            statusChanged?("意")
        }
    }
    /// Enhance with the selected mode and destination scene; any API failure keeps the transcript.
    @MainActor private func enhanceDictation(_ text: String, mode: DictationMode, app: String?, terms: [String], lineBreaks: Bool,
                                             scenes: ScenePrompts, config: APIConfiguration, token: String) async -> String {
        guard config.textAllowed, !config.paused, !text.isEmpty else { return text }
        hud.enhancing(); statusChanged?("整理…")
        let start = Date()
        // The user is waiting to see text; past 8 s the raw transcript is the better answer.
        guard let result = try? await api.polishDictation(text, scene: scenes.text(forApp: app, isTerminal: InputTarget.isTerminal(app ?? "")), terms: terms, lineBreaks: lineBreaks,
                                                          config: config, token: token, timeout: 8, systemPrompt: mode.systemPrompt, layoutPrompt: scenes.layout(lineBreaks: lineBreaks)) else {
            usage.record(latency: Date().timeIntervalSince(start), failed: true); return text
        }
        usage.record(tokens: result.usage, latency: Date().timeIntervalSince(start), failed: false, estimatedUSD: nil)
        return result.text
    }
    /// Stops recording, requests and the bubble; requests already sent cannot be recalled from the service.
    func cancel() {
        if let record = historyRecord, ["整理中", "转写完成", "待采用", "待写入"].contains(record.status) { saveHistory(status: "已取消 · 未写入") }
        historyRecord = nil
        recordAbandonedRequest()
        recordingAttempt = nil; focusAttempt = nil; focusPending = false; isDictating = false; dictationMode = nil; hud.dismiss()
        streamer?.cancel(); streamer = nil; recorder.onAudioChunk = nil; startSound.stop(); audioMute.restore()
        if isInline { isInline = false; inline.dismiss() }
        work?.cancel(); work = nil; recorder.cancel(); recordTimer?.invalidate(); recordTimer = nil; recordingStarted = nil
        draft.cancelRequest(); statusChanged?("意")
    }
    private func recordAbandonedRequest() {
        guard let pending = pendingUsage else { return }
        pendingUsage = nil
        usage.record(audioSeconds: pending.audioSeconds, latency: Date().timeIntervalSince(pending.started), failed: false)
    }
    func clear() { cancel(); draft.clear(); target = nil; writer = nil }
    func settingsChanged() { ReplyCoordinator.shared.cancel(); cancel(); if Preferences.shared.config.paused { target = nil; writer = nil } }
    /// Enhancement hotkey: works on the selection, or the whole small field, right where the user is typing.
    /// Anything that cannot be read or written in place is reported in the HUD; nothing opens a separate draft.
    func enhanceHotkey(retried: Bool = false) {
        ReplyCoordinator.shared.cancel()
        if isInline { dismissInline(); return }
        let config = Preferences.shared.config
        guard config.textAllowed, !config.paused else { hud.notice("整理未开启", detail: AIError.disabled.localizedDescription); return }
        guard Preferences.shared.hasToken() else { hud.notice("无法整理", detail: AIError.credentials.localizedDescription); return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        cancel()
        let controller = YiliuInputController.latest(for: app.bundleIdentifier)
        let found = InputTarget(app: app) ?? controller.flatMap { InputTarget(client: $0, app: app) }
        // Electron/Chromium expose their editors to AX only on request; ask once, then retry.
        if found == nil, !retried, InputTarget.requestWebAccessibility(app) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.enhanceHotkey(retried: true) }
            return
        }
        guard let found, let controller, controller.hostBundleID == found.bundleID,
              !found.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, found.selection.count <= 8000 else {
            let bundle = app.bundleIdentifier ?? "-"
            Logger(subsystem: "work.yiliu.inputmethod.Yiliu", category: "inline").notice("fallback ax=\(found?.element != nil, privacy: .public) app=\(bundle, privacy: .public) target=\(found != nil, privacy: .public) writer=\(controller != nil, privacy: .public) empty=\(found?.selection.isEmpty ?? true, privacy: .public)")
            if InputTarget.isTerminal(bundle) { hud.notice("终端不支持就地整理", detail: "终端无法读取或替换输入行；语音可直接上屏。") }
            else if !AXIsProcessTrusted() { hud.notice("无法整理", detail: "LinkInput 尚未获得辅助功能权限，请在“设置与隐私”中授权。") }
            else if controller == nil { hud.notice("LinkInput 未连上当前应用", detail: "切到其他应用再切回后重试。") }
            else { hud.notice("没有可整理的文字", detail: "请先选中文字，或在 2000 字以内的输入框中使用。") }
            return
        }
        target = found; writer = controller; found.bind(client: controller)
        Logger(subsystem: "work.yiliu.inputmethod.Yiliu", category: "inline").notice("start app=\(found.bundleID, privacy: .public) ax=\(found.element != nil, privacy: .public) whole=\(found.isWholeField, privacy: .public)")
        draft.begin(text: found.selection, target: found.id)
        startInlineEnhancement()
        guard isInline else { clear(); return }
        inline.loading(near: controller.caretRect(), source: found.isWholeField ? "输入框" : "选中文字")
    }
    /// Enter/Tab or the button: replace the original in place, only if field and text are unchanged.
    func acceptInline() {
        guard isInline, draft.suggestion != nil else { return }
        draft.acceptSuggestion()
        guard let target, let writer, target.isCurrent(), writer.hostBundleID == target.bundleID,
              let ticket = draft.beginCommit(target: target.id) else {
            Logger(subsystem: "work.yiliu.inputmethod.Yiliu", category: "inline").notice("accept blocked writer=\(self.writer != nil, privacy: .public) \(self.target?.diagnoseCurrency() ?? "no target", privacy: .public)")
            copy(draft.text); saveHistory(status: "已复制 · 未替换", delivered: draft.text); clear()
            hud.notice("原文或输入位置已变化，未替换", detail: "整理结果已复制，可自行粘贴。"); return
        }
        let written = draft.text, location = target.range.location
        let immediate = writer.writeDraft(written, range: NSRange(location: location, length: target.range.length))
        isInline = false; inline.dismiss()
        let finish = { [weak self, weak writer] in
            guard let self else { return }
            // One delayed read-back only; still unconfirmed means no retry and no second write.
            let verified = immediate || writer?.reads(written, at: location) == true
            self.draft.finishCommit(ticket, verified: verified)
            self.saveHistory(status: verified ? "已采用 · 替换已确认" : "已请求替换 · 宿主未确认", delivered: written)
            Logger(subsystem: "work.yiliu.inputmethod.Yiliu", category: "inline").notice("accept write immediate=\(immediate, privacy: .public) verified=\(verified, privacy: .public)")
            self.clear()
            if !verified { self.hud.notice("已请求替换，宿主未确认", detail: "请查看原输入框，勿重复粘贴。") }
        }
        if immediate { finish() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: finish) }
    }
    /// The bubble's copy button: the user edits and pastes the result themselves.
    func copyInline() {
        guard isInline, let suggestion = draft.suggestion else { return }
        copy(suggestion); saveHistory(status: "已复制 · 未替换", delivered: suggestion); clear()
        hud.notice("整理结果已复制", detail: "原文未改动，可自行编辑后粘贴。")
    }
    func dismissInline() { guard isInline else { return }; clear() }
    func diagnostics() -> String {
        "LinkInput 0.1.0\n辅助功能权限：\(AXIsProcessTrusted() ? "已授权" : "未授权")\n" + usage.summary() + "\n无正文、音频、联系人、密钥或窗口标题。不自动上传。"
    }
    private func safeError(_ error: Error) -> String {
        // The item exists but cannot be read: a rebuilt app no longer matches the Keychain access list.
        if case .credentials? = error as? AIError, Preferences.shared.hasToken() {
            return "钥匙串拒绝读取 API 凭据（重装后常见），请在设置中重新保存凭据。"
        }
        if let error = error as? AIError { return error.localizedDescription }
        if error is CancellationError { return "已取消。" }
        if let url = error as? URLError, url.code == .timedOut { return "请求超时，服务没有及时返回。" }
        if let url = error as? URLError { return "网络请求未完成（\(url.code.rawValue)）。" }
        return "操作未完成，请检查麦克风权限、设备或网络。"
    }
}
