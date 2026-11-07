// bubilator88-mcp — a headless PC-8801 as a Model Context Protocol server.
//
// Speaks MCP over stdio: one JSON-RPC message per line on stdin, one reply
// per line on stdout. Any MCP client that starts a command can use it: the
// client starts it and ends it with the session. stdout carries nothing but
// replies; logs go to stderr. With Claude Code, for one:
//
//   claude mcp add bubilator88-headless -- \
//     swift run --package-path <core> bubilator88-mcp [options]

import Bubilator88Automation
import Bubilator88Core
import Foundation
import Logging

let usage = """
usage: bubilator88-mcp [--rom-dir DIR] [--mode MODE] [--clock 4mhz|8mhz]
                       [--disk FILE[:IMAGE]] [--disk2 FILE[:IMAGE]]

  --rom-dir DIR  BIOS ROMs (N88.ROM and the rest). Default: \(BIOSDirectory.defaultDirectory.path)
  --mode MODE    \(BootMode.allCases.map(\.rawValue).joined(separator: ", ")). Default n88-v2.
  --clock        CPU clock. Default 4mhz.
  --disk         D88 image for drive 1 (booted at start); IMAGE picks one in a multi-image file.
  --disk2        D88 image for drive 2.
"""

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(2)
}

LoggingSystem.bootstrap { label in
  var handler = StreamLogHandler.standardError(label: label)
  handler.logLevel = .warning
  return handler
}

var romDirectory = BIOSDirectory.defaultDirectory
var mode = BootMode.n88v2
var clock8MHz = false
var disks: [Int: (path: String, image: Int)] = [:]

func diskArgument(_ text: String) -> (path: String, image: Int) {
  // FILE:IMAGE, but a Windows drive letter's colon is part of the path.
  if let colon = text.lastIndex(of: ":"), let image = Int(text[text.index(after: colon)...]) {
    return (String(text[..<colon]), image)
  }
  return (text, 0)
}

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
  let option = arguments.removeFirst()
  if option == "-h" || option == "--help" {
    print(usage)
    exit(0)
  }
  guard !arguments.isEmpty else { fail("Unknown option or missing value: \(option).\n\(usage)") }
  let value = arguments.removeFirst()
  switch option {
  case "--rom-dir": romDirectory = URL(fileURLWithPath: value, isDirectory: true)
  case "--mode":
    guard let parsed = BootMode(rawValue: value) else { fail("Unknown mode \(value).\n\(usage)") }
    mode = parsed
  case "--clock":
    switch value.lowercased() {
    case "4mhz": clock8MHz = false
    case "8mhz": clock8MHz = true
    default: fail("--clock takes 4mhz or 8mhz.")
    }
  case "--disk": disks[0] = diskArgument(value)
  case "--disk2": disks[1] = diskArgument(value)
  default: fail("Unknown option \(option).\n\(usage)")
  }
}

let host: PC88AutomationHost
do {
  host = try PC88AutomationHost(romDirectory: romDirectory, mode: mode, clock8MHz: clock8MHz)
  for (drive, disk) in disks.sorted(by: { $0.key < $1.key }) {
    let url = URL(fileURLWithPath: disk.path)
    _ = try host.mountDisk(drive: drive, url: url, imageIndex: disk.image, writeProtected: false)
  }
  if !disks.isEmpty {
    // Boot what was just mounted.
    try host.reset(cold: true, mode: nil, clock8MHz: nil)
  }
} catch {
  fail("\(error)")
}

let handler = MCPHandler(tools: AutomationTools(host: host), serverName: "bubilator88-headless")
while let line = readLine(strippingNewline: true) {
  guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
        let reply = handler.handle(Data(line.utf8)) else { continue }
  FileHandle.standardOutput.write(reply + Data("\n".utf8))
}
