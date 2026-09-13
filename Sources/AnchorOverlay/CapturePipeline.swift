import AppKit
import ScreenCaptureKit
import CoreMedia
import AnchorOverlayCore

/// All scheduling state is confined to frameQueue. OCR runs on a separate serial
/// worker; at most one request exists, and only the latest CVPixelBuffer is held
/// per display. No screenshot or recognized text is written to disk.
final class CapturePipeline: NSObject, SCStreamOutput, SCStreamDelegate, ReadingCapturePipeline {
    private final class DisplayState {
        var gate = FreshnessGate()
        var signature: FrameSignature?
        var latest: CVPixelBuffer?
        var processedAt: TimeInterval = -.infinity
        var invalidated = true
        var patches = [AccentPatch]()
        var reference: PixelFrame?
    }
    private final class BufferLease {
        var buffer: CVPixelBuffer?
        init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
    }
    private let frameQueue = DispatchQueue(label: "anchor.capture", qos: .userInitiated)
    private let ocrQueue = DispatchQueue(label: "anchor.ocr", qos: .utility)
    private var streams = [SCStream]()
    private var displayForStream = [ObjectIdentifier: CGDirectDisplayID]()
    private var states = [CGDirectDisplayID: DisplayState]()
    private var timer: DispatchSourceTimer?
    private var enabled = false
    private var interactionSuspended = false
    private var epoch: UInt64 = 0
    private var busy = false
    private var policy = ReadingPolicy()
    private let engine = EnhancementEngine()
    var onInvalidate: ((CGDirectDisplayID) -> Void)?
    var onResult: ((CGDirectDisplayID, RecognitionResult, CGSize) -> Void)?
    var onRetainPatches: ((CGDirectDisplayID, [AccentPatch], CGSize) -> Void)?
    var onError: ((String) -> Void)?
    var onIdle: (() -> Void)?

    @MainActor func start(content: SCShareableContent, captureScale: Double, policy: ReadingPolicy) async throws {
        let ownApps = content.applications.filter { $0.processID == getpid() }
        // Never capture our overlay; fail if ScreenCaptureKit cannot identify this app.
        guard !ownApps.isEmpty else { throw NSError(domain: "AnchorOverlay", code: 2, userInfo: [NSLocalizedDescriptionKey: "屏幕捕获尚未列出 Anchor Overlay，请再次开启。"]) }
        var created = [SCStream]()
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }) else { continue }
            let scale = min(captureScale, 2880 / screen.frame.width)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(screen.frame.width * scale)
            configuration.height = Int(screen.frame.height * scale)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
            created.append(stream)
            frameQueue.sync {
                displayForStream[ObjectIdentifier(stream)] = display.displayID
                states[display.displayID] = DisplayState()
            }
        }
        guard !created.isEmpty else { throw NSError(domain: "AnchorOverlay", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有可捕获的显示器"]) }
        streams = created
        frameQueue.sync {
            self.policy = policy; enabled = true; epoch &+= 1
            let t = DispatchSource.makeTimerSource(queue: frameQueue)
            t.schedule(deadline: .now(), repeating: .milliseconds(35), leeway: .milliseconds(8))
            t.setEventHandler { [weak self] in self?.scheduleLatest() }
            t.resume(); timer = t
        }
        do { for stream in streams { try await stream.startCapture() } }
        catch { await stop(); throw error }
    }

    @MainActor func stop() async {
        let previous = streams; streams = []
        frameQueue.sync {
            enabled = false; epoch &+= 1; timer?.cancel(); timer = nil
            states.removeAll(); displayForStream.removeAll()
        }
        for stream in previous { try? await stream.stopCapture() }
        // Drain the single worker before a replacement pipeline can start.
        await withCheckedContinuation { continuation in
            ocrQueue.async { continuation.resume() }
        }
    }

    func interact(suspended: Bool = false) {
        frameQueue.async { [weak self] in
            guard let self, self.enabled else { return }
            self.interactionSuspended = suspended
            let now = ProcessInfo.processInfo.systemUptime
            for (id, state) in self.states {
                state.gate.interacted(at: now)
                self.invalidate(id, state: state)
            }
        }
    }

    private func invalidate(_ id: CGDirectDisplayID, state: DisplayState) {
        state.patches.removeAll(); state.reference = nil
        if !state.invalidated {
            state.invalidated = true
            DispatchQueue.main.async { [weak self] in self?.onInvalidate?(id) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard enabled, type == .screen, sampleBuffer.isValid,
              let id = displayForStream[ObjectIdentifier(stream)], let state = states[id] else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let status = (attachments?.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        if status == .blank || status == .suspended || status == .stopped {
            state.gate.changed(at: ProcessInfo.processInfo.systemUptime); state.latest = nil
            invalidate(id, state: state); return
        }
        guard status == .complete || status == .started,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let signature = FrameSignature.read(buffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if state.signature == nil || signature.differs(from: state.signature!) {
            state.signature = signature; state.gate.changed(at: now)
        }
        if let reference=state.reference, !state.patches.isEmpty {
            let indices=reference.unchangedPatchIndices(in:buffer,rects:state.patches.map(\.pixelRect))
            if indices.count != state.patches.count {
                state.patches=indices.map{state.patches[$0]}
                state.gate.changed(at:now)
                let retained=state.patches
                let size=CGSize(width:reference.width,height:reference.height)
                DispatchQueue.main.async { [weak self] in self?.onRetainPatches?(id,retained,size) }
            }
        }
        state.latest = buffer
        // Fine changes missed by the sparse signature are refreshed periodically,
        // but don't launch another OCR on an idle display just to poll it.
        if !state.gate.needsRecognition && now-state.processedAt > 1.2 {
            state.gate.requestRefresh()
        }
    }

    private func scheduleLatest() {
        guard enabled, !busy, !interactionSuspended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Least recently served display first: a busy monitor cannot starve others.
        guard let (id,state) = states.filter({ $0.value.latest != nil && $0.value.gate.ready(at: now) })
            .min(by: {$0.value.processedAt < $1.value.processedAt}), let buffer = state.latest else { return }
        let token = state.gate.begin(at: now), session = epoch, settings = policy
        let lease = BufferLease(buffer)
        busy = true
        ocrQueue.async { [weak self] in
            guard let self else { return }
            // Copy once, before Vision: do not hold ScreenCaptureKit surfaces during OCR.
            let outcome: Result<(RecognitionResult, PixelFrame), Error> = autoreleasepool {
                let ownedFrame = lease.buffer.flatMap { PixelFrame(buffer: $0) }
                lease.buffer = nil
                guard let frame = ownedFrame else {
                    return .failure(NSError(domain:"AnchorOverlay",code:4,userInfo:[NSLocalizedDescriptionKey:"无法读取屏幕画面"]))
                }
                return Result { (try self.engine.recognize(frame, policy: settings), frame) }
            }
            self.frameQueue.async {
                self.busy = false
                guard self.enabled, !self.interactionSuspended, self.epoch == session, let current = self.states[id] else { return }
                let completed = ProcessInfo.processInfo.systemUptime
                guard current.gate.completed(token, at: completed) else { return }
                current.processedAt = completed
                switch outcome {
                case .success(let (result,reference)):
                    current.invalidated = false
                    current.patches = result.patches; current.reference=reference
                    let size=CGSize(width:reference.width,height:reference.height)
                    DispatchQueue.main.async { [weak self] in self?.onResult?(id,result,size) }
                case .failure(let error):
                    DispatchQueue.main.async { [weak self] in self?.onError?(error.localizedDescription) }
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error.localizedDescription) }
    }
}
