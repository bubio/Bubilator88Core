import Testing
@testable import EmulatorCore

@Suite("SubSystem Tests")
struct SubSystemTests {

    // MARK: - PIO Handshake Helpers

    /// Send a command byte to sub-CPU via ATN handshake.
    /// ATN=1 → write Port B (command) → ATN=0
    private func sendCommand(_ sub: SubSystem, cmd: UInt8) {
        // Set ATN=1 (mainPortCH bit 3 → port C bit 7)
        sub.pioWrite(port: 0xFF, value: 0x0F)  // CH, bit 3, set
        // Write command byte to Port B
        sub.pioWrite(port: 0xFD, value: cmd)
        // Clear ATN=0
        sub.pioWrite(port: 0xFF, value: 0x0E)  // CH, bit 3, clear
        // Set DAV then clear (STB handshake)
        sub.pioWrite(port: 0xFF, value: 0x09)  // CH, bit 0, set
        sub.pioWrite(port: 0xFF, value: 0x08)  // CH, bit 0, clear
    }

    /// Send a parameter/data byte to sub-CPU (normal handshake, no ATN).
    private func sendParam(_ sub: SubSystem, value: UInt8) {
        sub.pioWrite(port: 0xFD, value: value)
        sub.pioWrite(port: 0xFF, value: 0x09)  // DAV set
        sub.pioWrite(port: 0xFF, value: 0x08)  // DAV clear
    }

    /// Read one byte from sub-CPU via RFD/DAC handshake.
    private func readByte(_ sub: SubSystem) -> UInt8 {
        // Set RFD (mainPortCH bit 1)
        sub.pioWrite(port: 0xFF, value: 0x0B)  // CH, bit 1, set
        let value = sub.pioRead(port: 0xFC)
        // Set DAC (mainPortCH bit 2) to advance queue
        sub.pioWrite(port: 0xFF, value: 0x0D)  // CH, bit 2, set
        // Clear DAC
        sub.pioWrite(port: 0xFF, value: 0x0C)  // CH, bit 2, clear
        // Clear RFD
        sub.pioWrite(port: 0xFF, value: 0x0A)  // CH, bit 1, clear
        return value
    }

    /// Check if sub-CPU has data available (sub CH bit 0).
    private func subHasData(_ sub: SubSystem) -> Bool {
        return sub.portC & 0x01 != 0
    }

    /// Check if sub-CPU is ready (sub CH bit 1).
    private func subIsReady(_ sub: SubSystem) -> Bool {
        return sub.portC & 0x02 != 0
    }

    // MARK: - Disk Helpers

    /// Create a D88 disk with one sector at the given track/sector.
    private func makeDiskWithSector(
        track: Int = 0, c: UInt8 = 0, h: UInt8 = 0,
        r: UInt8 = 1, n: UInt8 = 1, data: [UInt8]? = nil
    ) -> D88Disk {
        var disk = D88Disk()
        var sector = D88Disk.Sector()
        sector.c = c
        sector.h = h
        sector.r = r
        sector.n = n
        sector.data = data ?? Array(0..<(128 << Int(n))).map { UInt8($0 & 0xFF) }
        disk.tracks[track] = [sector]
        return disk
    }

    // MARK: - Basic State Tests

    @Test func resetState() {
        let sub = SubSystem()
        sub.reset()

        #expect(sub.portB == 0x00)
        #expect(sub.drives[0] == nil)
        #expect(sub.drives[1] == nil)
        #expect(subIsReady(sub))
        #expect(!subHasData(sub))
    }

    @Test func pioReadWrite() {
        let sub = SubSystem()
        sub.reset()

        sub.pioWrite(port: 0xFD, value: 0x42)
        #expect(sub.portB == 0x42)

        let status = sub.pioRead(port: 0xFE)
        #expect(status & 0x04 != 0)  // sub DAC
    }

    @Test func pioBitSetReset() {
        let sub = SubSystem()
        sub.reset()

        // Set main CH bit 3 (ATN → port C bit 7)
        sub.pioWrite(port: 0xFF, value: 0x0F)
        #expect(sub.portC & 0x80 != 0)

        // Clear it
        sub.pioWrite(port: 0xFF, value: 0x0E)
        #expect(sub.portC & 0x80 == 0)
    }

