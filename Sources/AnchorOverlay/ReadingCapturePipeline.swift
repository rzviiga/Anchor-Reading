import AppKit
import ScreenCaptureKit
import AnchorOverlayCore

/// Both modes share presentation and rendering, but own separate capture lifecycles.
protocol ReadingCapturePipeline: AnyObject {
    @MainActor var onInvalidate: ((CGDirectDisplayID) -> Void)? { get set }
    @MainActor var onResult: ((CGDirectDisplayID, RecognitionResult, CGSize) -> Void)? { get set }
    @MainActor var onRetainPatches: ((CGDirectDisplayID, [AccentPatch], CGSize) -> Void)? { get set }
    @MainActor var onError: ((String) -> Void)? { get set }
    @MainActor var onIdle: (() -> Void)? { get set }
    @MainActor func start(content: SCShareableContent, captureScale: Double, policy: ReadingPolicy) async throws
    @MainActor func stop() async
    @MainActor func interact(suspended: Bool)
}
