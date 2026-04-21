/// Protocol to allow Pc88Bus to communicate with InterruptController
/// without creating a circular dependency.
public protocol InterruptControllerRef: AnyObject {
    var maskSound: Bool { get set }
    func writeControlPort(_ value: UInt8)
    func writeMaskPort(_ value: UInt8)
}

/// Wrapper class for InterruptController (struct) to satisfy InterruptControllerRef protocol.
/// Machine owns this box; Pc88Bus holds a weak reference to it.
public final class InterruptControllerBox: InterruptControllerRef {
    public var controller: InterruptController

    public init() {
        self.controller = InterruptController()
    }

    // MARK: - InterruptControllerRef

    public var maskSound: Bool {
        get { controller.maskSound }
        set { controller.maskSound = newValue }
    }

    public func writeControlPort(_ value: UInt8) {
        controller.writeControlPort(value)
    }

    public func writeMaskPort(_ value: UInt8) {
        controller.writeMaskPort(value)
    }
}
