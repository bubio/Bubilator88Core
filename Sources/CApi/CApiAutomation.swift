// CApiAutomation.swift — the MCP tools for AI agents (Bubilator88Automation).
//
// The host owns the transport (on macOS the app serves Streamable HTTP) and
// passes each JSON-RPC message through here. Call from the thread that runs
// the frames, between frames, as with every other function: the tools run
// frames themselves. Every function here must be `public` (see CApi.swift).

import Bubilator88Automation
import Foundation

/// Handle one MCP JSON-RPC message (`len` bytes of UTF-8 JSON). Returns the
/// length of the reply, which `b88_mcp_reply` copies out, or 0 when the
/// message needs none (a notification).
@_cdecl("b88_mcp_handle")
public func b88_mcp_handle(_ handle: UnsafeMutableRawPointer?,
                           _ json: UnsafePointer<UInt8>?, _ len: Int32) -> Int32 {
  guard let c = context(handle) else { return 0 }
  c.mcpReply = c.mcp.handle(Data(bytes(json, len))).map(Array.init) ?? []
  return Int32(c.mcpReply.count)
}

/// Copy the reply from the last `b88_mcp_handle` into `out` (`cap` bytes).
/// Returns the reply's full length; pass a nil buffer to ask for it.
@_cdecl("b88_mcp_reply")
public func b88_mcp_reply(_ handle: UnsafeMutableRawPointer?,
                          _ out: UnsafeMutablePointer<UInt8>?, _ cap: Int32) -> Int32 {
  guard let c = context(handle) else { return 0 }
  return copyOut(c.mcpReply, out, cap)
}
