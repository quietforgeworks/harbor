import AppKit
import QuartzCore

/// Native glass stays attached to the moving selection's view geometry.
final class HarborGlassSegments: NSControl {
    private let container = NSGlassEffectContainerView()
    private let content = NSView()
    private let selection = NSGlassEffectView()
    private var buttons: [NSButton] = []
    private var index = 0
    private var animation: Timer?
    var selectedSegment: Int {
        get { index }
        set { select(newValue, animated: false) }
    }
    override var isEnabled: Bool {
        didSet { buttons.forEach { $0.isEnabled = isEnabled } }
    }
    init(labels: [String]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 19
        container.spacing = 8
        container.contentView = content
        addSubview(container)
        selection.style = .regular
        selection.cornerRadius = 16
        selection.contentView = NSView()
        content.addSubview(selection)
        for (index, title) in labels.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(chose(_:)))
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: index == 0 ? .semibold : .medium)
            button.state = index == 0 ? .on : .off
            button.setAccessibilityValue(index == 0 ? 1 : 0)
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityIdentifier(index == 0 ? "harbor-mode-rule" : "harbor-mode-global")
            addSubview(button)
            buttons.append(button)
        }
        setAccessibilityElement(true)
        setAccessibilityChildren(buttons)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("代理模式")
        updateBackground()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        container.frame = bounds
        content.frame = bounds
        for (index, button) in buttons.enumerated() {
            button.frame = segmentFrame(index)
        }
        if animation == nil { selection.frame = segmentFrame(index) }
    }
    private func segmentFrame(_ index: Int) -> NSRect {
        let width = (bounds.width - 6) / CGFloat(buttons.count)
        return NSRect(x: 3 + CGFloat(index) * width, y: 3, width: width, height: bounds.height - 6)
    }
    private func select(_ value: Int, animated: Bool) {
        guard buttons.indices.contains(value) else { return }
        if index == value { return }
        animation?.invalidate()
        animation = nil
        index = value
        for (i, button) in buttons.enumerated() {
            button.state = i == value ? .on : .off
            button.font = .systemFont(ofSize: 13, weight: i == value ? .semibold : .medium)
            button.setAccessibilityValue(i == value ? 1 : 0)
        }
        let start = selection.frame
        let end = segmentFrame(value)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            selection.frame = end
            return
        }
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let fraction = min(1, (CACurrentMediaTime() - began) / 0.24)
            let eased = fraction * fraction * (3 - 2 * fraction)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.selection.frame = NSRect(x: start.minX + (end.minX - start.minX) * eased,
                                          y: end.minY, width: end.width, height: end.height)
            CATransaction.commit()
            if fraction >= 1 { timer.invalidate(); self.animation = nil }
        }
        animation = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    @objc private func chose(_ sender: NSButton) {
        guard isEnabled, index != sender.tag else { return }
        select(sender.tag, animated: true)
        _ = sendAction(action, to: target)
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.keyCode == 123 || event.keyCode == 124 else { super.keyDown(with: event); return }
        select(min(buttons.count - 1, max(0, index + (event.keyCode == 123 ? -1 : 1))), animated: true)
        _ = sendAction(action, to: target)
    }
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBackground() }
}