    @Test func mountEjectDisk() {
        let sub = SubSystem()
        sub.reset()

        #expect(sub.hasDisk(drive: 0) == false)
        var disk = D88Disk()
        disk.name = "TEST"
        sub.mountDisk(drive: 0, disk: disk)
        #expect(sub.hasDisk(drive: 0) == true)
        sub.ejectDisk(drive: 0)
        #expect(sub.hasDisk(drive: 0) == false)
    }

    @Test func twoDriveSupport() {
        let sub = SubSystem()
        sub.reset()

        var disk0 = D88Disk()
        disk0.name = "DISK0"
        var disk1 = D88Disk()
        disk1.name = "DISK1"
        sub.mountDisk(drive: 0, disk: disk0)
        sub.mountDisk(drive: 1, disk: disk1)

        #expect(sub.hasDisk(drive: 0) == true)
        #expect(sub.hasDisk(drive: 1) == true)
        #expect(sub.drives[0]?.name == "DISK0")
        #expect(sub.drives[1]?.name == "DISK1")
    }

    @Test func invalidDriveIgnored() {
        let sub = SubSystem()
        sub.reset()
        sub.mountDisk(drive: 5, disk: D88Disk())
        #expect(sub.hasDisk(drive: 5) == false)
    }

    // MARK: - Initialize (0x00)

    @Test func initializeFiresInterrupt() {
        let sub = SubSystem()
        sub.reset()

        var fired = false
        sub.onInterrupt = { fired = true }

        sendCommand(sub, cmd: 0x00)
        #expect(fired == true)
    }

    @Test func initializeResetsTracks() {
        let sub = SubSystem()
        sub.reset()
        sub.currentTrack[0] = 10
        sub.currentTrack[1] = 20

        sendCommand(sub, cmd: 0x00)

        #expect(sub.currentTrack[0] == 0)
        #expect(sub.currentTrack[1] == 0)
    }

    @Test("Z80 sub-CPU Port C does not raise legacy INT3")
    func z80SubCpuPortCDoesNotRaiseLegacyInterrupt() {
        let sub = SubSystem()
        sub.loadDiskROM([0x3E, 0x0F, 0xD3, 0xFF, 0x76])  // LD A,0F / OUT (FF),A / HALT
        sub.reset()

        var fired = 0
        sub.onInterrupt = { fired += 1 }

        let executed = sub.runSubCPUUntilSwitch(maxTStates: 64)

        #expect(sub.useLegacyMode == false)
        #expect(executed > 0)
        #expect(fired == 0)
        #expect(sub.pio.portC[PIO8255.Side.sub.rawValue][PIO8255.PortCHalf.ch.rawValue].data & 0x08 != 0)
    }

    @Test("Time-budgeted sub-CPU run is not cut short by Port C polling")
    func timeBudgetedRunIgnoresPortCPollBoundary() {
        let sub = SubSystem()
        sub.loadDiskROM([0xDB, 0xFE, 0xDB, 0xFE, 0x76])  // IN A,(FE) / IN A,(FE) / HALT
        sub.reset()

        let executed = sub.runSubCPU(maxTStates: 64)

        #expect(executed > 0)
        #expect(sub.subCpu.halted == true)
        #expect(sub.subCpu.pc == 0x0004)
    }

    // MARK: - ReadData (0x02) + SendResultStatus (0x06) + SendData (0x03)

    @Test func readDataSuccess() {
        let sub = SubSystem()
        sub.reset()

        // Create disk with sector at track 0 (C=0, H=0), sector 1, 256 bytes
        let disk = makeDiskWithSector(track: 0, c: 0, h: 0, r: 1, n: 1)
        sub.mountDisk(drive: 0, disk: disk)

        var intCount = 0
        sub.onInterrupt = { intCount += 1 }

        // ReadData: sectorCount=1, drive=0, track=0, sector=1
        sendCommand(sub, cmd: 0x02)
        sendParam(sub, value: 1)    // sectorCount
        sendParam(sub, value: 0)    // driveNo
        sendParam(sub, value: 0)    // trackNo
        sendParam(sub, value: 1)    // sectorNo
        #expect(intCount == 1)

        // SendResultStatus
        sendCommand(sub, cmd: 0x06)
        #expect(intCount == 2)
        let status = readByte(sub)
        #expect(status & 0x80 != 0)  // complete
        #expect(status & 0x40 != 0)  // data available
        #expect(status & 0x01 == 0)  // no error

        // SendData
        sendCommand(sub, cmd: 0x03)
        #expect(intCount == 3)

        // Read 256 bytes of sector data
        var data: [UInt8] = []
        for _ in 0..<256 {
            data.append(readByte(sub))
        }
        #expect(data[0] == 0x00)
        #expect(data[1] == 0x01)
        #expect(data[255] == 0xFF)
    }

