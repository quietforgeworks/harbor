import Foundation
import AppKit
import HarborCore

typealias SavedProfile = SubscriptionProfiles
final class AppModel {
    var onChange: (() -> Void)?
    var isConnected = false
    var isBusy = false
    var statusText = "未连接"
    var errorText: String?
    var delayText = "待测"
    private var rateTracker = TrafficRateTracker()
    private var latestRate: TrafficRateSample?
    private var rateSessionID = UUID()
    private var uploadTotal: UInt64?
    private var downloadTotal: UInt64?
    var downloadRateText: String { isConnected ? Self.rate(latestRate?.downloadBytesPerSecond) : "—" }
    var uploadRateText: String { isConnected ? Self.rate(latestRate?.uploadBytesPerSecond) : "—" }
    var downloadTotalText: String { downloadTotal.map(Self.bytes) ?? "—" }
    var uploadTotalText: String { uploadTotal.map(Self.bytes) ?? "—" }
    var trafficText: String { "↓ \(downloadRateText)    ↑ \(uploadRateText)" }
    var trafficTotalsText: String { "↓ \(downloadTotalText)    ↑ \(uploadTotalText)" }
    private static func rate(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        if bytes < 1024 { return String(format: "%.0f B/s", bytes) }
        if bytes < 1048576 { return String(format: "%.1f KB/s", bytes / 1024) }
        return String(format: "%.2f MB/s", bytes / 1048576)
    }
    var rulesValidationError: String?
    var rulesRevision = 0
    var rulesEditorText: String { ConfigBuilder.editableRulesText(profile.ruleOverride ?? ConfigBuilder.rules(mode: .rule, customRules: profile.rules)) }
    var canCancelOperation = false
    var serviceText = "AI 服务 · 待检查"
    private var profile = SavedProfile()
    private var delays = [String: String]()
    private var core: CoreSession?
    private var sessionSubscriptionID: String?
    private var sessionSubscriptionName: String?
    private var sessionDocument: SubscriptionDocument?
    private var sessionRules = [String]()
    private var sessionRuleOverride: [String]?
    private var sessionSelected: String?
    private var ownsInstance = false
    private var startupError: String?
    private var timer: Timer?
    private var operation: Task<Void, Never>?
    private var operationGeneration = UUID()
    private var pendingMode: String?
    private var lastSubscriptionCheck = Date.distantPast
    private var lastAttempts = [String: Date]()
    private var polling = false
    private var lastHealthCheck = Date.distantPast
    private var healthFailures = 0
    private let networkQueue = DispatchQueue(label: "app.harbor.network-settings", qos: .userInitiated)
    private var instanceLock: Int32 = -1
    let directory: URL
    private let proxy: SystemProxyManager
    private var profileURL: URL { directory.appendingPathComponent("profile.json") }
    var subscriptions: [SubscriptionSummary] { profile.subscriptions.map { SubscriptionSummary(id: $0.id, name: $0.name, nodeCount: $0.document?.count ?? 0) } }
    var activeSubscriptionID: String? { profile.activeSubscriptionID }
    var activeSubscriptionName: String { isConnected ? (sessionSubscriptionName ?? profile.active?.name ?? "尚未导入订阅") : (profile.active?.name ?? "尚未导入订阅") }
    var mode: String { pendingMode ?? profile.mode }
    var nodes: [String] { (isConnected ? sessionDocument : profile.document)?.names ?? [] }
    var selectedNode: String? { isConnected ? sessionSelected : profile.selected }
    var autoUpdateEnabled: Bool { profile.automatic }
    var subscriptionSummary: String { profile.document == nil ? "尚未导入订阅" : "已保存 \(profile.document!.count) 个节点" }
    var rulesSummary: String { if let rules = profile.ruleOverride { return "自定义规则 · \(rules.count) 条" }; return profile.rules.isEmpty ? "内置规则 · AI / Google 代理，Apple 与其他直连" : "内置规则 + \(profile.rules.count) 条自定义规则" }
    var updateSummary: String { profile.updated.map { "更新于 " + Self.dateLabel($0, time:true) } ?? "尚未更新" }
    var quotaFraction: Double? { guard let used = profile.quota.used, let total = profile.quota.total, total > 0 else { return nil }; return min(1, Double(used) / Double(total)) }
    var quotaUsageText: String { guard let used = profile.quota.used, let total = profile.quota.total else { return "—" }; return "\(Self.bytes(used)) / \(Self.bytes(total))" }
    var quotaExpiryText: String { profile.quota.expire.map { Self.dateLabel($0, time:false) } ?? "—" }
    var localProxyPort: Int? { isConnected ? core?.port : nil }
    func cancelOperation() { guard canCancelOperation else { return }; operation?.cancel() }
    func copyProxyEnvironment() { guard let port = localProxyPort else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString("export HTTPS_PROXY=http://127.0.0.1:\(port) HTTP_PROXY=http://127.0.0.1:\(port) ALL_PROXY=socks5h://127.0.0.1:\(port)", forType: .string) }
    var quotaText: String {
        let q = profile.quota
        var text = q.used.map { "机场已用 " + Self.bytes($0) } ?? "机场未提供流量信息"
        if let total = q.total { text += " / " + Self.bytes(total) }
        if let expiry = q.expire { text += " · 到期 " + DateFormatter.localizedString(from: expiry, dateStyle: .short, timeStyle: .none) }
        return text
    }
    private static func dateLabel(_ date:Date, time:Bool) -> String { let f = DateFormatter(); f.locale = Locale(identifier:"zh_CN"); f.dateFormat = time ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"; return f.string(from:date) }
    static func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .binary) }
    static var coreExecutable: URL { Bundle.main.resourceURL!.appendingPathComponent("mihomo") }
    init() {
        directory = ProcessInfo.processInfo.environment["HARBOR_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Harbor", isDirectory: true)
        proxy = SystemProxyManager(journalURL: directory.appendingPathComponent("recovery.plist"), executableURL: Bundle.main.executableURL!)
        do {
            try PrivateFiles.directory(directory)
            instanceLock = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else { throw HarborError.message("Harbor 已在运行，请使用菜单栏图标。") }
            ownsInstance = true
            if FileManager.default.fileExists(atPath: profileURL.path) {
                profile = try JSONDecoder().decode(SavedProfile.self, from: Data(contentsOf: profileURL))
                for index in profile.subscriptions.indices where profile.subscriptions[index].name == "订阅机场" {
                    if let account = profile.subscriptions[index].credentialAccount, let source = SecretStore.read(account: account) {
                        profile.subscriptions[index].name = SubscriptionProfile.displayName(for: source)
                    }
                }
            }
        } catch {
            startupError = Self.safeError(error); errorText = startupError; return
        }
        do { try proxy.recoverPending() } catch { errorText = Self.safeError(error) }
        updateTimer()
    }
    private func updateTimer() {
        let interval: TimeInterval = isConnected ? 2 : 60
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.5
    }
    private func networkOperation<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            networkQueue.async { do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) } }
        }
    }
    private func changed() {
        if ownsInstance, startupError == nil { updateTimer() }
        onChange?()
    }
    private static func safeError(_ error: Error) -> String {
        if let e = error as? HarborError { return e.localizedDescription }
        if let e = error as? ConfigError { return e.localizedDescription }
        if let e = error as? SystemProxyError { return e.localizedDescription }
        return "操作未完成，原配置已保留。请稍后重试。"
    }
    private static func importData(from url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: ConfigBuilder.maximumImportBytes + 1) ?? Data()
        guard data.count <= ConfigBuilder.maximumImportBytes else { throw HarborError.message("文件过大，请选择较小的配置文件。") }
        return data
    }
    private func save(_ candidate: SavedProfile) throws { try PrivateFiles.write(JSONEncoder().encode(candidate), to: profileURL); profile = candidate }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard startupError == nil, ownsInstance, !isBusy else { return }
        let generation = UUID()
        operationGeneration = generation
        isBusy = true; errorText = nil; changed()
        operation = Task { @MainActor in
            defer {
                if self.operationGeneration == generation {
                    self.isBusy = false; self.canCancelOperation = false; self.operation = nil; self.changed()
                }
            }
            do { try Task.checkCancellation(); try await work() }
            catch {
                guard self.operationGeneration == generation, !Task.isCancelled else { return }
                self.errorText = Self.safeError(error)
                if !self.isConnected { self.statusText = "未连接" }
            }
        }
    }
    private func makeCore(_ document: SubscriptionDocument, mode: String? = nil, rules: [String]? = nil, ruleOverride: [String]? = nil, useSessionOverride: Bool = false) async throws -> CoreSession {
        let c = try CoreSession(executable: Self.coreExecutable, directory: directory.appendingPathComponent("runtime-" + UUID().uuidString))
        do { try Task.checkCancellation(); try await c.start(document: document, mode: RoutingMode(rawValue: mode ?? profile.mode) ?? .rule, rules: rules ?? profile.rules, ruleOverride: useSessionOverride ? sessionRuleOverride : (ruleOverride ?? profile.ruleOverride)); try Task.checkCancellation(); return c }
        catch { await c.stopAsync(); throw error }
    }
    func toggleConnection() {
        guard startupError == nil, ownsInstance else { return }
        if isConnected {
            operation?.cancel()
            do { try proxy.disconnect(); core?.requestStop(); core = nil; isConnected = false; statusText = "未连接" }
            catch { errorText = Self.safeError(error) }
            changed(); return
        }
        perform {
            if self.isConnected || self.proxy.hasPendingRecovery {
                try self.proxy.disconnect(); self.core?.requestStop(); self.core = nil; self.isConnected = false; self.statusText = "未连接"; return
            }
            try await self.networkOperation { try SystemProxyManager.preflight() }
            guard let document = self.profile.document else { throw HarborError.message("请先在设置中导入订阅。") }
            self.statusText = "正在检查节点"; self.changed()
            let candidate = try await self.makeCore(document)
            do {
                let name = document.names.contains(self.profile.selected ?? "") ? self.profile.selected! : document.names[0]
                let result = await candidate.delay(name)
                try Task.checkCancellation()
                self.delays[name] = result; self.delayText = result
                guard result.hasSuffix(" ms") else { throw HarborError.message("当前节点 HTTPS 检查未通过，未接管系统代理。") }
                try await candidate.select(name)
                try Task.checkCancellation()
                guard candidate.isRunning else { throw HarborError.message("内核已停止，请重试连接。") }
                try await self.networkOperation { try self.proxy.connect(port: candidate.port, corePID: candidate.pid) }
                do {
                    try Task.checkCancellation()
                    guard candidate.isRunning else { throw HarborError.message("内核已停止，请重试连接。") }
                } catch {
                    try await self.networkOperation { try self.proxy.disconnect() }
                    throw error
                }
                self.core = candidate; self.sessionSubscriptionID = self.profile.activeSubscriptionID; self.sessionSubscriptionName = self.profile.active?.name; self.sessionDocument = document; self.sessionRules = self.profile.rules; self.sessionRuleOverride = self.profile.ruleOverride; self.sessionSelected = name; self.healthFailures = 0; self.lastHealthCheck = Date(); self.isConnected = true; self.statusText = "已连接"
                self.rateSessionID = UUID(); self.rateTracker.reset(); self.latestRate = nil; self.uploadTotal = nil; self.downloadTotal = nil
            } catch {
                if self.proxy.hasPendingRecovery { self.core = candidate; self.isConnected = true; self.statusText = "等待恢复代理" }
                else { candidate.requestStop(); self.statusText = "未连接" }
                throw error
            }
        }
    }
    private func preserveRecoveryAfterRollbackFailure() {
        do {
            try proxy.disconnect(); core?.requestStop(); core = nil
            isConnected = false; statusText = "已安全断开"
        } catch {
            statusText = "等待恢复代理"
        }
    }
    func setMode(_ value: String) {
        guard startupError == nil, ownsInstance, value != profile.mode, !isBusy else { return }
        pendingMode = value
        perform {
            defer { self.pendingMode = nil }
            guard let mode = RoutingMode(rawValue: value) else { return }
            var candidate = self.profile; candidate.mode = value
            guard let core = self.core, let doc = self.sessionDocument else { try self.save(candidate); return }
            let original = try core.configuration(doc, mode: RoutingMode(rawValue: self.profile.mode) ?? .rule, rules: self.sessionRules, selected: self.sessionSelected, ruleOverride: self.sessionRuleOverride)
            let config = try core.configuration(doc, mode: mode, rules: self.sessionRules, selected: self.sessionSelected, ruleOverride: self.sessionRuleOverride)
            do {
                _ = try await core.request("/configs?force=true", method: "PUT", body: ["payload": config])
                if let name = self.sessionSelected { try await core.select(name) }
                try Task.checkCancellation()
                try self.save(candidate)
            } catch {
                let failure = error
                do {
                    _ = try await core.request("/configs?force=true", method: "PUT", body: ["payload": original])
                    if let name = self.sessionSelected { try await core.select(name) }
                } catch {
                    self.preserveRecoveryAfterRollbackFailure()
                    throw HarborError.message("模式切换失败，原连接无法完整恢复。请检查连接状态并重连。")
                }
                throw failure
            }
        }
    }
    func selectNode(_ name: String) {
        guard nodes.contains(name), name != profile.selected || (isConnected && name != sessionSelected) else { return }
        perform {
            var candidate = self.profile
            if candidate.document?.names.contains(name) == true { candidate.selected = name }
            guard let core = self.core else { try self.save(candidate); self.delayText = self.delayText(for: name); return }
            guard self.sessionDocument?.names.contains(name) == true else { throw HarborError.message("这是新订阅中的节点，请断开后重新连接。") }
            let result = await core.delay(name)
            try Task.checkCancellation()
            self.delays[name] = result
            guard result.hasSuffix(" ms") else { throw HarborError.message("新节点 HTTPS 检查未通过，已保留当前节点。") }
            do {
                try await core.select(name)
                try Task.checkCancellation()
                try self.save(candidate)
                self.sessionSelected = name; self.healthFailures = 0; self.lastHealthCheck = Date(); self.delayText = result
            } catch {
                let failure = error
                do {
                    guard let previous = self.sessionSelected else { throw HarborError.message("无法恢复原节点。") }
                    try await core.select(previous)
                } catch {
                    self.preserveRecoveryAfterRollbackFailure()
                    throw HarborError.message("节点切换失败，原连接无法完整恢复。请检查连接状态并重连。")
                }
                throw failure
            }
        }
    }
    func delayText(for name: String) -> String { delays[name] ?? "待测" }
    var failoverNodes: [String] { Array((profile.active?.failoverNodes ?? []).filter { nodes.contains($0) }.prefix(5)) }
    func toggleFailoverNode(_ name:String) {
        guard !isBusy, nodes.contains(name) else { return }
        var group = failoverNodes
        if group.contains(name) { group.removeAll { $0 == name } }
        else { guard group.count < 5 else { errorText = "代理组最多包含 5 个节点。"; changed(); return }; group.append(name) }
        do { var candidate = profile; candidate.active?.failoverNodes = group; try save(candidate); errorText = nil }
        catch { errorText = Self.safeError(error) }; changed()
    }
    private func recoverUsingGroup(failed:String) {
        perform {
            guard let core = self.core, self.isConnected else { return }
            self.statusText = "正在寻找备用节点"
            let candidates = self.failoverNodes.filter { $0 != failed }
            var results = [(String,Int)]()
            for name in candidates {
                try Task.checkCancellation()
                let result = await core.delay(name); self.delays[name] = result
                if result.hasSuffix(" ms"), let ms = Int(result.dropLast(3)) { results.append((name,ms)) }
            }
            for (name,_) in results.sorted(by: { $0.1 < $1.1 }) {
                try Task.checkCancellation()
                do {
                    try await core.select(name)
                    let verified = await core.delay(name)
                    try Task.checkCancellation()
                    guard verified.hasSuffix(" ms") else { continue }
                    var candidate = self.profile; candidate.selected = name
                    try self.save(candidate); self.sessionSelected = name; self.healthFailures = 0
                    self.lastHealthCheck = Date(); self.delayText = verified; self.statusText = "已连接"
                    return
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
            try? await core.select(failed)
            try self.proxy.disconnect(); core.requestStop(); self.core = nil; self.isConnected = false
            self.statusText = "已自动断开"; self.errorText = "代理组没有通过校验的备用节点，已恢复原网络。"
        }
    }
    func testGroupNode(_ name:String) {
        guard failoverNodes.contains(name) else { return }
        perform {
            guard let document = self.isConnected ? self.sessionDocument : self.profile.document else { return }
            let temporary = self.core == nil
            let testingCore: CoreSession
            if let live = self.core { testingCore = live } else { testingCore = try await self.makeCore(document) }
            defer { if temporary { testingCore.requestStop() } }
            self.delays[name] = "检测中"; self.changed()
            let result = await testingCore.delay(name); try Task.checkCancellation()
            self.delays[name] = result
            if self.selectedNode == name { self.delayText = result }
        }
    }
    func testCurrentNode() {
        perform {
            guard let name = self.selectedNode, let document = (self.isConnected ? self.sessionDocument : self.profile.document) else { throw HarborError.message("请先选择一个节点。") }
            let previousDelay = self.delays[name]
            self.canCancelOperation = true; self.delayText = "检测中"; self.delays[name] = "检测中"; self.changed()
            defer { self.canCancelOperation = false; if self.delays[name] == "检测中" { self.delays[name] = previousDelay }; self.delayText = self.delayText(for:name) }
            let testCore: CoreSession
            let temporary: Bool
            if let live = self.core, self.isConnected { testCore = live; temporary = false }
            else { testCore = try await self.makeCore(document); temporary = true }
            defer { if temporary { testCore.requestStop() } }
            try Task.checkCancellation()
            let result = await testCore.delay(name)
            try Task.checkCancellation()
            self.delays[name] = result; self.delayText = result
        }
    }
    func testNodes() {
        perform {
            self.canCancelOperation = true
            self.changed()
            defer { self.canCancelOperation = false }
            guard let document = (self.isConnected ? self.sessionDocument : self.profile.document) else { throw HarborError.message("请先导入订阅。") }
            let candidate = try await self.makeCore(document, rules: self.isConnected ? self.sessionRules : nil, useSessionOverride: self.isConnected); defer { candidate.requestStop() }
            let previousDelays = self.delays
            for name in document.names { self.delays[name] = "检测中" }
            self.changed()
            var publication: Task<Void, Never>?
            defer {
                publication?.cancel()
                for name in document.names where self.delays[name] == "检测中" {
                    self.delays[name] = previousDelays[name]
                }
                self.delayText = self.selectedNode.map { self.delayText(for: $0) } ?? "待测"
            }
            try await NodeTester.run(names: document.names, measure: { name in
                await candidate.delay(name)
            }, onResult: { @MainActor name, value in
                self.delays[name] = value
                self.delayText = self.selectedNode.map { self.delayText(for: $0) } ?? "待测"
                if publication == nil {
                    publication = Task { @MainActor in
                        do { try await Task.sleep(nanoseconds: 100_000_000) }
                        catch { return }
                        publication = nil
                        self.changed()
                    }
                }
            })
        }
    }
    func importSubscription(_ value: String) {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = profile.subscriptions.first { item in
            guard let account = item.credentialAccount else { return false }
            return SecretStore.read(account: account) == source
        }
        fetchSubscription(source, existingID: existing?.id, activate: !isConnected)
    }
    private func fetchSubscription(_ source: String, existingID: String?, activate: Bool) {
        perform {
            let attemptID = existingID ?? UUID().uuidString
            self.lastAttempts[attemptID] = Date()
            let (document, quota) = try await SubscriptionClient.fetch(source)
            try Task.checkCancellation()
            let check = try await self.makeCore(document); await check.stopAsync()
            try Task.checkCancellation()
            var candidate = self.profile
            var entry = candidate.subscriptions.first { $0.id == existingID }
                ?? SubscriptionProfile(id: attemptID, name: SubscriptionProfile.displayName(for: source))
            let previousAccount = entry.credentialAccount
            let account = "subscription-" + UUID().uuidString
            try SecretStore.save(source, account: account)
            entry.credentialAccount = account
            entry.document = document; entry.quota = quota; entry.updated = Date()
            if !document.names.contains(entry.selected ?? "") { entry.selected = document.names.first }
            candidate.upsert(entry, activate: activate)
            do { try self.save(candidate) } catch { try? SecretStore.delete(account: account); throw error }
            if let previousAccount { try? SecretStore.delete(account: previousAccount) }
            if !self.isConnected { self.delays = [:]; self.delayText = "待测" }
            if self.isConnected { self.errorText = "订阅已保存，当前连接保持不变。可在机场列表中切换应用。" }
        }
    }
    func selectSubscription(_ id: String) {
        guard let entry = profile.subscriptions.first(where: { $0.id == id }),
              id != profile.activeSubscriptionID || (isConnected && (id != sessionSubscriptionID || entry.document != sessionDocument)) else { return }
        perform {
            var candidate = self.profile; candidate.activeSubscriptionID = id
            guard let core = self.core, self.isConnected else {
                try self.save(candidate); self.delays = [:]; self.delayText = "待测"; return
            }
            guard let document = entry.document, let oldDocument = self.sessionDocument else { throw HarborError.message("机场尚无可用节点。") }
            let selected = document.names.contains(entry.selected ?? "") ? entry.selected! : document.names[0]
            let check = try await self.makeCore(document, rules: self.sessionRules, useSessionOverride: true)
            let result = await check.delay(selected)
            await check.stopAsync()
            try Task.checkCancellation()
            guard result.hasSuffix(" ms") else { throw HarborError.message("机场节点 HTTPS 检查未通过，已保留当前连接。") }
            let mode = RoutingMode(rawValue: self.profile.mode) ?? .rule
            let original = try core.configuration(oldDocument, mode: mode, rules: self.sessionRules, selected: self.sessionSelected, ruleOverride: self.sessionRuleOverride)
            let replacement = try core.configuration(document, mode: mode, rules: self.sessionRules, selected: selected, ruleOverride: self.sessionRuleOverride)
            do {
                _ = try await core.request("/configs?force=true", method: "PUT", body: ["payload": replacement])
                try await core.select(selected)
                let liveResult = await core.delay(selected)
                guard liveResult.hasSuffix(" ms") else { throw HarborError.message("机场切换后的 HTTPS 检查失败，已恢复原连接。") }
                try Task.checkCancellation()
                candidate.selected = selected
                try self.save(candidate)
                self.sessionDocument = document; self.sessionSelected = selected
                self.sessionSubscriptionID = id; self.sessionSubscriptionName = entry.name
                self.delays = [selected: liveResult]; self.delayText = liveResult
                self.healthFailures = 0; self.lastHealthCheck = Date()
            } catch {
                let failure = error
                do {
                    _ = try await core.request("/configs?force=true", method: "PUT", body: ["payload": original])
                    if let previous = self.sessionSelected { try await core.select(previous) }
                } catch {
                    self.preserveRecoveryAfterRollbackFailure()
                    throw HarborError.message("机场切换失败，原连接无法完整恢复。请检查连接状态并重连。")
                }
                throw failure
            }
        }
    }
    func renameSubscription(_ id: String, name: String) {
        guard startupError == nil, ownsInstance, !isBusy else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("://"), let index = profile.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        do {
            var candidate = profile; candidate.subscriptions[index].name = String(name.prefix(80)); try save(candidate)
            if sessionSubscriptionID == id { sessionSubscriptionName = candidate.subscriptions[index].name }
        } catch { errorText = Self.safeError(error) }
        changed()
    }
    func removeSubscription(_ id: String) {
        guard startupError == nil, ownsInstance, !isBusy,
              let entry = profile.subscriptions.first(where: { $0.id == id }) else { return }
        guard !isConnected || (id != sessionSubscriptionID && id != profile.activeSubscriptionID) else {
            errorText = "请先切换机场或断开连接，再移除此机场。"; changed(); return
        }
        do {
            var candidate = profile; candidate.remove(id); try save(candidate)
            if let account = entry.credentialAccount { try? SecretStore.delete(account: account) }
            if id == sessionSubscriptionID || !isConnected { delays = [:]; delayText = "待测" }
        } catch { errorText = Self.safeError(error) }
        changed()
    }
    func repairNodeDNS(from url: URL) {
        perform {
            guard let document = self.profile.document else { throw HarborError.message("请先导入订阅。") }
            let data = try Self.importData(from: url)
            guard data.count <= ConfigBuilder.maximumImportBytes,
                  let text = String(data: data, encoding: .utf8) else {
                throw HarborError.message("参考配置过大或不是 UTF-8 文件。")
            }
            let reference = try ConfigBuilder.parseSubscription(text)
            let repaired = try ConfigBuilder.withNodeDNS(document: document, reference: reference)
            let check = try await self.makeCore(repaired)
            await check.stopAsync()
            try Task.checkCancellation()
            var candidate = self.profile
            candidate.document = repaired
            try self.save(candidate)
        }
    }
    func updateSubscription() {
        guard let id = profile.activeSubscriptionID else { errorText = "请先导入订阅链接。"; changed(); return }
        updateSubscription(id)
    }
    private func updateSubscription(_ id: String) {
        guard startupError == nil, ownsInstance, !isBusy else { return }
        lastAttempts[id] = Date()
        guard let entry = profile.subscriptions.first(where: { $0.id == id }), let account = entry.credentialAccount,
              let value = SecretStore.read(account: account) else { errorText = "此机场没有可更新的订阅链接。"; changed(); return }
        fetchSubscription(value, existingID: id, activate: false)
    }
    func importNodesFile(_ url: URL) {
        perform {
            let data = try Self.importData(from: url); guard data.count <= ConfigBuilder.maximumImportBytes, let text = String(data: data, encoding: .utf8) else { throw HarborError.message("文件过大或不是 UTF-8 配置。") }
            let document = try ConfigBuilder.parseSubscription(text); let check = try await self.makeCore(document); await check.stopAsync()
            try Task.checkCancellation()
            let entry = SubscriptionProfile(name: url.deletingPathExtension().lastPathComponent, document: document,
                                            selected: document.names.first, automatic: false, updated: Date())
            var candidate = self.profile; candidate.upsert(entry, activate: !self.isConnected)
            try self.save(candidate)
            if !self.isConnected { self.delays = [:]; self.delayText = "待测" }
            if self.isConnected { self.errorText = "本地机场已保存，可在机场列表中切换。" }
        }
    }
    func importRulesFile(_ url: URL) {
        do {
            let data = try Self.importData(from: url)
            guard data.count <= ConfigBuilder.maximumImportBytes, let text = String(data:data,encoding:.utf8) else { throw HarborError.message("规则文件过大或不是 UTF-8 文件。") }
            if (try? ConfigBuilder.parseEditableRules(text)) != nil { saveRulesText(text) }
            else {
                let custom = try ConfigBuilder.parseRules(text)
                saveRulesText(ConfigBuilder.editableRulesText(ConfigBuilder.rules(mode:.rule,customRules:custom)))
            }
        } catch { rulesValidationError = Self.safeError(error); errorText = rulesValidationError; changed() }
    }
    func saveRulesText(_ text: String) {
        guard !isBusy else { return }
        rulesValidationError = nil
        perform {
            do { try await self.applyRuleOverride(ConfigBuilder.parseEditableRules(text)) }
            catch { self.rulesValidationError = Self.safeError(error); throw error }
        }
    }
    @MainActor private func applyRuleOverride(_ rules: [String]?) async throws {
        var candidate = profile; candidate.ruleOverride = rules; candidate.rules = []
        let doc = isConnected ? sessionDocument : profile.document
        if let doc {
            let check = try CoreSession(executable:Self.coreExecutable,directory:directory.appendingPathComponent("rules-check-" + UUID().uuidString))
            do { try await check.start(document:doc,mode:.rule,rules:[],ruleOverride:rules); await check.stopAsync() }
            catch { await check.stopAsync(); throw error }
            try Task.checkCancellation()
        }
        if let core, isConnected, let doc = sessionDocument {
            let mode = RoutingMode(rawValue:profile.mode) ?? .rule
            let original = try core.configuration(doc,mode:mode,rules:sessionRules,selected:sessionSelected,ruleOverride:sessionRuleOverride)
            let next = try core.configuration(doc,mode:mode,rules:[],selected:sessionSelected,ruleOverride:rules)
            do {
                _ = try await core.request("/configs?force=true",method:"PUT",body:["payload":next])
                if let name = sessionSelected { try await core.select(name) }
                try Task.checkCancellation()
                try save(candidate); sessionRules = []; sessionRuleOverride = rules
            } catch {
                let failure = error
                do { _ = try await core.request("/configs?force=true",method:"PUT",body:["payload":original]); if let name = sessionSelected { try await core.select(name) } }
                catch { preserveRecoveryAfterRollbackFailure() }
                throw failure
            }
        } else { try save(candidate) }
        rulesRevision += 1; rulesValidationError = nil
    }
    func testServices() {
        perform {
            guard let doc = (self.isConnected ? self.sessionDocument : self.profile.document), let name = self.selectedNode else { throw HarborError.message("请先导入订阅并选择节点。") }
            let check = try await self.makeCore(doc, rules: self.isConnected ? self.sessionRules : nil, useSessionOverride: self.isConnected); defer { check.requestStop() }
            try await check.select(name)
            let previousServiceText = self.serviceText
            defer { if Task.isCancelled { self.serviceText = previousServiceText } }
            self.serviceText = "AI 服务 · 正在检查"; self.changed()
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": check.port, "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": check.port]
            config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 15
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            var lines = [String]()
            for (title, url) in [("ChatGPT", "https://chatgpt.com/"), ("Claude", "https://claude.ai/"), ("Gemini", "https://gemini.google.com/app")] {
                try Task.checkCancellation()
                do {
                    var request = URLRequest(url: URL(string: url)!); request.httpMethod = "HEAD"
                    let (_, response) = try await session.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    lines.append("\(title) · " + ((200..<400).contains(status) ? "HTTPS 可达" : "HTTP \(status) · 受限或需浏览器验证"))
                } catch { lines.append("\(title) · HTTPS 失败或超时") }
                try Task.checkCancellation()
                self.serviceText = lines.joined(separator: "\n"); self.changed()
            }
        }
    }
    func resetRules() {
        guard !isBusy else { return }; rulesValidationError = nil
        perform { do { try await self.applyRuleOverride(nil) } catch { self.rulesValidationError = Self.safeError(error); throw error } }
    }
    func setAutoUpdate(_ enabled: Bool) { guard startupError == nil, ownsInstance, !isBusy else { return }; do { var candidate = profile; candidate.automatic = enabled; try save(candidate) } catch { errorText = Self.safeError(error) }; changed() }
    private func tick() {
        guard startupError == nil, ownsInstance else { return }
        if let core, !core.isRunning, isConnected, !isBusy {
            do { try proxy.disconnect(); core.requestStop(); self.core = nil; isConnected = false; statusText = "已自动断开"; errorText = "内核已停止，已恢复原系统代理。" }
            catch { errorText = "内核异常，系统代理恢复未完成。请点击断开重试。" }
            changed()
        }
        if let core, isConnected, !polling {
            polling = true
            let generation = operationGeneration
            let subscriptionID = sessionSubscriptionID
            Task { @MainActor in
                defer { self.polling = false }
                let values = try? await core.request("/connections")
                guard self.core === core, self.isConnected else { return }
                if let values, let down = values["downloadTotal"] as? UInt64, let up = values["uploadTotal"] as? UInt64 {
                    self.uploadTotal = up; self.downloadTotal = down
                    self.latestRate = self.rateTracker.record(uploadTotal: up, downloadTotal: down, at: ProcessInfo.processInfo.systemUptime, sessionID: self.rateSessionID)
                    self.changed()
                } else {
                    self.rateTracker.reset(); self.latestRate = nil; self.changed()
                }
                guard !self.isBusy, self.operationGeneration == generation,
                      Date().timeIntervalSince(self.lastHealthCheck) >= 30, let name = self.sessionSelected else { return }
                self.lastHealthCheck = Date()
                let result = await core.delay(name)
                guard self.core === core, self.isConnected, !self.isBusy, self.sessionSelected == name,
                      self.sessionSubscriptionID == subscriptionID, self.operationGeneration == generation else { return }
                self.delays[name] = result; self.delayText = result
                self.healthFailures = result.hasSuffix(" ms") ? 0 : self.healthFailures + 1
                if self.healthFailures >= 3 { self.recoverUsingGroup(failed:name) }
                self.changed()
            }
        }
        guard Date().timeIntervalSince(lastSubscriptionCheck) >= 60 else { return }
        lastSubscriptionCheck = Date()
        if !CommandLine.arguments.contains("--capture-ui"), !isBusy,
           let due = profile.subscriptions.first(where: {
               $0.credentialAccount != nil && $0.automatic
                   && Date().timeIntervalSince($0.updated ?? .distantPast) >= Double($0.quota.updateHours ?? 24) * 3600
                   && Date().timeIntervalSince(lastAttempts[$0.id] ?? .distantPast) >= 900
           }) { updateSubscription(due.id) }
    }
    func shutdown() -> Bool {
        guard ownsInstance else { return true }
        guard !isBusy else { errorText = "请等待当前操作结束后退出。"; changed(); return false }
        do { try proxy.disconnect(); core?.requestStop(); core = nil; timer?.invalidate(); return true }
        catch { errorText = "代理恢复未完成，已保留内核运行。请点击断开重试。"; changed(); return false }
    }
    @MainActor func runFunctionalCheck(upstreamPort: Int) async throws -> [String:Any] {
        guard ProcessInfo.processInfo.environment["HARBOR_DATA_DIR"] != nil, !proxy.hasPendingRecovery, profile.subscriptions.isEmpty else { throw HarborError.message("检查必须使用空白隔离目录。") }
        let docA = try ConfigBuilder.parseSubscription("proxies: [{name: Alpha node, type: http, server: 127.0.0.1, port: \(upstreamPort)}, {name: Alternate node, type: http, server: 127.0.0.1, port: \(upstreamPort)}]")
        let docB = try ConfigBuilder.parseSubscription("proxies: [{name: Beta node, type: http, server: 127.0.0.1, port: \(upstreamPort)}, {name: Other node, type: http, server: 127.0.0.1, port: \(upstreamPort)}]")
        let bad = try ConfigBuilder.parseSubscription("proxies: [{name: Unavailable node, type: http, server: 127.0.0.1, port: 9}]")
        var fixture = SavedProfile()
        fixture.upsert(SubscriptionProfile(id:"alpha",name:"Alpha",document:docA,selected:"Alpha node",automatic:false),activate:true)
        fixture.upsert(SubscriptionProfile(id:"beta",name:"Beta",document:docB,selected:"Beta node",automatic:false),activate:false)
        fixture.upsert(SubscriptionProfile(id:"bad",name:"Unavailable",document:bad,selected:"Unavailable node",automatic:false),activate:false)
        try save(fixture)
        let testCore = try await makeCore(docA)
        self.core = testCore; self.isConnected = true; self.sessionDocument = docA; self.sessionSelected = "Alpha node"; self.sessionSubscriptionID = "alpha"; self.sessionSubscriptionName = "Alpha"
        defer { testCore.requestStop(); self.core = nil; self.isConnected = false; timer?.invalidate() }
        @MainActor func idle() async throws { for _ in 0..<300 { if !self.isBusy { return }; try await Task.sleep(nanoseconds:100_000_000) }; throw HarborError.message("隔离检查超时。") }
        let originalPID = testCore.pid
        if CommandLine.arguments.contains("--failover-only") {
            toggleFailoverNode("Alpha node"); toggleFailoverNode("Alternate node")
            recoverUsingGroup(failed:"Alpha node"); try await idle()
            return ["automaticFailover":sessionSelected == "Alternate node", "sameCore":core?.pid == originalPID,"connected":isConnected,"groupCount":failoverNodes.count,"systemProxyChanged":proxy.hasPendingRecovery]
        }
        selectSubscription("beta"); try await idle()
        let switchOK = profile.activeSubscriptionID == "beta" && sessionSubscriptionID == "beta" && sessionSelected == "Beta node" && core?.pid == originalPID
        selectSubscription("bad"); try await idle()
        let rollbackOK = profile.activeSubscriptionID == "beta" && sessionSelected == "Beta node" && errorText != nil
        let before = rulesEditorText
        saveRulesText("rules: [MATCH,UNKNOWN]"); try await idle()
        let invalidRulesOK = rulesEditorText == before && rulesValidationError != nil
        let edited = ConfigBuilder.rules(mode:.rule) .dropLast() + ["DOMAIN,route-check.example,REJECT", "MATCH,DIRECT"]
        saveRulesText(ConfigBuilder.editableRulesText(Array(edited))); try await idle()
        let savedRulesOK = rulesRevision == 1 && profile.ruleOverride?.contains("DOMAIN,route-check.example,REJECT") == true
        let runtime = try await testCore.request("/rules")
        let coreRulesOK = (runtime["rules"] as? [[String:Any]] ?? []).contains { $0["payload"] as? String == "route-check.example" && $0["proxy"] as? String == "REJECT" }
        resetRules(); try await idle()
        let resetOK = profile.ruleOverride == nil && rulesRevision == 2
        testCurrentNode(); try await idle()
        let singleTestOK = delays.keys.sorted() == ["Beta node"] && delayText.hasSuffix(" ms")
        testNodes(); try await Task.sleep(nanoseconds:50_000_000); cancelOperation(); try await idle()
        let cancellationOK = !canCancelOperation && !isBusy && core?.pid == originalPID && sessionSelected == "Beta node" && isConnected
        toggleFailoverNode("Beta node"); toggleFailoverNode("Other node")
        recoverUsingGroup(failed:"Beta node"); try await idle()
        let failoverOK = sessionSelected == "Other node" && isConnected && core?.pid == originalPID
        return ["automaticFailoverPreservesCore":failoverOK,"cancelTestPreservesConnection":cancellationOK,"airportSwitchWithoutCoreRestart":switchOK,"unavailableAirportPreservesSession":rollbackOK,"invalidRuleEditPreservesConfiguration":invalidRulesOK,"fullRuleEditSaved":savedRulesOK,"editedRulePresentInCore":coreRulesOK,"resetRestoresDefaults":resetOK,"currentNodeTestOnlyOneResult":singleTestOK,"systemProxyChanged":proxy.hasPendingRecovery]
    }

}
