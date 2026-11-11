import Foundation

public struct SubscriptionSummary: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let nodeCount: Int
    public init(id: String, name: String, nodeCount: Int) {
        self.id = id
        self.name = name
        self.nodeCount = nodeCount
    }
}

/// Subscription URLs live in Keychain. This record contains only the opaque account reference.
public struct SubscriptionProfile: Codable, Equatable {
    public var id: String
    public var name: String
    public var credentialAccount: String?
    public var document: SubscriptionDocument?
    public var quota: SubscriptionQuota
    public var selected: String?
    public var automatic: Bool
    public var updated: Date?
    public var failoverNodes: [String]?
    public init(id: String = UUID().uuidString, name: String, credentialAccount: String? = nil,
                document: SubscriptionDocument? = nil, quota: SubscriptionQuota = .parse(nil),
                selected: String? = nil, automatic: Bool = true, updated: Date? = nil) {
        self.id = id
        self.name = name
        self.credentialAccount = credentialAccount
        self.document = document
        self.quota = quota
        self.selected = selected
        self.automatic = automatic
        self.updated = updated
    }

    public static func displayName(for source: String) -> String {
        guard let host = URL(string: source)?.host, !host.isEmpty else { return "订阅机场" }
        if (host.lowercased() == "mesl.cloud" || host.lowercased().hasSuffix(".mesl.cloud")) { return "MESL" }
        return host
    }
}

/// Routing preferences belong to the application. Node selection and update metadata belong to each airport.
public struct SubscriptionProfiles: Codable {
    public var subscriptions = [SubscriptionProfile]()
    public var activeSubscriptionID: String?
    public var rules = [String]()
    public var mode = "rule"
    public var ruleOverride: [String]?
    public init() {}
    public var active: SubscriptionProfile? {
        get { subscriptions.first { $0.id == activeSubscriptionID } }
        set {
            guard let value = newValue, let index = subscriptions.firstIndex(where: { $0.id == activeSubscriptionID }) else { return }
            subscriptions[index] = value
        }
    }
    // Compatibility accessors keep existing connection and routing operations scoped to the active airport.
    public var credentialAccount: String? { get { active?.credentialAccount } set { active?.credentialAccount = newValue } }
    public var document: SubscriptionDocument? { get { active?.document } set { active?.document = newValue } }
    public var quota: SubscriptionQuota { get { active?.quota ?? .parse(nil) } set { active?.quota = newValue } }
    public var selected: String? { get { active?.selected } set { active?.selected = newValue } }
    public var automatic: Bool { get { active?.automatic ?? true } set { active?.automatic = newValue } }
    public var updated: Date? { get { active?.updated } set { active?.updated = newValue } }

    public mutating func upsert(_ subscription: SubscriptionProfile, activate: Bool) {
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) { subscriptions[index] = subscription }
        else { subscriptions.append(subscription) }
        if activate || activeSubscriptionID == nil { activeSubscriptionID = subscription.id }
    }
    public mutating func remove(_ id: String) {
        subscriptions.removeAll { $0.id == id }
        if activeSubscriptionID == id { activeSubscriptionID = subscriptions.first?.id }
    }
    private enum CodingKeys: String, CodingKey {
        case subscriptions, activeSubscriptionID, rules, mode, ruleOverride
        case credentialAccount, document, quota, selected, automatic, updated, name, subscriptionName
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rules = try values.decodeIfPresent([String].self, forKey: .rules) ?? []
        mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? "rule"
        ruleOverride = try values.decodeIfPresent([String].self, forKey: .ruleOverride)
        if let entries = try values.decodeIfPresent([SubscriptionProfile].self, forKey: .subscriptions) {
            subscriptions = entries
            let requested = try values.decodeIfPresent(String.self, forKey: .activeSubscriptionID)
            activeSubscriptionID = entries.contains { $0.id == requested } ? requested : entries.first?.id
        } else {
            let document = try values.decodeIfPresent(SubscriptionDocument.self, forKey: .document)
            let account = try values.decodeIfPresent(String.self, forKey: .credentialAccount)
            if document != nil || account != nil {
                let legacy = SubscriptionProfile(
                    name: try values.decodeIfPresent(String.self, forKey: .name) ?? values.decodeIfPresent(String.self, forKey: .subscriptionName) ?? "订阅机场",
                    credentialAccount: account, document: document,
                    quota: try values.decodeIfPresent(SubscriptionQuota.self, forKey: .quota) ?? .parse(nil),
                    selected: try values.decodeIfPresent(String.self, forKey: .selected),
                    automatic: try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? true,
                    updated: try values.decodeIfPresent(Date.self, forKey: .updated))
                subscriptions = [legacy]
                activeSubscriptionID = legacy.id
            }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(subscriptions, forKey: .subscriptions)
        try values.encodeIfPresent(activeSubscriptionID, forKey: .activeSubscriptionID)
        try values.encode(rules, forKey: .rules)
        try values.encode(mode, forKey: .mode)
        try values.encodeIfPresent(ruleOverride, forKey: .ruleOverride)
    }
}
