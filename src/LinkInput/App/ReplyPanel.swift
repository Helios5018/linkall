import AppKit

/// Non-activating candidate surface: the editor retains keyboard focus.
final class ReplyPanel: NSPanel {
    private let status = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private var caret = NSRect.zero
    private var rows: [ReplyChoiceButton] = []
    var onChoose: ((Int) -> Void)?
    var onCopy: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    var onSources: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 500, height: 90), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu; isOpaque = false; backgroundColor = .clear; hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; hidesOnDeactivate = false
        let effect = NSVisualEffectView(); effect.material = .popover; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 12; effect.layer?.masksToBounds = true; contentView = effect
        status.font = .systemFont(ofSize: 12, weight: .medium); status.textColor = .secondaryLabelColor
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor), stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor), stack.topAnchor.constraint(equalTo: effect.topAnchor), stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor), effect.widthAnchor.constraint(equalToConstant: 500)])
    }
    func show(_ message: String, candidates: [String] = [], selected: Int = 0, near: NSRect? = nil, copyOnly: Bool = false, details: String? = nil, keyboardSelection: Bool = true) {
        if let near { caret = near }
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        rows = []; status.stringValue = message; stack.addArrangedSubview(status)
        for (index, text) in candidates.enumerated() {
            let button = ReplyChoiceButton(title: "\(index + 1)  \(text)", target: self, action: #selector(choose(_:)))
            button.tag = index; button.isBordered = false; button.alignment = .left
            button.font = .systemFont(ofSize: 14); button.cell?.wraps = true
            button.chosen = index == selected
            button.toolTip = text; button.setAccessibilityLabel("候选 \(index + 1)：\(text)")
            let copy = NSButton(title: "复制", target: self, action: #selector(copyChoice(_:))); copy.tag = index; copy.bezelStyle = .rounded
            let row = NSStackView(views: [button, copy]); row.spacing = 8
            button.widthAnchor.constraint(equalToConstant: 396).isActive = true
            let height = (button.title as NSString).boundingRect(with: NSSize(width: 370, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 14)]).height
            button.heightAnchor.constraint(equalToConstant: min(150, max(36, height + 20))).isActive = true
            rows.append(button); stack.addArrangedSubview(row)
        }
        if !candidates.isEmpty {
            let sources = NSButton(title: details == nil ? "查看参考依据" : "收起参考依据", target: self, action: #selector(sourcesAction))
            sources.bezelStyle = .inline; stack.addArrangedSubview(sources)
        }
        if let details {
            let note = NSTextField(wrappingLabelWithString: details); note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor; note.preferredMaxLayoutWidth = 460; note.maximumNumberOfLines = 8
            note.toolTip = details; stack.addArrangedSubview(note)
        }
        let footer = NSButton(title: candidates.isEmpty ? "取消 · Esc" : (copyOnly ? "当前目标仅支持复制 · Esc 关闭" : keyboardSelection ? "↑↓ 选择 · 1/2/3 或 Enter 采用 · Esc 取消" : "点击候选插入 · 普通按键继续输入 · 不自动发送"), target: self, action: #selector(cancel))
        footer.bezelStyle = .inline; footer.font = .systemFont(ofSize: 11); stack.addArrangedSubview(footer)
        contentView?.layoutSubtreeIfNeeded()
        let size = NSSize(width: 500, height: contentView?.fittingSize.height ?? 100)
        let anchor = caret == .zero ? NSRect(origin: NSEvent.mouseLocation, size: .zero) : caret
        let bounds = (NSScreen.screens.first { NSPointInRect(anchor.origin, $0.frame) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let x = min(max(anchor.minX, bounds.minX + 8), bounds.maxX - size.width - 8)
        let below = anchor.minY - size.height - 6
        setFrame(NSRect(x: x, y: max(bounds.minY, below >= bounds.minY ? below : min(anchor.maxY + 6, bounds.maxY - size.height)), width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }
    func highlight(_ index: Int) { for row in rows { row.chosen = row.tag == index } }
    func dismiss() {
        orderOut(nil)
        // Release source excerpts and tooltips too, especially when cancellation is caused by screen lock.
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        rows = []; status.stringValue = ""
    }
    @objc private func choose(_ sender: NSButton) { onChoose?(sender.tag) }
    @objc private func copyChoice(_ sender: NSButton) { onCopy?(sender.tag) }
    @objc private func sourcesAction() { onSources?() }
    @objc private func cancel() { onCancel?() }
}

/// Standard rounded button cells truncate to one line even with wraps=true. Draw a real multiline label.
private final class ReplyChoiceButton: NSButton {
    var chosen = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let fill = chosen ? NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.25 : 0.12) : NSColor.quaternaryLabelColor
        fill.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping; paragraph.lineSpacing = 2
        (title as NSString).draw(with: bounds.insetBy(dx: 10, dy: 8), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
    }
}
