import Foundation
import Testing
import CApi

@Suite("C ABI PNG Encoding")
struct CApiPNGTests {
  @Test func pngEncodingIsPureAndSupportsSizeThenCopy() {
    let pixels: [UInt8] = [255, 0, 0, 255]
    let count = pixels.withUnsafeBufferPointer { b88_encode_png($0.baseAddress, 4, 1, 1, nil, 0) }
    #expect(count > 8)
    var output = [UInt8](repeating: 0, count: Int(max(0, count)))
    let copied = pixels.withUnsafeBufferPointer { b88_encode_png($0.baseAddress, 4, 1, 1, &output, count) }
    #expect(copied == count)
    #expect(Array(output.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
    #expect(b88_encode_png(nil, 0, 1, 1, nil, 0) == -1)
    #expect(b88_encode_png(nil, 0, Int32.max, Int32.max, nil, 0) == -1)
  }
}
