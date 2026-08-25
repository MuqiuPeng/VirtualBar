import Cocoa
import CoreImage

/// What to draw for an item when its live capture isn't available.
///
/// Captured icons are the real menu bar glyphs — monochrome, already tinted
/// by AppKit for the bar's appearance. Dropping a full-colour application
/// icon in among them reads as a different kind of thing entirely, so the
/// fallback is desaturated to sit in the same visual register. Saturation is
/// removed rather than the artwork being reduced to a silhouette: most app
/// icons are a filled rounded square, and a silhouette of one identifies
/// nothing.
///
/// Both the virtual bar and the settings list go through here, so the two
/// can't drift apart.
@MainActor
enum ItemIcon {
    static func fallback(for item: MenuBarItem, size: CGFloat) -> NSImage {
        let pointSize = NSSize(width: size, height: size)
        if let appIcon = NSRunningApplication(processIdentifier: item.pid)?.icon,
           let desaturated = desaturate(appIcon, to: pointSize) {
            return desaturated
        }
        return initials(for: item.ownerName, size: pointSize)
    }

    private static func desaturate(_ image: NSImage, to size: NSSize) -> NSImage? {
        guard let data = image.tiffRepresentation,
              let source = CIImage(data: data),
              let filter = CIFilter(name: "CIColorControls") else {
            return nil
        }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return nil }

        let result = NSImage(size: size)
        result.addRepresentation(NSCIImageRep(ciImage: output))
        result.size = size
        return result
    }

    /// Last resort when the process has no icon at all: its initials, drawn as
    /// a template so they pick up the same tint as everything around them.
    private static func initials(for name: String, size: NSSize) -> NSImage {
        let letters = String(name.prefix(2)).uppercased()
        let image = NSImage(size: size, flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: rect.height * 0.42, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black,
            ]
            let bounds = letters.size(withAttributes: attributes)
            letters.draw(
                at: NSPoint(
                    x: rect.midX - bounds.width / 2,
                    y: rect.midY - bounds.height / 2
                ),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = true
        return image
    }
}
