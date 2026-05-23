import AppKit
import CoreMedia

final class FirstMouseVisualEffectView: NSVisualEffectView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override var mouseDownCanMoveWindow: Bool {
        return true
    }
}

final class PiPCloseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override var mouseDownCanMoveWindow: Bool {
        return false
    }
}

final class HoverTrackingView: NSView {
    var onHoverChanged: ((Bool, NSPoint) -> Void)?
    var onHoverEntered: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private let hoverActivationInset: CGFloat = 10
    private var isInsideHoverActivationZone = false

    override var mouseDownCanMoveWindow: Bool {
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        if let oldTrackingArea = trackingArea {
            removeTrackingArea(oldTrackingArea)
        }
        
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = event.locationInWindow
        updateHoverState(isInside: true, location: location)
    }

    override func mouseEntered(with event: NSEvent) {
        let location = event.locationInWindow
        updateHoverState(isInside: true, location: location)
    }

    override func mouseExited(with event: NSEvent) {
        isInsideHoverActivationZone = false
        onHoverChanged?(false, .zero)
    }

    private func updateHoverState(isInside: Bool, location: NSPoint) {
        onHoverChanged?(isInside, location)

        guard shouldTriggerHover(at: location) else {
            isInsideHoverActivationZone = false
            return
        }

        guard !isInsideHoverActivationZone else { return }
        isInsideHoverActivationZone = true
        onHoverEntered?()
    }

    private func shouldTriggerHover(at location: NSPoint) -> Bool {
        let viewLocation = convert(location, from: nil)
        let activationBounds = bounds.insetBy(dx: hoverActivationInset, dy: hoverActivationInset)
        return activationBounds.contains(viewLocation)
    }
}

final class ResizeCornerHandleView: NSView {
    enum Corner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private let corner: Corner
    private var initialFrame: CGRect = .zero
    private var initialMouseLocation: NSPoint = .zero
    private let hitInset: CGFloat = 0
    private let resizeSensitivity: CGFloat = 1.25
    var onResizeEnded: (() -> Void)?

    init(corner: Corner) {
        self.corner = corner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool {
        return false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let expandedBounds = bounds.insetBy(dx: hitInset, dy: hitInset)
        return expandedBounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor
        switch corner {
        case .topLeft, .bottomRight:
            cursor = .resizeUpDown
        case .topRight, .bottomLeft:
            cursor = .resizeLeftRight
        }
        addCursorRect(bounds.insetBy(dx: hitInset, dy: hitInset), cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialFrame = window.frame
        initialMouseLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }

        let currentMouseLocation = NSEvent.mouseLocation
        let deltaX = (currentMouseLocation.x - initialMouseLocation.x) * resizeSensitivity
        let deltaY = (currentMouseLocation.y - initialMouseLocation.y) * resizeSensitivity

        var newFrame = initialFrame

        switch corner {
        case .topLeft:
            newFrame.origin.x += deltaX
            newFrame.size.width -= deltaX
            newFrame.size.height += deltaY
        case .topRight:
            newFrame.size.width += deltaX
            newFrame.size.height += deltaY
        case .bottomLeft:
            newFrame.origin.x += deltaX
            newFrame.size.width -= deltaX
            newFrame.origin.y += deltaY
            newFrame.size.height -= deltaY
        case .bottomRight:
            newFrame.size.width += deltaX
            newFrame.origin.y += deltaY
            newFrame.size.height -= deltaY
        }

        let minSize = window.minSize
        if newFrame.size.width < minSize.width {
            let widthDelta = minSize.width - newFrame.size.width
            newFrame.size.width = minSize.width
            if corner.isLeftEdge {
                newFrame.origin.x -= widthDelta
            }
        }
        if newFrame.size.height < minSize.height {
            let heightDelta = minSize.height - newFrame.size.height
            newFrame.size.height = minSize.height
            if corner.isBottomEdge {
                newFrame.origin.y -= heightDelta
            }
        }

        window.setFrame(newFrame, display: true, animate: false)
    }

    override func mouseUp(with event: NSEvent) {
        onResizeEnded?()
    }
}

final class PiPWindowController: NSWindowController {
    private static let savedFrameKey = "PiPWindowFrame"
    private static let minimumWindowSize = NSSize(width: 220, height: 124)
    private static let resizeHandleSize: CGFloat = 16
    private static let clickMovementTolerance: CGFloat = 3

