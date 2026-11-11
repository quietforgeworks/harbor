import Foundation
import SystemConfiguration
import Security
import Darwin

public enum SystemProxyError: LocalizedError {
    case conflict(String), unavailable, authorization, journal, guardUnavailable, changed, pendingRecovery
    public var errorDescription: String? {
        switch self {
        case .conflict(let reason): return reason
        case .unavailable: return "无法读写系统代理设置。"
        case .authorization: return "未获得网络设置权限；系统代理未接管。"
        case .journal: return "无法保存代理恢复记录；系统代理未接管。"
        case .guardUnavailable: return "自动恢复进程未就绪；系统代理未接管。"
        case .changed: return "网络设置已变化，请重试。"
        case .pendingRecovery: return "上次代理设置尚待恢复，请先恢复再连接。"
        }
    }
}

/// The store contract serializes read/compare/write under one configuration lock.
/// Test stores implement this contract without touching the machine's network.
public struct ProxyService {
    public let id: String
    public let name: String
    public let connectEligible: Bool
    public var configuration: [String: Any]
    public init(id: String, name: String, configuration: [String: Any], connectEligible: Bool = true) {
        self.id = id; self.name = name; self.configuration = configuration; self.connectEligible = connectEligible
    }
}

public protocol ProxyStore: AnyObject {
    func read() throws -> [ProxyService]
    func transaction(_ transform: ([ProxyService]) throws -> [String: [String: Any]]) throws
}

public struct ProxyJournal: Codable {
    public struct Entry: Codable {
        public let id: String
        public let original: Data
        public let applied: Data
    }
    public let version: Int
    public let token: String
    public let parentPID: Int32
    public let corePID: Int32
    public let created: Date
    public let entries: [Entry]
}

/// Pure ownership and rollback logic. Only HTTP(S) triples are owned by Harbor.
/// SOCKS, PAC, bypass lists, DNS, and later third-party edits remain untouched.
public enum ProxyTransaction {
    static let groups = [["HTTPEnable", "HTTPProxy", "HTTPPort"], ["HTTPSEnable", "HTTPSProxy", "HTTPSPort"]]
    static let enableKeys = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
    public static func hasEnabledProxy(_ dictionary: [String: Any]) -> Bool {
        enableKeys.contains { (dictionary[$0] as? NSNumber)?.boolValue == true }
    }
    static func encode(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }
    static func decode(_ data: Data) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { throw SystemProxyError.journal }
        return value
    }
    static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs else { return rhs == nil }
        guard let rhs else { return false }
        return NSDictionary(dictionary: ["v": lhs]).isEqual(to: ["v": rhs])
    }
    public static func prepare(services: [ProxyService], port: Int, parentPID: Int32, corePID: Int32) throws -> ProxyJournal {
        let eligible = services.filter(\.connectEligible)
        guard (1024...65535).contains(port), !eligible.isEmpty else { throw SystemProxyError.unavailable }
        let entries = try eligible.map { service -> ProxyJournal.Entry in
            guard !hasEnabledProxy(service.configuration) else {
                throw SystemProxyError.conflict("已有系统代理正在使用中。请先在原代理软件中断开，再连接 Harbor。")
            }
            var applied = service.configuration
            for group in groups { applied[group[0]] = 1; applied[group[1]] = "127.0.0.1"; applied[group[2]] = port }
            return .init(id: service.id, original: try encode(service.configuration), applied: try encode(applied))
        }
        return .init(version: 1, token: UUID().uuidString, parentPID: parentPID, corePID: corePID, created: Date(), entries: entries)
    }
    public static func apply(_ journal: ProxyJournal, store: ProxyStore) throws {
        try store.transaction { services in
            let eligible = services.filter(\.connectEligible)
            guard Set(eligible.map(\.id)) == Set(journal.entries.map(\.id)),
                  !eligible.contains(where: { hasEnabledProxy($0.configuration) }) else { throw SystemProxyError.changed }
            var changes: [String: [String: Any]] = [:]
            for entry in journal.entries {
                guard let current = services.first(where: { $0.id == entry.id }), NSDictionary(dictionary: current.configuration).isEqual(to: try decode(entry.original)) else { throw SystemProxyError.changed }
                changes[entry.id] = try decode(entry.applied)
            }
            return changes
        }
    }
    public static func restore(_ journal: ProxyJournal, store: ProxyStore) throws {
        try store.transaction { services in
            var changes: [String: [String: Any]] = [:]
            for entry in journal.entries {
                guard let service = services.first(where: { $0.id == entry.id }) else { continue }
                let applied = try decode(entry.applied), original = try decode(entry.original)
                var result = service.configuration
                for group in groups where group.allSatisfy({ equal(result[$0], applied[$0]) }) {
                    for key in group { result[key] = original[key] }
                }
                if !NSDictionary(dictionary: result).isEqual(to: service.configuration) { changes[entry.id] = result }
            }
            return changes
        }
    }
    public static func ownsAnySettings(_ journal: ProxyJournal, services: [ProxyService]) throws -> Bool {
        for entry in journal.entries {
            guard let current = services.first(where: { $0.id == entry.id }) else { continue }
            let applied = try decode(entry.applied)
            if groups.contains(where: { group in group.allSatisfy { equal(current.configuration[$0], applied[$0]) } }) { return true }
        }
        return false
    }
}