    @Test func readDataSectorNotFound() {
        let sub = SubSystem()
        sub.reset()

        var disk = D88Disk()
        disk.name = "EMPTY"
        sub.mountDisk(drive: 0, disk: disk)

        var fired = false
        sub.onInterrupt = { fired = true }

        // ReadData on empty disk
        sendCommand(sub, cmd: 0x02)
        sendParam(sub, value: 1)
        sendParam(sub, value: 0)
        sendParam(sub, value: 0)
        sendParam(sub, value: 1)
        #expect(fired == true)

        // Check result status = error
        sendCommand(sub, cmd: 0x06)
        let status = readByte(sub)
        #expect(status & 0x01 != 0)  // error bit set
    }

    @Test func readDataNoDisk() {
        let sub = SubSystem()
        sub.reset()

        var fired = false
        sub.onInterrupt = { fired = true }

        // ReadData with no disk mounted
        sendCommand(sub, cmd: 0x02)
        sendParam(sub, value: 1)
        sendParam(sub, value: 0)
        sendParam(sub, value: 0)
        sendParam(sub, value: 1)

        #expect(fired == true)

        // Result should be error
        sendCommand(sub, cmd: 0x06)
        let status = readByte(sub)
        #expect(status & 0x01 != 0)
    }

    @Test func multiSectorRead() {
        let sub = SubSystem()
        sub.reset()

        // Create disk with 3 sectors on track 0
        var disk = D88Disk()
        for i: UInt8 in 1...3 {
            var sector = D88Disk.Sector()
            sector.c = 0; sector.h = 0; sector.r = i; sector.n = 0  // 128 bytes each
            sector.data = Array(repeating: i, count: 128)
            disk.tracks[0].append(sector)
        }
        sub.mountDisk(drive: 0, disk: disk)

        // ReadData: 3 sectors starting at sector 1
        sendCommand(sub, cmd: 0x02)
        sendParam(sub, value: 3)    // sectorCount
        sendParam(sub, value: 0)    // driveNo
        sendParam(sub, value: 0)    // trackNo
        sendParam(sub, value: 1)    // sectorNo

        // Check status
        sendCommand(sub, cmd: 0x06)
        let status = readByte(sub)
        #expect(status == 0xC0)  // complete + data

        // SendData → 128*3 = 384 bytes
        sendCommand(sub, cmd: 0x03)
        for sect in 1...3 {
            for _ in 0..<128 {
                let byte = readByte(sub)
                #expect(byte == UInt8(sect))
            }
        }
    }

    // MARK: - SendDriveStatus (0x07)

    @Test func sendDriveStatusMounted() {
        let sub = SubSystem()
        sub.reset()

        var disk = D88Disk()
        disk.name = "TEST"
        sub.mountDisk(drive: 0, disk: disk)

        sendCommand(sub, cmd: 0x07)
        let status = readByte(sub)
        #expect(status & 0x10 != 0)  // drive 0 connected
    }

    @Test func sendDriveStatusEmpty() {
        let sub = SubSystem()
        sub.reset()

        sendCommand(sub, cmd: 0x07)
        let status = readByte(sub)
        #expect(status == 0x00)  // no drives connected
    }

    @Test func sendDriveStatusBothDrives() {
        let sub = SubSystem()
        sub.reset()
        sub.mountDisk(drive: 0, disk: D88Disk())
        sub.mountDisk(drive: 1, disk: D88Disk())

        sendCommand(sub, cmd: 0x07)
        let status = readByte(sub)
        #expect(status & 0x10 != 0)  // drive 0
        #expect(status & 0x20 != 0)  // drive 1
    }

