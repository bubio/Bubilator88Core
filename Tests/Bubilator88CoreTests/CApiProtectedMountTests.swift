import Testing
@testable import CApi
@_spi(Debug) @testable import Bubilator88Core

@Suite("C ABI Protected Disk Mount")
struct CApiProtectedMountTests {
  @Test func protectionIsInstalledBeforeTheDiskSwapDelay() {
    let machine = b88_create()
    defer { b88_destroy(machine) }
    // A synthetic JP 0 loop advances the sub-CPU clock without user BIOS or
    // device accesses. A disabled-interrupt HALT would intentionally stop it.
    var diskROM = [UInt8](repeating: 0, count: 8192)
    diskROM[0] = 0xc3
    b88_load_rom(machine, 2, diskROM, Int32(diskROM.count))
    var image = [UInt8](repeating: 0, count: 688)
    image[0x1c] = 0xb0; image[0x1d] = 0x02
    #expect(b88_mount_disk_protected(machine, 0, image, Int32(image.count), 0, 1) == 1)
    #expect(b88_is_write_protected(machine, 0) == 1)
    #expect(b88_mount_disk_protected(machine, 0, image, Int32(image.count), 0, 1) == 1)
    #expect(b88_disk_name(machine, 0, nil, 0) == -1)
    let subsystem = context(machine)!.pc88.machine.subSystem
    #expect(!subsystem.useLegacyMode)
    #expect(subsystem.subBus.romram[0] == 0xc3)
    let executed = subsystem.runSubCPU(maxTStates: 400_004)
    #expect(executed >= 400_000)
    #expect(subsystem.subCpuTStates >= 400_000)
    _ = subsystem.runSubCPU(maxTStates: 4)
    #expect(b88_disk_name(machine, 0, nil, 0) >= 0)
    #expect(b88_is_write_protected(machine, 0) == 1)
  }
}
