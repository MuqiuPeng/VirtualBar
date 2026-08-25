import Cocoa
import ApplicationServices

enum MenuBarItemKind: String { case thirdParty, systemControlCenter, liveActivity, unknown }

struct MenuBarItemCapability: OptionSet {
    let rawValue: Int
    static let spacerPaging = Self(rawValue: 1 << 0)
    static let accessibilityPress = Self(rawValue: 1 << 1)
    static let individualMovement = Self(rawValue: 1 << 2)
    static let limited = Self(rawValue: 1 << 3)
    static let unsupported = Self(rawValue: 1 << 4)
}

struct MenuBarItemIdentity: Hashable, CustomStringConvertible {
    let bundleIdentifier: String
    let ownerName: String
    let accessibilityIdentifier: String
    let accessibilityTitle: String
    let widthClass: Int
    let instanceKey: String

    var description: String {
        [bundleIdentifier, ownerName, accessibilityIdentifier, accessibilityTitle, String(widthClass), instanceKey].joined(separator: "|")
    }
}

struct MenuBarItem: Equatable, Identifiable {
    let id: MenuBarItemIdentity
    let windowID: CGWindowID
    let pid: pid_t
    let ownerName: String
    let bundleIdentifier: String
    let frame: CGRect
    let order: Int
    let kind: MenuBarItemKind
    let capability: MenuBarItemCapability
}

enum MenuBarItems {
    static func scanAll() -> [MenuBarItem] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let raws = list.compactMap { info -> RawItem? in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == Int(CGWindowLevelForKey(.statusWindow)),
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let number = info[kCGWindowNumber as String] as? Int,
                  let pidValue = info[kCGWindowOwnerPID as String] as? Int else { return nil }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard frame.height > 0, frame.height < 50, frame.origin.y < 5, frame.width > 5, frame.width < 300, alpha > 0 else { return nil }
            let pid = pid_t(pidValue)
            let app = NSRunningApplication(processIdentifier: pid)
            return RawItem(windowID: CGWindowID(number), pid: pid, ownerName: info[kCGWindowOwnerName as String] as? String ?? app?.localizedName ?? "Unknown", bundleIdentifier: app?.bundleIdentifier ?? "", frame: frame)
        }.sorted {
            $0.frame.minX == $1.frame.minX ? $0.windowID < $1.windowID : $0.frame.minX < $1.frame.minX
        }

        var occurrences: [String: Int] = [:]
        return raws.enumerated().map { order, raw in
            let metadata = accessibilityMetadata(for: raw)
            let itemKind = kind(for: raw, metadata: metadata)
            let base = [raw.bundleIdentifier, raw.ownerName, metadata.identifier, metadata.title, String(Int(raw.frame.width.rounded()))].joined(separator: "|")
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            let identity = MenuBarItemIdentity(bundleIdentifier: raw.bundleIdentifier, ownerName: raw.ownerName, accessibilityIdentifier: metadata.identifier, accessibilityTitle: metadata.title, widthClass: Int(raw.frame.width.rounded()), instanceKey: "instance:\(occurrence)")
            return MenuBarItem(id: identity, windowID: raw.windowID, pid: raw.pid, ownerName: raw.ownerName, bundleIdentifier: raw.bundleIdentifier, frame: raw.frame, order: order, kind: itemKind, capability: capability(for: itemKind, canPress: metadata.canPress, canMove: metadata.canMove))
        }
    }

    static func press(_ item: MenuBarItem) -> Bool {
        guard let element = axElement(pid: item.pid, frame: item.frame) else { return false }
        let actions = actionNames(of: element)
        for action in [kAXPressAction as String, kAXShowMenuAction as String] where actions.contains(action) {
            let result = AXUIElementPerformAction(element, action as CFString)
            debugLog("VirtualBar AX action=\(action) owner=\(item.ownerName) result=\(result.rawValue)")
            if result == .success || result == .cannotComplete { return true }
        }
        debugLog("VirtualBar AX actions unsupported owner=\(item.ownerName) actions=\(actions)")
        return false
    }

    private struct RawItem { let windowID: CGWindowID; let pid: pid_t; let ownerName: String; let bundleIdentifier: String; let frame: CGRect }
    private struct AccessibilityMetadata { let identifier: String; let title: String; let element: AXUIElement?; let canPress: Bool; let canMove: Bool }

    private static func kind(for item: RawItem, metadata: AccessibilityMetadata) -> MenuBarItemKind {
        let value = [item.bundleIdentifier, item.ownerName, metadata.identifier, metadata.title].joined(separator: " ").lowercased()
        if value.contains("liveactiv") || value.contains("activitydisplay") { return .liveActivity }
        if value.contains("cuaservice") || value.contains("computer use") { return .unknown }
        if item.bundleIdentifier.hasPrefix("com.apple.controlcenter") || item.ownerName == "Control Center" { return .systemControlCenter }
        if !item.bundleIdentifier.isEmpty && !item.bundleIdentifier.hasPrefix("com.apple.") { return .thirdParty }
        return .unknown
    }

    private static func capability(for kind: MenuBarItemKind, canPress: Bool, canMove: Bool) -> MenuBarItemCapability {
        switch kind {
        case .thirdParty:
            var value: MenuBarItemCapability = [.spacerPaging]
            if canPress { value.insert(.accessibilityPress) }
            if canMove { value.insert(.individualMovement) }
            return value
        case .systemControlCenter: return canPress ? [.accessibilityPress, .limited] : [.limited]
        case .liveActivity: return [.unsupported]
        case .unknown: return [.limited]
        }
    }

    private static func accessibilityMetadata(for item: RawItem) -> AccessibilityMetadata {
        guard let element = axElement(pid: item.pid, frame: item.frame) else { return .init(identifier: "", title: "", element: nil, canPress: false, canMove: false) }
        var settable = DarwinBoolean(false)
        let canMove = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
        let actions = actionNames(of: element)
        let canPress = actions.contains(kAXPressAction as String) || actions.contains(kAXShowMenuAction as String)
        return .init(identifier: stringAttribute(kAXIdentifierAttribute as String, of: element), title: stringAttribute(kAXTitleAttribute as String, of: element), element: element, canPress: canPress, canMove: canMove)
    }

    private static func axElement(pid: pid_t, frame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var extras: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success, let extras, CFGetTypeID(extras) == AXUIElementGetTypeID() else { return nil }
        var childrenReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(extras as! AXUIElement, kAXChildrenAttribute as CFString, &childrenReference) == .success, let children = childrenReference as? [AXUIElement], !children.isEmpty else { return nil }
        return children.min { distance(from: $0, to: frame) < distance(from: $1, to: frame) }
    }

    private static func distance(from element: AXUIElement, to target: CGRect) -> CGFloat {
        guard let frame = frame(of: element) else { return .greatestFiniteMagnitude }
        return abs(frame.midX - target.midX) + abs(frame.width - target.width)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success, AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success, let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let value else {
            return []
        }
        return value as? [String] ?? []
    }
}
