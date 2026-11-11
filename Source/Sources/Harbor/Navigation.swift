import AppKit
import QuartzCore

enum HarborPage: String, CaseIterable {
    case home, settings, airports, group, nodes, rules
    var size: NSSize {
        switch self {
        case .home: return HarborHomeController.size
        case .settings: return HarborSettingsController.size
        case .airports: return HarborAirportsController.size
        case .group: return HarborGroupController.size
        case .nodes: return HarborNodesController.size
        case .rules: return HarborRulesController.size
        }
    }
    var title: String { switch self { case .home: return "Harbor"; case .settings: return "订阅与设置"; case .airports: return "切换机场"; case .group: return "代理组"; case .nodes: return "选择节点"; case .rules: return "分流规则" } }
}
private final class NavigationRoot: NSView { override var isFlipped: Bool { true }; override var acceptsFirstResponder: Bool { true } }
private final class PageSlot: NSView {
    var interactive = false
    let scroll = NSScrollView()
    override var isFlipped: Bool { true }
    init(page: NSView) {
        super.init(frame: .zero)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.documentView = page; addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); scroll.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { interactive ? super.hitTest(point) : nil }
}

final class HarborNavigationController: NSViewController {
    private weak var owner: HarborAppDelegate?
    private let content = NavigationRoot()
    private var controllers: [HarborPage: NSViewController] = [:]
    private var slots: [HarborPage: PageSlot] = [:]
    private let motion = FrameAnimator()
    private var history: [HarborPage] = []
    private var frozenInputs: [(field: NSTextField, image: NSImageView)] = []
    private(set) var current: HarborPage = .home
    private(set) var transitionRecords = [[String: Any]]()
    var isAnimating: Bool { motion.isAnimating }
    var currentHeight: CGFloat { isViewLoaded ? view.bounds.height : HarborPage.home.size.height }
    init(owner: HarborAppDelegate) { self.owner = owner; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        let root = NavigationRoot(frame: NSRect(origin: .zero, size: HarborPage.home.size))
        let glass = NSGlassEffectView(frame: root.bounds); glass.style = .regular; glass.cornerRadius = 20
        glass.autoresizingMask = [.width, .height]; content.frame = root.bounds; content.autoresizingMask = [.width, .height]
        glass.contentView = content; root.addSubview(glass); view = root
        _ = ensure(.home); applyFinal(.home); refresh()
    }
    private func ensure(_ page: HarborPage) -> NSViewController {
        if let controller = controllers[page] { return controller }
        let controller: NSViewController
        guard let owner else { fatalError("Missing owner") }
        switch page {
        case .home: controller = HarborHomeController(owner: owner)
        case .settings: controller = HarborSettingsController(owner: owner)
        case .airports: controller = HarborAirportsController(owner: owner)
        case .group: controller = HarborGroupController(owner: owner)
        case .nodes: controller = HarborNodesController(owner: owner)
        case .rules: controller = HarborRulesController(owner: owner)
        }
        addChild(controller); controller.view.setFrameSize(page.size)
        let slot = PageSlot(page: controller.view)
        slot.frame = NSRect(x: 0, y: 0, width: page.size.width, height: currentHeight)
        slot.isHidden = true; controller.view.alphaValue = 0; content.addSubview(slot)
        controllers[page] = controller; slots[page] = slot
        return controller
    }
    func refresh() {
        guard isViewLoaded else { return }
        for (page, controller) in controllers where page == current || motion.isAnimating {
            switch controller {
            case let c as HarborHomeController: c.refresh()
            case let c as HarborSettingsController: c.refresh()
            case let c as HarborAirportsController: c.refresh()
            case let c as HarborGroupController: c.refresh()
            case let c as HarborNodesController: c.refresh()
            case let c as HarborRulesController: c.refresh()
            default: break
            }
        }
    }
    func navigate(to page: HarborPage, back: Bool = false, animated: Bool = true) {
        _ = view
        guard current != page else { refresh(); return }
        view.window?.makeFirstResponder(view)
        if motion.isAnimating { saveMotion(interrupted: true) }
        motion.cancel()
        let previous = current
        if !back { history.append(current) }
        _ = ensure(page)
        current = page; refresh()
        let target = min(page.size.height, owner?.availablePanelHeight ?? page.size.height)
        let startHeight = currentHeight
        for (key, slot) in slots {
            slot.interactive = key == page
            controllers[key]?.view.setAccessibilityHidden(key != page)
        }
        freezeInputs()
        let incoming = slots[page]!
        if incoming.isHidden { incoming.frame.origin.x = back ? -14 : 14; controllers[page]!.view.alphaValue = 0 }
        incoming.isHidden = false
        content.addSubview(incoming, positioned: .above, relativeTo: nil)
        let starts = Dictionary(uniqueKeysWithValues: slots.map { key, slot in
            (key, (x: slot.frame.minX, alpha: controllers[key]!.view.alphaValue))
        })
        let shouldAnimate = animated && owner?.isPanelVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        owner?.beginPanelTransition()
        motion.animate(duration: shouldAnimate ? 0.26 : 0, window: view.window, update: { [weak self] progress in
            guard let self else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let height = startHeight + (target - startHeight) * progress
            self.owner?.resizePanel(height: height)
            for (key, slot) in self.slots {
                guard let start = starts[key] else { continue }
                let destinationX: CGFloat = key == page ? 0 : (back ? 14 : -14)
                slot.frame = NSRect(x: start.x + (destinationX - start.x) * progress, y: 0, width: 420, height: self.view.bounds.height)
                self.controllers[key]!.view.alphaValue = start.alpha + ((key == page ? 1 : 0) - start.alpha) * progress
                slot.layoutSubtreeIfNeeded()
            }
            CATransaction.commit()
        }, observe: { [weak self] in
            guard let self, let window = self.view.window else { return [] }
            let top = window.convertPoint(toScreen: self.view.convert(NSPoint(x: 0, y: 0), to: nil))
            return [Double(self.view.bounds.height), Double(window.frame.minX), Double(window.frame.maxY), Double(top.x), Double(top.y),
                    Double(self.controllers[previous]?.view.alphaValue ?? 0), Double(self.controllers[page]?.view.alphaValue ?? 0),
                    Double(self.slots[previous]?.frame.minX ?? 0), Double(self.slots[page]?.frame.minX ?? 0)]
        }, completion: { [weak self] in
            guard let self else { return }
            self.saveMotion(interrupted: false); self.applyFinal(page); self.restoreInputs(); self.owner?.endPanelTransition(); self.refresh()
            self.view.window?.makeFirstResponder(self.view)
        })
    }
    func goBack() { navigate(to: history.popLast() ?? .home, back: true) }
    func settle() {
        if motion.isAnimating { saveMotion(interrupted: true) }; motion.cancel()
        owner?.resizePanel(height: min(current.size.height, owner?.availablePanelHeight ?? current.size.height))
        applyFinal(current); restoreInputs(); owner?.endPanelTransition()
    }
    // AppKit field editors and native text bezels can redraw in separate passes while
    // a popover resizes. Freeze only editable fields during the 260 ms transition.
    // Secure-field snapshots remain masked, are kept in memory, and are discarded on settle.
    private func freezeInputs() {
        func collect(_ parent:NSView) {
            if let field = parent as? NSTextField, field.isEditable {
                guard !field.isHidden, !frozenInputs.contains(where: { $0.field === field }), let superview = field.superview else { return }
                field.layoutSubtreeIfNeeded()
                guard let bitmap = field.bitmapImageRepForCachingDisplay(in: field.bounds) else { return }
                field.cacheDisplay(in:field.bounds,to:bitmap)
                let image = NSImage(size:field.bounds.size); image.addRepresentation(bitmap)
                let overlay = NSImageView(frame:field.frame); overlay.image = image; overlay.imageScaling = .scaleAxesIndependently
                overlay.setAccessibilityElement(false)
                superview.addSubview(overlay,positioned:.above,relativeTo:field)
                field.isHidden = true; frozenInputs.append((field,overlay)); return
            }
            for child in parent.subviews { collect(child) }
        }
        for controller in controllers.values { collect(controller.view) }
    }
    private func restoreInputs() {
        for pair in frozenInputs { pair.field.isHidden = false; pair.image.removeFromSuperview() }
        frozenInputs.removeAll()
    }
    private func applyFinal(_ page: HarborPage) {
        for (key, slot) in slots {
            slot.isHidden = key != page; slot.interactive = key == page
            slot.frame = NSRect(x: 0, y: 0, width: 420, height: currentHeight)
            controllers[key]?.view.alphaValue = key == page ? 1 : 0
            controllers[key]?.view.setAccessibilityHidden(key != page)
        }
    }
    private func saveMotion(interrupted: Bool) {
        guard !motion.samples.isEmpty else { return }
        transitionRecords.append(["destination": current.rawValue, "interrupted": interrupted, "driver": motion.driverName,
                                  "samples": motion.samples.map { ["elapsed": $0.elapsed, "progress": $0.progress, "values": $0.values] as [String: Any] }])
        if transitionRecords.count > 16 { transitionRecords.removeFirst() }
    }
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { if current != .home { goBack() } else { owner?.closePanel() } }
}
