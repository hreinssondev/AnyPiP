import CoreGraphics
import Darwin

final class WindowOrderController {
    private typealias CGSConnectionID = UInt32
    private typealias CGSMainConnectionIDFunction = @convention(c) () -> CGSConnectionID
    private typealias CGSOrderWindowFunction = @convention(c) (CGSConnectionID, CGWindowID, Int32, CGWindowID) -> CGError

    private let connectionID: CGSConnectionID
    private let orderWindow: CGSOrderWindowFunction

    init?() {
        let handles = [
            dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
            dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
            dlopen(nil, RTLD_NOW)
        ].compactMap { $0 }

        guard let mainConnectionID: CGSMainConnectionIDFunction = Self.loadSymbol("CGSMainConnectionID", from: handles),
              let orderWindow: CGSOrderWindowFunction = Self.loadSymbol("CGSOrderWindow", from: handles)
        else {
            return nil
        }

        self.connectionID = mainConnectionID()
        self.orderWindow = orderWindow
    }

    /// Push the given window behind the bottommost on-screen window.
    func sendToBack(windowID: CGWindowID) {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        // Find the bottommost window that is not the target window itself.
        // CGWindowListCopyWindowInfo returns windows front-to-back, so the last element is the bottommost.
        for windowInfo in windowList.reversed() {
            guard let otherWindowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  otherWindowID != windowID else {
                continue
            }
            _ = orderWindow(connectionID, windowID, -1, otherWindowID) // -1 = below
            return
        }
    }

    private static func loadSymbol<T>(_ name: String, from handles: [UnsafeMutableRawPointer]) -> T? {
        for handle in handles {
            if let symbol = dlsym(handle, name) {
                return unsafeBitCast(symbol, to: T.self)
            }
        }
        return nil
    }
}
