import AppKit
import Carbon

/// Reads the explicit selection, or with none the whole focused field when it is small (a compose box).
/// Never reads conversation history or a document beyond that limit.
final class InputTarget: @unchecked Sendable {
    let id = UUID()
    let pid: pid_t
    let bundleID: String
    /// The AX editor when the app exposes one; otherwise the target is read through the input method client.
    let element: AXUIElement?
    private weak var client: YiliuInputController?
    static let wholeFieldLimit = 2000
    let range: CFRange
    private let initialSelection: CFRange
    /// The text the range covers: the selection, or the whole field when `isWholeField`.
    let selection: String
    let isWholeField: Bool
    /// Terminal targets validate editor identity only. Their scrollback is not an editable draft.
    let insertionOnly: Bool
    let window: AXUIElement?
    let name: String
    /// AX role of the editor, "" when it is hidden from AX; AXTextField and AXComboBox are single-line.
    let role: String
    /// Reply insertion can bind a terminal editor without pretending its buffer is an editable draft.
    init?(app: NSRunningApplication, allowTerminal: Bool = false, captureText: Bool = true, terminalInsertionOnly: Bool = false, excludedApps: [String]? = nil) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let bundle = app.bundleIdentifier ?? ""
        let isTerminal = Self.isTerminal(bundle)
        guard !(excludedApps ?? Preferences.shared.config.excludedApps).contains(bundle), allowTerminal || !isTerminal else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        if !captureText { AXUIElementSetMessagingTimeout(application, 0.08) }
        guard let focused = Self.attribute(application, kAXFocusedUIElementAttribute) else { return nil }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        if !captureText { AXUIElementSetMessagingTimeout(element, 0.08) }
        let role = Self.attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = Self.attribute(element, kAXSubroleAttribute) as? String ?? ""
        let insertionOnly = terminalInsertionOnly && isTerminal && allowTerminal && !captureText
        guard !subrole.lowercased().contains("secure"), ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) else { return nil }
        let selected = insertionOnly ? CFRange(location: 0, length: 0) : Self.selectedRange(element)
        guard let range = selected, range.location >= 0, range.length >= 0, range.length <= 20_000 else { return nil }
        self.insertionOnly = insertionOnly
        self.element = element; pid = app.processIdentifier; bundleID = bundle; self.role = role; initialSelection = range
        name = app.localizedName ?? "目标应用"
        if !captureText {
            self.range = range; selection = ""; isWholeField = false
        } else if range.length == 0, !isTerminal, let field = Self.smallFieldText(element) {
            self.range = CFRange(location: 0, length: field.utf16.count); selection = field; isWholeField = true
        } else {
            self.range = range; isWholeField = false
            selection = range.length == 0 ? "" : (Self.attribute(element, kAXSelectedTextAttribute) as? String ?? "")
            guard range.length == 0 || selection.utf16.count == range.length else { return nil }
        }
        if let win = Self.attribute(element, kAXWindowAttribute), CFGetTypeID(win) == AXUIElementGetTypeID() {
            window = unsafeBitCast(win, to: AXUIElement.self)
        } else { window = nil }
    }
    /// For editors hidden from AX (Feishu's composer): the input method's own client reports selection and text.
    init?(client: YiliuInputController, app: NSRunningApplication) {
        let bundle = app.bundleIdentifier ?? ""
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !IsSecureEventInputEnabled(),
              client.hostBundleID == bundle, !Preferences.shared.config.excludedApps.contains(bundle), !Self.isTerminal(bundle),
              let snapshot = client.snapshot(limit: Self.wholeFieldLimit) else { return nil }
        element = nil; window = nil; self.client = client; role = ""
        pid = app.processIdentifier; bundleID = bundle; name = app.localizedName ?? "目标应用"
        range = CFRange(location: snapshot.range.location, length: snapshot.range.length)
        let selected = client.selectedRange() ?? snapshot.range
        initialSelection = CFRange(location: selected.location, length: selected.length)
        selection = snapshot.text; isWholeField = snapshot.whole; insertionOnly = false
    }
    /// Chromium builds its web AX tree only after an assistive client sets this; other apps reject it.
    /// Electron honours AXManualAccessibility; Chrome-family browsers build the web tree only for AXEnhancedUserInterface.
    static func requestWebAccessibility(_ app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var enabled = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        let bundle = app.bundleIdentifier ?? ""
        if ["com.google.chrome", "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.browser", "com.vivaldi.vivaldi", "com.operasoftware.opera"].contains(where: bundle.lowercased().hasPrefix) {
            enabled = AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success || enabled
        }
        return enabled
    }
    /// Roles and capabilities only, never text, for the local log when no target is found.
    static func diagnose(_ app: NSRunningApplication) -> String {
        guard AXIsProcessTrusted() else { return "accessibility=no" }
        guard let focused = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return "focused=none" }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        return "role=\(attribute(element, kAXRoleAttribute) as? String ?? "?") subrole=\(attribute(element, kAXSubroleAttribute) as? String ?? "-") range=\(selectedRange(element) != nil)"
    }
    static func isTerminal(_ bundle: String) -> Bool {
        ["terminal", "ghostty", "cmux", "iterm", "warp", "alacritty", "kitty", "wezterm"].contains(where: bundle.lowercased().contains)
    }
    /// The full value of a non-empty field up to `wholeFieldLimit` UTF-16 units; the length is checked before the value is read.
    private static func smallFieldText(_ element: AXUIElement) -> String? {
        guard let count = attribute(element, kAXNumberOfCharactersAttribute) as? Int, count > 0, count <= wholeFieldLimit,
              let value = attribute(element, kAXValueAttribute) as? String, value.utf16.count == count else { return nil }
        return value
    }
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) ? range : nil
    }
    /// The caret as it is now, only while the same editor in the same window still has focus.
    func focusedRange() -> CFRange? {
        guard !IsSecureEventInputEnabled(), AXIsProcessTrusted(),
              !Preferences.shared.config.excludedApps.contains(bundleID),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        guard element != nil else {
            guard let selected = client?.selectedRange(), selected.location != NSNotFound else { return nil }
            return CFRange(location: selected.location, length: selected.length)
        }
        return currentEditor().flatMap { Self.selectedRange($0) }
    }
    /// The focused editor if it is ours. Chrome rebuilds web AX nodes, so a re-created editor in the same
    /// window also counts; callers still compare its text and range before writing.
    private func currentEditor() -> AXUIElement? {
        guard let element, let ref = Self.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let focus = unsafeBitCast(ref, to: AXUIElement.self)
        if CFEqual(focus, element) { return focus }
        guard let window, let now = Self.attribute(focus, kAXWindowAttribute), CFEqual(window, now),
              ["AXTextArea", "AXTextField", "AXComboBox"].contains(Self.attribute(focus, kAXRoleAttribute) as? String ?? "") else { return nil }
        return focus
    }
    /// Bound after creation so AX targets can also be confirmed through the client that performs the write.
    func bind(client: YiliuInputController) { if self.client == nil { self.client = client } }
    /// Which currency check fails, as booleans and lengths only, for the local log.
    func diagnoseCurrency() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let snap = client?.snapshot(limit: Self.wholeFieldLimit)
        let editor = currentEditor()
        let text = editor.flatMap { isWholeField ? Self.smallFieldText($0) : Self.attribute($0, kAXSelectedTextAttribute) as? String }
        return "front=\(front) whole=\(isWholeField) client=\(client != nil) clientRange=\(snap.map { $0.range.location == range.location && $0.range.length == range.length } ?? false) clientText=\(snap?.text == selection) ax=\(element != nil) editor=\(editor != nil) axText=\(text == selection) len=\(text?.utf16.count ?? -1)/\(selection.utf16.count)"
    }
    /// The original text is still at the original range: via the AX editor, or via the input method client.
    func isCurrent() -> Bool {
        guard focusedRange() != nil else { return false }
        if let now = client?.snapshot(limit: Self.wholeFieldLimit),
           now.range.location == range.location, now.range.length == range.length, now.text == selection { return true }
        guard element != nil, let editor = currentEditor(), let now = Self.selectedRange(editor) else { return false }
        if isWholeField { return Self.smallFieldText(editor) == selection }
        guard now.location == range.location, now.length == range.length else { return false }
        return range.length == 0 || (Self.attribute(editor, kAXSelectedTextAttribute) as? String) == selection
    }
    /// Suggestions require the exact editor and caret. Do not treat a different same-window field as equivalent.
    func isReplyCurrent() -> Bool {
        if insertionOnly {
            guard !IsSecureEventInputEnabled(), !Preferences.shared.config.excludedApps.contains(bundleID),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let element,
                  let focus = Self.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
                  CFEqual(element, focus) else { return false }
            if let window {
                guard let current = Self.attribute(element, kAXWindowAttribute), CFEqual(window, current) else { return false }
            }
            return true
        }
        guard let now = focusedRange(), now.location == initialSelection.location, now.length == initialSelection.length else { return false }
        if let element {
            guard let ref = Self.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute), CFEqual(element, ref) else { return false }
        }
        return isCurrent()
    }
    func diagnoseReplyCurrency() -> String {
        if insertionOnly { return "insertionOnly=true current=\(isReplyCurrent())" }
        let now = focusedRange()
        let focus = Self.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
        let same = element.flatMap { original in focus.map { CFEqual(original, $0) } } ?? false
        return "caret=\(now?.location ?? -1)+\(now?.length ?? -1)/\(initialSelection.location)+\(initialSelection.length) exactEditor=\(same) " + diagnoseCurrency()
    }
}
