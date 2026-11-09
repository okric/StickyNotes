import AppKit
import CoreGraphics

/// Screen bookkeeping for note windows.
///
/// A note remembers the display it was last on (UUID + offset from that
/// screen's origin) instead of only an absolute position, so it comes back to
/// the same display when the arrangement, resolution or scale changes.
enum ScreenGeometry {

    // MARK: - Screen identity

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    private static var uuidCache: [CGDirectDisplayID: String] = [:]

    /// Stable per-display identifier (derived from the display's EDID).
    static func uuid(for screen: NSScreen) -> String? {
        guard let id = displayID(for: screen) else { return nil }
        if let cached = uuidCache[id] { return cached }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            return nil
        }
        let value = (CFUUIDCreateString(nil, uuid) as String).uppercased()
        uuidCache[id] = value
        return value
    }

    static func screen(uuid: String?) -> NSScreen? {
        guard let uuid else { return nil }
        return NSScreen.screens.first { self.uuid(for: $0) == uuid }
    }

    /// Display a window belongs to: the one it overlaps most.
    static func screen(for frame: NSRect) -> NSScreen? {
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(frame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if best == nil || area > best!.area {
                best = (screen, area)
            }
        }
        if let best { return best.screen }

        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: - Restore

    /// Window origin relative to the origin of the screen it is on.
    static func offset(of origin: NSPoint, on screen: NSScreen) -> NSPoint {
        NSPoint(x: origin.x - screen.frame.minX, y: origin.y - screen.frame.minY)
    }

    /// Where the window should be created.
    ///
    /// Prefers the remembered screen + offset. Falls back to the absolute
    /// position when that is still on a display, and clamps to the main screen
    /// otherwise (e.g. the display was unplugged).
    static func restoredOrigin(
        position: NSPoint,
        screenUUID: String?,
        screenOffset: NSPoint?,
        size: NSSize
    ) -> NSPoint {
        if let screenOffset, let screen = screen(uuid: screenUUID) {
            let origin = NSPoint(
                x: screen.frame.minX + screenOffset.x,
                y: screen.frame.minY + screenOffset.y
            )
            return clampedFrame(NSRect(origin: origin, size: size), to: screen).origin
        }

        let frame = NSRect(origin: position, size: size)
        let visible = NSScreen.screens.contains { screen in
            let intersection = screen.frame.intersection(frame)
            return !intersection.isNull && intersection.width >= 40 && intersection.height >= 40
        }
        if visible { return position }

        let main = NSScreen.main ?? NSScreen.screens.first
        guard let main else { return position }
        return clampedFrame(frame, to: main).origin
    }

    /// Keeps a window fully inside one screen's usable area.
    static func clampedFrame(_ frame: NSRect, to screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        var result = frame
        result.size.width = min(result.width, visible.width)
        result.size.height = min(result.height, visible.height)
        result.origin.x = min(max(result.origin.x, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.origin.y, visible.minY), visible.maxY - result.height)
        return result
    }
}

/// Note panel that accepts the frame AppKit proposes.
///
/// The default constraint pulls a window that is momentarily off every display
/// (fast drag, gap between mirrored/arranged screens) onto the main screen,
/// which reads as a jump while crossing displays. Restored windows are clamped
/// explicitly in `ScreenGeometry.restoredOrigin`, so nothing gets stranded.
final class NotePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
