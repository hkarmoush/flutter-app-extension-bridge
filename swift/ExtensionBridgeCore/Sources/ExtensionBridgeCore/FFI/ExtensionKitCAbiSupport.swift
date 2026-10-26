import Darwin
import Foundation

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Runtime helper primitives used by generated `<Name>ExtensionKit` `@_cdecl`
/// C-ABI entrypoints (`eb_reload_widget_timelines`, `eb_reload_control_widgets`,
/// and `eb_la_<key>_*`) as well as Swift-side state stores.
///
/// Centralizing C-pointer conversion, buffer bounds checking, and
/// `WidgetCenter` / iOS 18 `ControlCenter` dispatch in `ExtensionBridgeCore`
/// keeps generated Swift code concise and strictly `Sendable`.
public enum ExtensionKitCAbiSupport: Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var widgetReloadSpy: (@Sendable (String?) -> Void)?
    nonisolated(unsafe) private static var controlReloadSpy: (@Sendable (String?) -> Void)?

    /// Installs optional spy callbacks for testing widget and control timeline
    /// reloads in unit tests without requiring a running SpringBoard session.
    public static func installTestReloadSpies(
        onWidgetReload: (@Sendable (String?) -> Void)? = nil,
        onControlReload: (@Sendable (String?) -> Void)? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        widgetReloadSpy = onWidgetReload
        controlReloadSpy = onControlReload
    }

    /// Triggers `WidgetCenter.shared.reloadTimelines(ofKind:)` (or
    /// `reloadAllTimelines()` when `kind` is `nil`).
    public static func reloadWidgetTimelines(kind: String? = nil) {
        lock.lock()
        let spy = widgetReloadSpy
        lock.unlock()
        spy?(kind)

        #if canImport(WidgetKit)
        if #available(iOS 14.0, macOS 11.0, *) {
            if let kind = kind, !kind.isEmpty {
                WidgetCenter.shared.reloadTimelines(ofKind: kind)
            } else {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        #endif
    }

    /// Triggers `WidgetCenter` timeline reload from a nullable C string pointer
    /// passed across `@_cdecl` FFI.
    public static func reloadWidgetTimelines(cStringKind: UnsafePointer<CChar>?) {
        let kind = decodeOptionalCString(cStringKind)
        reloadWidgetTimelines(kind: kind)
    }

    /// Triggers iOS 18+ `ControlCenter.shared.reloadControls(ofKind:)` (or
    /// `reloadAllControls()` when `kind` is `nil`).
    public static func reloadControlWidgets(kind: String? = nil) {
        lock.lock()
        let spy = controlReloadSpy
        lock.unlock()
        spy?(kind)

        #if canImport(WidgetKit) && os(iOS)
        if #available(iOS 18.0, *) {
            if let kind = kind, !kind.isEmpty {
                ControlCenter.shared.reloadControls(ofKind: kind)
            } else {
                ControlCenter.shared.reloadAllControls()
            }
        }
        #endif
    }

    /// Triggers iOS 18+ `ControlCenter` reload from a nullable C string pointer
    /// passed across `@_cdecl` FFI.
    public static func reloadControlWidgets(cStringKind: UnsafePointer<CChar>?) {
        let kind = decodeOptionalCString(cStringKind)
        reloadControlWidgets(kind: kind)
    }

    /// Decodes a nullable UTF-8 C string pointer into a Swift `String?`.
    @inlinable
    public static func decodeOptionalCString(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer = pointer else { return nil }
        return String(cString: pointer)
    }

    /// Decodes a UTF-8 C string pointer into UTF-8 `Data`, returning `nil` if
    /// `pointer` is `nil`.
    @inlinable
    public static func decodeUTF8Data(_ pointer: UnsafePointer<CChar>?) -> Data? {
        guard let str = decodeOptionalCString(pointer) else { return nil }
        return str.data(using: .utf8)
    }

    /// Safely copies a Swift `String` as a null-terminated UTF-8 C string into
    /// `outBuffer` of size `capacity`.
    ///
    /// - Returns `0` on success, or `-1` if `outBuffer` is `nil`, `capacity <= 0`,
    ///   or the UTF-8 byte length plus null terminator exceeds `capacity`.
    @discardableResult
    public static func copyCString(
        _ string: String,
        to outBuffer: UnsafeMutablePointer<CChar>?,
        capacity: Int32
    ) -> Int32 {
        guard let outBuffer = outBuffer, capacity > 0 else { return -1 }
        let utf8 = Array(string.utf8)
        guard utf8.count + 1 <= Int(capacity) else { return -1 }
        for (idx, byte) in utf8.enumerated() {
            outBuffer[idx] = CChar(bitPattern: byte)
        }
        outBuffer[utf8.count] = 0
        return 0
    }
}
