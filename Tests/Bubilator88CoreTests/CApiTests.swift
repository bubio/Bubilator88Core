import Foundation
import Testing
@testable import Bubilator88Core
import CApi

/// The C ABI functions that mirror what the macOS app uses, called the way
/// the Windows shell calls them.
@Suite("C ABI Tests")
struct CApiTests {

  /// Run `body` with a fresh handle, destroyed afterwards.
  private func withHandle(_ body: (UnsafeMutableRawPointer) -> Void) {
    let handle = b88_create()
    defer { b88_destroy(handle) }
    body(handle)
  }

  /// Call a size-then-copy string function twice, as a host would.
  private func readString(_ fill: (UnsafeMutablePointer<UInt8>?, Int32) -> Int32) -> String? {
    let length = fill(nil, 0)
    guard length >= 0 else { return nil }
    var buffer = [UInt8](repeating: 0xEE, count: Int(length) + 1)
    let again = buffer.withUnsafeMutableBufferPointer { fill($0.baseAddress, Int32($0.count)) }
    #expect(again == length)
    #expect(buffer[Int(length)] == 0)
    return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
  }

  private func readBytes(_ fill: (UnsafeMutablePointer<UInt8>?, Int32) -> Int32) -> [UInt8] {
    let length = fill(nil, 0)
    guard length > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: Int(length))
    _ = buffer.withUnsafeMutableBufferPointer { fill($0.baseAddress, Int32($0.count)) }
    return buffer
  }

  @Test func settingsReadBack() {
    withHandle { h in
      b88_set_dipsw1(h, 0xC2)
      #expect(b88_get_dipsw1(h) == 0xC2)
      b88_set_dipsw2(h, 0xB9)
      #expect(b88_get_dipsw2(h) == 0xB9)
      b88_set_memory_wait_dip(h, 1)
      #expect(b88_get_memory_wait_dip(h) == 1)
      b88_set_cpu_overclock(h, 4)
      #expect(b88_get_cpu_overclock(h) == 4)
      b88_set_force_opn(h, 1)
      #expect(b88_get_force_opn(h) == 1)
    }
  }

  @Test func badStemIsRejected() {
    withHandle { h in
      var out = [Float](repeating: 0, count: 8)
      #expect(b88_drain_audio_stem(h, 4, &out, 4) == -1)
      #expect(b88_drain_audio_stem(h, 0, &out, 4) == 0)
    }
  }

  @Test func immersiveStemsFollowTheMix() {
    withHandle { h in
      b88_set_immersive_output(h, 1)
      _ = b88_run_frame(h)
      var mix = [Float](repeating: 0, count: 8192)
      let pairs = b88_drain_audio(h, &mix, 4096)
      #expect(pairs > 0)
      var stem = [Float](repeating: 0, count: 8192)
      #expect(b88_drain_audio_stem(h, 1, &stem, 4096) == pairs)
    }
  }

  @Test func tapeMountAndEject() {
    withHandle { h in
      #expect(b88_is_tape_loaded(h) == 0)
      let cmt: [UInt8] = [0xD3, 0xD3, 0xD3, 0x41]
      #expect(b88_mount_tape(h, cmt, Int32(cmt.count)) == 2)
      #expect(b88_is_tape_loaded(h) == 1)
      #expect(b88_tape_progress(h) == 0)
      b88_eject_tape(h)
      #expect(b88_is_tape_loaded(h) == 0)
    }
  }

  @Test func emptyDriveHasNoName() {
    withHandle { h in
      #expect(b88_disk_name(h, 0, nil, 0) == -1)
      #expect(b88_is_write_protected(h, 0) == 0)
      #expect(b88_take_disk_written(h) == 0)
      #expect(b88_take_dirty_disk(h, 0) == 0)
    }
  }

  @Test func pastedTextPressesKeys() {
    withHandle { h in
      #expect(b88_paste_is_idle(h) == 1)
      b88_paste_text(h, "a")
      #expect(b88_paste_is_idle(h) == 0)
      for _ in 0..<12 { b88_paste_tick(h) }
      #expect(b88_paste_is_idle(h) == 1)
    }
  }

  @Test func cancelStopsEveryTypist() {
    withHandle { h in
      b88_paste_text(h, "LIST\n")
      b88_tape_autoboot_start(h)
      #expect(b88_tape_autoboot_phase(h) == 1)
      b88_paste_cancel(h)
      #expect(b88_paste_is_idle(h) == 1)
      #expect(b88_tape_autoboot_phase(h) == 0)
    }
  }

  @Test func memoryImageNeedsTheRightSize() {
    withHandle { h in
      let short = [UInt8](repeating: 0, count: 16)
      #expect(b88_memory_image_boot_start(h, short, Int32(short.count)) == 0)
      #expect(b88_memory_image_boot_tick(h) == 0)
      let image = [UInt8](repeating: 0, count: PC88.memoryImageSize)
      #expect(b88_memory_image_boot_start(h, image, Int32(image.count)) == 1)
      #expect(b88_memory_image_boot_tick(h) == 1)
    }
  }

  @Test func saveStateCarriesThumbnailAndHostSections() {
    withHandle { h in
      let thumb: [UInt8] = [1, 2, 3]
      let tag = b88_fourcc("AMTA")
      let meta = Array("{}".utf8)
      var extra: [UInt8] = []
      for v in [tag, UInt32(meta.count)] {
        extra += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
      }
      extra += meta
      let length = b88_save_state_ex(h, thumb, Int32(thumb.count), extra, Int32(extra.count))
      #expect(length > 0)
      var blob = [UInt8](repeating: 0, count: Int(length))
      #expect(b88_save_state_read(h, &blob, length) == length)

      #expect(b88_state_timestamp(blob, Int32(blob.count)) > 0)
      let got = readBytes { b88_state_section(blob, Int32(blob.count), tag, $0, $1) }
      #expect(got == meta)
      #expect(b88_state_section(blob, Int32(blob.count), b88_fourcc("NONE"), nil, 0) == -1)
      #expect(b88_load_state(h, blob, Int32(blob.count)) == 1)
    }
  }

  @Test func patFileIsListedByGroup() {
    let text = "[Infinite lives]\n0100:C000:09\n"
    let data = Array(text.utf8)
    let listing = readString { b88_pat_parse(data, Int32(data.count), $0, $1) }
    let expected = PATFile.parse(text)
    #expect(listing?.hasPrefix("G\t" + (expected.first?.name ?? "")) == true)
    let codes = listing?.split(separator: "\n").filter { $0.hasPrefix("C\t") } ?? []
    #expect(!codes.isEmpty)
    #expect(codes.count == expected.first?.codes.count)
  }

  @Test func screenTextAndGlyph() {
    withHandle { h in
      #expect(readString { b88_copy_text(h, $0, $1) } != nil)
      #expect(b88_glyph(h, 0x41, nil, 0) == 8)
    }
  }
}
