import Foundation
import Network

/// A Vision Pro or Mac this iPhone can mirror to. Written by the app after a
/// successful pairing check, read by the broadcast extension through the
/// App Group.
struct Pairing: Codable, Equatable, Identifiable {
    var id: String { serviceName }
    /// Bonjour service name advertised by the receiver.
    var serviceName: String
    /// Human-readable name returned by the receiver in its welcome message.
    var headsetName: String
    var code: String
    /// Nil for pairings saved before Macs were supported (all Vision Pro).
    var kind: ReceiverKind?
    var lastUsed: Date?

    var receiverKind: ReceiverKind { kind ?? .visionPro }
}

enum PairingStore {
    private static let key = "pairings"
    private static let legacyKey = "pairing"
    private static let defaults = UserDefaults(suiteName: SigningInfo.appGroup)

    /// Most recently used first.
    static func all() -> [Pairing] {
        migrateIfNeeded()
        guard let data = defaults?.data(forKey: key),
              let list = try? JSONDecoder().decode([Pairing].self, from: data) else { return [] }
        return list.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    static func upsert(_ pairing: Pairing) {
        var list = all().filter { $0.serviceName != pairing.serviceName }
        list.insert(pairing, at: 0)
        save(list)
    }

    static func remove(_ serviceName: String) {
        save(all().filter { $0.serviceName != serviceName })
    }

    static func markUsed(_ serviceName: String) {
        save(all().map { pairing in
            var pairing = pairing
            if pairing.serviceName == serviceName { pairing.lastUsed = .now }
            return pairing
        })
    }

    private static func save(_ list: [Pairing]) {
        defaults?.set(try? JSONEncoder().encode(list), forKey: key)
    }

    /// Earlier versions stored a single Vision Pro pairing.
    private static func migrateIfNeeded() {
        guard let defaults, let data = defaults.data(forKey: legacyKey) else { return }
        if var old = try? JSONDecoder().decode(Pairing.self, from: data) {
            old.kind = .visionPro
            old.lastUsed = .now
            defaults.set(try? JSONEncoder().encode([old]), forKey: key)
        }
        defaults.removeObject(forKey: legacyKey)
    }
}

/// Lists the receivers currently advertising on the network.
enum ReceiverFinder {
    /// Browses for `timeout` seconds and reports the service names seen.
    static func find(timeout: TimeInterval, queue: DispatchQueue, completion: @escaping (Set<String>) -> Void) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: TetherConstants.serviceType, domain: nil), using: parameters)
        var names = Set<String>()
        browser.browseResultsChangedHandler = { results, _ in
            names = Set(results.compactMap { result in
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return nil
            })
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            browser.cancel()
            completion(names)
        }
    }
}
