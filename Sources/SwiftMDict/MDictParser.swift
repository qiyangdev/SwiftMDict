import Foundation

#if canImport(CoreFoundation)
  import CoreFoundation
#endif

struct MDictParser {
  private let data: Data
  private let limits: MDictLimits
  private var reader: BinaryReader

  init(data: Data, limits: MDictLimits) {
    self.data = data
    self.limits = limits
    self.reader = BinaryReader(data)
  }

  mutating func parse() throws -> ParsedMDict {
    try validateLimit(UInt64(data.count), maximum: limits.maximumFileSize, resource: "File size")

    let header = try parseHeader()
    try validateHeader(header)

    let encoding = try stringEncoding(named: header.encodingName, kind: header.kind)
    let keyEntries = try parseKeySection(
      encoding: encoding,
      encryptedKeyInfo: encryptionFlags(in: header) & 0x02 != 0
    )
    let recordBlocks = try parseRecordSection(expectedEntryCount: keyEntries.count)
    guard reader.isAtEnd else {
      throw MDictError.invalidFormat("MDict data contains unexpected trailing bytes.")
    }

    var totalRecordSize: UInt64 = 0
    for block in recordBlocks {
      totalRecordSize = try totalRecordSize.checkedAdding(
        UInt64(block.decompressedSize),
        context: "Total record size"
      )
    }
    let entries = try attachRecordLengths(to: keyEntries, totalRecordSize: totalRecordSize)

    return ParsedMDict(
      header: header,
      encoding: encoding,
      entries: entries,
      recordBlocks: recordBlocks,
      data: data
    )
  }

