import Bubilator88Core

/// Mount an image whose write-protect flag is set BEFORE it is exposed to the
/// machine, including the pending disk-swap slot. A nonzero writeProtected
/// forces protection; zero preserves the image's own tab, matching the macOS
/// app. Returns image count on success, or 0 for invalid drive/image/data.
/// Additive counterpart of b88_mount_disk; that function's behavior is unchanged.
@_cdecl("b88_mount_disk_protected")
public func b88_mount_disk_protected(_ handle: UnsafeMutableRawPointer?, _ drive: Int32,
  _ input: UnsafePointer<UInt8>?, _ len: Int32, _ imageIndex: Int32, _ writeProtected: Int32) -> Int32 {
  guard let c = context(handle), (0...1).contains(drive) else { return 0 }
  var disks = D88Disk.parseAll(data: bytes(input, len))
  let image = Int(imageIndex)
  guard disks.indices.contains(image) else { return 0 }
  disks[image].writeProtected = disks[image].writeProtected || writeProtected != 0
  c.pc88.mountDisk(drive: Int(drive), disk: disks[image])
  return Int32(disks.count)
}
