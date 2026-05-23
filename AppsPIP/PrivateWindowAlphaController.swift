import CoreGraphics
import Darwin

final class PrivateWindowAlphaController {
    private typealias CGSConnectionID = UInt32
    private typealias CGSMainConnectionIDFunction = @convention(c) () -> CGSConnectionID
    private typealias CGSGetWindowAlphaFunction = @convention(c) (CGSConnectionID, CGWindowID, UnsafeMutablePointer<CGFloat>) -> CGError
    private typealias CGSSetWindowAlphaFunction = @convention(c) (CGSConnectionID, CGWindowID, CGFloat) -> CGError

    private let connectionID: CGSConnectionID
    private let getWindowAlpha: CGSGetWindowAlphaFunction
    private let setWindowAlpha: CGSSetWindowAlphaFunction
    private var originalAlphaByWindowID: [CGWindowID: CGFloat] = [:]
    private(set) var lastHideAttemptDescription = "Private window alpha has not been tried."

    init?() {
        guard let loader = PrivateWindowAlphaSymbolLoader() else { return nil }
        connectionID = loader.mainConnectionID()
        getWindowAlpha = loader.getWindowAlpha
        setWindowAlpha = loader.setWindowAlpha
    }

    func hide(windowID: CGWindowID) -> Bool {
        if originalAlphaByWindowID[windowID] == nil {
            var originalAlpha = CGFloat(1)
            let getOriginalAlphaError = getWindowAlpha(connectionID, windowID, &originalAlpha)
            guard getOriginalAlphaError == .success else {
                lastHideAttemptDescription = "Private alpha could not read the source window alpha: \(getOriginalAlphaError)."
                return false
            }
            originalAlphaByWindowID[windowID] = originalAlpha
        }

        let setAlphaError = setWindowAlpha(connectionID, windowID, 0)
        guard setAlphaError == .success else {
            lastHideAttemptDescription = "Private alpha set failed: \(setAlphaError)."
            return false
        }

        var currentAlpha = CGFloat(1)
        let getCurrentAlphaError = getWindowAlpha(connectionID, windowID, &currentAlpha)
        guard getCurrentAlphaError == .success else {
            lastHideAttemptDescription = "Private alpha was set, but alpha verification failed: \(getCurrentAlphaError)."
            return false
        }

        if currentAlpha <= 0.01 {
            lastHideAttemptDescription = "Private alpha applied. Private window alpha is \(currentAlpha)."
            return true
        }

        lastHideAttemptDescription = "Private alpha returned success, but private window alpha is still \(currentAlpha)."
        return false
    }

    func restore(windowID: CGWindowID) {
        let originalAlpha = originalAlphaByWindowID.removeValue(forKey: windowID) ?? 1
        _ = setWindowAlpha(connectionID, windowID, originalAlpha)
    }

    func restoreAll() {
        let savedAlphaByWindowID = originalAlphaByWindowID
        originalAlphaByWindowID.removeAll()

        for (windowID, originalAlpha) in savedAlphaByWindowID {
            _ = setWindowAlpha(connectionID, windowID, originalAlpha)
        }
    }

    private func publicWindowAlpha(windowID: CGWindowID) -> CGFloat? {
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let windowInfo = windowInfoList.first,
              let alphaValue = windowInfo[kCGWindowAlpha as String]
        else {
            return nil
        }

        if let alpha = alphaValue as? CGFloat {
            return alpha
        }

        if let alpha = alphaValue as? Double {
            return CGFloat(alpha)
        }

        if let alpha = alphaValue as? Float {
            return CGFloat(alpha)
        }

        if let alpha = alphaValue as? Int {
            return CGFloat(alpha)
        }

        return nil
    }
}

fileprivate struct PrivateWindowAlphaSymbolLoader {
    fileprivate typealias CGSConnectionID = UInt32
    fileprivate typealias CGSMainConnectionIDFunction = @convention(c) () -> CGSConnectionID
    fileprivate typealias CGSGetWindowAlphaFunction = @convention(c) (CGSConnectionID, CGWindowID, UnsafeMutablePointer<CGFloat>) -> CGError
    fileprivate typealias CGSSetWindowAlphaFunction = @convention(c) (CGSConnectionID, CGWindowID, CGFloat) -> CGError

    fileprivate let mainConnectionID: CGSMainConnectionIDFunction
    fileprivate let getWindowAlpha: CGSGetWindowAlphaFunction
    fileprivate let setWindowAlpha: CGSSetWindowAlphaFunction

    init?() {
        let handles = [
            dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
            dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
            dlopen(nil, RTLD_NOW)
        ].compactMap { $0 }

        guard let mainConnectionID: CGSMainConnectionIDFunction = Self.loadSymbol("CGSMainConnectionID", from: handles),
              let getWindowAlpha: CGSGetWindowAlphaFunction = Self.loadSymbol("CGSGetWindowAlpha", from: handles),
              let setWindowAlpha: CGSSetWindowAlphaFunction = Self.loadSymbol("CGSSetWindowAlpha", from: handles)
        else {
            return nil
        }

        self.mainConnectionID = mainConnectionID
        self.getWindowAlpha = getWindowAlpha
        self.setWindowAlpha = setWindowAlpha
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