    // MARK: - SenseDeviceStatus (0x14)

    @Test func senseDeviceStatus() {
        let sub = SubSystem()
        sub.reset()
        sub.mountDisk(drive: 0, disk: D88Disk())

        sendCommand(sub, cmd: 0x14)
        sendParam(sub, value: 0x00)  // drive 0

        let st3 = readByte(sub)
        #expect(st3 & 0x20 != 0)  // Ready
        #expect(st3 & 0x08 != 0)  // Two-sided
        #expect(st3 & 0x10 != 0)  // Track 0
    }

    @Test func senseDeviceStatusWriteProtected() {
        let sub = SubSystem()
        sub.reset()

        var disk = D88Disk()
        disk.writeProtected = true
        sub.mountDisk(drive: 0, disk: disk)

        sendCommand(sub, cmd: 0x14)
        sendParam(sub, value: 0x00)

        let st3 = readByte(sub)
        #expect(st3 & 0x40 != 0)  // Write protected
    }

    // MARK: - DriveReadyCheck (0x23)

    @Test func driveReadyCheckDiskInserted() {
        let sub = SubSystem()
        sub.reset()
        sub.mountDisk(drive: 0, disk: D88Disk())

        sendCommand(sub, cmd: 0x23)
        sendParam(sub, value: 0x00)

        let status = readByte(sub)
        #expect(status == 0x00)  // disk inserted
    }

    @Test func driveReadyCheckNoDisk() {
        let sub = SubSystem()
        sub.reset()

        sendCommand(sub, cmd: 0x23)
        sendParam(sub, value: 0x00)

        let status = readByte(sub)
        #expect(status == 0xFF)  // no disk
    }

    // MARK: - TestMemory (0x08)

    @Test func testMemoryReturnsOK() {
        let sub = SubSystem()
        sub.reset()

        sendCommand(sub, cmd: 0x08)
        let status = readByte(sub)
        #expect(status == 0x80)  // OK
    }

    // MARK: - SetSurfaceMode (0x17) / SendSurfaceMode (0x18)

    @Test func surfaceMode() {
        let sub = SubSystem()
        sub.reset()

        // Set double-sided for drive 0
        sendCommand(sub, cmd: 0x17)
        sendParam(sub, value: 0x01)  // bit 0 = drive 0 double-sided

        // Read it back
        sendCommand(sub, cmd: 0x18)
        let mode = readByte(sub)
        #expect(mode == 0x01)
    }

    // MARK: - ATN Framing

    @Test("ATN framing: bytes without ATN are parameters, not commands")
    func atnFraming() {
        let sub = SubSystem()
        sub.reset()

        var intCount = 0
        sub.onInterrupt = { intCount += 1 }

        // Start ReadData command with ATN
        sendCommand(sub, cmd: 0x02)

        // These are parameter bytes (no ATN), not new commands
        sendParam(sub, value: 1)    // sectorCount — NOT command 0x01
        sendParam(sub, value: 0)    // driveNo
        sendParam(sub, value: 0)    // trackNo
        sendParam(sub, value: 1)    // sectorNo

        // Should have fired exactly 1 INT (from ReadData completion)
        // NOT from interpreting 0x01 as WriteData command
        #expect(intCount == 1)
    }

    // MARK: - WriteData (0x01)

    @Test func writeDataSuccess() {
        let sub = SubSystem()
        sub.reset()

        // Create disk with an existing sector to write to
        let disk = makeDiskWithSector(
            track: 0, c: 0, h: 0, r: 1, n: 0,
            data: Array(repeating: 0x00, count: 128)
        )
        sub.mountDisk(drive: 0, disk: disk)

        var fired = false
        sub.onInterrupt = { fired = true }

        // WriteData: sectorCount=1, drive=0, track=0, sector=1
        sendCommand(sub, cmd: 0x01)
        sendParam(sub, value: 1)    // sectorCount
        sendParam(sub, value: 0)    // driveNo
        sendParam(sub, value: 0)    // trackNo
        sendParam(sub, value: 1)    // sectorNo

        // INT3 should NOT have fired yet (waiting for data)
        #expect(fired == false)

        // Send 128 bytes of data
        for i in 0..<128 {
            sendParam(sub, value: UInt8(i & 0xFF))
        }

        // NOW INT3 should fire
        #expect(fired == true)

        // Check result
        sendCommand(sub, cmd: 0x06)
        let status = readByte(sub)
        #expect(status & 0x01 == 0)  // no error

        // Verify data was written
        let written = sub.drives[0]?.findSector(track: 0, c: 0, h: 0, r: 1)
        #expect(written?.data[0] == 0x00)
        #expect(written?.data[127] == 0x7F)
    }

