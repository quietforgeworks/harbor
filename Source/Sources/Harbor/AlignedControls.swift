import AppKit

class HarborTopDownView: NSView {
    override var isFlipped: Bool { true }
}

final class HarborCard: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.035).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.065).cgColor
            layer?.borderWidth = 0.5
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
}

func harborLabel(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = secondary ? .secondaryLabelColor : .labelColor
    label.lineBreakMode = .byTruncatingTail
    return label
}

func harborIdentify(_ view: NSView, _ name: String) {
    view.identifier = NSUserInterfaceItemIdentifier(name)
    view.setAccessibilityIdentifier(name)
}

func harborSymbol(_ name: String, size: CGFloat = 14) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .medium))
}

func harborButton(_ title: String = "", symbol name: String? = nil, help: String, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = .glass
    button.font = .systemFont(ofSize: 12, weight: .medium)
    if let name {
        button.image = harborSymbol(name)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }
    button.toolTip = help
    button.setAccessibilityLabel(help)
    return button
}

func harborPlace(_ view: NSView, in parent: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
    view.frame = NSRect(x: x, y: y, width: width, height: height)
    parent.addSubview(view)
}

/// Labels use their native cell height, centered within the shared row rectangle.
func harborPlaceLabel(_ label: NSTextField, in parent: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ rowHeight: CGFloat) {
    let height = ceil(label.cell?.cellSize.height ?? label.intrinsicContentSize.height)
    harborPlace(label, in: parent, x, y + (rowHeight - height) / 2, width, height)
}

func harborHeading(_ title: String, symbol name: String, in parent: NSView, y: CGFloat = 12) {
    let icon = NSImageView(image: harborSymbol(name) ?? NSImage())
    icon.contentTintColor = .secondaryLabelColor
    harborPlace(icon, in: parent, 16, y + 5, 16, 16)
    harborPlaceLabel(harborLabel(title, size: 12, weight: .semibold), in: parent, 42, y, 220, 26)
}

final class HarborServiceChip: HarborTopDownView {
    private let dot = NSImageView()
    private let label: NSTextField
    init(title: String) {
        label = harborLabel(title, size: 11, weight: .medium)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 13
        dot.image = harborSymbol("circle.fill", size: 5)
        dot.contentTintColor = .tertiaryLabelColor
        addSubview(dot)
        addSubview(label)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let labelSize = label.cell?.cellSize ?? label.intrinsicContentSize
        let totalWidth = 6 + 7 + ceil(labelSize.width)
        let x = (bounds.width - totalWidth) / 2
        dot.frame = NSRect(x: x, y: (bounds.height - 6) / 2, width: 6, height: 6)
        label.frame = NSRect(x: x + 13, y: (bounds.height - ceil(labelSize.height)) / 2, width: ceil(labelSize.width), height: ceil(labelSize.height))
    }
    func update(color: NSColor, detail: String) {
        dot.contentTintColor = color
        toolTip = detail
        setAccessibilityLabel(detail)
    }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
}

final class HarborCenteredSecureCell: NSSecureTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let height = textHeight
        result.origin.y += max(0, (result.height - height) / 2)
        result.size.height = min(result.height, height)
        return result
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centeredEditorRect(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centeredEditorRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    private var textHeight: CGFloat {
        let font = font ?? .systemFont(ofSize: 12)
        return ceil(font.ascender - font.descender) + 2
    }
    private func centeredEditorRect(_ rect: NSRect) -> NSRect {
        let height = textHeight + 2
        return NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }
}

/// A stable, non-promoted input surface. Only the text field freezes during navigation;
/// the rounded background stays in the page's normal compositing hierarchy.
final class HarborInputSurface: HarborTopDownView {
    private let field: NSTextField
    private var leadingIcon: NSImageView?
    var focused = false { didSet { updateAppearance() } }
    init(field: NSTextField, leadingSymbol: String? = nil) {
        self.field = field
        super.init(frame:.zero)
        wantsLayer = true; layer?.cornerRadius = 10
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        addSubview(field)
        if let leadingSymbol {
            let icon = NSImageView(image:harborSymbol(leadingSymbol,size:13) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor; addSubview(icon); leadingIcon = icon
        }
        updateAppearance()
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let leading: CGFloat = leadingIcon == nil ? 9 : 32
        leadingIcon?.frame = NSRect(x:11,y:(bounds.height-14)/2-1,width:14,height:14)
        field.frame = NSRect(x:leading,y:0,width:max(0,bounds.width-leading-9),height:bounds.height)
    }
    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
            layer?.borderColor = (focused ? NSColor.controlAccentColor.withAlphaComponent(0.65) : NSColor.labelColor.withAlphaComponent(0.08)).cgColor
            layer?.borderWidth = focused ? 1.5 : 0.5
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
}

final class HarborCenteredTextCell: NSTextFieldCell {
    private var textHeight: CGFloat { let font = font ?? .systemFont(ofSize:12); return ceil(font.ascender-font.descender)+2 }
    override func drawingRect(forBounds rect:NSRect) -> NSRect {
        var result = super.drawingRect(forBounds:rect)
        result.origin.y += max(0,(result.height-textHeight)/2); result.size.height = min(result.height,textHeight)
        return result
    }
    private func editorRect(_ rect:NSRect) -> NSRect { NSRect(x:rect.minX,y:rect.midY-(textHeight+2)/2,width:rect.width,height:textHeight+2) }
    override func select(withFrame rect:NSRect,in controlView:NSView,editor textObj:NSText,delegate:Any?,start selStart:Int,length selLength:Int) {
        super.select(withFrame:editorRect(rect),in:controlView,editor:textObj,delegate:delegate,start:selStart,length:selLength)
    }
    override func edit(withFrame rect:NSRect,in controlView:NSView,editor textObj:NSText,delegate:Any?,event:NSEvent?) {
        super.edit(withFrame:editorRect(rect),in:controlView,editor:textObj,delegate:delegate,event:event)
    }
}
