import AppKit

/// One opaque fill inside transparent corners, with no material highlight or border stroke.
/// The layer clips children to the same rounded shape used for the background.
final class FloatingSurface: NSView {
    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateFill()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }
    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}