    @Test func writeDataProtected() {
        let sub = SubSystem()
        sub.reset()

        var disk = D88Disk()
        disk.writeProtected = true
        var sector = D88Disk.Sector()
        sector.c = 0; sector.h = 0; sector.r = 1; sector.n = 0
        sector.data = Array(repeating: 0xAA, count: 128)
        disk.tracks[0] = [sector]
        sub.mountDisk(drive: 0, disk: disk)

        // WriteData
        sendCommand(sub, cmd: 0x01)
        sendParam(sub, value: 1)
        sendParam(sub, value: 0)
        sendParam(sub, value: 0)
        sendParam(sub, value: 1)

        // Send data
        for i in 0..<128 {
            sendParam(sub, value: UInt8(i))
        }

        // Check result — should be error (write protected)
        sendCommand(sub, cmd: 0x06)
        let status = readByte(sub)
        #expect(status & 0x01 != 0)  // error

        // Original data unchanged
        let original = sub.drives[0]?.findSector(track: 0, c: 0, h: 0, r: 1)
        #expect(original?.data[0] == 0xAA)
    }

    // MARK: - Full Boot Sequence

    @Test("Full boot sequence: Init → DriveStatus → ReadData → Status → SendData")
    func fullBootSequence() {
        let sub = SubSystem()
        sub.reset()

        // Create boot disk with sector at track 0, sector 1
        var disk = D88Disk()
        var sector = D88Disk.Sector()
        sector.c = 0; sector.h = 0; sector.r = 1; sector.n = 1  // 256 bytes
        sector.data = Array(0..<256).map { UInt8($0 & 0xFF) }
        disk.tracks[0] = [sector]
        sub.mountDisk(drive: 0, disk: disk)

        var intCount = 0
        sub.onInterrupt = { intCount += 1 }

        // Step 1: Initialize
        sendCommand(sub, cmd: 0x00)
        #expect(intCount == 1)

        // Step 2: SendResultStatus after Init
        sendCommand(sub, cmd: 0x06)
        #expect(intCount == 2)
        let initStatus = readByte(sub)
        #expect(initStatus & 0x80 != 0)  // complete

        // Step 3: SendDriveStatus
        sendCommand(sub, cmd: 0x07)
        #expect(intCount == 3)
        let driveStatus = readByte(sub)
        #expect(driveStatus & 0x10 != 0)  // drive 0 connected

        // Step 4: ReadData (track 0, sector 1, 1 sector)
        sendCommand(sub, cmd: 0x02)
        sendParam(sub, value: 1)    // sectorCount
        sendParam(sub, value: 0)    // driveNo
        sendParam(sub, value: 0)    // trackNo
        sendParam(sub, value: 1)    // sectorNo
        #expect(intCount == 4)

        // Step 5: SendResultStatus
        sendCommand(sub, cmd: 0x06)
        #expect(intCount == 5)
        let readStatus = readByte(sub)
        #expect(readStatus == 0xC0)  // complete + data

        // Step 6: SendData
        sendCommand(sub, cmd: 0x03)
        #expect(intCount == 6)

        // Read boot sector data
        var bootData: [UInt8] = []
        for _ in 0..<256 {
            bootData.append(readByte(sub))
        }
        #expect(bootData[0] == 0x00)
        #expect(bootData[255] == 0xFF)

        // Queue should be exhausted
        #expect(!subHasData(sub))
    }

    // MARK: - Double-sided disk access

