import CoreGraphics
import CoreMedia
import ScreenCaptureKit

final class WindowCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let sampleHandler: (CMSampleBuffer) -> Void

    init(sampleHandler: @escaping (CMSampleBuffer) -> Void) {
        self.sampleHandler = sampleHandler
        super.init()
    }

    func start(windowID: CGWindowID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

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
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
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