final class MacProxyStore: ProxyStore {
    private let preferences: SCPreferences
    init(authorization: AuthorizationRef? = nil) throws {
        guard let value = SCPreferencesCreateWithAuthorization(nil, "Harbor" as CFString, nil, authorization) else { throw SystemProxyError.unavailable }
        preferences = value
    }
    private func services() throws -> [ProxyService] {
        guard let set = SCNetworkSetCopyCurrent(preferences), let active = SCNetworkSetCopyServices(set) as? [SCNetworkService],
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else { throw SystemProxyError.unavailable }
        let activeIDs = Set(active.compactMap { SCNetworkServiceGetServiceID($0) as String? })
        return services.compactMap { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  [kSCNetworkInterfaceTypeEthernet as String, kSCNetworkInterfaceTypeIEEE80211 as String].contains(type),
                  let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
            let path = "/NetworkServices/\(id)/Proxies" as CFString
            let configuration = SCPreferencesPathGetValue(preferences, path) as? [String: Any] ?? [:]
            return ProxyService(id: id, name: SCNetworkServiceGetName(service) as String? ?? "网络", configuration: configuration,
                                connectEligible: activeIDs.contains(id) && SCNetworkServiceGetEnabled(service))
        }
    }
    func read() throws -> [ProxyService] { SCPreferencesSynchronize(preferences); return try services() }
    func transaction(_ transform: ([ProxyService]) throws -> [String: [String: Any]]) throws {
        SCPreferencesSynchronize(preferences)
        guard SCPreferencesLock(preferences, false) else { throw SystemProxyError.unavailable }
        defer { SCPreferencesUnlock(preferences) }
        // Refresh again after acquiring the configuration lock so the transform
        // compares against the state actually protected by that lock.
        SCPreferencesSynchronize(preferences)
        let current = try services()
        let changes = try transform(current)
        guard !changes.isEmpty else { return }
        do {
            for (id, configuration) in changes {
                guard current.contains(where: { $0.id == id }), SCPreferencesPathSetValue(preferences, "/NetworkServices/\(id)/Proxies" as CFString, configuration as CFDictionary) else { throw SystemProxyError.unavailable }
            }
            guard SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else { throw SystemProxyError.unavailable }
        } catch {
            // Discard any uncommitted in-memory changes. The durable journal remains
            // available if Commit succeeded but Apply failed.
            SCPreferencesSynchronize(preferences)
            throw error
        }
    }
}

private final class NetworkAuthorization {
    let ref: AuthorizationRef
    init(interaction: Bool) throws {
        var value: AuthorizationRef?
        let status = "system.preferences.network".withCString { right -> OSStatus in
            var item = AuthorizationItem(name: right, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                var flags: AuthorizationFlags = [.extendRights, .preAuthorize]
                if interaction { flags.insert(.interactionAllowed) }
                return AuthorizationCreate(&rights, nil, flags, &value)
            }
        }
        guard status == errAuthorizationSuccess, let value else { throw SystemProxyError.authorization }
        ref = value
    }
    init(external: Data) throws {
        var form = AuthorizationExternalForm()
        guard external.count == MemoryLayout<AuthorizationExternalForm>.size else { throw SystemProxyError.authorization }
        _ = withUnsafeMutableBytes(of: &form) { external.copyBytes(to: $0) }
        var value: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &value) == errAuthorizationSuccess, let value else { throw SystemProxyError.authorization }
        ref = value
    }
    func external() throws -> Data {
        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(ref, &form) == errAuthorizationSuccess else { throw SystemProxyError.authorization }
        return withUnsafeBytes(of: form) { Data($0) }
    }
    func verifyReusableRight() throws {
        let status = "system.preferences.network".withCString { right -> OSStatus in
            var item = AuthorizationItem(name: right, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                // Unlike preauthorization, this requires a currently usable
                // imported right, without presenting UI from the guardian.
                return AuthorizationCopyRights(ref, &rights, nil, [.extendRights], nil)
            }
        }
        guard status == errAuthorizationSuccess else { throw SystemProxyError.authorization }
    }
    deinit { AuthorizationFree(ref, []) }
}