    @Test("ReadData accesses correct D88 track in double-sided mode")
    func readDataDoubleSided() {
        let sub = SubSystem()
        sub.reset()

        // Create disk with sector on track 1 (C=0, H=1 in D88)
        var disk = D88Disk()
        var sector = D88Disk.Sector()
        sector.c = 0; sector.h = 1; sector.r = 1; sector.n = 0
        sector.data = Array(repeating: 0xBB, count: 128)
        disk.tracks[1] = [sector]  // D88 track 1 = C0H1
        sub.mountDisk(drive: 0, disk: disk)

        // Set double-sided mode for drive 0
        sendCommand(sub, cmd: 0x17)
        sendParam(sub, value: 0x01)

        // ReadData: track 1 in double-sided = D88 track 1
        sendCommand(sub, cmd: 0x02)
        sendParam(sub, value: 1)    // sectorCount
        sendParam(sub, value: 0)    // driveNo
        sendParam(sub, value: 1)    // trackNo (=D88 track 1)
        sendParam(sub, value: 1)    // sectorNo

        sendCommand(sub, cmd: 0x06)
        let status = readByte(sub)
        #expect(status == 0xC0)

        sendCommand(sub, cmd: 0x03)
        let byte = readByte(sub)
        #expect(byte == 0xBB)
    }

    @Test("ReadData accesses correct D88 track in single-sided mode")
    func readDataSingleSided() {
        let sub = SubSystem()
        sub.reset()

        // Create disk with sector on D88 track 2 (C=1, H=0)
        var disk = D88Disk()
        var sector = D88Disk.Sector()
        sector.c = 1; sector.h = 0; sector.r = 1; sector.n = 0
        sector.data = Array(repeating: 0xCC, count: 128)
        disk.tracks[2] = [sector]  // D88 track 2 = C1H0
        sub.mountDisk(drive: 0, disk: disk)

        // Single-sided mode (default): track 1 → D88 track 2 (cylinder 1, head 0)
        sendCommand(sub, cmd: 0x02)
        sendParam(sub, value: 1)    // sectorCount
        sendParam(sub, value: 0)    // driveNo
        sendParam(sub, value: 1)    // trackNo (single-sided: track 1 → D88 track 2)
        sendParam(sub, value: 1)    // sectorNo

        sendCommand(sub, cmd: 0x06)
        let status = readByte(sub)
        #expect(status == 0xC0)

        sendCommand(sub, cmd: 0x03)
        let byte = readByte(sub)
        #expect(byte == 0xCC)
    }

    // MARK: - Load&Go (0x10)

    @Test func loadAndGo() {
        let sub = SubSystem()
        sub.reset()

        let disk = makeDiskWithSector(
            track: 0, c: 0, h: 0, r: 1, n: 1,
            data: Array(repeating: 0x42, count: 256)
        )
        sub.mountDisk(drive: 0, disk: disk)

        var fired = false
        sub.onInterrupt = { fired = true }

        sendCommand(sub, cmd: 0x10)
        #expect(fired == true)

        // Check status
        sendCommand(sub, cmd: 0x06)
        let status = readByte(sub)
        #expect(status == 0xC0)  // complete + data

        // Get data via SendData
        sendCommand(sub, cmd: 0x03)
        let first = readByte(sub)
        #expect(first == 0x42)
    }

    // MARK: - ErrorInfo (0x13)

    @Test func errorInfoReturns8Bytes() {
        let sub = SubSystem()
        sub.reset()

        sendCommand(sub, cmd: 0x13)

        var bytes: [UInt8] = []
        for _ in 0..<8 {
            bytes.append(readByte(sub))
        }
        #expect(bytes.count == 8)
    }

    // MARK: - PIO Handshake Edge Cases

    @Test("Sub-CPU ACK set after Port B write, cleared after DAV clear")
    func pioHandshakeACK() {
        let sub = SubSystem()
        sub.reset()

        #expect(subIsReady(sub))

        // Write to Port B → sub acknowledges (DAC)
        sub.pioWrite(port: 0xFD, value: 0x42)
        #expect(sub.portC & 0x04 != 0)  // sub DAC set

        // Set DAV then clear → sub clears DAC
        sub.pioWrite(port: 0xFF, value: 0x09)
        sub.pioWrite(port: 0xFF, value: 0x08)
        #expect(sub.portC & 0x04 == 0)  // sub DAC cleared
    }
}
