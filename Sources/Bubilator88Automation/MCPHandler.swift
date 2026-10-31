import Foundation

/// The Model Context Protocol server side, without a transport.
///
/// Takes one JSON-RPC 2.0 message and returns the reply, or nil when the
/// message needs none (a notification, or a response from the client). The
/// stdio server feeds it lines, the app's HTTP server request bodies, and
/// the C ABI whatever the Windows shell receives. Only the tools capability
/// is offered: `initialize`, `ping`, `tools/list` and `tools/call`.
///
/// Call from one thread at a time.
public final class MCPHandler {
  /// Protocol revisions this server speaks, newest first. The tool results
  /// it sends (text and image content) are the same in all of them.
  public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

  public let tools: AutomationTools
  private let serverName: String
  private let serverVersion: String

  public init(tools: AutomationTools, serverName: String = "bubilator88", serverVersion: String = "1.0.0") {
    self.tools = tools
    self.serverName = serverName
    self.serverVersion = serverVersion
  }

  /// Handle one message given as JSON bytes.
  public func handle(_ data: Data) -> Data? {
    let message: JSONValue
    do {
      message = try JSONValue(parsing: data)
    } catch {
      return Self.error(id: .null, code: -32700, "Parse error").encoded()
    }
    return handle(message)?.encoded()
  }

  /// Handle one parsed message.
  public func handle(_ message: JSONValue) -> JSONValue? {
    guard case .object(let fields) = message else {
      // Batches were dropped from the protocol in 2025-06-18.
      return Self.error(id: .null, code: -32600, "Invalid Request: expected one JSON-RPC object")
    }
    guard let method = fields["method"]?.stringValue else {
      // A response or error from the client; this server sends no requests.
      return nil
    }
    guard let id = fields["id"], id != .null else {
      // Notifications (`notifications/initialized`, cancellations) need no
      // reply, and calls run to completion before the next message is read.
      return nil
    }
    let params = fields["params"] ?? [:]

    switch method {
    case "initialize":
      let requested = params["protocolVersion"]?.stringValue
      let version = requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil }
        ?? Self.supportedVersions[0]
      return Self.result(id: id, [
        "protocolVersion": .string(version),
        "capabilities": ["tools": [:]],
        "serverInfo": ["name": .string(serverName), "version": .string(serverVersion)],
        "instructions": """
        Drives a NEC PC-8801 emulator. Time advances only when a tool runs frames \
        (run_frames, key with tap, type_text) unless the app is running it in real time. \
        Look at the screen with screenshot or read_text after acting.
        """,
      ])
    case "ping":
      return Self.result(id: id, [:])
    case "tools/list":
      let list = AutomationTools.definitions.map { definition -> JSONValue in
        [
          "name": .string(definition.name),
          "description": .string(definition.description),
          "inputSchema": definition.inputSchema,
        ]
      }
      return Self.result(id: id, ["tools": .array(list)])
    case "tools/call":
      guard let name = params["name"]?.stringValue else {
        return Self.error(id: id, code: -32602, "Invalid params: name is required")
      }
      var arguments: [String: JSONValue] = [:]
      switch params["arguments"] {
      case nil, .null?: break
      case .object(let a)?: arguments = a
      default: return Self.error(id: id, code: -32602, "Invalid params: arguments must be an object")
      }
      guard let result = tools.call(name, arguments: arguments) else {
        return Self.error(id: id, code: -32602, "Unknown tool: \(name)")
      }
      return Self.result(id: id, Self.encode(result))
    default:
      return Self.error(id: id, code: -32601, "Method not found: \(method)")
    }
  }

  static func encode(_ result: ToolResult) -> JSONValue {
    let content = result.content.map { item -> JSONValue in
      switch item {
      case .text(let text):
        return ["type": "text", "text": .string(text)]
      case .png(let bytes):
        return ["type": "image", "mimeType": "image/png", "data": .string(Data(bytes).base64EncodedString())]
      }
    }
    return ["content": .array(content), "isError": .bool(result.isError)]
  }

  static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
    ["jsonrpc": "2.0", "id": id, "result": result]
  }

  static func error(id: JSONValue, code: Int, _ message: String) -> JSONValue {
    ["jsonrpc": "2.0", "id": id, "error": ["code": JSONValue(code), "message": .string(message)]]
  }
}
