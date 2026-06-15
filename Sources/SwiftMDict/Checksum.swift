enum MDictChecksum {
  static func adler32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
    let modulo: UInt32 = 65_521
    var a: UInt32 = 1
    var b: UInt32 = 0
    var index = bytes.startIndex

    while index != bytes.endIndex {
      var remaining = 5_552
      while remaining > 0, index != bytes.endIndex {
        a += UInt32(bytes[index])
        b += a
        bytes.formIndex(after: &index)
        remaining -= 1
      }
      a %= modulo
      b %= modulo
    }

    return (b << 16) | a
  }
}
