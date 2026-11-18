import CoreGraphics
import CoreMedia
import ScreenCaptureKit

final class WindowCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    // Bumped by every start/stop so a start that is still in flight when stop() is called
    // tears its stream down instead of leaving capture running.
    private var generation = 0
    private let sampleHandler: (CMSampleBuffer) -> Void

    init(sampleHandler: @escaping (CMSampleBuffer) -> Void) {
        self.sampleHandler = sampleHandler
        super.init()
    }

    func start(windowID: CGWindowID) async throws {
        guard stream == nil else { return }
        generation += 1
        let startGeneration = generation

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard startGeneration == generation else { return }

        guard let targetWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotAvailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(targetWindow.frame.width), 1)
        configuration.height = max(Int(targetWindow.frame.height), 1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "appspip.capture.samples"))
        try await stream.startCapture()
        guard startGeneration == generation else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
    }

    func stop() async {
        generation += 1
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        DispatchQueue.main.async { [sampleHandler] in
            sampleHandler(sampleBuffer)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .captureStreamStoppedWithError, object: error)
        }
    }
}

enum CaptureError: LocalizedError {
    case windowNotAvailable

    var errorDescription: String? {
        switch self {
        case .windowNotAvailable:
            return "The frontmost window could not be captured."
        }
    }
}

extension Notification.Name {
    static let captureStreamStoppedWithError = Notification.Name("captureStreamStoppedWithError")
}
