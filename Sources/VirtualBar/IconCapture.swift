import Cocoa
import ScreenCaptureKit

/// Grabs live pictures of other apps' menu bar icons.
///
/// `CGWindowListCreateImage` was removed outright in macOS 15 (it's a hard
/// compile error, not a deprecation), so ScreenCaptureKit is the only route.
/// Capturing works even while an item is parked off-screen, which is what
/// lets the panel show folded-away icons without briefly un-folding them.
enum IconCapture {
    /// Captures each item, keyed by window id. Items that fail to capture are
    /// simply absent from the result rather than failing the whole batch.
    static func capture(_ items: [MenuBarItem]) async -> [CGWindowID: NSImage] {
        guard !items.isEmpty else { return [:] }

        let wanted = Set(items.map(\.windowID))
        let windows: [SCWindow]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            windows = content.windows.filter { wanted.contains($0.windowID) }
        } catch {
            debugLog("VirtualBar: SCShareableContent failed: \(error.localizedDescription)")
            return [:]
        }

        var result: [CGWindowID: NSImage] = [:]
        for window in windows {
            guard window.frame.width > 0, window.frame.height > 0 else { continue }
            do {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                // Capture at 2x for Retina, then hand back an NSImage sized in
                // points so it draws crisply at its natural size.
                config.width = Int(window.frame.width * 2)
                config.height = Int(window.frame.height * 2)
                config.showsCursor = false
                config.ignoreGlobalClipDisplay = true

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                result[window.windowID] = NSImage(
                    cgImage: image,
                    size: NSSize(width: window.frame.width, height: window.frame.height)
                )
            } catch {
                debugLog("VirtualBar: capture failed for window \(window.windowID): \(error.localizedDescription)")
            }
        }
        return result
    }
}