  private mutating func parseHeader() throws -> MDictHeader {
    let byteCount = UInt64(try reader.readUInt32BE())
    try validateLimit(byteCount, maximum: limits.maximumHeaderSize, resource: "Header size")

    let headerData = try reader.readData(count: byteCount.checkedInt(context: "Header size"))
    let checksum = try reader.readUInt32LE()
    guard MDictChecksum.adler32(headerData) == checksum else {
      throw MDictError.integrityCheckFailed(section: "header")
    }

    let text = try decodeHeader(headerData)
    let attributes = parseAttributes(from: text)
    let kind = try containerKind(from: text)
    let rawEncoding = attributes["Encoding"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let effectiveEncoding =
      rawEncoding.isEmpty
      ? (kind == .resources ? "UTF-16LE" : "UTF-8")
      : rawEncoding
    return MDictHeader(
      rawText: text,
      attributes: attributes,
      kind: kind,
      effectiveEncodingName: effectiveEncoding
    )
  }

  private func validateHeader(_ header: MDictHeader) throws {
    guard header.generatedByEngineVersion >= 2, header.generatedByEngineVersion < 3 else {
      throw MDictError.unsupported("Only MDict engine version 2.x is supported.")
    }

    let flags = encryptionFlags(in: header)
    if flags & 0x01 != 0 || flags & ~0x03 != 0 {
      throw MDictError.unsupported("This MDict encryption mode is not supported.")
    }
  }

  private func encryptionFlags(in header: MDictHeader) -> Int {
    guard let encrypted = header.attributes["Encrypted"] else {
      return 0
    }
    if encrypted.caseInsensitiveCompare("yes") == .orderedSame
      || encrypted.caseInsensitiveCompare("true") == .orderedSame
    {
      return 1
    }
    return Int(encrypted) ?? 0
  }

  private mutating func parseKeySection(
    encoding: String.Encoding,
    encryptedKeyInfo: Bool
  ) throws -> [ParsedEntry] {
    let metadataStart = reader.offset
    let keyBlockCount = try readLimitedCount(
      maximum: limits.maximumBlockCount,
      resource: "Key block count"
    )
    let declaredEntryCount = try readLimitedCount(
      maximum: limits.maximumEntryCount,
      resource: "Entry count"
    )
    let keyBlockInfoDecompressedSize = try readLimitedSize(
      maximum: limits.maximumDecompressedBlockSize,
      resource: "Key block info decompressed size"
    )
    let keyBlockInfoCompressedSize = try readLimitedSize(
      maximum: limits.maximumCompressedBlockSize,
      resource: "Key block info compressed size"
    )
    let declaredKeyBlockDataSize = try readNumber()
    try validateLimit(
      declaredKeyBlockDataSize,
      maximum: limits.maximumFileSize,
      resource: "Key block data size"
    )
    let metadataEnd = reader.offset
    let metadataChecksum = try reader.readUInt32BE()
    let metadata = data.subdata(in: metadataStart..<metadataEnd)
    guard MDictChecksum.adler32(metadata) == metadataChecksum else {
      throw MDictError.integrityCheckFailed(section: "key section metadata")
    }

    var keyBlockInfoBlock = try reader.readData(count: keyBlockInfoCompressedSize)
    if encryptedKeyInfo {
      keyBlockInfoBlock = try MDictCrypto.decryptKeyBlockInfo(keyBlockInfoBlock)
    }
    let keyBlockInfo = try MDictCompression.decodeBlock(
      keyBlockInfoBlock,
      expectedSize: keyBlockInfoDecompressedSize
    )

    let infos = try parseKeyBlockInfo(
      keyBlockInfo,
      count: keyBlockCount,
      encoding: encoding
    )
    let aggregateEntryCount = try infos.reduce(UInt64(0)) {
      try $0.checkedAdding(UInt64($1.entryCount), context: "Key block entry count")
    }
    guard aggregateEntryCount == UInt64(declaredEntryCount) else {
      throw MDictError.invalidFormat(
        "Key block info entry count mismatch. Expected \(declaredEntryCount), got \(aggregateEntryCount)."
      )
    }

    let aggregateCompressedSize = try infos.reduce(UInt64(0)) {
      try $0.checkedAdding(UInt64($1.compressedSize), context: "Key block compressed size")
    }
    guard aggregateCompressedSize == declaredKeyBlockDataSize else {
      throw MDictError.invalidFormat(
        "Key block data size mismatch. Expected \(declaredKeyBlockDataSize), got \(aggregateCompressedSize)."
      )
    }

    var entries: [ParsedEntry] = []
    entries.reserveCapacity(declaredEntryCount)

    for info in infos {
      let compressedBlock = try reader.readData(count: info.compressedSize)
      let decompressedBlock = try MDictCompression.decodeBlock(
        compressedBlock,
        expectedSize: info.decompressedSize
      )
      entries += try parseKeyBlock(
        decompressedBlock,
        expectedEntries: info.entryCount,
        encoding: encoding
      )
    }

    guard entries.count == declaredEntryCount else {
      throw MDictError.invalidFormat(
        "Key section entry count mismatch. Expected \(declaredEntryCount), got \(entries.count)."
      )
    }
    return entries
  }

  private func parseKeyBlockInfo(
    _ data: Data,
    count: Int,
    encoding: String.Encoding
  ) throws -> [KeyBlockInfo] {
    var infoReader = BinaryReader(data)
    var blocks: [KeyBlockInfo] = []
    blocks.reserveCapacity(count)

    var totalDecompressedSize: UInt64 = 0
    for _ in 0..<count {
      let entryCount = try readLimitedCount(
        from: &infoReader,
        maximum: limits.maximumEntryCount,
        resource: "Key block entry count"
      )
      _ = try readSizedTerm(from: &infoReader, encoding: encoding)
      _ = try readSizedTerm(from: &infoReader, encoding: encoding)
      let compressedSize = try readLimitedSize(
        from: &infoReader,
        maximum: limits.maximumCompressedBlockSize,
        resource: "Key block compressed size"
      )
      let decompressedSize = try readLimitedSize(
        from: &infoReader,
        maximum: limits.maximumDecompressedBlockSize,
        resource: "Key block decompressed size"
      )
      totalDecompressedSize = try totalDecompressedSize.checkedAdding(
        UInt64(decompressedSize),
        context: "Total key block decompressed size"
      )
      try validateLimit(
        totalDecompressedSize,
        maximum: limits.maximumTotalDecompressedSize,
        resource: "Total key block decompressed size"
      )

      blocks.append(
        KeyBlockInfo(
          entryCount: entryCount,
          compressedSize: compressedSize,
          decompressedSize: decompressedSize
        )
      )
    }

    guard infoReader.isAtEnd else {
      throw MDictError.invalidFormat("Key block info contains unexpected trailing bytes.")
    }
    return blocks
  }

  private func parseKeyBlock(
    _ data: Data,
    expectedEntries: Int,
    encoding: String.Encoding
  ) throws -> [ParsedEntry] {
    var keyReader = BinaryReader(data)
    var entries: [ParsedEntry] = []
    entries.reserveCapacity(expectedEntries)

    for _ in 0..<expectedEntries {
      let recordOffset = try keyReader.readUInt64BE()
      let termBytes = try keyReader.readNullTerminatedBytes(
        codeUnitWidth: isUTF16(encoding) ? 2 : 1
      )
      guard let term = String(bytes: termBytes, encoding: encoding) else {
        throw MDictError.invalidFormat("Could not decode key text.")
      }
      entries.append(ParsedEntry(term: term, recordOffset: recordOffset))
    }

    guard keyReader.isAtEnd else {
      throw MDictError.invalidFormat("Key block contains unexpected trailing bytes.")
    }
    return entries
  }

  private mutating func parseRecordSection(expectedEntryCount: Int) throws -> [RecordBlock] {
    let recordBlockCount = try readLimitedCount(
      maximum: limits.maximumBlockCount,
      resource: "Record block count"
    )
    let declaredEntryCount = try readLimitedCount(
      maximum: limits.maximumEntryCount,
      resource: "Record entry count"
    )
    let recordBlockInfoSize = try readLimitedSize(
      maximum: limits.maximumCompressedBlockSize,
      resource: "Record block info size"
    )
    let declaredRecordBlockDataSize = try readNumber()
    try validateLimit(
      declaredRecordBlockDataSize,
      maximum: limits.maximumFileSize,
      resource: "Record block data size"
    )

    guard declaredEntryCount == expectedEntryCount else {
      throw MDictError.invalidFormat(
        "Record section entry count mismatch. Expected \(expectedEntryCount), got \(declaredEntryCount)."
      )
    }
    let expectedInfoSize = try UInt64(recordBlockCount).checkedMultiplying(
      16,
      context: "Record block info size"
    )
    guard UInt64(recordBlockInfoSize) == expectedInfoSize else {
      throw MDictError.invalidFormat(
        "Record block info size mismatch. Expected \(expectedInfoSize), got \(recordBlockInfoSize)."
      )
    }

    let infoData = try reader.readData(count: recordBlockInfoSize)
    var infoReader = BinaryReader(infoData)
    var blockSizes: [(compressed: Int, decompressed: Int)] = []
    blockSizes.reserveCapacity(recordBlockCount)

    var totalCompressedSize: UInt64 = 0
    var totalDecompressedSize: UInt64 = 0
    for _ in 0..<recordBlockCount {
      let compressed = try readLimitedSize(
        from: &infoReader,
        maximum: limits.maximumCompressedBlockSize,
        resource: "Record block compressed size"
      )
      let decompressed = try readLimitedSize(
        from: &infoReader,
        maximum: limits.maximumDecompressedBlockSize,
        resource: "Record block decompressed size"
      )
      totalCompressedSize = try totalCompressedSize.checkedAdding(
        UInt64(compressed),
        context: "Total record block compressed size"
      )
      totalDecompressedSize = try totalDecompressedSize.checkedAdding(
        UInt64(decompressed),
        context: "Total record block decompressed size"
      )
      try validateLimit(
        totalDecompressedSize,
        maximum: limits.maximumTotalDecompressedSize,
        resource: "Total record block decompressed size"
      )
      blockSizes.append((compressed, decompressed))
    }

    guard infoReader.isAtEnd else {
      throw MDictError.invalidFormat("Record block info contains unexpected trailing bytes.")
    }
    guard totalCompressedSize == declaredRecordBlockDataSize else {
      throw MDictError.invalidFormat(
        "Record block data size mismatch. Expected \(declaredRecordBlockDataSize), got \(totalCompressedSize)."
      )
    }

    var blocks: [RecordBlock] = []
    blocks.reserveCapacity(recordBlockCount)
    var decompressedOffset: UInt64 = 0

    for size in blockSizes {
      let start = reader.offset
      try reader.skip(size.compressed)
      let end = reader.offset
      blocks.append(
        RecordBlock(
          compressedRange: start..<end,
          decompressedOffset: decompressedOffset,
          compressedSize: size.compressed,
          decompressedSize: size.decompressed
        )
      )
      decompressedOffset = try decompressedOffset.checkedAdding(
        UInt64(size.decompressed),
        context: "Record block offset"
      )
    }

    return blocks
  }

  private func attachRecordLengths(
    to keyEntries: [ParsedEntry],
    totalRecordSize: UInt64
  ) throws -> [ParsedEntry] {
    let offsets = Array(Set(keyEntries.map(\.recordOffset))).sorted()
    guard offsets.allSatisfy({ $0 <= totalRecordSize }) else {
      throw MDictError.invalidFormat("A record offset exceeds the total record data size.")
    }

    var lengths: [UInt64: UInt64] = [:]
    lengths.reserveCapacity(offsets.count)
    for (index, offset) in offsets.enumerated() {
      let nextOffset = index + 1 < offsets.count ? offsets[index + 1] : totalRecordSize
      let length = nextOffset - offset
      try validateLimit(length, maximum: limits.maximumRecordSize, resource: "Record size")
      lengths[offset] = length
    }

    return keyEntries.map {
      ParsedEntry(
        term: $0.term,
        recordOffset: $0.recordOffset,
        recordLength: lengths[$0.recordOffset] ?? 0
      )
    }
  }

  private mutating func readNumber() throws -> UInt64 {
    try reader.readUInt64BE()
  }

  private func readLimitedCount(
    from reader: inout BinaryReader,
    maximum: UInt64,
    resource: String
  ) throws -> Int {
    let value = try reader.readUInt64BE()
    try validateLimit(value, maximum: maximum, resource: resource)
    return try value.checkedInt(context: resource)
  }

  private mutating func readLimitedCount(
    maximum: UInt64,
    resource: String
  ) throws -> Int {
    try readLimitedCount(from: &reader, maximum: maximum, resource: resource)
  }

  private func readLimitedSize(
    from reader: inout BinaryReader,
    maximum: UInt64,
    resource: String
  ) throws -> Int {
    let value = try reader.readUInt64BE()
    try validateLimit(value, maximum: maximum, resource: resource)
    return try value.checkedInt(context: resource)
  }

  private mutating func readLimitedSize(
    maximum: UInt64,
    resource: String
  ) throws -> Int {
    try readLimitedSize(from: &reader, maximum: maximum, resource: resource)
  }

  private func validateLimit(
    _ value: UInt64,
    maximum: UInt64,
    resource: String
  ) throws {
    guard value <= maximum else {
      throw MDictError.limitExceeded(resource: resource, limit: maximum, actual: value)
    }
  }

  private func readSizedTerm(
    from reader: inout BinaryReader,
    encoding: String.Encoding
  ) throws -> String {
    let elementCount = UInt64(try reader.readUInt16BE())
    let byteCount = try elementCount.checkedMultiplying(
      isUTF16(encoding) ? 2 : 1,
      context: "Key text size"
    )
    try validateLimit(
      byteCount,
      maximum: limits.maximumDecompressedBlockSize,
      resource: "Key text size"
    )
    let termData = try reader.readData(count: byteCount.checkedInt(context: "Key text size"))
    try reader.skipZeroTerminator(codeUnitWidth: isUTF16(encoding) ? 2 : 1)

    guard let term = String(data: termData, encoding: encoding) else {
      throw MDictError.invalidFormat("Could not decode key block boundary text.")
    }
    return term
  }

  private func isUTF16(_ encoding: String.Encoding) -> Bool {
    encoding == .utf16
      || encoding == .utf16LittleEndian
      || encoding == .utf16BigEndian
  }

  private func decodeHeader(_ data: Data) throws -> String {
    let candidates: [String.Encoding] = [
      .utf16LittleEndian,
      .utf16BigEndian,
      .utf8,
    ]

    for encoding in candidates {
      if let text = String(data: data, encoding: encoding), text.contains("<") {
        return text.trimmingCharacters(in: .controlCharacters)
      }
    }

    throw MDictError.invalidFormat("Could not decode MDict header.")
  }

  private func containerKind(from text: String) throws -> MDictContainerKind {
    if text.contains("<Library_Data") {
      return .resources
    }
    if text.contains("<Dictionary") {
      return .dictionary
    }
    throw MDictError.invalidFormat("Unknown MDict container header.")
  }

  private func parseAttributes(from text: String) -> [String: String] {
    var attributes: [String: String] = [:]
    let chars = Array(text)
    var index = 0

    while index < chars.count {
      while index < chars.count, !(chars[index].isLetter || chars[index] == "_") {
        index += 1
      }

      let nameStart = index
      while index < chars.count,
        chars[index].isLetter
          || chars[index].isNumber
          || chars[index] == "_"
          || chars[index] == "-"
      {
        index += 1
      }

      guard nameStart < index else {
        break
      }

      let name = String(chars[nameStart..<index])
      while index < chars.count, chars[index].isWhitespace {
        index += 1
      }
      guard index < chars.count, chars[index] == "=" else {
        continue
      }
      index += 1
      while index < chars.count, chars[index].isWhitespace {
        index += 1
      }
      guard index < chars.count, chars[index] == "\"" || chars[index] == "'" else {
        continue
      }

      let quote = chars[index]
      index += 1
      let valueStart = index
      while index < chars.count, chars[index] != quote {
        index += 1
      }
      guard index < chars.count else {
        break
      }

      attributes[name] = unescapeEntities(String(chars[valueStart..<index]))
      index += 1
    }

    return attributes
  }

  private func unescapeEntities(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&amp;", with: "&")
  }

  private func stringEncoding(
    named name: String,
    kind: MDictContainerKind
  ) throws -> String.Encoding {
    let normalized = name.uppercased().replacingOccurrences(of: "_", with: "-")
    switch normalized {
    case "":
      return kind == .resources ? .utf16LittleEndian : .utf8
    case "UTF-8", "UTF8":
      return .utf8
    case "UTF-16", "UTF16":
      return .utf16
    case "UTF-16LE", "UTF-16-LITTLE-ENDIAN":
      return .utf16LittleEndian
    case "UTF-16BE", "UTF-16-BIG-ENDIAN":
      return .utf16BigEndian
    case "GBK", "CP936":
      return try coreFoundationEncoding(0x0631, name: name)
    case "GB2312", "GB-2312":
      return try coreFoundationEncoding(0x0630, name: name)
    case "GB18030", "GB-18030":
      return try coreFoundationEncoding(0x0632, name: name)
    case "BIG5", "BIG-5":
      return try coreFoundationEncoding(0x0A03, name: name)
    case "SHIFT-JIS", "SHIFTJIS", "SJIS":
      return .shiftJIS
    case "EUC-JP", "EUCJP":
      return .japaneseEUC
    default:
      throw MDictError.unsupported("Dictionary encoding '\(name)' is not supported.")
    }
  }

  private func coreFoundationEncoding(
    _ rawValue: UInt32,
    name: String
  ) throws -> String.Encoding {
    #if canImport(CoreFoundation)
      return String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(rawValue))
      )
    #else
      throw MDictError.unsupported("Dictionary encoding '\(name)' requires CoreFoundation.")
    #endif
  }
}

private struct KeyBlockInfo {
  let entryCount: Int
  let compressedSize: Int
  let decompressedSize: Int
}
