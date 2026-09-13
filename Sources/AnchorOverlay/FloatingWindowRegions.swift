import CoreGraphics
import Foundation

/// Read geometry, never window titles or text. Called only around a requested
/// screenshot, not on a timer. Treat all foreign floating windows as protected
/// so this does not depend on a particular input method's process name.
enum FloatingWindowRegions {
    static func read() -> [CGRect]? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        return windows.compactMap { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value != getpid(),
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.int32Value > CGWindowLevelForKey(.normalWindow),
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary),
                  !bounds.isEmpty else { return nil }
            return bounds.insetBy(dx: -3, dy: -3)
        }
    }

    static func pixels(_ regions: [CGRect], displayBounds: CGRect, pixelSize: CGSize) -> [CGRect] {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return [CGRect(origin: .zero, size: pixelSize)] }
        return regions.compactMap { region in
            let clipped = region.intersection(displayBounds)
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            // Both CGWindow bounds and CGDisplay bounds use top-left screen coordinates.
            return CGRect(x: (clipped.minX-displayBounds.minX)*pixelSize.width/displayBounds.width,
                          y: (clipped.minY-displayBounds.minY)*pixelSize.height/displayBounds.height,
                          width: clipped.width*pixelSize.width/displayBounds.width,
                          height: clipped.height*pixelSize.height/displayBounds.height)
        }
    }
}
