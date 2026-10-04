import AppKit
import InputMethodKit
import YiliuCore
import OSLog

@objc(YiliuInputController)
final class YiliuInputController: IMKInputController {
    /// Controllers per host; a background host activating must not steal the frontmost host's writer.
    private static let controllers = NSHashTable<YiliuInputController>.weakObjects()
    private var activatedAt = Date.distantPast
    static func latest(for bundleID: String?) -> YiliuInputController? {
        guard let bundleID else { return nil }
        return controllers.allObjects.filter { $0.hostBundleID == bundleID }.max { $0.activatedAt < $1.activatedAt }
    }
    private lazy var engine = RimeEngine()
    private lazy var candidatePanel = CandidatePanel()
    private var inputClient: IMKTextInput?
    private var state = RimeState()
    private var candidateViewport = CandidateViewport()
    /// A lone Shift tap toggles Chinese/English; any other key or modifier in between voids it.
    private var shiftTap: Date?
    private var pendingV: NSEvent?
    private var vHasMarkedText = false
    private var replayingV = false
    private var replyTrigger = ReplyTrigger()
    var hostBundleID: String { inputClient?.bundleIdentifier() ?? "" }
    override func activateServer(_ sender: Any!) {
        inputClient = sender as? IMKTextInput
        if hostBundleID != Bundle.main.bundleIdentifier { activatedAt = Date(); Self.controllers.add(self) }
        if engine.scheme != Preferences.shared.scheme || engine.revision != RimeEngine.revision { _ = engine.setScheme(Preferences.shared.scheme) }
        AppDelegate.shared?.asciiMode = engine.isEnglishMode
    }
    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }
    override func deactivateServer(_ sender: Any!) { ReplyCoordinator.shared.cancel(); commitComposition(sender); candidatePanel.orderOut(nil) }
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        inputClient = client
        if event.type == .flagsChanged {
            if replyModifier(event) { return true }
            if pendingV != nil, event.keyCode == 55 { return false }
            if pendingV != nil, [56, 60].contains(event.keyCode), event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty { return false }
            flushV(client)
            shiftChanged(event, client); return false
        }
        guard event.type == .keyDown else { return false }
        replyTrigger.cancel()
        shiftTap = nil; Hotkeys.shared.noteOtherInput()
        if ReplyCoordinator.shared.handle(event, writer: self) { return true }
        if pendingV != nil {
            if event.keyCode == 53 || event.keyCode == 51 { discardV(client); return true }
            flushV(client)
        }
        // The enhancement bubble owns Enter/Tab/Esc; Enter is swallowed so it can never send the message.
        if Coordinator.shared.isInline, state.preedit.isEmpty {
            switch event.keyCode {
            // The host blocks while it waits for this key, so it cannot answer AX or client queries yet:
            // swallow the key now and verify/replace once the host is free again.
            case 36, 76, 48: DispatchQueue.main.async { Coordinator.shared.acceptInline() }; return true
            case 53: Coordinator.shared.dismissInline(); return true
            default: Coordinator.shared.dismissInline()
            }
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) { commitComposition(sender); return false }
        if modifiers.contains(.control) || modifiers.contains(.option) { return false }
        if event.keyCode == 53, state.preedit.isEmpty, Coordinator.shared.isDictating { Coordinator.shared.cancel(); return true }
        if engine.scheme != Preferences.shared.scheme || engine.revision != RimeEngine.revision { commitComposition(sender); _ = engine.setScheme(Preferences.shared.scheme) }
        if !replayingV, state.preedit.isEmpty, !event.isARepeat, event.characters?.lowercased() == "v",
           modifiers.intersection([.command, .control, .option]).isEmpty {
            let range = client.selectedRange()
            // A selected range stays untouched until V becomes ordinary input or the Agent captures it.
            // Hosts without a readable selection still get ordinary Rime input (e.g. flypy `ve`).
            // Only the optional Agent trigger depends on this range; returning false would leak a literal V.
            if range.location != NSNotFound, range.length <= InputTarget.wholeFieldLimit {
                pendingV = event
                vHasMarkedText = range.length == 0
                if vHasMarkedText { client.setMarkedText(event.characters ?? "v", selectionRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                candidatePanel.show(state: RimeState(preedit: "v", candidates: ["轻点左 ⌘ · 推荐回复"], cursorUTF16: 1), caret: caretRect()) { _ in }
                return true
            }
        }
        if engine.activeScheme == .englishDirect {
            if let text = event.characters, !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control && $0.value < 0xF700 }) {
                HistoryBridge.shared.typed(text, app: hostBundleID, passthrough: true)
            }
            return false
        }
        if modifiers.intersection([.shift, .control, .option, .command]).isEmpty, !state.candidates.isEmpty {
            if event.keyCode == 125 || event.keyCode == 126 {
                moveCandidate(backward: event.keyCode == 126); return true
            }
            if candidateViewport.expanded, event.keyCode == 123 || event.keyCode == 124 {
                moveCandidate(backward: event.keyCode == 123, horizontal: true); return true
            }
            if candidateViewport.expanded, event.keyCode == 49 {
                engine.selectAbsolute(state.page * RimeEngine.options.pageSize + state.highlighted, appendSpace: true)
                candidateViewport.reset(); update(client); return true
            }
            if candidateViewport.expanded, let digit = event.characters.flatMap(Int.init), (0...9).contains(digit) {
                let index = digit == 0 ? 9 : digit - 1
                let rowStart = state.page * RimeEngine.options.pageSize
                let slice = engine.candidateSlice(start: rowStart, count: RimeEngine.options.pageSize)
                if slice.candidates.indices.contains(index) {
                    engine.selectAbsolute(rowStart + index)
                    candidateViewport.reset(); update(client)
                }
                return true
            }
        }
        candidateViewport.reset()
        let keys: [UInt16: Int] = [36: 0xff0d, 76: 0xff0d, 48: 0xff09, 51: 0xff08, 53: 0xff1b, 123: 0xff51, 124: 0xff53, 125: 0xff54, 126: 0xff52, 116: 0xff55, 121: 0xff56, 117: 0xffff, 115: 0xff50, 119: 0xff57]
        // The schema keeps `-` literal while composing (`c-d`); past the first page it still pages back.
        let pageBack = event.characters == "-" && !modifiers.contains(.shift) && state.page > 0 && !state.candidates.isEmpty
        guard let key = pageBack ? 0xff55 : keys[event.keyCode] ?? event.characters?.unicodeScalars.first.map({ Int($0.value) }) else { return false }
        let handled = engine.process(key: key, modifiers: modifiers.contains(.shift) ? 1 : 0)
        update(client)
        if !handled, let text = event.characters, !text.isEmpty,
           text.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control && $0.value < 0xF700 }) {
            HistoryBridge.shared.typed(text, app: hostBundleID, passthrough: true)
        }
        return handled
    }
    /// Command flags can bypass IMK; Hotkeys also forwards the global flag monitor here.
    @discardableResult func replyModifier(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command, .function])
        guard replyTrigger.flags(keyCode: event.keyCode, commandOnly: flags == .command && event.modifierFlags.rawValue & 0x10 == 0,
                                 noModifiers: flags.isEmpty, pendingV: pendingV != nil, now: event.timestamp), let client = inputClient else { return false }
        discardV(client)
        DispatchQueue.main.async { [weak self] in guard let self else { return }; ReplyCoordinator.shared.start(writer: self) }
        return true
    }
    func replyOtherInput(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.contains(.command) {
            replyTrigger.cancel()
            if let client = inputClient { flushV(client) }
            ReplyCoordinator.shared.cancel()
        }
    }
    private func shiftChanged(_ event: NSEvent, _ client: IMKTextInput) {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command, .function])
        guard [56, 60].contains(event.keyCode) else { shiftTap = nil; return }
        if flags == .shift { shiftTap = Date(); return }
        guard flags.isEmpty, let start = shiftTap, Date().timeIntervalSince(start) < 0.5 else { shiftTap = nil; return }
        shiftTap = nil
        let raw = engine.toggleEnglish()
        if !raw.isEmpty { client.insertText(raw, replacementRange: NSRange(location: NSNotFound, length: 0)); HistoryBridge.shared.typed(raw, app: hostBundleID) }
        candidateViewport.reset()
        update(client)
        AppDelegate.shared?.asciiMode = engine.isEnglishMode
    }
    private func update(_ client: IMKTextInput) {
        AppDelegate.shared?.asciiMode = engine.isEnglishMode
        state = engine.state()
        if !state.commit.isEmpty { client.insertText(state.commit, replacementRange: NSRange(location: NSNotFound, length: 0)); HistoryBridge.shared.typed(state.commit, app: hostBundleID) }
        let marked = NSAttributedString(string: state.preedit)
        client.setMarkedText(marked, selectionRange: NSRange(location: state.cursorUTF16, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        if state.candidates.isEmpty { candidateViewport.reset(); candidatePanel.orderOut(nil); return }
        var display = state
        let rows = Preferences.shared.inputOptions.visibleCandidateRows
        if candidateViewport.expanded {
            let selected = state.page * RimeEngine.options.pageSize + state.highlighted
            candidateViewport.reveal(selected, rows: rows, columns: RimeEngine.options.pageSize)
            let slice = engine.candidateSlice(start: candidateViewport.start, count: rows * RimeEngine.options.pageSize)
            display.candidates = slice.candidates; display.highlighted = selected - candidateViewport.start
            display.lastPage = !slice.hasMore
        }
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        let offset = candidateViewport.expanded ? candidateViewport.start : state.page * RimeEngine.options.pageSize
        candidatePanel.onMove = { [weak self] backward in self?.moveCandidate(backward: backward) }
        candidatePanel.show(state: display, caret: rect, expanded: candidateViewport.expanded, visibleRows: rows, visibleColumns: RimeEngine.options.pageSize) { [weak self] index in
            guard let self, let client = self.inputClient else { return }
            self.engine.selectAbsolute(offset + index); self.candidateViewport.reset(); self.update(client)
        }
    }
    private func moveCandidate(backward: Bool, horizontal: Bool = false) {
        guard let client = inputClient, !state.candidates.isEmpty else { return }
        if candidateViewport.expanded {
            let selected = state.page * RimeEngine.options.pageSize + state.highlighted
            let columns = RimeEngine.options.pageSize
            if horizontal {
                _ = engine.highlightCandidate(max(0, selected + (backward ? -1 : 1)))
            } else {
                let rowStart = (selected / columns + (backward ? -1 : 1)) * columns
                if rowStart >= 0 {
                    let row = engine.candidateSlice(start: rowStart, count: columns)
                    if !row.candidates.isEmpty { _ = engine.highlightCandidate(rowStart + min(selected % columns, row.candidates.count - 1)) }
                }
            }
        } else { candidateViewport.expanded = true }
        update(client)
    }
    override func commitComposition(_ sender: Any!) {
        candidateViewport.reset()
        guard let client = sender as? IMKTextInput ?? inputClient else { return }
        if pendingV != nil, NSEvent.modifierFlags.contains(.command) { return }
        flushV(client)
        if !state.preedit.isEmpty {
            _ = engine.process(key: 0xff0d); update(client)
        }
        engine.clear(); candidatePanel.orderOut(nil)
    }
    private func discardV(_ client: IMKTextInput) {
        guard pendingV != nil else { return }
        pendingV = nil; replyTrigger.cancel(); candidatePanel.orderOut(nil)
        if vHasMarkedText { client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        vHasMarkedText = false
    }
    private func flushV(_ client: IMKTextInput) {
        guard let event = pendingV else { return }
        // Ordinary continuation replaces the pending mark through update/insertText below.
        // Clearing it first would unnecessarily end and restart the host's composition mid-keystroke.
        pendingV = nil; vHasMarkedText = false
        replyTrigger.cancel(); candidatePanel.orderOut(nil)
        replayingV = true
        let handled = handle(event, client: client)
        replayingV = false
        if !handled { client.insertText(event.characters ?? "v", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }
    func writeDraft(_ text: String, range: NSRange) -> Bool {
        guard let inputClient else { return false }
        engine.clear(); candidatePanel.orderOut(nil)
        inputClient.insertText(text, replacementRange: range)
        return reads(text, at: range.location)
    }
    /// Read-back of exactly the written span; renderer-process hosts (Chrome) may only answer a moment later.
    func reads(_ text: String, at location: Int) -> Bool {
        inputClient?.attributedSubstring(from: NSRange(location: location, length: text.utf16.count))?.string == text
    }
    func selectedRange() -> NSRange? { inputClient?.selectedRange() }
    /// The selection, or with none the whole field up to `limit` UTF-16 units, as the client reports it.
    func snapshot(limit: Int) -> (range: NSRange, text: String, whole: Bool)? {
        guard let client = inputClient else { return nil }
        let selected = client.selectedRange()
        guard selected.location != NSNotFound else { return nil }
        if selected.length > 0 {
            guard selected.length <= 20_000, let text = client.attributedSubstring(from: selected)?.string, text.utf16.count == selected.length else { return nil }
            return (selected, text, false)
        }
        let total = client.length()
        if total == 0, selected.location == 0 { return (selected, "", true) }
        let text = total > 0 && total <= limit ? client.attributedSubstring(from: NSRange(location: 0, length: total))?.string : nil
        guard let text, text.utf16.count == total else {
            // Numbers only: how the host answered, to tell an empty field from a client that cannot report its text.
            Logger(subsystem: "work.yiliu.inputmethod.Yiliu", category: "inline").notice("client snapshot failed host=\(self.hostBundleID, privacy: .public) selected=\(selected.location, privacy: .public)+\(selected.length, privacy: .public) length=\(total, privacy: .public) read=\(text?.utf16.count ?? -1, privacy: .public)")
            return nil
        }
        return (NSRange(location: 0, length: total), text, true)
    }
    /// Caret line in screen coordinates, or zero when the host does not report it.
    func caretRect() -> NSRect {
        var rect = NSRect.zero
        _ = inputClient?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }
    /// Inserts at the caret exactly like committed typing; the caller guarantees no control characters.
    func insertTyped(_ text: String) {
        guard let inputClient else { return }
        engine.clear(); candidatePanel.orderOut(nil)
        inputClient.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func finishForDraft() {
        if let client = inputClient { flushV(client) }
        guard !state.preedit.isEmpty, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == hostBundleID else { return }
        commitComposition(inputClient)
    }
    override func menu() -> NSMenu! { AppDelegate.shared?.makeMenu() }
}
