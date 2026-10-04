import AppKit
import YiliuCore

final class CandidatePanel: NSPanel {
    private static let cornerRadius: CGFloat = 8
    private var choose: ((Int) -> Void)?
    var onMove: ((Bool) -> Void)?
    private var expanded = false
    private var expandedWidth: CGFloat = 320
    private var scrollRemainder: CGFloat = 0
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu; hasShadow = true; isOpaque = false; backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    func show(state: RimeState, caret: NSRect, expanded: Bool = false, visibleRows: Int = 5, visibleColumns: Int = 5, choose: @escaping (Int) -> Void) {
        self.choose = choose; self.expanded = expanded
        if !expanded { expandedWidth = 320; scrollRemainder = 0 }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let preedit = NSTextField(labelWithString: state.preedit); preedit.textColor = .labelColor; preedit.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(preedit)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) }) ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let maxWidth = min(900, bounds.width - 24)
        let buttons = state.candidates.enumerated().map { index, text -> CandidateButton in
            let number: Int? = !expanded || index / visibleColumns == state.highlighted / visibleColumns ? (index % visibleColumns + 1) % 10 : nil
            let button = CandidateButton(number: number, text: text, selected: index == state.highlighted, cornerRadius: Self.cornerRadius)
            button.target = self; button.action = #selector(selectCandidate(_:)); button.tag = index; button.toolTip = text
            return button
        }
        if expanded {
            let preferredCellWidth = max(56, buttons.map(\.labelWidth).max() ?? 56)
            expandedWidth = min(max(expandedWidth, preferredCellWidth * CGFloat(visibleColumns) + CGFloat(visibleColumns - 1) * 4), maxWidth - 24)
            let cellWidth = (expandedWidth - CGFloat(visibleColumns - 1) * 4) / CGFloat(visibleColumns)
            for rowIndex in 0..<visibleRows {
                let row = NSStackView(); row.spacing = 4
                for column in 0..<visibleColumns {
                    let index = rowIndex * visibleColumns + column
                    let cell: NSView = buttons.indices.contains(index) ? buttons[index] : NSView()
                    cell.widthAnchor.constraint(equalToConstant: cellWidth).isActive = true
                    cell.heightAnchor.constraint(equalToConstant: 26).isActive = true
                    row.addArrangedSubview(cell)
                }
                stack.addArrangedSubview(row)
            }
            let hint = NSTextField(labelWithString: "↑ ↓ 换行 · ← → 选词 · 空格确认" + (state.lastPage ? " · 已到末尾" : ""))
            hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
            stack.addArrangedSubview(hint)
        } else {
            var row = NSStackView(); row.spacing = 4
            var rowWidth: CGFloat = 0
            stack.addArrangedSubview(row)
            for button in buttons {
                let width = min(button.labelWidth, maxWidth - 24)
                if rowWidth > 0, rowWidth + 4 + width > maxWidth - 24 {
                    row = NSStackView(); row.spacing = 4; stack.addArrangedSubview(row); rowWidth = 0
                }
                button.widthAnchor.constraint(equalToConstant: width).isActive = true
                button.heightAnchor.constraint(equalToConstant: 26).isActive = true
                rowWidth += width + (rowWidth > 0 ? 4 : 0)
                row.addArrangedSubview(button)
            }
        }
        let surface = FloatingSurface(cornerRadius: Self.cornerRadius)
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            stack.topAnchor.constraint(equalTo: surface.topAnchor),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        contentView = surface
        // A leading-aligned stack's fitting width can omit its trailing inset.
        let contentWidth = stack.arrangedSubviews.map { $0.fittingSize.width }.max() ?? 0
        let width = min(max(contentWidth + stack.edgeInsets.left + stack.edgeInsets.right, expanded ? expandedWidth + 24 : 250), maxWidth)
        let height = max(70, stack.fittingSize.height)
        let x = min(max(caret.minX, bounds.minX), bounds.maxX - width)
        let y = caret.minY >= bounds.minY + height + 2 ? caret.minY - height - 2 : max(bounds.minY, caret.maxY + 8)
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        invalidateShadow(); orderFrontRegardless()
    }
    override func scrollWheel(with event: NSEvent) {
        guard expanded else { super.scrollWheel(with: event); return }
        scrollRemainder += event.scrollingDeltaY
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 18 : 1
        if abs(scrollRemainder) >= threshold {
            onMove?(scrollRemainder > 0); scrollRemainder = 0
        }
    }
    @objc private func selectCandidate(_ sender: NSButton) { choose?(sender.tag) }
}

/// Draw the label explicitly: a borderless NSButton cell otherwise dims/resolves its
/// attributed title using the inactive window appearance, making dark-mode text unreadable.
private final class CandidateButton: NSButton {
    private let number: Int?
    private let candidate: String
    private let selected: Bool
    init(number: Int?, text: String, selected: Bool, cornerRadius: CGFloat) {
        self.number = number; candidate = text; self.selected = selected
        super.init(frame: .zero)
        title = (number.map { "\($0) " } ?? "") + text; isBordered = false; focusRingType = .none
        wantsLayer = true; layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        updateFill()
    }
    required init?(coder: NSCoder) { fatalError() }
    private var label: NSAttributedString {
        let result = NSMutableAttributedString(string: number.map { "\($0) " } ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: selected ? NSColor.white.withAlphaComponent(0.85) : NSColor.secondaryLabelColor
        ])
        result.append(NSAttributedString(string: candidate, attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: selected ? .semibold : .regular),
            .foregroundColor: selected ? NSColor.white : NSColor.labelColor
        ]))
        return result
    }
    var labelWidth: CGFloat { ceil(label.size().width) + 14 }
    override func draw(_ dirtyRect: NSRect) {
        let text = label
        text.draw(at: NSPoint(x: 7, y: (bounds.height - text.size().height) / 2))
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); updateFill(); needsDisplay = true
    }
    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
    }
}
