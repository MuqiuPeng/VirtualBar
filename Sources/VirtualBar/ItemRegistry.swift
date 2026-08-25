import Cocoa

@MainActor
final class ItemRegistry {
    private(set) var items: [MenuBarItem] = []
    private(set) var revision = 0

    @discardableResult
    func refresh(ownPID: pid_t, leftOf spacerX: CGFloat?, knownIDs: Set<MenuBarItemIdentity>? = nil) -> Bool {
        let next = MenuBarItems.scanAll().filter { item in
            guard item.pid != ownPID, item.kind == .thirdParty, item.capability.contains(.spacerPaging) else { return false }
            if let knownIDs { return knownIDs.contains(item.id) }
            return spacerX.map { item.frame.minX < $0 } ?? true
        }
        guard next != items else { return false }
        items = next
        revision += 1
        return true
    }

    func pages(maximumWidth: CGFloat) -> [[MenuBarItemIdentity]] {
        var result: [[MenuBarItemIdentity]] = []
        var current: [MenuBarItemIdentity] = []
        var width: CGFloat = 0
        for item in items.reversed() {
            if !current.isEmpty && width + item.frame.width > maximumWidth {
                result.append(current.reversed())
                current = []
                width = 0
            }
            current.append(item.id)
            width += item.frame.width
        }
        if !current.isEmpty { result.append(current.reversed()) }
        return result
    }

    func item(id: MenuBarItemIdentity) -> MenuBarItem? { items.first { $0.id == id } }
}