    private let previewView = CapturePreviewView(frame: .zero)
    private let glanceOverlayView = FirstMouseVisualEffectView()
    private let title: String
    private let shouldPersistFrame: Bool
    var allowsInteractiveControls = true {
        didSet {
            if !allowsInteractiveControls {
                exitButton?.isHidden = true
            }
            updateInteractionMode()
        }
    }
    var allowsClickToSource = true {
        didSet {
            updateInteractionMode()
        }
    }
    var hoverSwitchEnabled = false {
        didSet {
            updateInteractionMode()
        }
    }
    var onGlance: (() -> Void)?
    var onExit: (() -> Void)?
    private var resizeHandles: [ResizeCornerHandleView] = []
    private var exitButton: NSButton!
    private var previewClickRecognizer: NSClickGestureRecognizer?
    private var overlayClickRecognizer: NSClickGestureRecognizer?
    private var rootClickRecognizer: NSClickGestureRecognizer?
    private var exitButtonTrailingConstraint: NSLayoutConstraint?
    private var frameBeforeGlance: CGRect?
    private var isSwitchAnimationInProgress = false
    private var lastHoverSwitchTriggerDate: Date?
    private let hoverSwitchCooldown: TimeInterval = 0.5
    private let sourceAspectRatio: CGFloat
    private var isAdjustingResizeFrame = false
    private var clickStartWindowOrigin: CGPoint?
    var onClose: (() -> Void)?

