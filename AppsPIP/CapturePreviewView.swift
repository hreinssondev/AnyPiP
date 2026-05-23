import AppKit
import AVFoundation
import CoreMedia

final class CapturePreviewView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override var mouseDownCanMoveWindow: Bool {
        return true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    private func setupLayer() {
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = displayLayer
        displayLayer.frame = bounds
    }
}
