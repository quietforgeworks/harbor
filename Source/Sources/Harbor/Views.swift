import AppKit
import UniformTypeIdentifiers

class HarborPageController: NSViewController {
    weak var owner: HarborAppDelegate?
    init(owner: HarborAppDelegate) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    func makePage(height: CGFloat, title: String? = nil) {
        view = HarborTopDownView(frame: NSRect(x: 0, y: 0, width: 420, height: height))
        if let title {
            let back = harborButton(symbol: "chevron.left", help: "返回", target: self, action: #selector(goBack))
            back.borderShape = .circle
            harborIdentify(back, "harbor-back")
            harborPlace(back, in: view, 20, 16, 30, 30)
            harborPlaceLabel(harborLabel(title, size: 15, weight: .semibold), in: view, 62, 16, 300, 30)
        }
    }
    func card(y: CGFloat, height: CGFloat) -> HarborCard {
        let card = HarborCard(frame: NSRect(x: 20, y: y, width: 380, height: height))
        view.addSubview(card)
        return card
    }
    func action(_ title: String = "", symbol: String, help: String, id: String, action: Selector) -> NSButton {
        let button = harborButton(title, symbol: symbol, help: help, target: self, action: action)
        harborIdentify(button, id)
        return button
    }
    func chooseFile(title: String, completion: @escaping (URL) -> Void) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "导入"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml"), .json, .plainText].compactMap { $0 }
        owner?.beginFileSelection()
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.owner?.endFileSelection()
            if response == .OK, let url = panel.url { completion(url) }
        }
    }
    func refresh() {}
    @objc private func goBack() { owner?.goBack() }
}

private final class HarborTrafficColumn: HarborTopDownView {
    private let icon: NSImageView
    private let title: NSTextField
    private let rate = harborLabel("0 KB/s", size: 17, weight: .medium)
    private let total = harborLabel("累计 0 KB", size: 10, secondary: true)
    init(title: String, symbol: String) {
        self.title = harborLabel(title, size: 10, secondary: true)
        icon = NSImageView(image: harborSymbol(symbol, size: 10) ?? NSImage())
        super.init(frame: .zero)
        icon.contentTintColor = .secondaryLabelColor
        rate.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
        rate.alignment = .center
        total.alignment = .center
        addSubview(icon)
        addSubview(self.title)
        addSubview(rate)
        addSubview(total)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let titleSize = title.cell?.cellSize ?? title.intrinsicContentSize
        let groupWidth = 11 + 5 + ceil(titleSize.width)
        let startX = (bounds.width - groupWidth) / 2
        icon.frame = NSRect(x: startX, y: 14, width: 11, height: 11)
        title.frame = NSRect(x: startX + 16, y: 12 + (16 - ceil(titleSize.height)) / 2, width: ceil(titleSize.width), height: ceil(titleSize.height))
        let rateHeight = ceil(rate.cell?.cellSize.height ?? 23)
        rate.frame = NSRect(x: 0, y: 31 + (25 - rateHeight) / 2, width: bounds.width, height: rateHeight)
        let totalHeight = ceil(total.cell?.cellSize.height ?? 14)
        total.frame = NSRect(x: 0, y: 61 + (16 - totalHeight) / 2, width: bounds.width, height: totalHeight)
    }
    func update(rate rateText: String, total totalText: String) {
        rate.stringValue = rateText
        total.stringValue = "累计 " + totalText
        setAccessibilityLabel(title.stringValue + " " + rateText + "，累计 " + totalText)
        needsLayout = true
    }
}

