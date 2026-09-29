import Foundation

/// Identifiers that depend on who signed the app. Building with another Apple
/// ID, or re-signing with a sideloading tool, renames the App Group and the
/// extension, so they are read from the installed app instead of hard-coded.
enum SigningInfo {
    /// The App Group shared by the app and its broadcast extension.
    static let appGroup: String = {
        if let group = profileEntitlements()?["com.apple.security.application-groups"] as? [String],
           let tether = group.first(where: { $0.lowercased().contains("tether") }) ?? group.first {
            return tether
        }
        // App Store builds carry no provisioning profile.
        return TetherConstants.appGroup
    }()

    /// Bundle identifier of the broadcast extension inside the app.
    static let broadcastExtensionID: String = {
        let plugIns = Bundle.main.builtInPlugInsURL
            .flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        for url in plugIns where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url),
                  let info = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  info["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload",
                  let id = bundle.bundleIdentifier else { continue }
            return id
        }
        return TetherConstants.broadcastExtensionID
    }()

    /// Entitlements from `embedded.mobileprovision`, a signed container
    /// around a plain XML property list.
    private static func profileEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil
              ) as? [String: Any] else { return nil }
        return plist["Entitlements"] as? [String: Any]
    }
}
