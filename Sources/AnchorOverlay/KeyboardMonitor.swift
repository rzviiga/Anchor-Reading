import AppKit
import CoreGraphics

/// Passive keyboard activity only. No Unicode text is extracted or retained.
/// The event tap and its callbacks live on the main run loop.
@MainActor
final class KeyboardMonitor {
    struct Activity {
        let type: CGEventType
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onActivity: ((Activity) -> Void)?
    var onInterrupted: (() -> Void)?
    var isListening: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult func start() -> Bool {
        if isListening { return true }
        stop()
        // Permission is requested only by the app's explicit menu action.
        guard CGPreflightListenEventAccess() else { return false }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                // The source is installed exclusively on the main run loop.
                MainActor.assumeIsolated {
                    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        monitor.onInterrupted?()
                        if CGPreflightListenEventAccess(), let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    } else {
                        monitor.onActivity?(Activity(type: type,
                            keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags))
                    }
                }
                // Always pass the original event through unchanged.
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return false }
        tap = port; source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return isListening
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
    }
}