enum JournalIO {
    /// This lock inode is never unlinked. Every publisher, remover, and restorer
    /// uses it, so old guardians cannot race a new connection using the same port.
    static func withLock<T>(at url: URL, _ operation: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw SystemProxyError.journal }
        let fd = open(url.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SystemProxyError.journal }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o077) == 0 else { throw SystemProxyError.journal }
        let deadline = Date().addingTimeInterval(8)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard (errno == EWOULDBLOCK || errno == EINTR), Date() < deadline else { throw SystemProxyError.journal }
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
    /// Caller must hold the stable journal lock throughout publication/apply.
    static func write(_ journal: ProxyJournal, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw SystemProxyError.journal }
        let temporary = directory.appendingPathComponent(".recovery-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SystemProxyError.journal }
        defer { close(fd); unlink(temporary.path) }
        let data = try PropertyListEncoder().encode(journal)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw SystemProxyError.journal }
                offset += count
            }
        }
        // Atomic no-replace publication: a second instance cannot overwrite a
        // live owner's recovery record between preflight and publication.
        guard fsync(fd) == 0, link(temporary.path, url.path) == 0 else { throw SystemProxyError.journal }
        let dfd = open(directory.path, O_RDONLY); if dfd >= 0 { _ = fsync(dfd); close(dfd) }
    }
    static func read(_ url: URL) throws -> ProxyJournal {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG, (info.st_mode & 0o077) == 0, info.st_size < 2_000_000 else { throw SystemProxyError.journal }
        let journal = try PropertyListDecoder().decode(ProxyJournal.self, from: Data(contentsOf: url))
        guard journal.version == 1, journal.parentPID > 1, journal.corePID > 1 else { throw SystemProxyError.journal }
        return journal
    }
    static func remove(_ url: URL, token: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard try read(url).token == token else { throw SystemProxyError.changed }
        try FileManager.default.removeItem(at: url)
    }
    /// Safe for a stale guardian: token validation, restore, and removal form one
    /// locked operation. A newer connection can neither be restored nor removed.
    @discardableResult
    static func restoreIfCurrent(_ url: URL, token: String, store: ProxyStore) throws -> Bool {
        try withLock(at: url) {
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            let current = try read(url)
            guard current.token == token else { return false }
            try ProxyTransaction.restore(current, store: store)
            try remove(url, token: token)
            return true
        }
    }
}

public final class SystemProxyManager {
    public let journalURL: URL
    private let executableURL: URL
    private var authorization: NetworkAuthorization?
    private var guardProcess: Process?
    public private(set) var isConnected = false
    public var hasPendingRecovery: Bool { FileManager.default.fileExists(atPath: journalURL.path) }
    public init(journalURL: URL, executableURL: URL) { self.journalURL = journalURL; self.executableURL = executableURL }

