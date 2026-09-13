import AppKit
import ScreenCaptureKit
import CoreMedia
// The Swift 5 core predates Sendable annotations. Frames own immutable bytes;
// this pipeline confines its engine and mutable font cache to ocrQueue.
@preconcurrency import AnchorOverlayCore

/// Energy-saving mode: one capture per display per settled interaction, then
/// no capture stream, periodic timer, pixel comparison, or background OCR.
@MainActor
final class SnapshotCapturePipeline: ReadingCapturePipeline {
    private struct Source {
        let id: CGDirectDisplayID
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let displayBounds: CGRect
    }
    private let ocrQueue = DispatchQueue(label: "anchor.snapshot.ocr", qos: .utility)
    private let engine = EnhancementEngine()
    private var sources = [Source]()
    private var pending = [Source]()
    private var wake: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var enabled = false
    private var suspended = false
    private var revision: UInt64 = 0
    private var readyAt: TimeInterval = 0
    private var policy = ReadingPolicy()
    private let settleInterval: TimeInterval = 0.30

    var onInvalidate: ((CGDirectDisplayID) -> Void)?
    var onResult: ((CGDirectDisplayID, RecognitionResult, CGSize) -> Void)?
    var onRetainPatches: ((CGDirectDisplayID, [AccentPatch], CGSize) -> Void)?
    var onError: ((String) -> Void)?
    var onIdle: (() -> Void)?

    func start(content: SCShareableContent, captureScale: Double, policy: ReadingPolicy) async throws {
        let ownApps = content.applications.filter { $0.processID == getpid() }
        guard !ownApps.isEmpty else {
            throw NSError(domain: "AnchorOverlay", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "屏幕捕获尚未列出 Anchor Overlay，请再次开启。"])
        }
        sources = content.displays.compactMap { display in
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }) else { return nil }
            let scale = min(captureScale, 2880 / screen.frame.width)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(screen.frame.width * scale)
            configuration.height = Int(screen.frame.height * scale)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            return Source(id: display.displayID, filter: filter, configuration: configuration,
                          displayBounds: CGDisplayBounds(display.displayID))
        }
        guard !sources.isEmpty else {
            throw NSError(domain: "AnchorOverlay", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "没有可捕获的显示器"])
        }
        self.policy = policy
        enabled = true
        interact(suspended: false)
    }

    func stop() async {
        enabled = false; revision &+= 1
        wake?.cancel(); wake = nil
        pending.removeAll(); sources.removeAll()
        let previous = worker
        previous?.cancel()
        // A single-frame API call or Vision request may already be in flight.
        // Drain it before changing modes; its result can no longer be published.
        await previous?.value
        worker = nil
    }

    func interact(suspended: Bool) {
        guard enabled else { return }
        revision &+= 1
        self.suspended = suspended
        readyAt = ProcessInfo.processInfo.systemUptime + settleInterval
        pending = sources
        wake?.cancel(); wake = nil
        for source in sources { onInvalidate?(source.id) }
        if !suspended { scheduleWake() }
    }

    private func scheduleWake() {
        guard enabled, !suspended, !pending.isEmpty else { return }
        wake?.cancel()
        let ticket = revision
        let delay = max(0, readyAt - ProcessInfo.processInfo.systemUptime)
        // This is a cancellable one-shot delay after an event, never a repeating
        // polling loop. Nothing wakes this pipeline while a page stays idle.
        wake = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled, self.enabled, self.revision == ticket else { return }
            self.wake = nil
            self.startNextCapture()
        }
    }

    private func startNextCapture() {
        guard enabled, !suspended, worker == nil else { return }
        guard !pending.isEmpty else {
            wake?.cancel(); wake = nil
            onIdle?()
            return
        }
        guard ProcessInfo.processInfo.systemUptime >= readyAt else { scheduleWake(); return }
        let source = pending.removeFirst()
        let ticket = revision
        worker = Task { [weak self] in
            guard let self else { return }
            await self.capture(source, ticket: ticket)
            self.worker = nil
            self.startNextCapture()
        }
    }

    private func accepts(_ ticket: UInt64) -> Bool {
        enabled && !suspended && revision == ticket && !Task.isCancelled
    }

    private func capture(_ source: Source, ticket: UInt64) async {
        let queue = ocrQueue
        let protectedBefore = FloatingWindowRegions.read() ?? [source.displayBounds]
        do {
            let frame: PixelFrame = try await withCheckedThrowingContinuation { continuation in
                SCScreenshotManager.captureSampleBuffer(contentFilter: source.filter, configuration: source.configuration) { sample, error in
                    if let error { continuation.resume(throwing: error); return }
                    // Copy off the main thread and release the capture surface
                    // before beginning font matching or OCR.
                    queue.async {
                        let outcome: Result<PixelFrame, Error> = autoreleasepool {
                            guard let sample, sample.isValid,
                                  let buffer = CMSampleBufferGetImageBuffer(sample),
                                  let frame = PixelFrame(buffer: buffer) else {
                                return .failure(NSError(domain: "AnchorOverlay", code: 4,
                                    userInfo: [NSLocalizedDescriptionKey: "无法读取屏幕截图"]))
                            }
                            return .success(frame)
                        }
                        continuation.resume(with: outcome)
                    }
                }
            }
            guard accepts(ticket) else { return }
            let engine = self.engine, settings = policy
            let outcome: Result<RecognitionResult, Error> = await withCheckedContinuation { continuation in
                queue.async {
                    let result = autoreleasepool { Result { try engine.recognize(frame, policy: settings) } }
                    continuation.resume(returning: result)
                }
            }
            guard accepts(ticket) else { return }
            let size = CGSize(width: frame.width, height: frame.height)
            // Candidate windows can appear or move while OCR is working. Protect
            // both the captured popup pixels and the current popup positions.
            let protectedNow = FloatingWindowRegions.read() ?? [source.displayBounds]
            let regions = FloatingWindowRegions.pixels(protectedBefore + protectedNow,
                displayBounds: source.displayBounds, pixelSize: size)
            let result = try outcome.get().excludingPatches(intersecting: regions)
            onResult?(source.id, result, size)
            // No reference frame is retained for future pixel comparisons.
        } catch {
            guard accepts(ticket) else { return }
            // Stop this batch; leave restart/error presentation to the app.
            pending.removeAll(); suspended = true
            onError?(error.localizedDescription)
        }
    }
}
