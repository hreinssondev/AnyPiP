import AppKit
import ApplicationServices
import CoreGraphics

struct PermissionManager {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static var isScreenRecordingTrusted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    private static func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
