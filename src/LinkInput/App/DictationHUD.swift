import AppKit

/// Floating pill at the bottom of the screen while dictating. Never becomes key, so the host editor keeps focus.
final class DictationHUD: NSPanel {
    private let dot = NSView(), bars = LevelBars(), label = NSTextField(labelWithString: ""), hint = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var timer: Timer?
    private var noticeTimer: Timer?
    private var started: Date?
    private var partial = ""
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar; isOpaque = false; backgroundColor = .clear; hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]; hidesOnDeactivate = false
        // A solid surface avoids the system material's bright rim against dark content.
        let effect = FloatingSurface(cornerRadius: 26)
        contentView = effect
        dot.wantsLayer = true; dot.layer?.backgroundColor = NSColor.systemRed.cgColor; dot.layer?.cornerRadius = 5
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold); label.textColor = .labelColor
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let text = NSStackView(views: [label, hint]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 1
        let row = NSStackView(views: [dot, spinner, bars, text]); row.spacing = 12; row.alignment = .centerY
        row.setCustomSpacing(16, after: dot)
        row.setCustomSpacing(16, after: bars)
        row.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(row)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10),
            bars.widthAnchor.constraint(equalToConstant: 46), bars.heightAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20), row.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -20)
        ])
    }
    func preparing() { noticeTimer?.invalidate(); setBusy(true); label.stringValue = "正在打开麦克风…"; hint.stringValue = "Esc 取消"; hint.isHidden = false; present() }
    func listening(level: @escaping () -> Float) {
        noticeTimer?.invalidate(); present(); setBusy(false); hint.isHidden = false; started = Date(); tick(level)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick(level) }
    }
    func transcribing() {
        timer?.invalidate(); timer = nil; present(); setBusy(true)
        label.stringValue = "正在转写"; hint.stringValue = ""; hint.isHidden = true
    }
    func enhancing() {
        transcribing()
    }
    /// A short outcome or failure in place of a draft window; it fades on its own and never takes focus.
    func notice(_ title: String, detail: String = "") {
        timer?.invalidate(); timer = nil; started = nil; partial = ""; setBusy(false); dot.isHidden = true; bars.isHidden = true
        label.stringValue = title; hint.stringValue = detail; hint.isHidden = detail.isEmpty
        present(width: min(560, max(300, max(label.fittingSize.width, hint.fittingSize.width) + 48)))
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: detail.isEmpty ? 2.5 : 5, repeats: false) { [weak self] _ in self?.dismiss() }
    }
    /// Streaming text so far; the tail shows in the hint line while listening.
    func show(partial text: String) { partial = text; if timer != nil { hint.stringValue = Self.tail(text) } }
    func dismiss() { noticeTimer?.invalidate(); noticeTimer = nil; timer?.invalidate(); timer = nil; started = nil; partial = ""; spinner.stopAnimation(nil); orderOut(nil) }
    private static func tail(_ text: String) -> String { text.count > 22 ? "…" + text.suffix(22) : text }
    private func tick(_ level: () -> Float) {
        let seconds = Int(Date().timeIntervalSince(started ?? Date()))
        label.stringValue = String(format: "正在聆听 %d:%02d", seconds / 60, seconds % 60)
        hint.stringValue = partial.isEmpty ? Hotkeys.shared.voiceHint : Self.tail(partial)
        bars.push(level())
    }
    private func setBusy(_ busy: Bool) {
        dot.isHidden = busy; bars.isHidden = busy
        // A stopped spinner still occupies stack space unless explicitly hidden.
        spinner.isHidden = !busy
        if busy { bars.reset(); spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    private func present(width: CGFloat = 300) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .zero
        setFrame(NSRect(x: bounds.midX - width / 2, y: bounds.minY + 72, width: width, height: 52), display: true)
        invalidateShadow(); orderFrontRegardless()
    }
}

private final class LevelBars: NSView {
    private var values = [Float](repeating: 0, count: 7)
    func push(_ value: Float) { values.removeFirst(); values.append(value); needsDisplay = true }
    func reset() { values = values.map { _ in 0 }; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let width: CGFloat = 4, gap = (bounds.width - width * CGFloat(values.count)) / CGFloat(values.count - 1)
        NSColor.labelColor.setFill()
        for (i, value) in values.enumerated() {
            let height = max(4, bounds.height * CGFloat(value))
            let rect = NSRect(x: CGFloat(i) * (width + gap), y: (bounds.height - height) / 2, width: width, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}