final class HarborHomeController: HarborPageController {
    static let size = NSSize(width: 420, height: 350)
    private let status = harborLabel("未连接", size: 20, weight: .semibold)
    private let dot = NSImageView()
    private let mode = HarborGlassSegments(labels: ["规则", "全局"])
    private let nodeTitle = harborLabel("选择节点", size: 13, weight: .medium)
    private let airport = harborLabel("当前机场", size: 10, secondary: true)
    private let download = HarborTrafficColumn(title: "下载", symbol: "arrow.down")
    private let upload = HarborTrafficColumn(title: "上传", symbol: "arrow.up")
    private let message = harborLabel("", size: 10)
    private var connect: NSButton!
    private var nodes: NSButton!
    private var test: NSButton!
    override func loadView() {
        makePage(height: Self.size.height)
        dot.image = harborSymbol("circle.fill", size: 7)
        harborPlace(dot, in: view, 23, 38, 8, 8)
        harborPlaceLabel(status, in: view, 42, 21, 252, 42)
        connect = action(symbol: "power", help: "连接", id: "harbor-connect", action: #selector(toggleConnection))
        connect.borderShape = .circle
        harborPlace(connect, in: view, 352, 20, 48, 48)
        mode.target = self
        mode.action = #selector(modeChanged)
        harborIdentify(mode, "harbor-mode")
        mode.toolTip = "规则模式使用分流规则；全局模式通过当前节点连接，局域网保持直连。"
        harborPlace(mode, in: view, 20, 86, 380, 38)
        let node = card(y: 140, height: 76)
        let icon = NSImageView(image: harborSymbol("network", size: 18) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        harborPlace(icon, in: node, 16, 28, 20, 20)
        harborPlaceLabel(airport, in: node, 48, 14, 224, 18)
        harborPlaceLabel(nodeTitle, in: node, 48, 34, 216, 24)
        let chevron = NSImageView(image: harborSymbol("chevron.right", size: 10) ?? NSImage())
        chevron.contentTintColor = .tertiaryLabelColor
        harborPlace(chevron, in: node, 268, 33, 10, 10)
        nodes = NSButton(title: "", target: self, action: #selector(showNodes))
        nodes.isBordered = false
        harborIdentify(nodes, "harbor-nodes")
        harborPlace(nodes, in: node, 0, 0, 286, 76)
        test = action("待测", symbol: "waveform.path.ecg", help: "测试当前节点 HTTPS 延迟", id: "harbor-test", action: #selector(testCurrentNode))
        test.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        harborPlace(test, in: node, 292, 23, 72, 30)
        let network = card(y: 228, height: 90)
        network.toolTip = "实时通过 Harbor 的速率与本次连接累计流量"
        harborIdentify(network, "harbor-traffic")
        harborIdentify(download, "harbor-download-traffic")
        harborIdentify(upload, "harbor-upload-traffic")
        harborPlace(download, in: network, 12, 0, 172, 90)
        harborPlace(upload, in: network, 196, 0, 172, 90)
        let divider = NSBox()
        divider.boxType = .separator
        divider.alphaValue = 0.4
        harborPlace(divider, in: network, 190, 16, 1, 58)
        let settings = action(symbol: "gearshape", help: "设置", id: "harbor-settings", action: #selector(showSettings))
        settings.borderShape = .circle
        harborPlace(settings, in: view, 310, 29, 30, 30)
        message.textColor = .systemOrange
        harborIdentify(message, "harbor-message")
        harborPlaceLabel(message, in: view, 24, 328, 372, 16)
        refresh()
    }
    override func refresh() {
        guard isViewLoaded, let model = owner?.model else { return }
        status.stringValue = model.statusText
        dot.contentTintColor = model.errorText != nil ? .systemOrange : (model.isConnected ? .systemGreen : .tertiaryLabelColor)
        connect.isEnabled = !model.isBusy || model.isConnected
        connect.tintProminence = model.isConnected ? .primary : .secondary
        connect.bezelColor = model.isConnected ? .systemGreen : nil
        connect.toolTip = model.isConnected ? "断开连接并恢复原有设置" : "连接"
        connect.setAccessibilityLabel(model.isConnected ? "断开连接" : "连接")
        mode.selectedSegment = model.mode == "global" ? 1 : 0
        mode.isEnabled = !model.isBusy
        nodeTitle.stringValue = model.selectedNode ?? "导入订阅以选择节点"
        airport.stringValue = model.activeSubscriptionName
        airport.toolTip = model.activeSubscriptionName
        nodes.setAccessibilityLabel("选择机场与节点，" + (model.selectedNode ?? "尚未导入"))
        test.title = model.delayText
        test.isEnabled = !model.isBusy && !model.nodes.isEmpty
        download.update(rate: model.downloadRateText, total: model.downloadTotalText)
        upload.update(rate: model.uploadRateText, total: model.uploadTotalText)
        message.stringValue = model.errorText ?? ""
        message.toolTip = model.errorText
        message.isHidden = model.errorText == nil
    }
    @objc private func toggleConnection() { owner?.model.toggleConnection() }
    @objc private func modeChanged() { owner?.model.setMode(mode.selectedSegment == 1 ? "global" : "rule") }
    @objc private func testCurrentNode() { owner?.model.testCurrentNode() }
    @objc private func showSettings() { owner?.navigate(to: .settings) }
    @objc private func showNodes() { owner?.navigate(to: .group) }
}

final class HarborSettingsController: HarborPageController, NSTextFieldDelegate {
    static let size = NSSize(width: 420, height: 508)
    private let subscription = NSSecureTextField()
    private let airport = harborLabel("尚未导入订阅", size: 11, weight: .medium)
    private let quota = harborLabel("—", size: 11, secondary: true)
    private let expiry = harborLabel("—", size: 10, secondary: true)
    private let updated = harborLabel("尚未更新", size: 10, secondary: true)
    private let quotaBar = NSProgressIndicator()
    private let autoUpdate = NSSwitch()
    private let rulesStatus = harborLabel("内置规则", size: 10, secondary: true)
    private let result = harborLabel("", size: 10)
    private var chips: [HarborServiceChip] = []
    private var controls: [NSButton] = []
    private var serviceButton: NSButton!
    private var importButton: NSButton!
    override func loadView() {
        makePage(height: Self.size.height, title: "设置")
        let source = card(y: 62, height: 236)
        harborHeading("节点订阅", symbol: "link", in: source)
        let file = action(symbol: "doc.badge.plus", help: "导入节点文件", id: "harbor-import-nodes", action: #selector(importNodes))
        let update = action(symbol: "arrow.clockwise", help: "更新当前机场订阅", id: "harbor-update-subscription", action: #selector(updateSubscription))
        harborPlace(file, in: source, 292, 10, 30, 30)
        harborPlace(update, in: source, 334, 10, 30, 30)
        controls += [file, update]
        subscription.cell = HarborCenteredSecureCell(textCell: "")
        subscription.placeholderString = "HTTPS 订阅链接"
        subscription.font = .systemFont(ofSize: 12)
        subscription.delegate = self
        subscription.isEditable = true
        subscription.isSelectable = true
        subscription.refusesFirstResponder = false
        subscription.setAccessibilityLabel("HTTPS 订阅链接")
        harborIdentify(subscription, "harbor-subscription")
        harborPlace(HarborInputSurface(field:subscription), in: source, 16, 52, 306, 32)
        importButton = action(symbol: "plus", help: "添加机场订阅", id: "harbor-import-subscription", action: #selector(importSubscription))
        importButton.tintProminence = .primary
        harborPlace(importButton, in: source, 334, 52, 30, 32)
        harborPlaceLabel(airport, in: source, 16, 104, 236, 22)
        let switchAirport = action("切换机场", symbol: "chevron.right", help: "切换机场", id: "harbor-subscription-picker", action: #selector(showAirports))
        harborPlace(switchAirport, in: source, 264, 100, 100, 30)
        controls.append(switchAirport)
        quotaBar.style = .bar
        quotaBar.isIndeterminate = false
        quotaBar.minValue = 0
        quotaBar.maxValue = 1
        quotaBar.controlSize = .small
        harborPlace(quotaBar, in: source, 16, 143, 348, 5)
        harborPlaceLabel(quota, in: source, 16, 157, 210, 20)
        expiry.alignment = .right
        harborPlaceLabel(expiry, in: source, 230, 157, 134, 20)
        harborPlaceLabel(updated, in: source, 16, 199, 208, 22)
        harborPlaceLabel(harborLabel("自动更新", size: 11, secondary: true), in: source, 247, 199, 67, 22)
        autoUpdate.controlSize = .mini
        autoUpdate.target = self
        autoUpdate.action = #selector(autoUpdateChanged)
        autoUpdate.setAccessibilityLabel("自动更新订阅")
        harborIdentify(autoUpdate, "harbor-auto-update")
        harborPlace(autoUpdate, in: source, 327, 199, 37, 22)

        let rules = card(y: 310, height: 80)
        harborHeading("分流规则", symbol: "arrow.triangle.branch", in: rules)
        harborPlaceLabel(rulesStatus, in: rules, 16, 45, 324, 20)
        let chevron = NSImageView(image: harborSymbol("chevron.right", size: 11) ?? NSImage())
        chevron.contentTintColor = .tertiaryLabelColor
        harborPlace(chevron, in: rules, 346, 34, 10, 12)
        let openRules = NSButton(title: "", target: self, action: #selector(showRules))
        openRules.isBordered = false
        openRules.setAccessibilityLabel("展开完整分流规则编辑器")
        harborIdentify(openRules, "harbor-open-rules")
        harborPlace(openRules, in: rules, 0, 0, 380, 80)

        let services = card(y: 402, height: 82)
        harborHeading("AI 服务", symbol: "sparkles", in: services, y: 10)
        serviceButton = action(symbol: "arrow.clockwise", help: "检测 AI 服务 HTTPS 响应", id: "harbor-test-services", action: #selector(testServices))
        serviceButton.toolTip = "检查当前节点 HTTPS 响应；不代表账号或地区权限可用。"
        harborPlace(serviceButton, in: services, 334, 8, 30, 30)
        let chipWidth: CGFloat = 108
        for (index, title) in ["ChatGPT", "Claude", "Gemini"].enumerated() {
            let chip = HarborServiceChip(title: title)
            harborPlace(chip, in: services, 16 + CGFloat(index) * 120, 44, chipWidth, 26)
            chips.append(chip)
        }
        result.textColor = .systemOrange
        harborIdentify(result, "harbor-settings-result")
        harborPlaceLabel(result, in: view, 24, 490, 372, 14)
        refresh()
    }
    override func refresh() {
        guard isViewLoaded, let model = owner?.model else { return }
        airport.stringValue = model.activeSubscriptionName
        airport.toolTip = model.subscriptionSummary
        quota.stringValue = model.quotaUsageText
        quota.toolTip = model.quotaText
        expiry.stringValue = "到期 " + model.quotaExpiryText
        quotaBar.doubleValue = model.quotaFraction ?? 0
        quotaBar.alphaValue = model.quotaFraction == nil ? 0.3 : 1
        quotaBar.setAccessibilityLabel(model.quotaUsageText)
        updated.stringValue = model.updateSummary
        autoUpdate.state = model.autoUpdateEnabled ? .on : .off
        autoUpdate.isEnabled = !model.isBusy
        rulesStatus.stringValue = model.rulesSummary
        rulesStatus.toolTip = model.rulesSummary
        if subscription.isEnabled == model.isBusy { subscription.isEnabled = !model.isBusy }
        controls.forEach { $0.isEnabled = !model.isBusy }
        serviceButton.isEnabled = !model.isBusy && !model.nodes.isEmpty
        for (index, name) in ["ChatGPT", "Claude", "Gemini"].enumerated() {
            let line = model.serviceText.components(separatedBy: "\n").first { $0.hasPrefix(name) }
            let color: NSColor = line.map { $0.contains("HTTPS 可达") ? .systemGreen : .systemOrange } ?? .tertiaryLabelColor
            let pending = model.serviceText.contains("正在") ? "检测中" : "待测"
            chips[index].update(color: color, detail: line ?? "\(name) · \(pending)")
        }
        importButton.isEnabled = !model.isBusy && !subscription.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        result.stringValue = model.errorText ?? ""
        result.toolTip = model.errorText
        result.isHidden = model.errorText == nil
    }
    func controlTextDidBeginEditing(_ obj: Notification) { (subscription.superview as? HarborInputSurface)?.focused = true }
    func controlTextDidEndEditing(_ obj: Notification) { (subscription.superview as? HarborInputSurface)?.focused = false }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    @objc private func importSubscription() {
        let value = subscription.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        subscription.stringValue = ""
        owner?.model.importSubscription(value)
        refresh()
    }
    @objc private func updateSubscription() { owner?.model.updateSubscription() }
    @objc private func autoUpdateChanged() { owner?.model.setAutoUpdate(autoUpdate.state == .on) }
    @objc private func testServices() { owner?.model.testServices() }
    @objc private func importNodes() { chooseFile(title: "导入 Clash 节点配置") { [weak self] in self?.owner?.model.importNodesFile($0) } }
    @objc private func showAirports() { owner?.navigate(to: .airports) }
    @objc private func showRules() { owner?.navigate(to: .rules) }
}

private final class HarborAirportCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("harbor-airport-cell")
    private let nameLabel = harborLabel("", size: 12, weight: .medium)
    private let detailLabel = harborLabel("", size: 10, secondary: true)
    private let marker = NSImageView()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseIdentifier
        addSubview(nameLabel)
        addSubview(detailLabel)
        addSubview(marker)
        textField = nameLabel
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let nameHeight = ceil(nameLabel.cell?.cellSize.height ?? 17)
        let detailHeight = ceil(detailLabel.cell?.cellSize.height ?? 14)
        nameLabel.frame = NSRect(x: 12, y: 9, width: max(0, bounds.width - 60), height: nameHeight)
        detailLabel.frame = NSRect(x: 12, y: 34, width: max(0, bounds.width - 60), height: detailHeight)
        marker.frame = NSRect(x: bounds.width - 34, y: (bounds.height - 18) / 2, width: 18, height: 18)
    }
    func update(name: String, nodeCount: Int, current: Bool) {
        nameLabel.stringValue = name
        nameLabel.font = .systemFont(ofSize: 12, weight: current ? .semibold : .medium)
        detailLabel.stringValue = "\(nodeCount) 个节点" + (current ? " · 当前机场" : "")
        marker.image = harborSymbol(current ? "checkmark.circle.fill" : "circle", size: 16)
        marker.contentTintColor = current ? .controlAccentColor : .tertiaryLabelColor
        toolTip = name + " · " + detailLabel.stringValue
        setAccessibilityLabel(toolTip)
        needsLayout = true
    }
}

final class HarborAirportsController: HarborPageController, NSTableViewDataSource, NSTableViewDelegate {
    static let size = NSSize(width: 420, height: 460)
    private struct Row: Equatable {
        var id: String
        var name: String
        var nodeCount: Int
    }
    private let table = NSTableView()
    private let summary = harborLabel("", size: 11, secondary: true)
    private let message = harborLabel("", size: 10)
    private var rows: [Row] = []
    private var currentID: String?
    private var updating = false
    override func loadView() {
        makePage(height: Self.size.height, title: "切换机场")
        harborPlaceLabel(summary, in: view, 24, 62, 372, 24)
        let list = card(y: 98, height: 330)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 60
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .fullWidth
        table.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: .init("airport"))
        column.width = 360
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(chooseAirport)
        harborIdentify(table, "harbor-airport-list")
        scroll.documentView = table
        harborPlace(scroll, in: list, 6, 8, 368, 314)
        message.textColor = .systemOrange
        harborIdentify(message, "harbor-airport-message")
        harborPlaceLabel(message, in: view, 24, 436, 372, 16)
        refresh()
    }
    override func refresh() {
        guard isViewLoaded, let model = owner?.model else { return }
        table.isEnabled = !model.isBusy
        summary.stringValue = model.subscriptions.isEmpty ? "在设置中添加机场订阅" : "已添加 \(model.subscriptions.count) 个机场"
        message.stringValue = model.errorText ?? ""
        message.toolTip = model.errorText
        message.isHidden = model.errorText == nil
        let nextRows = model.subscriptions.map { Row(id: $0.id, name: $0.name, nodeCount: $0.nodeCount) }
        guard rows != nextRows || currentID != model.activeSubscriptionID else { return }
        rows = nextRows
        currentID = model.activeSubscriptionID
        updating = true
        table.reloadData()
        if let row = rows.firstIndex(where: { $0.id == currentID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        updating = false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let cell = tableView.makeView(withIdentifier: HarborAirportCell.reuseIdentifier, owner: self) as? HarborAirportCell ?? HarborAirportCell(frame: .zero)
        cell.update(name: item.name, nodeCount: item.nodeCount, current: item.id == currentID)
        return cell
    }
    @objc private func chooseAirport() {
        guard !updating, let model = owner?.model, !model.isBusy, rows.indices.contains(table.selectedRow) else { return }
        let id = rows[table.selectedRow].id
        guard id != model.activeSubscriptionID else { return }
        model.selectSubscription(id)
        refresh()
    }
}

private final class HarborNodeCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("harbor-node-cell")
    private let marker = NSImageView()
    private let nameLabel = harborLabel("", size: 12)
    private let latencyLabel = harborLabel("", size: 10, secondary: true)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseIdentifier
        addSubview(marker)
        addSubview(nameLabel)
        addSubview(latencyLabel)
        textField = nameLabel
        latencyLabel.alignment = .right
        latencyLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        marker.frame = NSRect(x: 8, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let nameHeight = ceil(nameLabel.cell?.cellSize.height ?? 16)
        nameLabel.frame = NSRect(x: 36, y: (bounds.height - nameHeight) / 2, width: max(0, bounds.width - 116), height: nameHeight)
        let delayHeight = ceil(latencyLabel.cell?.cellSize.height ?? 14)
        latencyLabel.frame = NSRect(x: bounds.width - 74, y: (bounds.height - delayHeight) / 2, width: 65, height: delayHeight)
    }
    func update(name: String, delay: String, current: Bool) {
        marker.image = harborSymbol(current ? "checkmark.circle.fill" : "circle", size: 15)
        marker.contentTintColor = current ? .controlAccentColor : .tertiaryLabelColor
        nameLabel.stringValue = name
        nameLabel.font = .systemFont(ofSize: 12, weight: current ? .semibold : .regular)
        latencyLabel.stringValue = delay
        toolTip = name + " · " + delay
        setAccessibilityLabel(toolTip)
        needsLayout = true
    }
}

final class HarborNodesController: HarborPageController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let size = NSSize(width: 420, height: 534)
    private let airport = harborLabel("尚未导入机场", size: 12, weight: .medium)
    private let airportCount = harborLabel("在设置中添加订阅", size: 10, secondary: true)
    private let search = NSTextField()
    private let table = NSTableView()
    private var editingGroup = true
    private var groupButton: NSButton!
    private let count = harborLabel("", size: 10, secondary: true)
    private var test: NSButton!
    private var sort: NSButton!
    private var stop: NSButton!
    private var sorted = false
    private var filtered: [String] = []
    private struct Snapshot: Equatable {
        var nodes: [String]
        var delays: [String]
        var selected: String?
        var query: String
        var sorted: Bool
    }
    private var snapshot: Snapshot?
    private var displayedDelays: [String: String] = [:]
    private var updating = false
    override func loadView() {
        makePage(height: Self.size.height, title: "选择节点")
        let source = card(y: 62, height: 66)
        harborPlaceLabel(airport, in: source, 16, 10, 348, 24)
        harborPlaceLabel(airportCount, in: source, 16, 36, 348, 18)
        search.cell = HarborCenteredTextCell(textCell: "")
        search.font = .systemFont(ofSize:12)
        search.isEditable = true; search.isSelectable = true
        search.placeholderString = "搜索当前机场节点"
        search.delegate = self
        harborIdentify(search, "harbor-node-search")
        harborPlace(HarborInputSurface(field:search,leadingSymbol:"magnifyingglass"), in: view, 20, 142, 380, 30)
        harborPlaceLabel(count, in: view, 24, 184, 128, 28)
        sort = action("延迟", symbol: "arrow.up.arrow.down", help: "按延迟排序", id: "harbor-sort-nodes", action: #selector(toggleSort))
        harborPlace(sort, in: view, 166, 184, 76, 28)
        test = action("全部测速", symbol: "waveform.path.ecg", help: "测试全部节点 HTTPS 延迟", id: "harbor-test-all-nodes", action: #selector(testAll))
        harborPlace(test, in: view, 254, 184, 98, 28)
        stop = action(symbol: "stop.fill", help: "停止测速", id: "harbor-cancel-test", action: #selector(cancel))
        harborPlace(stop, in: view, 364, 184, 36, 28)
        groupButton = action("代理组 0/5", symbol:"arrow.triangle.2.circlepath", help:"设置最多 5 个自动备用节点", id:"harbor-failover-group", action:#selector(editGroup))
        harborPlace(groupButton,in:view,20,222,380,30)
        let list = card(y: 266, height: 244)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 38
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.style = .fullWidth
        table.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: .init("node"))
        column.width = 360
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(choose)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        harborIdentify(table, "harbor-node-list")
        scroll.documentView = table
        harborPlace(scroll, in: list, 6, 8, 368, 228)
        refresh()
    }
    override func refresh() {
        guard isViewLoaded, let model = owner?.model else { return }
        airport.stringValue = model.activeSubscriptionName
        airport.toolTip = model.activeSubscriptionName
        airportCount.stringValue = model.nodes.isEmpty ? "在设置中添加机场订阅" : "当前机场 · \(model.nodes.count) 个节点"
        groupButton.title = editingGroup ? "完成选择 · \(model.failoverNodes.count)/5" : "自动备用组 · \(model.failoverNodes.count)/5"
        groupButton.isEnabled = !model.isBusy
        table.isEnabled = !model.isBusy
        test.isEnabled = !model.isBusy && !model.nodes.isEmpty
        stop.isEnabled = model.canCancelOperation
        sort.state = sorted ? .on : .off
        let nodes = model.nodes
        let current = Snapshot(nodes: nodes, delays: nodes.map { model.delayText(for: $0) }, selected: model.selectedNode,
                               query: search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), sorted: sorted)
        guard current != snapshot else { return }
        let old = snapshot
        let oldDelays = displayedDelays
        displayedDelays = Dictionary(zip(current.nodes, current.delays), uniquingKeysWith: { first, _ in first })
        let visibleRows = table.rows(in: table.visibleRect)
        let topRow = visibleRows.location
        let topNode = filtered.indices.contains(topRow) ? filtered[topRow] : nil
        let topOffset = topNode == nil ? 0 : table.visibleRect.minY - table.rect(ofRow: topRow).minY
        var nextNodes = filtered
        if old?.nodes != current.nodes || old?.query != current.query || old?.sorted != current.sorted || (sorted && old?.delays != current.delays) {
            nextNodes = nodes.filter { current.query.isEmpty || $0.localizedCaseInsensitiveContains(current.query) }
            if sorted {
                let milliseconds = displayedDelays.mapValues { Double($0.replacingOccurrences(of: " ms", with: "")) ?? .infinity }
                nextNodes.sort {
                    let lhs = milliseconds[$0] ?? .infinity
                    let rhs = milliseconds[$1] ?? .infinity
                    return lhs == rhs ? $0.localizedStandardCompare($1) == .orderedAscending : lhs < rhs
                }
            }
        }
        snapshot = current
        updating = true
        defer { updating = false }
        if nextNodes != filtered {
            filtered = nextNodes
            table.reloadData()
            if let topNode, let row = filtered.firstIndex(of: topNode), old?.query == current.query, let scroll = table.enclosingScrollView {
                let maxY = max(0, table.bounds.height - scroll.contentView.bounds.height)
                let y = min(maxY, max(0, table.rect(ofRow: row).minY + topOffset))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        } else {
            let changed = IndexSet(filtered.indices.filter { row in
                let name = filtered[row]
                return oldDelays[name] != displayedDelays[name] || (old?.selected != current.selected && (name == old?.selected || name == current.selected))
            })
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        }
        if let selected = current.selected, let row = filtered.firstIndex(of: selected) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        count.stringValue = current.query.isEmpty ? "\(filtered.count) 个节点" : "\(filtered.count) / \(nodes.count) 个节点"
    }
    func controlTextDidBeginEditing(_ obj: Notification) { (search.superview as? HarborInputSurface)?.focused = true }
    func controlTextDidEndEditing(_ obj: Notification) { (search.superview as? HarborInputSurface)?.focused = false }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let name = filtered[row]
        let cell = tableView.makeView(withIdentifier: HarborNodeCell.reuseIdentifier, owner: self) as? HarborNodeCell ?? HarborNodeCell(frame: .zero)
        cell.update(name: name, delay: displayedDelays[name] ?? "待测", current: editingGroup ? (owner?.model.failoverNodes.contains(name) == true) : name == snapshot?.selected)
        return cell
    }
    @objc private func editGroup() { owner?.goBack() }
    @objc private func toggleSort() { sorted.toggle(); refresh() }
    @objc private func testAll() { owner?.model.testNodes() }
    @objc private func cancel() { owner?.model.cancelOperation() }
    @objc private func choose() {
        let row = table.selectedRow
        guard !updating, filtered.indices.contains(row), owner?.model.isBusy == false else { return }
        if editingGroup { owner?.model.toggleFailoverNode(filtered[row]); snapshot = nil; table.reloadData(); refresh() }
        else { owner?.model.selectNode(filtered[row]) }
    }
}

final class HarborRulesController: HarborPageController, NSTextViewDelegate {
    static let size = NSSize(width: 420, height: 540)
    private let editor = NSTextView()
    private let message = harborLabel("", size: 10, secondary: true)
    private var save: NSButton!
    private var reset: NSButton!
    private var importButton: NSButton!
    private var baseline = ""
    private var changingText = false
    private var observedRevision: Int?
    private var pendingRuleChange = false
    private var isDirty: Bool { editor.string != baseline }
    override func loadView() {
        makePage(height: Self.size.height, title: "分流规则")
        let toolbar = card(y: 62, height: 60)
        harborHeading("完整规则", symbol: "curlybraces", in: toolbar, y: 17)
        importButton = action(symbol: "square.and.arrow.down", help: "导入规则文件", id: "harbor-import-rules", action: #selector(importRules))
        reset = action(symbol: "arrow.counterclockwise", help: "恢复内置规则", id: "harbor-reset-rules", action: #selector(resetRules))
        harborPlace(importButton, in: toolbar, 292, 15, 30, 30)
        harborPlace(reset, in: toolbar, 334, 15, 30, 30)
        let code = card(y: 134, height: 328)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        editor.isRichText = false
        editor.importsGraphics = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.textColor = .labelColor
        editor.backgroundColor = .clear
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 10, height: 12)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = true
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.allowsUndo = true
        editor.delegate = self
        harborIdentify(editor, "harbor-rules-editor")
        editor.setAccessibilityLabel("完整分流规则代码")
        scroll.documentView = editor
        harborPlace(scroll, in: code, 4, 4, 372, 320)
        save = action("保存规则", symbol: "checkmark", help: "保存完整分流规则", id: "harbor-save-rules", action: #selector(saveRules))
        save.tintProminence = .primary
        harborPlace(save, in: view, 286, 476, 114, 32)
        harborPlaceLabel(message, in: view, 24, 480, 250, 24)
        refresh()
    }
    override func refresh() {
        guard isViewLoaded, let model = owner?.model else { return }
        if let observedRevision, observedRevision != model.rulesRevision, pendingRuleChange {
            baseline = editor.string
            pendingRuleChange = false
        }
        observedRevision = model.rulesRevision
        if !model.isBusy && model.rulesValidationError != nil { pendingRuleChange = false }
        if !isDirty && editor.string != model.rulesEditorText {
            changingText = true
            editor.string = model.rulesEditorText
            baseline = model.rulesEditorText
            changingText = false
        }
        if editor.string == model.rulesEditorText { baseline = model.rulesEditorText }
        save.isEnabled = !model.isBusy && isDirty
        reset.isEnabled = !model.isBusy
        importButton.isEnabled = !model.isBusy
        editor.isEditable = !model.isBusy
        let error = model.rulesValidationError ?? model.errorText
        message.stringValue = error ?? (isDirty ? "有未保存的修改" : "规则已保存")
        message.textColor = error == nil ? .secondaryLabelColor : .systemOrange
        message.toolTip = error
    }
    func textDidChange(_ notification: Notification) {
        if !changingText { refresh() }
    }
    @objc private func saveRules() {
        pendingRuleChange = true
        owner?.model.saveRulesText(editor.string)
        refresh()
    }
    @objc private func importRules() {
        chooseFile(title: "导入分流规则") { [weak self] url in
            guard let self else { return }
            self.pendingRuleChange = true
            self.owner?.model.importRulesFile(url)
            self.refresh()
        }
    }
    @objc private func resetRules() {
        pendingRuleChange = true
        owner?.model.resetRules()
        refresh()
    }
}

