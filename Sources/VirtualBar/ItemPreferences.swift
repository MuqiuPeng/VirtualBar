import Foundation

@MainActor
final class ItemPreferences {
    private enum Keys {
        static let order = "VirtualBar.VirtualBar.ItemOrder"
        static let hidden = "VirtualBar.VirtualBar.HiddenItems"
    }

    private let defaults: UserDefaults
    private(set) var order: [String]
    private(set) var hidden: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = Self.unique(defaults.stringArray(forKey: Keys.order) ?? [])
        hidden = Set(defaults.stringArray(forKey: Keys.hidden) ?? [])
    }

    @discardableResult
    func reconcile(_ items: [MenuBarItem]) -> Bool {
        var changed = false
        let existing = Set(order)
        var additions: [String] = []
        var seen = existing
        for item in items.sorted(by: Self.naturalOrder) {
            let key = item.id.preferenceKey
            if seen.insert(key).inserted {
                additions.append(key)
            }
        }
        if !additions.isEmpty {
            order.append(contentsOf: additions)
            changed = true
        }
        if changed {
            save()
        }
        return changed
    }

    func ordered(_ items: [MenuBarItem]) -> [MenuBarItem] {
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return items.sorted { lhs, rhs in
            let leftRank = ranks[lhs.id.preferenceKey] ?? Int.max
            let rightRank = ranks[rhs.id.preferenceKey] ?? Int.max
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            return Self.naturalOrder(lhs, rhs)
        }
    }

    func displayed(_ items: [MenuBarItem]) -> [MenuBarItem] {
        ordered(items).filter { !hidden.contains($0.id.preferenceKey) }
    }

    func isEnabled(_ item: MenuBarItem) -> Bool {
        !hidden.contains(item.id.preferenceKey)
    }

    func setEnabled(_ enabled: Bool, for key: String) {
        if enabled {
            hidden.remove(key)
        } else {
            hidden.insert(key)
        }
        save()
    }

    func setCurrentOrder(_ keys: [String]) {
        let orderedKeys = Self.unique(keys)
        let current = Set(orderedKeys)
        order = orderedKeys + order.filter { !current.contains($0) }
        save()
    }

    func resetCurrentOrder(_ items: [MenuBarItem]) {
        setCurrentOrder(items.sorted(by: Self.naturalOrder).map { $0.id.preferenceKey })
    }

    private func save() {
        defaults.set(order, forKey: Keys.order)
        defaults.set(Array(hidden).sorted(), forKey: Keys.hidden)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func naturalOrder(_ lhs: MenuBarItem, _ rhs: MenuBarItem) -> Bool {
        if lhs.order != rhs.order {
            return lhs.order < rhs.order
        }
        return lhs.windowID < rhs.windowID
    }
}

extension MenuBarItemIdentity {
    var preferenceKey: String {
        let components = [
            bundleIdentifier,
            ownerName,
            accessibilityIdentifier,
            accessibilityTitle,
            String(widthClass),
            instanceKey
        ]
        return components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}
