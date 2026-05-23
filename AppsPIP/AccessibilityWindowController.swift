import AppKit
import ApplicationServices
import CoreGraphics

struct AccessibilityWindowController {
    static func frontmostWindow() -> WindowTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return windowTarget(for: app)
    }

    static func windowTarget(for app: NSRunningApplication) -> WindowTarget? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue)

        let windowElement: AXUIElement
        if focusedResult == .success, let focusedValue {
            windowElement = focusedValue as! AXUIElement
        } else if let firstWindow = firstWindow(for: appElement) {
            windowElement = firstWindow
        } else {
            return nil
        }

        let title = stringAttribute(kAXTitleAttribute, from: windowElement) ?? app.localizedName ?? "Window"
        let frame = frameAttribute(from: windowElement) ?? .zero

        guard let windowID = matchingWindowID(processID: app.processIdentifier, title: title, frame: frame) else {
            return nil
        }

        return WindowTarget(
            windowID: windowID,
            processID: app.processIdentifier,
            appName: app.localizedName ?? "Unknown App",
            title: title,
            frame: frame,
            accessibilityWindow: windowElement
        )
    }

    static func minimize(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    static func restore(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    static func currentFrame(of window: AXUIElement) -> CGRect? {
        frameAttribute(from: window)
    }

    static func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var position = frame.origin
        guard let positionValue = AXValueCreate(.cgPoint, &position) else { return }

        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)

        if currentFrame(of: window)?.size != frame.size {
            var size = frame.size
            guard let sizeValue = AXValueCreate(.cgSize, &size) else { return }
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    static func fakeHide(_ window: AXUIElement, preserving frame: CGRect) -> Bool {
        let parkingFrame = bottomRightParkingFrame(for: frame)
        setFrame(parkingFrame, of: window)
        return true
    }

    private static func bottomRightParkingFrame(for frame: CGRect) -> CGRect {
        guard !NSScreen.screens.isEmpty else {
            return CGRect(x: frame.maxX + 24, y: frame.minY, width: frame.width, height: frame.height)
        }

        let sourceScreenFrame = cgScreenFrame(containing: frame) ?? cgScreenFrames().first ?? frame

        // Keep the parked window near the screen it came from. Mission Control uses
        // window bounds when laying out Spaces, so huge parking coordinates make the
        // desktop appear zoomed far away.
        let x = sourceScreenFrame.maxX - 1
        let y = min(
            max(frame.minY, sourceScreenFrame.minY),
            sourceScreenFrame.maxY - 1
        )

        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    private static func cgScreenFrame(containing frame: CGRect) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return cgScreenFrames().first { $0.contains(center) }
            ?? cgScreenFrames().max { lhs, rhs in
                intersectionArea(lhs, frame) < intersectionArea(rhs, frame)
            }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func cgScreenFrames() -> [CGRect] {
        guard let primaryScreen = NSScreen.screens.first else { return [] }
        let primaryHeight = primaryScreen.frame.height

        return NSScreen.screens.map { screen in
            CGRect(
                x: screen.frame.minX,
                y: primaryHeight - screen.frame.minY - screen.frame.height,
                width: screen.frame.width,
                height: screen.frame.height
            )
        }
    }

    private static func firstWindow(for appElement: AXUIElement) -> AXUIElement? {
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement]
        else {
            return nil
        }

        return windows.first
    }

    private static func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frameAttribute(from element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private static func matchingWindowID(processID: pid_t, title: String, frame: CGRect) -> CGWindowID? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let candidates = infoList.filter { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return ownerPID == processID
        }

        if let titledMatch = candidates.first(where: { info in
            let windowTitle = info[kCGWindowName as String] as? String
            return !title.isEmpty && windowTitle == title
        }), let id = titledMatch[kCGWindowNumber as String] as? CGWindowID {
            return id
        }

        let bestFrameMatch = candidates.min { lhs, rhs in
            frameDistance(lhs[kCGWindowBounds as String], frame) < frameDistance(rhs[kCGWindowBounds as String], frame)
        }

        return bestFrameMatch?[kCGWindowNumber as String] as? CGWindowID
    }

    private static func frameDistance(_ boundsValue: Any?, _ target: CGRect) -> CGFloat {
        guard let boundsValue,
              let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary)
        else {
            return .greatestFiniteMagnitude
        }

        return abs(bounds.minX - target.minX)
            + abs(bounds.minY - target.minY)
            + abs(bounds.width - target.width)
            + abs(bounds.height - target.height)
    }

    private static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }
}
