import Foundation

enum MDictCrypto {
  static func decryptKeyBlockInfo(_ block: Data) throws -> Data {
    guard block.count >= 8 else {
      throw MDictError.truncatedData(offset: 0, needed: 8, available: block.count)
    }

    let bytes = [UInt8](block)
    let keyMaterial = Array(bytes[4..<8]) + [0x95, 0x36, 0x00, 0x00]
    let key = RIPEMD128.digest(keyMaterial)
    var result = Array(bytes[..<8])
    result += fastDecrypt(Array(bytes[8...]), key: key)
    return Data(result)
  }

  private static func fastDecrypt(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(data.count)
    var previous: UInt8 = 0x36

    for (index, byte) in data.enumerated() {
      let swapped = (byte >> 4) | (byte << 4)
      let decrypted = swapped ^ previous ^ UInt8(truncatingIfNeeded: index) ^ key[index % key.count]
      previous = byte
      result.append(decrypted)
    }

    return result
  }
}

enum RIPEMD128 {
  private static let messageOrder = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
    3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
    1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
  ]

  private static let parallelMessageOrder = [
    5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
    6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
    15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
    8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
  ]

  private static let rotations = [
    11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
    7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
    11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
    11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
  ]

  private static let parallelRotations = [
    8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
    9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
    9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
    15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
  ]

  static func digest(_ input: [UInt8]) -> [UInt8] {
    let blocks = paddedBlocks(input)
    var h0: UInt32 = 0x6745_2301
    var h1: UInt32 = 0xefcd_ab89
    var h2: UInt32 = 0x98ba_dcfe
    var h3: UInt32 = 0x1032_5476

    for words in blocks {
      var a = h0
      var b = h1
      var c = h2
      var d = h3
      var parallelA = h0
      var parallelB = h1
      var parallelC = h2
      var parallelD = h3

      for index in 0..<64 {
        let next = rotateLeft(
          a &+ function(index, b, c, d)
            &+ words[messageOrder[index]]
            &+ constant(index),
          by: rotations[index]
        )
        (a, d, c, b) = (d, c, b, next)

        let parallelNext = rotateLeft(
          parallelA &+ function(63 - index, parallelB, parallelC, parallelD)
            &+ words[parallelMessageOrder[index]]
            &+ parallelConstant(index),
          by: parallelRotations[index]
        )
        (parallelA, parallelD, parallelC, parallelB) =
          (parallelD, parallelC, parallelB, parallelNext)
      }

      let nextH0 = h1 &+ c &+ parallelD
      h1 = h2 &+ d &+ parallelA
      h2 = h3 &+ a &+ parallelB
      h3 = h0 &+ b &+ parallelC
      h0 = nextH0
    }

    return [h0, h1, h2, h3].flatMap(littleEndianBytes)
  }

  private static func function(_ index: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
    switch index {
    case 0..<16:
      return x ^ y ^ z
    case 16..<32:
      return (x & y) | (z & ~x)
    case 32..<48:
      return (x | ~y) ^ z
    default:
      return (x & z) | (y & ~z)
    }
  }

  private static func constant(_ index: Int) -> UInt32 {
    switch index {
    case 0..<16:
      return 0x0000_0000
    case 16..<32:
      return 0x5a82_7999
    case 32..<48:
      return 0x6ed9_eba1
    default:
      return 0x8f1b_bcdc
    }
  }

  private static func parallelConstant(_ index: Int) -> UInt32 {
    switch index {
    case 0..<16:
      return 0x50a2_8be6
    case 16..<32:
      return 0x5c4d_d124
    case 32..<48:
      return 0x6d70_3ef3
    default:
      return 0x0000_0000
    }
  }

  private static func rotateLeft(_ value: UInt32, by count: Int) -> UInt32 {
    (value << UInt32(count)) | (value >> UInt32(32 - count))
  }

  private static func paddedBlocks(_ input: [UInt8]) -> [[UInt32]] {
    var bytes = input
    let bitCount = UInt64(bytes.count) * 8
    bytes.append(0x80)
    while bytes.count % 64 != 56 {
      bytes.append(0)
    }
    for shift in stride(from: 0, through: 56, by: 8) {
      bytes.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
    }

    return stride(from: 0, to: bytes.count, by: 64).map { blockStart in
      stride(from: 0, to: 64, by: 4).map { wordOffset in
        let start = blockStart + wordOffset
        return UInt32(bytes[start])
          | (UInt32(bytes[start + 1]) << 8)
          | (UInt32(bytes[start + 2]) << 16)
          | (UInt32(bytes[start + 3]) << 24)
      }
    }
  }

  private static func littleEndianBytes(_ value: UInt32) -> [UInt8] {
    [
      UInt8(value & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 24) & 0xff),
    ]
  }
}
