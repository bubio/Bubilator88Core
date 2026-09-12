# ``Bubilator88Core``

Emulate an NEC PC-8801-FA: run it a frame at a time, and take its picture and
sound.

## Overview

Bubilator88Core is the emulation core of the macOS emulator
[Bubilator88](https://github.com/bubio/Bubilator88). It has no user interface
and does no file I/O, drawing or audio output of its own. A host feeds it
ROMs, disks and keys, calls ``PC88/runFrame()`` at the machine's frame rate,
and after each frame takes a 640×400 RGBA picture and 44.1kHz stereo samples.

Everything starts from ``PC88``:

```swift
import Bubilator88Core

let pc88 = PC88()

// No ROMs are bundled. Pass images dumped from a real machine.
pc88.loadROM(.n88Basic, data: n88ROM)
pc88.loadROM(.nBasic, data: n80ROM)
for bank in 0..<4 {
  pc88.loadROM(.n88Ext(bank: bank), data: n88ExtROM[bank])
}
pc88.loadROM(.disk, data: diskROM)
pc88.loadROM(.font, data: fontROM)
pc88.loadROM(.kanji1, data: kanji1ROM)

pc88.setBootMode(.n88v2)
if let disk = D88Disk.parse(data: d88Bytes) {
  pc88.mountDisk(drive: 0, disk: disk)
}
pc88.applyBootStrap()  // boot from disk if drive 0 holds one
pc88.reset()

var frame = [UInt8](repeating: 0, count: PC88.frameBufferSize)

// Repeat at pc88.frameRate (about 55 or 62Hz, never exactly 60).
pc88.runFrame()
pc88.render(into: &frame, blinkCursor: true)
let audio = pc88.takeAudioSamples()
```

The values that cross into the host — `D88Disk`, `PC88Key`, `BootMode`,
`MonitorType` and `TapeFormat` — are defined in the PC88Types module, which
`import Bubilator88Core` brings in with it.

### Threading

Use a ``PC88`` from one serial queue for its whole lifetime. Its callbacks
run on that queue too, during ``PC88/runFrame()``.

### API stability

``PC88``, the types it uses, and the other symbols on these pages are the
stable API: from 1.0.0 they change only with the major version. Symbols seen
through `@_spi(Debug) import Bubilator88Core` exist for Bubilator88's
debugger and change without notice.

## Topics

### The machine

- ``PC88``

### b88script

Record play and play it back, as text a person can read and edit.

- ``ScriptParser``
- ``ScriptStep``
- ``KeyAction``
- ``ScriptError``
- ``ScriptPlayer``
- ``ScriptRecorder``
- ``ScriptWriter``

### Pasting text

- ``TextPasteQueue``

### Save state files

- ``SaveStateFile``
- ``SaveStateError``
