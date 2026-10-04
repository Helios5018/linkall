import AppKit

// Isolated native host for real IMK/HID acceptance. All visible content is synthetic.
final class Fixture: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private var window: NSWindow!
    private var editor: NSTextView!
    private var second: NSTextView!
    private var sent = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 160, y: 180, width: 820, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "海棠项目 · 林岚 · LinkAgent 验收"
        let root = NSView(); window.contentView = root
        let heading = NSTextField(labelWithString: "海棠项目 / 林岚"); heading.font = .systemFont(ofSize: 22, weight: .bold)
        heading.frame = NSRect(x: 24, y: 566, width: 760, height: 30); root.addSubview(heading)
        let conversation = NSTextField(wrappingLabelWithString: "林岚 14:20：海棠项目的预算还没审批，先别承诺周五上线。\n我 14:21：知道了，我先确认测试范围。\n林岚 14:22：这次先验证登录和支付流程，报表可以下一轮。你准备怎么安排？")
        conversation.font = .systemFont(ofSize: 19); conversation.frame = NSRect(x: 24, y: 330, width: 760, height: 220); root.addSubview(conversation)
        editor = makeEditor(NSRect(x: 24, y: 170, width: 760, height: 135), label: "回复输入框", root: root)
        second = makeEditor(NSRect(x: 24, y: 55, width: 540, height: 80), label: "另一个输入框", root: root)
        let send = NSButton(title: "发送（验收计数）", target: self, action: #selector(sendMessage)); send.frame = NSRect(x: 590, y: 76, width: 190, height: 34); root.addSubview(send)
        let help = NSTextField(labelWithString: "V → 轻点左 Command · 选择建议只写入，不发送"); help.frame = NSRect(x: 24, y: 20, width: 760, height: 24); root.addSubview(help)
        NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window.makeFirstResponder(editor)
        snapshot()
    }
    private func makeEditor(_ frame: NSRect, label: String, root: NSView) -> NSTextView {
        let scroll = NSScrollView(frame: frame); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        let view = NSTextView(frame: NSRect(origin: .zero, size: frame.size)); view.isRichText = false; view.font = .systemFont(ofSize: 18)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.setAccessibilityLabel(label); view.delegate = self; scroll.documentView = view; root.addSubview(scroll); return view
    }
    func textDidChange(_ notification: Notification) { snapshot() }
    @objc private func sendMessage() { sent += 1; snapshot() }
    private func snapshot() {
        guard CommandLine.arguments.count > 1 else { return }
        let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "text": editor.string, "second": second.string, "sendCount": sent]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = Fixture(); app.delegate = delegate; app.run()