    /// Read-only. Merely calling preflight never requests authorization.
    public static func preflight() throws {
        if let proxy = SCDynamicStoreCopyProxies(nil) as? [String: Any], ProxyTransaction.hasEnabledProxy(proxy) {
            throw SystemProxyError.conflict("已有系统代理正在使用中。请先在原代理软件中断开，再连接 Harbor。")
        }
        let services = try MacProxyStore().read()
        if services.contains(where: { $0.connectEligible && ProxyTransaction.hasEnabledProxy($0.configuration) }) {
            throw SystemProxyError.conflict("网络服务已有代理配置。请先停用原代理，再连接 Harbor。")
        }
        // A plain utun interface can belong to Apple services; only an actual
        // public route using a tunnel is considered a conflicting network owner.
        for routeArguments in [["-n", "get", "1.1.1.1"], ["-n", "get", "8.8.8.8"], ["-n", "get", "-inet6", "2606:4700:4700::1111"]] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/sbin/route")
            process.arguments = routeArguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            for line in output.split(separator: "\n") where line.contains("interface:") {
                let interface = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
                if ["utun", "tun", "ppp", "ipsec"].contains(where: interface.hasPrefix) {
                    throw SystemProxyError.conflict("检测到 VPN／TUN 正在接管网络。请先断开原软件，再连接 Harbor。")
                }
            }
        }
    }

    public func connect(port: Int, corePID: Int32) throws {
        guard !hasPendingRecovery, !isConnected else { throw SystemProxyError.pendingRecovery }
        try Self.preflight()
        let authorization = try NetworkAuthorization(interaction: true)
        let store = try MacProxyStore(authorization: authorization.ref)
        try JournalIO.withLock(at: journalURL) {
            guard !hasPendingRecovery else { throw SystemProxyError.pendingRecovery }
            // Repeat after authorization: another app may have changed the network.
            try Self.preflight()
            let journal = try ProxyTransaction.prepare(services: store.read(), port: port, parentPID: getpid(), corePID: corePID)
            try JournalIO.write(journal, to: journalURL)
            self.authorization = authorization
            do {
                // Guardian announces READY before ever acquiring this file lock.
                try startGuard(authorization: authorization)
                try ProxyTransaction.apply(journal, store: store)
                isConnected = true
            } catch {
                do {
                    try ProxyTransaction.restore(journal, store: store)
                    try JournalIO.remove(journalURL, token: journal.token)
                    guardProcess?.terminate(); guardProcess = nil; self.authorization = nil
                } catch { /* Keep the guard and journal alive for recovery. */ }
                throw error
            }
        }
    }

    public func disconnect() throws {
        try JournalIO.withLock(at: journalURL) { try disconnectLocked() }
    }

    private func disconnectLocked() throws {
        guard hasPendingRecovery else { isConnected = false; guardProcess?.terminate(); guardProcess = nil; authorization = nil; return }
        let journal = try JournalIO.read(journalURL)
        guard journal.parentPID == getpid() || kill(journal.parentPID, 0) != 0 else { throw SystemProxyError.pendingRecovery }
        let authorization = try self.authorization ?? NetworkAuthorization(interaction: true)
        let store = try MacProxyStore(authorization: authorization.ref)
        try ProxyTransaction.restore(journal, store: store)
        try JournalIO.remove(journalURL, token: journal.token)
        isConnected = false
        guardProcess?.terminate(); guardProcess = nil; self.authorization = nil
    }

    /// Call at startup. If a live owner exists, never steal its session.
    /// Authorization is only requested when stale settings actually need repair.
    public func recoverPending() throws {
        guard hasPendingRecovery else { return }
        try JournalIO.withLock(at: journalURL) {
            guard hasPendingRecovery else { return }
            let journal = try JournalIO.read(journalURL)
            guard journal.parentPID == getpid() || kill(journal.parentPID, 0) != 0 else { throw SystemProxyError.pendingRecovery }
            if try !ProxyTransaction.ownsAnySettings(journal, services: MacProxyStore().read()) {
                try JournalIO.remove(journalURL, token: journal.token); return
            }
            try disconnectLocked()
        }
    }

    private func startGuard(authorization: NetworkAuthorization) throws {
        let process = Process(); process.executableURL = executableURL
        process.arguments = ["--proxy-guard", journalURL.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let external = try authorization.external()
        try input.fileHandleForWriting.write(contentsOf: external)
        try input.fileHandleForWriting.close()
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 5000) > 0,
              String(data: output.fileHandleForReading.availableData, encoding: .utf8)?.hasPrefix("READY") == true,
              process.isRunning else { process.terminate(); throw SystemProxyError.guardUnavailable }
        guardProcess = process
    }
}

public enum SystemProxyGuard {
    /// Invoke before AppKit setup. A capability is received only through the
    /// anonymous parent pipe; it is never put in command arguments or on disk.
    public static func runIfRequested() -> Int32? {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, arguments[1] == "--proxy-guard" else { return nil }
        guard arguments.count == 3 else { return 64 }
        do {
            let authorization = try NetworkAuthorization(external: FileHandle.standardInput.readDataToEndOfFile())
            let url = URL(fileURLWithPath: arguments[2])
            let journal = try JournalIO.read(url)
            guard journal.parentPID == getppid() else { return 65 }
            let store = try MacProxyStore(authorization: authorization.ref)
            _ = try store.read()
            try authorization.verifyReusableRight()
            try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8))
            try FileHandle.standardOutput.close()
            while kill(journal.parentPID, 0) == 0 {
                guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
                // If the core dies before Apply, remain armed until the parent's
                // transaction either applies settings or cancels its journal.
                if kill(journal.corePID, 0) != 0 {
                    // An intermittent preferences read failure must not kill
                    // the guardian silently; retry or enter restore if owned.
                    if let owned = try? ProxyTransaction.ownsAnySettings(journal, services: store.read()), owned { break }
                }
                Thread.sleep(forTimeInterval: 1)
            }
            // Retry transient configuration locks. If authorization expires or
            // the OS denies writes, retain the journal for next-launch recovery.
            for _ in 0..<60 {
                do {
                    try JournalIO.restoreIfCurrent(url, token: journal.token, store: store)
                    return 0
                } catch { Thread.sleep(forTimeInterval: 1) }
            }
            return 74
        } catch { return 70 }
    }
}
