import Foundation

public struct TeamsInstalledAgent: Identifiable, Equatable, Sendable {
    public let id: String
    public let appID: String
    public let name: String
    public init(id: String, appID: String, name: String) { self.id = id; self.appID = appID; self.name = name }
}

struct TeamsInstalledAppsEnvelope: Decodable {
    struct Value: Decodable {
        struct Entitlement: Decodable { let id: String; let state: String; let entitlementType: String?; let installedVersion: String? }
        struct Definition: Decodable {
            struct Bot: Decodable {
                let id: String
                let isNotificationOnly: Bool?
            }
            let id: String
            let name: String?
            let bots: [Bot]?
        }
        let entitlements: [Entitlement]
        let definitions: [Definition]
        let installedDefinitions: [String: Definition]?
    }
    let errorCode: String?
    let value: Value

    func agents() -> [TeamsInstalledAgent] {
        let definitions = Dictionary(value.definitions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let states: Set<String> = ["Installed", "InstalledAndFavorited", "InstalledAndPermanent", "AdminPreInstalled"]
        return value.entitlements.compactMap { entitlement in
            guard states.contains(entitlement.state),
                  let base = definitions[entitlement.id] else { return nil }
            let versionKey = entitlement.id.lowercased() + "_" + (entitlement.installedVersion ?? "")
            let definition = value.installedDefinitions?[versionKey] ?? value.installedDefinitions?[entitlement.id] ?? base
            let agentic = entitlement.entitlementType == "AgenticUser"
            guard agentic || entitlement.entitlementType == nil || entitlement.entitlementType == "" || entitlement.entitlementType == "App",
                  let name = definition.name, !name.isEmpty else { return nil }
            if agentic { return TeamsInstalledAgent(id: definition.id, appID: definition.id, name: name) }
            guard let bot = definition.bots?.first, !bot.id.isEmpty,
                  bot.isNotificationOnly != true else { return nil }
            return TeamsInstalledAgent(id: bot.id, appID: definition.id, name: name)
        }
    }
}
