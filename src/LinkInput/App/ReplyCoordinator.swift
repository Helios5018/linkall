import AppKit
import Carbon
import LinkAgent
import LinkRecordCore
import YiliuCore
import OSLog

/// One request bound to one editor. All mutable UI/session state stays on the main queue.
final class ReplyCoordinator {
    static let shared = ReplyCoordinator()
    private let log = Logger(subsystem: "work.yiliu.inputmethod.Yiliu", category: "reply")
    private lazy var panel: ReplyPanel = {
        let panel = ReplyPanel()
        panel.onChoose = { [weak self] in self?.choose($0) }
        panel.onCopy = { [weak self] in self?.copy($0) }
        panel.onSources = { [weak self] in guard let self else { return }; self.sourcesVisible.toggle(); self.render() }
        panel.onCancel = { [weak self] in self?.cancel() }
        return panel
    }()
    private let api = AIClient()
    private var task: Task<Void, Never>?
    private var epoch = UUID()
    private var target: InputTarget?
    private weak var writer: YiliuInputController?
    private var candidates: [String] = []
    private var selected = 0
    private var recommendation: ReplyRecommendation?
    private var context: ReplyContext?
    private var sourcesVisible = false
    private var terminalSession = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private(set) var active = false
    init() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in self?.cancel() }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.cancel() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.cancel() })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.cancel() })
    }
    func cancel(reason: String = #function) {
        if active { log.notice("session cancelled reason=\(reason, privacy: .public)") }
        epoch = UUID(); task?.cancel(); task = nil; active = false; target = nil; writer = nil
        candidates = []; selected = 0; recommendation = nil; context = nil; sourcesVisible = false; terminalSession = false; panel.dismiss()
    }
    /// Called after the IMK callback returns, so the host can answer text/AX queries.
    func start(writer: YiliuInputController) {
        cancel(); Coordinator.shared.cancel()
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == writer.hostBundleID,
              !IsSecureEventInputEnabled() else { return }
        active = true; self.writer = writer
        terminalSession = InputTarget.isTerminal(writer.hostBundleID)
        log.notice("request started")
        let config = Preferences.shared.config
        guard config.textAllowed, !config.paused else { panel.show("请先在设置中开启云端文本处理，再使用 V → 左 ⌘。", near: writer.caretRect()); return }
        guard !config.excludedApps.contains(writer.hostBundleID) else { panel.show("当前应用已排除，未读取或上传上下文。", near: writer.caretRect()); return }
        let stamp = epoch, bundle = writer.hostBundleID
        panel.show("LinkAgent 正在筛选当前场景的近期记录…", near: writer.caretRect())
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                let store = try await Task.detached(priority: .userInitiated) { try HistoryStore() }.value
                let settings = try await Task.detached(priority: .userInitiated) { try store.settings() }.value
                try Task.checkCancellation()
                guard self.epoch == stamp else { return }
                guard self.isCurrent(app: app) else { self.log.notice("currency rejected"); self.cancel(); return }
                guard !settings.excludedApps.contains(bundle) else { throw ReplyError.excluded }
                // Unknown targets still receive scene suggestions, but can only copy explicitly.
                let captured = InputTarget.isTerminal(bundle)
                    ? InputTarget(app: app, allowTerminal: true, captureText: false, terminalInsertionOnly: true)
                    : (InputTarget(app: app) ?? InputTarget(client: writer, app: app))
                let found = captured.flatMap { $0.selection.utf16.count <= InputTarget.wholeFieldLimit ? $0 : nil }
                self.target = found; found?.bind(client: writer)
                self.log.notice("target captured known=\(found != nil, privacy: .public)")
                let window = Self.windowTitle(app.processIdentifier)
                let field = found?.selection ?? ""
                let fieldAvailable = found != nil && found?.insertionOnly != true
                let context = try await Task.detached(priority: .userInitiated) {
                    try ReplyAgent.context(store: store, app: bundle, window: window, field: field, fieldAvailable: fieldAvailable)
                }.value
                try Task.checkCancellation()
                guard self.epoch == stamp else { return }
                guard self.isCurrent(app: app) else { self.log.notice("currency rejected"); self.cancel(); return }
                self.log.notice("context selected count=\(context.records.count, privacy: .public)")
                let token = await Preferences.shared.token()
                try Task.checkCancellation()
                guard self.epoch == stamp else { return }
                guard self.isCurrent(app: app) else { self.log.notice("currency rejected"); self.cancel(); return }
                var units: TokenUsage?
                let recommendation = try await ReplyAgent.recommend(context: context) { system, user in
                    let result = try await self.api.suggest(system: system, user: user, config: config, token: token)
                    units = result.1; return result.0
                }
                try Task.checkCancellation()
                guard self.epoch == stamp else { return }
                guard self.isCurrent(app: app) else { self.log.notice("currency rejected"); self.cancel(); return }
                Coordinator.shared.usage.record(tokens: units, latency: Date().timeIntervalSince(started), failed: false)
                self.log.notice("recommendations ready count=3")
                self.candidates = recommendation.candidates.map(\.text)
                self.recommendation = recommendation; self.context = context; self.render()
            } catch {
                guard !Task.isCancelled, self.epoch == stamp else { return }
                Coordinator.shared.usage.record(latency: Date().timeIntervalSince(started), failed: true)
                let message: String
                if let error = error as? AIError { message = error.localizedDescription }
                else if let error = error as? ReplyError { message = error.localizedDescription }
                else if error is URLError { message = "网络请求未完成，请稍后重新触发。" }
                else { message = "无法读取上下文或生成建议，请稍后重新触发。" }
                self.panel.show(message)
            }
        }
    }
    private func render() {
        guard let recommendation, let context else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        let references = Set(recommendation.candidates[selected].evidenceIDs)
        let used = context.records.filter { references.contains($0.id) }
        let detail = (used.isEmpty ? ["这条建议未引用历史，主要依据当前草稿或用于澄清。"] : used.map {
            "\(formatter.string(from: $0.time)) · \($0.kind) · \($0.relation)\n\(String($0.original.prefix(160)))"
        }) + context.cautions
        let delivery = target == nil ? " · 仅复制" : target?.insertionOnly == true ? " · 插入光标处，保留已有内容" : " · 采用后不发送"
        panel.show("\(recommendation.summary)\nLinkAgent · 筛选 \(context.records.count) 条记录 · 当前建议引用 \(used.count) 条\(delivery)",
                   candidates: recommendation.candidates.map { "【\($0.intent)】\($0.text)" }, selected: selected,
                   copyOnly: target == nil, details: sourcesVisible ? detail.joined(separator: "\n") : nil, keyboardSelection: !terminalSession)
    }
    private static func windowTitle(_ pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.2)
        guard let ref = InputTarget.attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else { return "" }
        let window = unsafeBitCast(ref, to: AXUIElement.self); AXUIElementSetMessagingTimeout(window, 0.2)
        return InputTarget.attribute(window, kAXTitleAttribute) as? String ?? ""
    }
    private func isCurrent(app: NSRunningApplication) -> Bool {
        guard active, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              !IsSecureEventInputEnabled(), !Preferences.shared.config.paused, Preferences.shared.config.textAllowed,
              !Preferences.shared.config.excludedApps.contains(app.bundleIdentifier ?? "") else { return false }
        return target?.isReplyCurrent() ?? true
    }
    /// Return/Tab are always swallowed while open, including loading/error states.
    func handle(_ event: NSEvent, writer: YiliuInputController) -> Bool {
        guard active else { return false }
        guard self.writer === writer else { cancel(); return false }
        // Terminal hosts may deliver ASCII/control keys to their PTY even when IMK reports them handled.
        // A mouse choice is unambiguous; ordinary terminal keys cancel the panel and keep their usual meaning.
        if terminalSession { cancel(); return event.keyCode == 53 }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { cancel(); return false }
        switch event.keyCode {
        case 53: cancel(); return true
        case 36, 76, 48:
            // IMK's remote key reply must reach the host before AX validation. A plain async can run too early.
            let index = selected, stamp = epoch; DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in guard self?.epoch == stamp else { return }; self?.choose(index) }; return true
        case 125, 126:
            if !candidates.isEmpty { selected = (selected + (event.keyCode == 125 ? 1 : 2)) % 3; render() }
            return true
        default:
            if let number = event.characters.flatMap(Int.init), (1...3).contains(number) {
                let stamp = epoch
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in guard self?.epoch == stamp else { return }; self?.choose(number - 1) }; return true
            }
            cancel(); return false
        }
    }
    private func choose(_ index: Int) {
        guard active, candidates.indices.contains(index) else { return }
        guard let target, let writer else { copy(index); return }
        guard target.isReplyCurrent(), Preferences.shared.config.textAllowed, !Preferences.shared.config.paused else { log.notice("accept currency rejected \(target.diagnoseReplyCurrency(), privacy: .public)"); cancel(); return }
        let text = candidates[index]
        // Invalidate before issuing exactly one write; an unconfirmed host result is never retried.
        cancel()
        let verified: Bool
        if target.insertionOnly {
            // Normal IMK commit at the terminal cursor. No replacement range, clipboard, or synthetic Return.
            writer.insertTyped(text)
            verified = false
        } else {
            verified = writer.writeDraft(text, range: NSRange(location: target.range.location, length: target.range.length))
        }
        log.notice("write requested verified=\(verified, privacy: .public)")
        // Keep source/generated semantics without adding a new persisted enum that older versions cannot read.
        if var record = HistoryBridge.shared.record(kind: .enhancement, app: target.bundleID, text: target.selection,
                                                   status: verified ? "Agent 建议 · 已采用 · 不代表发送" : "Agent 建议 · 已请求上屏 · 宿主未确认") {
            record.result = text; record.delivered = text; HistoryBridge.shared.submit(record)
        }
    }
    private func copy(_ index: Int) {
        guard active, candidates.indices.contains(index) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(candidates[index], forType: .string); cancel()
    }
}
