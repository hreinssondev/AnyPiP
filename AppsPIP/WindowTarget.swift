import AppKit
import ApplicationServices
import CoreGraphics

struct WindowTarget {
    let windowID: CGWindowID
    let processID: pid_t
    let appName: String
    let title: String
    let frame: CGRect
    let accessibilityWindow: AXUIElement
}
