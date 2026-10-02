import Combine
import Foundation

struct ExcludedApp: Codable, Identifiable, Equatable {
    var id: String
    var name: String
}

final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var maxCount: Int { didSet { defaults.set(maxCount, forKey: "history.maxCount") } }
    @Published var maxAgeDays: Int { didSet { defaults.set(maxAgeDays, forKey: "history.maxAgeDays") } }
    @Published var recordSound: Bool { didSet { defaults.set(recordSound, forKey: "sound.record") } }
    @Published var pasteSound: Bool { didSet { defaults.set(pasteSound, forKey: "sound.paste") } }
    @Published var excludedApps: [ExcludedApp] {
        didSet { defaults.set(try? JSONEncoder().encode(excludedApps), forKey: "excludedApps") }
    }
    @Published var shortcut: GlobalHotKey.Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["history.maxCount": 1_000, "history.maxAgeDays": 30])
        maxCount = max(1, defaults.integer(forKey: "history.maxCount"))
        maxAgeDays = max(1, defaults.integer(forKey: "history.maxAgeDays"))
        recordSound = defaults.bool(forKey: "sound.record")
        pasteSound = defaults.bool(forKey: "sound.paste")
        excludedApps = defaults.data(forKey: "excludedApps")
            .flatMap { try? JSONDecoder().decode([ExcludedApp].self, from: $0) } ?? []
        shortcut = defaults.data(forKey: "shortcut")
            .flatMap { try? JSONDecoder().decode(GlobalHotKey.Shortcut.self, from: $0) } ?? .default
    }
}