    init(title: String, sourceFrame: CGRect, restoredFrame: CGRect?, shouldPersistFrame: Bool = true) {
        self.title = title
        self.shouldPersistFrame = shouldPersistFrame
        self.sourceAspectRatio = max(sourceFrame.width, 1) / max(sourceFrame.height, 1)

        let initialFrame = Self.initialFrame(for: sourceFrame, restoredFrame: restoredFrame)
        let window = NSPanel(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = ""
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.minSize = Self.minimumWindowSize
        window.delegate = self
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = makeContentView()
        
        // Setup visual effect overlay
        glanceOverlayView.material = .hudWindow
        glanceOverlayView.blendingMode = .withinWindow
        glanceOverlayView.state = .active
        
        // Starts hidden
        setGlancing(false)
        updateInteractionMode()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.orderFrontRegardless()
        window?.contentView?.subviews.forEach { subview in
            if let button = subview as? NSButton, button.title == "×" {
                subview.layer?.zPosition = .greatestFiniteMagnitude
                subview.superview?.addSubview(subview, positioned: .above, relativeTo: nil)
            }
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // Only render the video stream if we are not in glance/revert mode
        if glanceOverlayView.isHidden {
            previewView.enqueue(sampleBuffer)
        }
    }

    func stop() {
        persistFrame()
        previewView.flush()
        close()
    }

    func persistFrame() {
        guard shouldPersistFrame, let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.savedFrameKey)
    }

    static func restoredFrame() -> CGRect? {
        guard let stored = UserDefaults.standard.string(forKey: savedFrameKey) else { return nil }
        let rect = NSRectFromString(stored)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    func setGlancing(_ glancing: Bool, animated: Bool = true) {
        let shouldAnimate = animated && !hoverSwitchEnabled

        if glancing {
            frameBeforeGlance = window?.frame
        }

        if glancing {
            previewView.flush()
            if hoverSwitchEnabled {
                glanceOverlayView.isHidden = false
                animateParkingIfNeeded(animated: shouldAnimate)
            } else {
                glanceOverlayView.isHidden = true
                window?.orderOut(nil)
                isSwitchAnimationInProgress = false
            }
        } else {
            glanceOverlayView.isHidden = true
            animateRestoreIfNeeded(animated: shouldAnimate)
            frameBeforeGlance = nil
        }
        updateExitButtonPosition(forGlancing: glancing)
        updateInteractionMode()
    }

    private func makeContentView() -> NSView {
        let root = HoverTrackingView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.onHoverChanged = { [weak self] isInside, location in
            self?.updateExitButtonVisibility(isInside: isInside, location: location)
        }
        root.onHoverEntered = { [weak self] in
            self?.handleHoverEntered()
        }

        // 1. Live video preview view
        previewView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(previewView)

        // 2. Glancing/Revert Overlay (gray with big counterclockwise icon)
        glanceOverlayView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(glanceOverlayView)

        let revertImageView = NSImageView()
        revertImageView.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Revert")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 64, weight: .bold))
        revertImageView.contentTintColor = .white
        revertImageView.imageScaling = .scaleProportionallyUpOrDown
        revertImageView.translatesAutoresizingMaskIntoConstraints = false
        glanceOverlayView.addSubview(revertImageView)

        // 3. Exit Button
        exitButton = PiPCloseButton(title: "×", target: self, action: #selector(closeTapped))
        exitButton.bezelStyle = .shadowlessSquare
        exitButton.translatesAutoresizingMaskIntoConstraints = false
        exitButton.isHidden = true
        exitButton.wantsLayer = true
        exitButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        exitButton.layer?.cornerRadius = 19
        exitButton.layer?.zPosition = .greatestFiniteMagnitude
        exitButton.contentTintColor = .white
        exitButton.font = .systemFont(ofSize: 22, weight: .bold)
        exitButton.isBordered = false
        exitButton.setButtonType(.momentaryChange)
        root.addSubview(exitButton)

        // Setup gestures
        let rootClickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(glanceTapped))
        root.addGestureRecognizer(rootClickRecognizer)
        rootClickRecognizer.delegate = self
        self.rootClickRecognizer = rootClickRecognizer

        let previewClickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(glanceTapped))
        previewView.addGestureRecognizer(previewClickRecognizer)
        previewClickRecognizer.delegate = self
        self.previewClickRecognizer = previewClickRecognizer

        let overlayClickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(glanceTapped))
        glanceOverlayView.addGestureRecognizer(overlayClickRecognizer)
        overlayClickRecognizer.delegate = self
        self.overlayClickRecognizer = overlayClickRecognizer

        let topLeftHandle = ResizeCornerHandleView(corner: .topLeft)
        let topRightHandle = ResizeCornerHandleView(corner: .topRight)
        let bottomLeftHandle = ResizeCornerHandleView(corner: .bottomLeft)
        let bottomRightHandle = ResizeCornerHandleView(corner: .bottomRight)
        resizeHandles = [topLeftHandle, topRightHandle, bottomLeftHandle, bottomRightHandle]

        for handle in resizeHandles {
            handle.translatesAutoresizingMaskIntoConstraints = false
            handle.onResizeEnded = { [weak self] in
                self?.finishResize()
            }
            root.addSubview(handle)
        }

        root.addSubview(exitButton, positioned: .above, relativeTo: nil)

        exitButtonTrailingConstraint = exitButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -7)

        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: root.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            glanceOverlayView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glanceOverlayView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            glanceOverlayView.topAnchor.constraint(equalTo: root.topAnchor),
            glanceOverlayView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            revertImageView.centerXAnchor.constraint(equalTo: glanceOverlayView.centerXAnchor),
            revertImageView.centerYAnchor.constraint(equalTo: glanceOverlayView.centerYAnchor),
            revertImageView.widthAnchor.constraint(equalToConstant: 72),
            revertImageView.heightAnchor.constraint(equalToConstant: 72),

            topLeftHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topLeftHandle.topAnchor.constraint(equalTo: root.topAnchor),
            topLeftHandle.widthAnchor.constraint(equalToConstant: Self.resizeHandleSize),
            topLeftHandle.heightAnchor.constraint(equalToConstant: Self.resizeHandleSize),

            topRightHandle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topRightHandle.topAnchor.constraint(equalTo: root.topAnchor),
            topRightHandle.widthAnchor.constraint(equalToConstant: Self.resizeHandleSize),
            topRightHandle.heightAnchor.constraint(equalToConstant: Self.resizeHandleSize),

            bottomLeftHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomLeftHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomLeftHandle.widthAnchor.constraint(equalToConstant: Self.resizeHandleSize),
            bottomLeftHandle.heightAnchor.constraint(equalToConstant: Self.resizeHandleSize),

            bottomRightHandle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomRightHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomRightHandle.widthAnchor.constraint(equalToConstant: Self.resizeHandleSize),
            bottomRightHandle.heightAnchor.constraint(equalToConstant: Self.resizeHandleSize),

            exitButtonTrailingConstraint!,
            exitButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            exitButton.widthAnchor.constraint(equalToConstant: 38),
            exitButton.heightAnchor.constraint(equalToConstant: 38)
        ])

        return root
    }

    @objc private func glanceTapped() {
        guard didStayWithinClickMovementTolerance() else { return }
        onGlance?()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    private func handleHoverEntered() {
        guard allowsInteractiveControls, hoverSwitchEnabled, !isSwitchAnimationInProgress else { return }
        let now = Date()
        if let lastHoverSwitchTriggerDate,
           now.timeIntervalSince(lastHoverSwitchTriggerDate) < hoverSwitchCooldown {
            return
        }
        lastHoverSwitchTriggerDate = now
        onGlance?()
    }

    private func updateInteractionMode() {
        let clicksEnabled = allowsClickToSource && !hoverSwitchEnabled
        rootClickRecognizer?.isEnabled = clicksEnabled
        previewClickRecognizer?.isEnabled = clicksEnabled
        overlayClickRecognizer?.isEnabled = clicksEnabled
    }

    private func animateParkingIfNeeded(animated: Bool) {
        guard let window else { return }
        let sourceFrame = frameBeforeGlance ?? window.frame
        let parkedFrame = parkedFrame(for: sourceFrame)

        isSwitchAnimationInProgress = true
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(parkedFrame, display: true)
            } completionHandler: {
                self.isSwitchAnimationInProgress = false
            }
        } else {
            window.setFrame(parkedFrame, display: true)
            isSwitchAnimationInProgress = false
        }
    }

    private func animateRestoreIfNeeded(animated: Bool) {
        guard let window, let frameBeforeGlance else { return }

        isSwitchAnimationInProgress = true
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frameBeforeGlance, display: true)
            } completionHandler: {
                self.isSwitchAnimationInProgress = false
            }
        } else {
            window.setFrame(frameBeforeGlance, display: true)
            isSwitchAnimationInProgress = false
        }
    }

    private func parkedFrame(for frame: CGRect) -> CGRect {
        let scale: CGFloat = 0.42
        let width = max(Self.minimumWindowSize.width, floor(frame.width * scale))
        let height = max(Self.minimumWindowSize.height, floor(frame.height * scale))

        let visibleFrame = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 100, y: 100, width: 800, height: 600)
        let margin: CGFloat = 16
        let x = visibleFrame.maxX - width - margin
        let y = visibleFrame.maxY - height - margin
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func initialFrame(for sourceFrame: CGRect, restoredFrame: CGRect?) -> CGRect {
        let aspect = max(sourceFrame.width, 1) / max(sourceFrame.height, 1)

        if let restoredFrame {
            return sanitizeRestoredFrame(restoredFrame, aspect: aspect)
        }

        guard let screen = NSScreen.main else {
            return sanitize(frame: CGRect(x: 100, y: 100, width: 360, height: 220))
        }

        let visible = screen.visibleFrame
        let width: CGFloat = 360
        let height = width / aspect
        let x = visible.maxX - width - 29
        let y = visible.maxY - height - 27
        return sanitize(frame: CGRect(x: x, y: y, width: width, height: height))
    }

    private static func sanitizeRestoredFrame(_ restoredFrame: CGRect, aspect: CGFloat) -> CGRect {
        let area = max(restoredFrame.width * restoredFrame.height, minimumWindowSize.width * minimumWindowSize.height)
        var width = max(minimumWindowSize.width, sqrt(area * aspect))
        let height = max(minimumWindowSize.height, width / aspect)

        if height == minimumWindowSize.height {
            width = max(minimumWindowSize.width, height * aspect)
        }

        let center = CGPoint(x: restoredFrame.midX, y: restoredFrame.midY)
        return sanitize(frame: CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        ))
    }

    private static func sanitize(frame: CGRect) -> CGRect {
        var sanitized = frame
        sanitized.size.width = max(sanitized.size.width, minimumWindowSize.width)
        sanitized.size.height = max(sanitized.size.height, minimumWindowSize.height)

        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(sanitized) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            sanitized.origin.x = min(max(sanitized.origin.x, visible.minX), visible.maxX - sanitized.size.width)
            sanitized.origin.y = min(max(sanitized.origin.y, visible.minY), visible.maxY - sanitized.size.height)
        }

        return sanitized
    }
}

