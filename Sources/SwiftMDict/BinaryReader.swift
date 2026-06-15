import Foundation

struct BinaryReader {
  private let data: Data
  private(set) var offset: Int

  init(_ data: Data, offset: Int = 0) {
    self.data = data
    self.offset = offset
  }

  var remainingCount: Int {
    data.count - offset
  }

  var isAtEnd: Bool {
    offset >= data.count
  }

  mutating func readUInt8() throws -> UInt8 {
    try require(1)
    let value = data[offset]
    offset += 1
    return value
  }

  mutating func readUInt16BE() throws -> UInt16 {
    try require(2)
    let value =
      (UInt16(data[offset]) << 8)
      | UInt16(data[offset + 1])
    offset += 2
    return value
  }

  mutating func readUInt32BE() throws -> UInt32 {
    try require(4)
    let value =
      (UInt32(data[offset]) << 24)
      | (UInt32(data[offset + 1]) << 16)
      | (UInt32(data[offset + 2]) << 8)
      | UInt32(data[offset + 3])
    offset += 4
    return value
  }

  mutating func readUInt32LE() throws -> UInt32 {
    try require(4)
    let value =
      UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
    offset += 4
    return value
  }

  mutating func readUInt64BE() throws -> UInt64 {
    try require(8)
    let value =
      (UInt64(data[offset]) << 56)
      | (UInt64(data[offset + 1]) << 48)
      | (UInt64(data[offset + 2]) << 40)
      | (UInt64(data[offset + 3]) << 32)
      | (UInt64(data[offset + 4]) << 24)
      | (UInt64(data[offset + 5]) << 16)
      | (UInt64(data[offset + 6]) << 8)
      | UInt64(data[offset + 7])
    offset += 8
    return value
  }

  mutating func readData(count: Int) throws -> Data {
    guard count >= 0 else {
      throw MDictError.invalidFormat("Negative byte count requested.")
    }
    try require(count)
    let range = offset..<(offset + count)
    offset += count
    return data.subdata(in: range)
  }

  mutating func skip(_ count: Int) throws {
    guard count >= 0 else {
      throw MDictError.invalidFormat("Negative skip requested.")
    }
    try require(count)
    offset += count
  }

  mutating func readNullTerminatedBytes(codeUnitWidth: Int) throws -> [UInt8] {
    guard codeUnitWidth == 1 || codeUnitWidth == 2 else {
      throw MDictError.invalidFormat("Unsupported string code unit width \(codeUnitWidth).")
    }

    let start = offset
    while remainingCount >= codeUnitWidth {
      let isTerminator =
        data[offset] == 0
        && (codeUnitWidth == 1 || data[offset + 1] == 0)
      if isTerminator {
        let result = [UInt8](data[start..<offset])
        offset += codeUnitWidth
        return result
      }
      offset += codeUnitWidth
    }

    throw MDictError.truncatedData(
      offset: offset,
      needed: codeUnitWidth,
      available: remainingCount
    )
  }

  mutating func skipZeroTerminator(codeUnitWidth: Int) throws {
    guard remainingCount >= codeUnitWidth else {
      return
    }

    let isTerminator =
      data[offset] == 0
      && (codeUnitWidth == 1 || data[offset + 1] == 0)
    if isTerminator {
      offset += codeUnitWidth
    }
  }

  private func require(_ count: Int) throws {
    guard count <= remainingCount else {
      throw MDictError.truncatedData(offset: offset, needed: count, available: remainingCount)
    }
  }
}

extension FixedWidthInteger where Self: UnsignedInteger {
  func checkedInt(context: String) throws -> Int {
    guard self <= UInt64(Int.max) else {
      throw MDictError.invalidFormat("\(context) is too large for this platform.")
    }
    return Int(self)
  }
}

extension UInt64 {
  func checkedAdding(_ other: UInt64, context: String) throws -> UInt64 {
    let (result, overflow) = addingReportingOverflow(other)
    guard !overflow else {
      throw MDictError.invalidFormat("\(context) overflows UInt64.")
    }
    return result
  }

  func checkedMultiplying(_ other: UInt64, context: String) throws -> UInt64 {
    let (result, overflow) = multipliedReportingOverflow(by: other)
    guard !overflow else {
      throw MDictError.invalidFormat("\(context) overflows UInt64.")
    }
    return result
  }
}
