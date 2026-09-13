import AppKit
import AnchorOverlayCore

final class OverlayPanel: NSPanel {
    private let canvas = AccentView()
    init(screen: NSScreen, avoidSystemPopups: Bool = false) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        ignoresMouseEvents = true; acceptsMouseMovedEvents = false
        level = avoidSystemPopups ? .floating : .init(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        sharingType = .none
        isReleasedWhenClosed = false
        contentView = canvas
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    func present(_ patches: [AccentPatch], pixelSize: CGSize) {
        canvas.patches = patches; canvas.pixelSize = pixelSize
        canvas.needsDisplay = true
        if !patches.isEmpty {
            // Prepare the new buffer before showing; an in-place refresh never
            // orders the window out or exposes a blank intermediate frame.
            canvas.displayIfNeeded()
            if !isVisible { orderFrontRegardless() }
        } else if isVisible { orderOut(nil) }
    }
    func clear() {
        if isVisible { orderOut(nil) }
        if !canvas.patches.isEmpty { canvas.patches = []; canvas.needsDisplay = true }
    }
}

private final class AccentView: NSView {
    var patches = [AccentPatch]()
    var pixelSize = CGSize(width: 1, height: 1)
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        context.interpolationQuality = .high
        for patch in patches {
            let rect = OverlayGeometry.points(from: patch.pixelRect, pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height), screenSize: bounds.size)
            guard rect.intersects(dirtyRect) else { continue }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(patch.image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
    }
}
