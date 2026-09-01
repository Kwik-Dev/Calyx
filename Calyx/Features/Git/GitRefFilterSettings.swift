// GitRefFilterSettings.swift
// Calyx
//
// UserDefaults-backed store for the per-repository ref-picker choice
// (GitRefSelection). Same "route every read/write through a private
// SettingsStore" shape as SessionSettings; see
// Calyx/Helpers/SettingsStore.swift for the full test/production
// resolution rationale.

import Foundation

struct GitRefFilterSettings: Sendable {

    static let refSelectionsKey = "calyx.git.refSelections"

    private static let settingsStore = SettingsStore()

    static func _testUseSuite(named name: String) {
        settingsStore.testUseSuite(named: name)
    }

    static func _testTeardownSuite(named name: String) {
        settingsStore.testTeardownSuite(named: name)
    }

    private static var store: UserDefaults {
        settingsStore.store
    }

    /// `.auto` when `repoID` has nothing saved, or what was saved could not
    /// be decoded.
    static func selection(forRepo repoID: String) -> GitRefSelection {
        guard let data = store.data(forKey: refSelectionsKey),
              let decoded = try? JSONDecoder().decode([String: GitRefSelection].self, from: data)
        else {
            return .auto
        }
        return decoded[repoID] ?? .auto
    }

    /// Persists `selection` for `repoID`. `.auto` removes the repository's
    /// entry entirely rather than writing it explicitly, since `.auto` is
    /// already what a missing entry answers.
    static func set(_ selection: GitRefSelection, forRepo repoID: String) {
        var map: [String: GitRefSelection] = [:]
        if let data = store.data(forKey: refSelectionsKey) {
            map = (try? JSONDecoder().decode([String: GitRefSelection].self, from: data)) ?? [:]
        }

        if case .auto = selection {
            map.removeValue(forKey: repoID)
        } else {
            map[repoID] = selection
        }

        guard let encoded = try? JSONEncoder().encode(map) else { return }
        store.set(encoded, forKey: refSelectionsKey)
    }
}
