import Bubilator88Automation

/// Encode host-owned RGBA8 pixels using the common, platform-independent PNG
/// encoder. This pure size-then-copy function never touches a machine. Returns
/// the full PNG length, or -1 for invalid dimensions/insufficient pixel data.
/// Width and height must each be 1...4096; len must cover width*height*4 bytes.
@_cdecl("b88_encode_png")
public func b88_encode_png(_ pixels: UnsafePointer<UInt8>?, _ len: Int32, _ width: Int32, _ height: Int32,
                            _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int32) -> Int32 {
  guard let pixels, width > 0, height > 0, width <= 4096, height <= 4096,
        Int64(len) >= Int64(width) * Int64(height) * 4 else { return -1 }
  let png = PNGEncoder.encodeRGB(rgba: bytes(pixels, width * height * 4), width: Int(width), height: Int(height))
  return copyOut(png, output, capacity)
}
