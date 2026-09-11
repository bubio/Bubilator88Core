/// Protocol to allow Pc88Bus to communicate with InterruptController
/// without creating a circular dependency.
package protocol InterruptControllerRef: AnyObject {
  var maskSound: Bool { get set }
  func writeControlPort(_ value: UInt8)
  func writeMaskPort(_ value: UInt8)
}

/// Wrapper class for InterruptController (struct) to satisfy InterruptControllerRef protocol.
/// Machine owns this box; Pc88Bus holds a weak reference to it.
package final class InterruptControllerBox: InterruptControllerRef {
  package var controller: InterruptController

  package init() {
    self.controller = InterruptController()
  }

  // MARK: - InterruptControllerRef

  package var maskSound: Bool {
    get { controller.maskSound }
    set { controller.maskSound = newValue }
  }

  package func writeControlPort(_ value: UInt8) {
    controller.writeControlPort(value)
  }

  package func writeMaskPort(_ value: UInt8) {
    controller.writeMaskPort(value)
  }
}
