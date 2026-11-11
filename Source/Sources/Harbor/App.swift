import AppKit

@main enum HarborApplication {
    static func main() {
        if HarborCommandLine.handle() { return }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = HarborAppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
final class HarborAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var navigation: HarborNavigationController!
    private var anchor: NSPoint?
    var isPanelVisible: Bool { popover.isShown }
    var availablePanelHeight: CGFloat { max(280, (statusItem?.button?.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 700) - 24 }
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp]); statusItem.button?.setAccessibilityIdentifier("harbor-menu")
        navigation = HarborNavigationController(owner: self); popover.contentViewController = navigation
        popover.contentSize = HarborPage.home.size; popover.behavior = .transient; popover.delegate = self
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.onChange = { [weak self] in self?.refresh() }; refresh()
        if let index = CommandLine.arguments.firstIndex(of: "--repair-node-dns"), CommandLine.arguments.indices.contains(index+1) { model.repairNodeDNS(from: URL(fileURLWithPath: CommandLine.arguments[index+1])) }
        if let index = CommandLine.arguments.firstIndex(of: "--import-link-file"), CommandLine.arguments.indices.contains(index+1), let value = try? String(contentsOfFile: CommandLine.arguments[index+1], encoding: .utf8) { model.importSubscription(value) }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--show-settings") { DispatchQueue.main.async { self.showSettings() } }
        else if CommandLine.arguments.contains("--show") || CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--ui-check") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showPanel() } }
        if let at = CommandLine.arguments.firstIndex(of: "--ui-check"), CommandLine.arguments.indices.contains(at+1) {
            let path = URL(fileURLWithPath: CommandLine.arguments[at+1], isDirectory: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.runInterfaceCheck(at: path) }
        }
    }
    private func installMenu() {
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self; appMenu.addItem(settings)
        appMenu.addItem(.separator()); appMenu.addItem(NSMenuItem(title: "退出 Harbor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.submenu = appMenu; menu.addItem(item)
        let editItem = NSMenuItem(), edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销","undo:","z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] { edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)) }
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
    }
    func refresh() {
        statusItem?.button?.image = HarborBrand.menuImage(connected:model.isConnected)
        statusItem?.button?.image?.size = NSSize(width: 17, height: 17); statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.toolTip = "Harbor · \(model.statusText)"; statusItem?.button?.setAccessibilityLabel("Harbor，\(model.statusText)")
        if popover.isShown { navigation?.refresh() }
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu(); let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
            settings.target = self; menu.addItem(settings); menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "退出 Harbor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else if popover.isShown { closePanel() } else { showPanel() }
    }
    func showPanel() {
        guard let button = statusItem?.button else { return }
        navigation.settle(); navigation.refresh()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        navigation.view.window?.title = "Harbor"; navigation.view.window?.makeKey()
    }
    func beginFileSelection() { popover.behavior = .applicationDefined }
    func endFileSelection() { popover.behavior = .transient; if !popover.isShown { showPanel() } }
    func closePanel() { navigation.settle(); popover.performClose(nil) }
    func navigate(to page: HarborPage) {
        if !popover.isShown { showPanel() }
        navigation.navigate(to: page)
    }
    func goBack() { navigation.goBack() }
    @objc func showSettings() { navigate(to: .settings) }
    func beginPanelTransition() {
        if anchor == nil, let frame = navigation.view.window?.frame { anchor = NSPoint(x: frame.minX, y: frame.maxY) }
        popover.animates = false; navigation.view.window?.animationBehavior = .none
    }
    func resizePanel(height: CGFloat) {
        let size = NSSize(width: 420, height: height.rounded())
        if popover.contentSize != size { popover.contentSize = size; navigation.view.setFrameSize(size) }
        navigation.view.layoutSubtreeIfNeeded()
        if let anchor, let window = navigation.view.window {
            var frame = window.frame; frame.origin = NSPoint(x: anchor.x, y: anchor.y - frame.height)
            if window.frame.origin != frame.origin { window.setFrame(frame, display: true, animate: false) }
        }
    }
    func endPanelTransition() { anchor = nil; popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    func popoverDidClose(_ notification: Notification) { navigation.settle() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.shutdown() { return .terminateNow }
        showPanel(); navigation.navigate(to:.home); return .terminateCancel
    }
    private func runInterfaceCheck(at path: URL) {
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                var windowIDs = [Int](); var geometry = [[String: Any]]()
                @MainActor func capture(_ name: String) throws {
                    self.navigation.view.layoutSubtreeIfNeeded()
                    if let window = self.navigation.view.window { windowIDs.append(window.windowNumber) }
                    if let bitmap = self.navigation.view.bitmapImageRepForCachingDisplay(in: self.navigation.view.bounds) {
                        self.navigation.view.cacheDisplay(in: self.navigation.view.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: path.appendingPathComponent(name + ".png")) }
                    }
                    geometry.append(["page":name,"height":self.navigation.currentHeight,"width":self.navigation.view.bounds.width])
                }
                try capture("home")
                for page in [HarborPage.settings,.airports,.nodes,.rules] {
                    self.navigate(to: page); try await Task.sleep(nanoseconds: 400_000_000); try capture(page.rawValue)
                    if page == .nodes {
                        @MainActor func findSearch(_ view:NSView) -> NSTextField? {
                            if view.identifier?.rawValue == "harbor-node-search" { return view as? NSTextField }
                            for child in view.subviews { if let field = findSearch(child) { return field } }; return nil
                        }
                        if let field = findSearch(self.navigation.view) {
                            self.navigation.view.window?.makeFirstResponder(field)
                            if let editor = field.currentEditor() as? NSTextView { editor.insertText("台",replacementRange:editor.selectedRange()); try capture("search-editing"); editor.selectAll(nil); editor.insertText("",replacementRange:editor.selectedRange()) }
                            self.navigation.view.window?.makeFirstResponder(self.navigation.view)
                        }
                    }
                }
                self.navigate(to: .settings); try await Task.sleep(nanoseconds: 60_000_000)
                self.goBack(); try await Task.sleep(nanoseconds: 60_000_000)
                self.navigate(to: .home); try await Task.sleep(nanoseconds: 400_000_000)
                self.navigate(to: .settings); try await Task.sleep(nanoseconds: 60_000_000); self.closePanel(); self.showPanel()
                try await Task.sleep(nanoseconds: 350_000_000)
                let records = self.navigation.transitionRecords
                let report: [String:Any] = ["sameWindow": Set(windowIDs).count == 1, "windowIDs":windowIDs,"pages":geometry,"transitions":records,"animationStopped": !self.navigation.isAnimating]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: path.appendingPathComponent("navigation.json"))
                print("Interface checks saved"); NSApp.terminate(nil)
            } catch { print("Interface checks failed"); NSApp.terminate(nil) }
        }
    }
}
