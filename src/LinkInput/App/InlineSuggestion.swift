import AppKit

/// Result bubble beside the caret for in-place enhancement. Never becomes key, so the host editor keeps focus
/// and Enter/Tab/Esc reach LinkInput through the input method.
final class InlineSuggestion: NSPanel {
    private let status = NSTextField(labelWithString: ""), result = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let accept = NSButton(title: "采用 ⏎", target: nil, action: nil)
    private let edit = NSButton(title: "复制", target: nil, action: nil)
    private let discard = NSButton(title: "放弃 esc", target: nil, action: nil)
    private var caret = NSRect.zero
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 80), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu; isOpaque = false; backgroundColor = .clear; hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; hidesOnDeactivate = false
        let effect = NSVisualEffectView(); effect.material = .popover; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 10; effect.layer?.masksToBounds = true
        contentView = effect
        status.font = .systemFont(ofSize: 12, weight: .medium); status.textColor = .secondaryLabelColor
        result.font = .systemFont(ofSize: 15); result.textColor = .labelColor; result.maximumNumberOfLines = 14
        result.preferredMaxLayoutWidth = 428
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        for (button, action) in [(accept, #selector(acceptAction)), (edit, #selector(editAction)), (discard, #selector(discardAction))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded; button.controlSize = .small
        }
        let header = NSStackView(views: [spinner, status]); header.spacing = 6
        let buttons = NSStackView(views: [accept, edit, discard]); buttons.spacing = 8
        let stack = NSStackView(views: [header, result, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor), stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: effect.topAnchor), stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
                                     effect.widthAnchor.constraint(equalToConstant: 460)])
    }
    func loading(near caret: NSRect, source: String) {
        self.caret = caret
        status.stringValue = "正在整理\(source)…  Esc 取消"; spinner.startAnimation(nil)
        result.isHidden = true; accept.isHidden = true; edit.isHidden = true; discard.isHidden = false
        present()
    }
    func show(result text: String, note: String) {
        spinner.stopAnimation(nil)
        status.stringValue = "AI 整理结果 · \(note)"
        result.stringValue = text; result.isHidden = false
        accept.isHidden = false; edit.isHidden = false; discard.isHidden = false
        present()
    }
    func failed(_ message: String) {
        spinner.stopAnimation(nil); status.stringValue = message
        result.isHidden = true; accept.isHidden = true; edit.isHidden = true; discard.isHidden = false
        present()
    }
    func dismiss() { spinner.stopAnimation(nil); orderOut(nil) }
    /// Below the caret line when it fits, otherwise above it; caret rects are in screen coordinates.
    private func present() {
        contentView?.layoutSubtreeIfNeeded()
        let size = NSSize(width: 460, height: contentView?.fittingSize.height ?? 80)
        let anchor = caret == .zero ? NSRect(origin: NSEvent.mouseLocation, size: .zero) : caret
        let screen = NSScreen.screens.first { NSPointInRect(anchor.origin, $0.frame) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let x = min(max(anchor.minX, bounds.minX + 8), bounds.maxX - size.width - 8)
        let below = anchor.minY - size.height - 6
        let y = below >= bounds.minY ? below : min(anchor.maxY + 6, bounds.maxY - size.height)
        setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        orderFrontRegardless()
    }
    @objc private func acceptAction() { Coordinator.shared.acceptInline() }
    @objc private func editAction() { Coordinator.shared.copyInline() }
    @objc private func discardAction() { Coordinator.shared.dismissInline() }
}