private extension ResizeCornerHandleView.Corner {
    var isLeftEdge: Bool {
        switch self {
        case .topLeft, .bottomLeft:
            return true
        case .topRight, .bottomRight:
            return false
        }
    }

    var isBottomEdge: Bool {
        switch self {
        case .bottomLeft, .bottomRight:
            return true
        case .topLeft, .topRight:
            return false
        }
    }
}

extension PiPWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        persistFrame()
        onExit?()
    }

    func windowDidMove(_ notification: Notification) {
        persistFrame()
    }

    func windowDidResize(_ notification: Notification) {
        adjustWindowFrameToSourceAspectIfNeeded()
        persistFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        finishResize()
    }
}

extension PiPWindowController: NSGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard allowsClickToSource else { return false }
        clickStartWindowOrigin = window?.frame.origin
        guard let rootView = exitButton.superview, !exitButton.isHidden else {
            return true
        }

        let locationInRoot = rootView.convert(event.locationInWindow, from: nil)
        let protectedFrame = exitButton.frame.insetBy(dx: -8, dy: -8)
        return !protectedFrame.contains(locationInRoot)
    }
}

extension PiPWindowController {
    private func didStayWithinClickMovementTolerance() -> Bool {
        guard let clickStartWindowOrigin, let currentWindowOrigin = window?.frame.origin else {
            return true
        }

        self.clickStartWindowOrigin = nil
        return abs(currentWindowOrigin.x - clickStartWindowOrigin.x) <= Self.clickMovementTolerance
            && abs(currentWindowOrigin.y - clickStartWindowOrigin.y) <= Self.clickMovementTolerance
    }

    private func finishResize() {
        adjustWindowFrameToSourceAspectIfNeeded()
        persistFrame()
    }

    private func updateExitButtonPosition(forGlancing glancing: Bool) {
        exitButtonTrailingConstraint?.constant = glancing ? -5 : -7
    }

    private func updateExitButtonVisibility(isInside: Bool, location: NSPoint) {
        guard allowsInteractiveControls else {
            exitButton.isHidden = true
            return
        }
        guard let window = window else { return }
        
        if !isInside {
            exitButton.isHidden = true
            return
        }
        
        let windowHeight = window.frame.height
        
        // Show exit button only in top half of window
        if location.y > windowHeight / 2 {
            exitButton.isHidden = false
        } else {
            exitButton.isHidden = true
        }
    }

    private func adjustWindowFrameToSourceAspectIfNeeded() {
        guard let window, !isAdjustingResizeFrame else { return }

        let currentFrame = window.frame
        let currentAspect = max(currentFrame.width, 1) / max(currentFrame.height, 1)
        let difference = abs(currentAspect - sourceAspectRatio) / max(sourceAspectRatio, 0.0001)
        guard difference > 0.002 else { return }

        let targetWidth = currentFrame.width
        let targetHeight = max(Self.minimumWindowSize.height, targetWidth / sourceAspectRatio)
        let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        let correctedFrame = CGRect(
            x: center.x - (targetWidth / 2),
            y: center.y - (targetHeight / 2),
            width: targetWidth,
            height: targetHeight
        )

        isAdjustingResizeFrame = true
        window.setFrame(Self.sanitize(frame: correctedFrame), display: true, animate: false)
        isAdjustingResizeFrame = false
    }

}
