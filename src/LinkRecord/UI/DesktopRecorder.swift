import AppKit
import ScreenCaptureKit
import Carbon
import LinkRecordCore

/// Sampling and OCR are bounded to one task; Accessibility calls never block the UI or the input method.
@MainActor public final class DesktopRecorder {
    private let model: RecordModel
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var busy = false
    private var resampleNeeded = false
    private var lifecycle = CaptureLifecycle()
    private var locked: Bool { lifecycle.isLocked }
    private var sleeping: Bool { lifecycle.isSleeping }
    private var generation: Int { lifecycle.revision }
    private var cadence = CaptureCadence()
    private var activationWork: DispatchWorkItem?
    private var interactionWork: DispatchWorkItem?
    private var interactionMonitor: Any?
    private var visualHint = false
    private var lastActivity: HistoryRecord?
    private var lastContext: HistoryRecord?
    private var lastScreenshot: HistoryRecord?
    public init(model: RecordModel) { self.model = model }
    public func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.sample() } }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.activationWork?.cancel()
                let work = DispatchWorkItem { self?.sample() }; self?.activationWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            }
        })
        for (name, lock) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.setLocked(lock) } })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.setSleeping(true) } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.setSleeping(false) } })
        interactionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .scrollWheel, .keyDown]) { [weak self] event in
            // Only navigation key codes; never read or store event characters.
            guard event.type != .keyDown || [116, 121, 123, 124, 125, 126].contains(event.keyCode) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.interactionWork?.cancel()
                let work = DispatchWorkItem { self.visualHint = true; self.sample() }
                self.interactionWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            }
        }
        model.bookmark = { [weak self] in self?.sample(bookmark: true) }
        sample()
    }
    public func changed() { lifecycle.invalidate(); cadence.reset(); lastScreenshot = nil; sample() }
    private func setLocked(_ value: Bool) { lifecycle.setLocked(value); if value { lastActivity = nil; lastContext = nil; lastScreenshot = nil }; sample() }
    private func setSleeping(_ value: Bool) {
        lifecycle.setSleeping(value)
        if value { lastActivity = nil; lastScreenshot = nil }
        sample()
    }
    func sample(bookmark: Bool = false) {
        let settings = model.settings
        guard !locked, !sleeping, !settings.paused else { lastActivity = nil; lastScreenshot = nil; model.desktopStatus = locked ? "锁屏中 · 已暂停" : (sleeping ? "休眠中 · 已暂停" : "记录已暂停"); return }
        if bookmark, NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("work.yiliu.") == true, let previous = lastContext, settings.allows(.bookmark, app: previous.app) {
            var mark = HistoryRecord(kind: .bookmark, app: previous.app, appName: previous.appName, window: previous.window, original: "记住最近的工作片段")
            mark.starred = true
            let store = model.store
            Task {
                do { try await Task.detached(priority: .utility) { try store.insert(mark) }.value; model.message = "已标记最近的工作片段。"; model.reload() }
                catch { model.message = "标记保存失败，请检查磁盘空间。" }
            }
            return
        }
        guard !busy else { resampleNeeded = true; if bookmark { model.message = "正在保存屏幕，请稍后再标记。" }; return }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return }
        guard !bundle.hasPrefix("work.yiliu."), settings.allows(bookmark ? .bookmark : .activity, app: bundle), !IsSecureEventInputEnabled() else {
            lastActivity = nil; lastScreenshot = nil
            model.desktopStatus = !settings.desktop ? "桌面记录已关闭" : "当前应用不采集"; return
        }
        busy = true
        let epoch = generation, pid = app.processIdentifier, name = app.localizedName ?? bundle, store = model.store
        let captureAllowed = settings.screenshots && CGPreflightScreenCaptureAccess()
        model.desktopStatus = !settings.screenshots ? "活动记录中 · 截图已关闭" : (captureAllowed ? "活动与截图记录中" : "活动记录中 · 屏幕录制未授权")
        if !AXIsProcessTrusted() { model.desktopStatus += " · 窗口标题未授权" }
        Task {
            defer {
                busy = false
                if resampleNeeded {
                    resampleNeeded = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.sample() }
                }
            }
            let title = await Task.detached(priority: .utility) { Self.windowTitle(pid: pid) }.value
            guard valid(epoch, pid: pid) else { return }
            do {
                let changed = lastActivity?.app != bundle || lastActivity?.window != title
                if changed { lastScreenshot = nil }
                var activity = changed ? HistoryRecord(kind: .activity, app: bundle, appName: name, window: title) : lastActivity!
                activity.ended = Date()
                let activityCopy = activity
                try await Task.detached(priority: .utility) { if changed { try store.insert(activityCopy) } else { try store.updateContent(activityCopy) } }.value
                lastActivity = activity; lastContext = activity
                if bookmark {
                    var mark = HistoryRecord(kind: .bookmark, app: bundle, appName: name, window: title, original: "记住这一刻")
                    mark.starred = true
                    try await Task.detached(priority: .utility) { try store.insert(mark) }.value
                    model.message = "已标记这一刻，可在重要记录中添加备注。"
                }
                let context = bundle + "\n" + title
                if captureAllowed && cadence.shouldCapture(context: context, interval: visualHint ? 3 : settings.screenshotSeconds, explicit: bookmark) {
                    cadence.attempted(context: context); visualHint = false
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard valid(epoch, pid: pid) else { return }
                    // Only the display with the frontmost app's window: no capture of hidden window contents.
                    let appWindows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
                    let frontWindow = appWindows.first { !title.isEmpty && $0.title == title } ?? appWindows.first
                    let display = content.displays.max { a, b in
                        let frame = frontWindow?.frame ?? .zero
                        return Self.area(a.frame.intersection(frame)) < Self.area(b.frame.intersection(frame))
                    }
                    if let display {
                        let excluded = content.applications.filter { $0.bundleIdentifier.hasPrefix("work.yiliu.") || settings.excludedApps.contains($0.bundleIdentifier) }
                        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                        let config = SCStreamConfiguration()
                        // Capture native backing pixels; JPEG storage and OCR share the same coordinate system.
                        config.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
                        config.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
                        config.showsCursor = false; config.capturesAudio = false
                        let visible: VisibleAccessibility.Result
                        if let frontWindow {
                            let windowID = frontWindow.windowID, windowFrame = frontWindow.frame, displayFrame = display.frame
                            visible = await Task.detached(priority: .utility) {
                                VisibleAccessibility.read(pid: pid, windowID: windowID, windowFrame: windowFrame, displayFrame: displayFrame)
                            }.value
                        } else { visible = .init() }
                        guard valid(epoch, pid: pid) else { return }
                        let capturedAt = Date()
                        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        guard valid(epoch, pid: pid) else { return }
                        let previousScreenshot = lastScreenshot
                        let processed = try await Task.detached(priority: .utility) {
                            try Self.process(image, previousRecord: previousScreenshot, visible: visible, store: store)
                        }.value
                        if let processed {
                            var record = HistoryRecord(kind: .screenshot, app: bundle, appName: name, window: title, original: processed.text, status: "屏幕抽样 · 可见文字与 OCR")
                            record.date = capturedAt; record.ended = capturedAt
                            record.starred = bookmark; record.screenshotFingerprint = processed.exactFingerprint
                            record.screenshotOCRComplete = processed.snapshot.ocrComplete
                            record.screenText = processed.snapshot
                            // The frame was validated when acquired. Switching apps during OCR must not erase that history.
                            guard lifecycle.accepts(epoch), !model.settings.paused, !model.settings.excludedApps.contains(bundle) else { return }
                            let saved = record
                            let continuing = !bookmark && previousScreenshot?.screenshotFingerprint == processed.exactFingerprint ? previousScreenshot?.id : nil
                            let result = try await Task.detached(priority: .utility) {
                                let stored = try store.saveScreenshot(saved, jpeg: processed.jpeg, continuing: continuing, reusedOCRSource: processed.reusedSource)
                                let bytes = try store.pruneImages(days: settings.retentionDays, maxBytes: Int64(settings.maxImageMB) * 1024 * 1024)
                                return (stored, bytes)
                            }.value
                            model.imageBytes = result.1
                            if let stored = result.0, lifecycle.accepts(epoch) {
                                lastScreenshot = stored
                                cadence.saved(context: context)
                            }
                        }
                    }
                }
                model.scheduleReload()
            } catch { model.desktopStatus = "桌面记录异常"; model.message = "桌面记录未完成，请检查录屏权限、辅助功能权限和磁盘空间。" }
        }
    }
    private func valid(_ epoch: Int, pid: pid_t) -> Bool { lifecycle.accepts(epoch) && !model.settings.paused && !IsSecureEventInputEnabled() && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
    nonisolated private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
    nonisolated private static func windowTitle(pid: pid_t) -> String {
        guard AXIsProcessTrusted() else { return "" }
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return "" }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.2)
        var title: CFTypeRef?; AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        return title as? String ?? ""
    }
    private struct Processed: Sendable {
        var jpeg: Data?
        var text: String
        var exactFingerprint: String?
        var snapshot: ScreenTextSnapshot
        var reusedSource: UUID?
    }
    nonisolated private static func process(_ image: CGImage, previousRecord: HistoryRecord?, visible: VisibleAccessibility.Result, store: HistoryStore) throws -> Processed? {
        let exact = ScreenOCR.fingerprint(image)
        if let exact, let reused = try store.reusableScreenshot(fingerprint: exact),
           var snapshot = reused.screenText, snapshot.version == ScreenTextSnapshot.currentVersion {
            // Only OCR is reusable across visits: AX always belongs to the current target/window.
            snapshot.accessibility = visible.blocks; snapshot.accessibilityStatus = visible.status
            snapshot.windowTextBounds = visible.windowTextBounds
            snapshot.recognizedRegions = 0; snapshot.reusedRegions = snapshot.regions.count; snapshot.ocrMilliseconds = 0
            return Processed(jpeg: nil, text: snapshot.text, exactFingerprint: exact, snapshot: snapshot, reusedSource: reused.id)
        }
        // Do not use the old 256px thumbnail threshold here: it can miss a one-character edit.
        // Exact region hashes bound the work even for small pixel changes (including a caret blink).
        let cached = try previousRecord.flatMap { try store.reusableScreenText(id: $0.id) }
        var snapshot = ScreenOCR.recognize(image, previous: cached)
        snapshot.accessibility = visible.blocks; snapshot.accessibilityStatus = visible.status
            snapshot.windowTextBounds = visible.windowTextBounds
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.65]) else { return nil }
        let text = snapshot.ocrComplete ? snapshot.text : snapshot.text + "\n[部分区域文字识别未完成，可查看截图]"
        return Processed(jpeg: jpeg, text: text, exactFingerprint: exact, snapshot: snapshot, reusedSource: snapshot.reusedRegions > 0 ? previousRecord?.id : nil)
    }
}
