import AppKit
import Carbon
import YiliuCore

struct ShortcutChoice {
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32
    /// A lone modifier key (right ⌘): Carbon cannot register it, so flag-change monitors drive it.
    var isModifierOnly: Bool { modifiers == 0 }
    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = [.control]
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }
}
/// One Carbon hotkey handler owns both press/release actions; ordinary typing is never intercepted.
final class Hotkeys {
    static let shared = Hotkeys()
    // ⌃⌥Space is macOS's default "next input source" shortcut, so it is not the default.
    static let draftChoices = [ShortcutChoice(title: "⌃⌥D", keyCode: 2, modifiers: UInt32(controlKey | optionKey)), ShortcutChoice(title: "⌃⇧Space", keyCode: 49, modifiers: UInt32(controlKey | shiftKey)), ShortcutChoice(title: "⌃⌥Space（可能与系统切换输入法冲突）", keyCode: 49, modifiers: UInt32(controlKey | optionKey))]
    static let voiceChoices = [ShortcutChoice(title: "右 ⌘", keyCode: 54, modifiers: 0), ShortcutChoice(title: "⌃⌥R", keyCode: 15, modifiers: UInt32(controlKey | optionKey)), ShortcutChoice(title: "⌃⇧R", keyCode: 15, modifiers: UInt32(controlKey | shiftKey)), ShortcutChoice(title: "⌃⌥V", keyCode: 9, modifiers: UInt32(controlKey | optionKey))]
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    private var pressed: Set<UInt32> = []
    private var monitors: [Any] = []
    /// One press of the voice key: right ⌘ or the Carbon chord.
    private struct VoicePress { let key: UInt32; let title: String; let start: TimeInterval; let startedRecording: Bool; let isModifier: Bool }
    private var press: VoicePress?
    private var lastVoicePress: TimeInterval = -10
    static let holdThreshold: TimeInterval = 0.5
    var recordMode: RecordMode { Preferences.shared.voiceOptions.recordMode }
    var voiceHint: String {
        let title = press?.title ?? voice.title
        if let press, press.startedRecording,
           recordMode == .pushToTalk || (recordMode == .hybrid && ProcessInfo.processInfo.systemUptime - press.start >= Self.holdThreshold) {
            return "松开 \(title) 完成 · Esc 取消"
        }
        return "再按 \(title) 完成 · Esc 取消"
    }
    var draft: ShortcutChoice { Self.draftChoices[min(max(0, UserDefaults.standard.integer(forKey: "draftShortcut")), Self.draftChoices.count - 1)] }
    var voice: ShortcutChoice { Self.voiceChoices[min(max(0, UserDefaults.standard.integer(forKey: "voiceShortcut")), Self.voiceChoices.count - 1)] }
    func matches(_ event: NSEvent) -> Bool {
        [draft, voice].contains { !$0.isModifierOnly && UInt32(event.keyCode) == $0.keyCode && event.modifierFlags.intersection([.control, .option, .shift, .command]) == $0.eventFlags }
    }
    func configure() -> String? {
        refs.forEach { UnregisterEventHotKey($0) }; refs = []
        pressed = []; press = nil
        if handler == nil {
            var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let error = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard error == noErr, id.signature == 0x594c4955 else { return OSStatus(eventNotHandledErr) }
                let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                if down {
                    guard Hotkeys.shared.pressed.insert(id.id).inserted else { return noErr }
                } else { Hotkeys.shared.pressed.remove(id.id) }
                if down, id.id == 1 { YiliuInputController.latest(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)?.finishForDraft() }
                if id.id == 1, down { Coordinator.shared.enhanceHotkey() }
                if id.id == 2 {
                    let now = ProcessInfo.processInfo.systemUptime
                    if down { Hotkeys.shared.voiceDown(key: 1_000, title: Hotkeys.shared.voice.title, isModifier: false, at: now) }
                    else { Hotkeys.shared.voiceUp(key: 1_000, at: now) }
                }
                return noErr
            }, events.count, &events, nil, &handler)
            if status != noErr { return "快捷键注册失败（\(status)），请使用菜单栏入口。" }
        }
        if monitors.isEmpty { installModifierMonitors() }
        for (index, choice) in [draft, voice].enumerated() where !choice.isModifierOnly {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(choice.keyCode, choice.modifiers, EventHotKeyID(signature: 0x594c4955, id: UInt32(index + 1)), GetApplicationEventTarget(), 0, &ref)
            guard result == noErr, let ref else { return "快捷键 \(choice.title) 已被占用或无法注册，请换一个组合键。" }
            refs.append(ref)
        }
        return nil
    }
    /// Recording starts on key-down so the first syllable is not lost.
    private func voiceDown(key: UInt32, title: String, isModifier: Bool, at time: TimeInterval) {
        guard press == nil, time - lastVoicePress >= Self.holdThreshold else { return }
        lastVoicePress = time
        let wasBusy = Coordinator.shared.isVoiceBusy
        YiliuInputController.latest(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)?.finishForDraft()
        Coordinator.shared.voiceHotkey(triggeredAt: time)
        press = VoicePress(key: key, title: title, start: time, startedRecording: !wasBusy && Coordinator.shared.isVoiceBusy, isModifier: isModifier)
    }
    /// Push-to-talk ends on release; hybrid ends only after a long hold, a short tap stays hands-free.
    private func voiceUp(key: UInt32, at time: TimeInterval) {
        guard let current = press, current.key == key else { return }
        press = nil
        guard current.startedRecording else { return }
        if recordMode == .pushToTalk || (recordMode == .hybrid && time - current.start >= Self.holdThreshold) {
            Coordinator.shared.stopHeldRecording()
        }
    }
    /// A key or click soon after a voice modifier went down means a chord (⌘C, ⌥-letter): drop the accidental start.
    func noteOtherInput() {
        guard let current = press, current.isModifier, current.startedRecording,
              ProcessInfo.processInfo.systemUptime - current.start < 1.5 else { return }
        press = nil
        Coordinator.shared.cancel()
    }
    private func installModifierMonitors() {
        let flags: (NSEvent) -> Void = { [weak self] event in self?.flagsChanged(event) }
        let other: (NSEvent) -> Void = { [weak self] event in
            self?.noteOtherInput()
            YiliuInputController.latest(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)?.replyOtherInput(event)
        }
        let inputs: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags),
                    NSEvent.addGlobalMonitorForEvents(matching: inputs, handler: other),
                    NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 },
                    NSEvent.addLocalMonitorForEvents(matching: inputs) { other($0); return $0 }].compactMap { $0 }
    }
    private func flagsChanged(_ event: NSEvent) {
        if event.keyCode == 55 { YiliuInputController.latest(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)?.replyModifier(event) }
        // Device-dependent bits: right ⌘ 0x10, left ⌘ 0x08.
        guard event.keyCode == 54, voice.isModifierOnly else { noteOtherInput(); return }
        let raw = event.modifierFlags.rawValue
        if raw & 0x10 != 0 {
            let others = event.modifierFlags.intersection([.shift, .control, .option, .command, .function]).subtracting(.command)
            guard others.isEmpty, raw & 0x08 == 0 else { noteOtherInput(); return }
            voiceDown(key: UInt32(event.keyCode), title: voice.title, isModifier: true, at: event.timestamp)
        } else {
            voiceUp(key: UInt32(event.keyCode), at: event.timestamp)
        }
    }
}
