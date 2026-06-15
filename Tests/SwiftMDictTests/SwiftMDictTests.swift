import CZlib
import Foundation
import Testing

@testable import SwiftMDict

private let oxfordFixture = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "oxfordstu_no_audio/oxfordstu.mdx")
private let oxfordResourceFixture =
  oxfordFixture
  .deletingLastPathComponent()
  .appending(path: "oxfordstu.mdd")

@Test func parsesZlibCompressedMDictData() throws {
  let data = makeFixture(entries: [
    ("apple", "<h1>Apple</h1>"),
    ("banana", "<h1>Banana</h1>"),
  ])

  let dictionary = try MDict(data: data)

  #expect(dictionary.header.generatedByEngineVersion == 2.0)
  #expect(dictionary.header.encodingName == "UTF-8")
  #expect(dictionary.header.title == "Fixture")
  #expect(dictionary.entries.map(\.term) == ["apple", "banana"])
  #expect(try dictionary.text(for: "apple") == "<h1>Apple</h1>")
  #expect(try dictionary.text(for: "banana") == "<h1>Banana</h1>")
}

@Test func rejectsCorruptedKeyBlockInfoChecksum() {
  var data = [UInt8](makeFixture(entries: [("apple", "fruit")]))
  let headerSize = Int(data.readUInt32BE(at: 0))
  let checksumOffset = 4 + headerSize + 4 + (5 * 8)
  data[checksumOffset] ^= 0xff

  #expect(throws: MDictError.self) {
    try MDict(data: Data(data))
  }
}

@Test func rejectsCorruptedRecordBlockChecksumOnAccess() throws {
  var data = [UInt8](makeFixture(entries: [("apple", "fruit")]))
  let recordBlockOffset = firstRecordBlockOffset(in: data)
  data[recordBlockOffset + 4] ^= 0xff

  let dictionary = try MDict(data: Data(data))

  #expect(
    throws: MDictError.integrityCheckFailed(section: "compressed block")
  ) {
    try dictionary.text(for: "apple")
  }
}

@Test func enforcesConfiguredHeaderLimit() {
  var limits = MDictLimits()
  limits.maximumHeaderSize = 16

  #expect(
    throws: MDictError.limitExceeded(
      resource: "Header size",
      limit: 16,
      actual: 182
    )
  ) {
    try MDict(
      data: makeFixture(entries: [("apple", "fruit")]),
      options: MDictOptions(limits: limits)
    )
  }
}

@Test func rejectsMismatchedDeclaredKeyBlockSize() {
  var data = [UInt8](makeFixture(entries: [("apple", "fruit")]))
  let headerSize = Int(data.readUInt32BE(at: 0))
  let metadataOffset = 4 + headerSize + 4
  let keyBlockSizeOffset = metadataOffset + (4 * 8)
  data.writeUInt64BE(data.readUInt64BE(at: keyBlockSizeOffset) + 1, at: keyBlockSizeOffset)
  data.writeUInt32BE(
    adler32(Array(data[metadataOffset..<(metadataOffset + 40)])),
    at: metadataOffset + 40
  )

  #expect(throws: MDictError.self) {
    try MDict(data: Data(data))
  }
}

@Test func rejectsUnexpectedTrailingBytes() {
  var data = makeFixture(entries: [("apple", "fruit")])
  data.append(0)

  #expect(
    throws: MDictError.invalidFormat(
      "MDict data contains unexpected trailing bytes."
    )
  ) {
    try MDict(data: data)
  }
}

@Test func appliesDeclaredKeySemanticsToExactAndPrefixLookup() throws {
  let header =
    #"<Dictionary GeneratedByEngineVersion="2.0" Encoding="UTF-8" Title="Fixture" Encrypted="0" KeyCaseSensitive="No" StripKey="Yes"/>"#
  let dictionary = try MDict(
    data: makeFixture(
      entries: [("A-B", "first"), ("abacus", "second")],
      header: header
    ))

  #expect(try dictionary.text(for: "a b") == "first")
  #expect(dictionary.entries(matchingPrefix: "A_").map(\.term) == ["A-B", "abacus"])
}

@Test func honorsCaseSensitiveDictionaryKeys() throws {
  let header =
    #"<Dictionary GeneratedByEngineVersion="2.0" Encoding="UTF-8" Title="Fixture" Encrypted="0" KeyCaseSensitive="Yes" StripKey="No"/>"#
  let dictionary = try MDict(
    data: makeFixture(
      entries: [("Apple", "fruit")],
      header: header
    ))

  #expect(try dictionary.text(for: "Apple") == "fruit")
  #expect(throws: MDictError.entryNotFound("apple")) {
    try dictionary.text(for: "apple")
  }
  #expect(dictionary.entries(matchingPrefix: "app").isEmpty)
}

@Test func rejectsEntryFromAnotherDictionary() throws {
  let first = try MDict(data: makeFixture(entries: [("apple", "fruit")]))
  let second = try MDict(data: makeFixture(entries: [("apple", "company")]))

  #expect(throws: MDictError.foreignEntry) {
    try second.record(for: first.entries[0])
  }
}

@Test func indexingModesPreserveLookupBehavior() throws {
  let data = makeFixture(entries: [
    ("application", "software"),
    ("banana", "fruit"),
    ("app", "root"),
    ("apple", "fruit"),
  ])

  for indexing in [MDictIndexing.none, .exact, .exactAndPrefix] {
    let dictionary = try MDict(data: data, options: MDictOptions(indexing: indexing))

    #expect(try dictionary.text(for: "APPLE") == "fruit")
    #expect(
      dictionary.entries(matchingPrefix: "app").map(\.term) == [
        "application", "app", "apple",
      ])
  }
}

@Test func recordsUseDictionaryEncodingByDefault() throws {
  let header =
    #"<Dictionary GeneratedByEngineVersion="2.0" Encoding="UTF-16LE" Title="Fixture" Encrypted="0"/>"#
  let dictionary = try MDict(
    data: makeFixture(
      entries: [("word", "definition")],
      header: header,
      textEncoding: .utf16LittleEndian
    ))
  let record = try dictionary.lookup("word")[0]

  #expect(record.text() == "definition")
  #expect(try dictionary.text(for: "word") == "definition")
}

@Test func concurrentLookupsShareSafeRecordAccess() async throws {
  let dictionary = try MDict(
    data: makeFixture(
      entries: [("letter", String(repeating: "a", count: 100))],
      recordCompression: 1
    ))

  try await withThrowingTaskGroup(of: String.self) { group in
    for _ in 0..<32 {
      group.addTask {
        try dictionary.text(for: "letter")
      }
    }
    for try await value in group {
      #expect(value.count == 100)
    }
  }
}

@Test func returnsPrefixMatchesWithLimit() throws {
  let data = makeFixture(entries: [
    ("app", "root"),
    ("apple", "fruit"),
    ("application", "software"),
  ])

  let dictionary = try MDict(data: data)
  let matches = dictionary.entries(matchingPrefix: "app", limit: 2)

  #expect(matches.map(\.term) == ["app", "apple"])
}

@Test func preservesPrefixOrderForUnsortedEntries() throws {
  let data = makeFixture(entries: [
    ("application", "software"),
    ("banana", "fruit"),
    ("app", "root"),
    ("apple", "fruit"),
  ])

  let dictionary = try MDict(data: data)
  let matches = dictionary.entries(matchingPrefix: "app", limit: 2)

  #expect(matches.map(\.term) == ["application", "app"])
}

@Test func returnsAllRecordsForDuplicateTerms() throws {
  let dictionary = try MDict(
    data: makeFixture(entries: [
      ("apple", "fruit"),
      ("apple", "company"),
    ]))

  let records = try dictionary.lookup("apple")

  #expect(records.map(\.data) == [Data("fruit".utf8), Data("company".utf8)])
}

@Test func throwsForMissingEntry() throws {
  let dictionary = try MDict(data: makeFixture(entries: [("apple", "fruit")]))

  #expect(throws: MDictError.entryNotFound("pear")) {
    try dictionary.lookup("pear")
  }
}

@Test func readsARecordSpanningCompressedBlocks() throws {
  let dictionary = try MDict(
    data: makeFixture(
      entries: [("apple", "<h1>Apple</h1>")],
      recordSplitAt: 5
    ))

  #expect(try dictionary.text(for: "apple") == "<h1>Apple</h1>")
}

@Test func readsLZOCompressedRecordBlock() throws {
  let definition = String(repeating: "a", count: 100)
  let dictionary = try MDict(
    data: makeFixture(
      entries: [("letter", definition)],
      recordCompression: 1
    ))

  #expect(try dictionary.text(for: "letter") == definition)
}

@Test func readsLiteralOnlyLZOCompressedRecordBlock() throws {
  let dictionary = try MDict(
    data: makeFixture(
      entries: [("letter", "a")],
      recordCompression: 1
    ))

  #expect(try dictionary.text(for: "letter") == "a")
}

@Test func rejectsMalformedLZORecordBlock() throws {
  var data = [UInt8](
    makeFixture(
      entries: [("letter", String(repeating: "a", count: 100))],
      recordCompression: 1
    ))
  let recordBlockOffset = firstRecordBlockOffset(in: data)
  data[recordBlockOffset + 8] = 0x10

  let dictionary = try MDict(data: Data(data))

  #expect(throws: MDictError.self) {
    try dictionary.text(for: "letter")
  }
}

@Test func sharesARecordBetweenAliasEntries() throws {
  let dictionary = try MDict(
    data: makeFixture(
      entries: [("apple", "fruit"), ("malus", "")],
      recordOffsets: [0, 0]
    ))

  #expect(try dictionary.text(for: "apple") == "fruit")
  #expect(try dictionary.text(for: "malus") == "fruit")
}

@Test func computesRIPEMD128Digest() {
  let digest = RIPEMD128.digest(Array("The quick brown fox jumps over the lazy dog".utf8))

  #expect(
    digest == [
      0x3f, 0xa9, 0xb5, 0x7f, 0x05, 0x3c, 0x05, 0x3f,
      0xbe, 0x27, 0x35, 0xb2, 0x38, 0x0d, 0xb5, 0x96,
    ])
}

@Test(
  .enabled(
    if: FileManager.default.fileExists(atPath: oxfordFixture.path),
    "Requires the local Oxford MDX fixture."
  ))
func parsesEncryptedOxfordFixture() throws {
  let dictionary = try MDict(contentsOf: oxfordFixture)

  #expect(dictionary.entries.count == 28_894)
  #expect(dictionary.header.title == "Oxford Student's Dictionary")
  #expect(dictionary.header.generatedByEngineVersion == 2.0)
}

@Test(
  .enabled(
    if: FileManager.default.fileExists(atPath: oxfordResourceFixture.path),
    "Requires the local Oxford MDD fixture."
  ))
func parsesOxfordResourceArchive() throws {
  let resources = try MDict(contentsOf: oxfordResourceFixture)

  #expect(resources.header.kind == .resources)
  #expect(resources.header.encodingName == "UTF-16LE")
  #expect(resources.entries.count == 1_747)
  #expect(try resources.data(for: "\\font\\DictBats.ttf").count == 39_176)
}

private func makeFixture(
  entries: [(String, String)],
  recordOffsets: [UInt64]? = nil,
  recordSplitAt: Int? = nil,
  recordCompression: UInt32 = 2,
  header: String? = nil,
  textEncoding: String.Encoding = .utf8
) -> Data {
  var data: [UInt8] = []
  let headerText =
    header
    ?? #"<Dictionary GeneratedByEngineVersion="2.0" Encoding="UTF-8" Title="Fixture" Encrypted="0"/>"#
  let headerBytes = Array(headerText.utf16LittleEndianBytes)
  data.appendUInt32BE(UInt32(headerBytes.count))
  data += headerBytes
  data.appendUInt32LE(adler32(headerBytes))

  let definitionBytes = entries.map {
    [UInt8]($0.1.data(using: textEncoding)!)
  }
  let recordBytes = definitionBytes.flatMap { $0 }
  var keyBlock: [UInt8] = []
  var offset: UInt64 = 0
  for (index, entry) in entries.enumerated() {
    let (term, _) = entry
    keyBlock.appendUInt64BE(recordOffsets?[index] ?? offset)
    keyBlock += [UInt8](term.data(using: textEncoding)!)
    keyBlock += Array(repeating: 0, count: textEncoding.isUTF16 ? 2 : 1)
    offset += UInt64(definitionBytes[index].count)
  }

  let keyBlockCompressed = block(type: 2, payload: keyBlock)
  let firstKey = entries.first?.0 ?? ""
  let lastKey = entries.last?.0 ?? ""
  var keyBlockInfo: [UInt8] = []
  keyBlockInfo.appendUInt64BE(UInt64(entries.count))
  keyBlockInfo.appendSized(firstKey, encoding: textEncoding)
  keyBlockInfo.appendSized(lastKey, encoding: textEncoding)
  keyBlockInfo.appendUInt64BE(UInt64(keyBlockCompressed.count))
  keyBlockInfo.appendUInt64BE(UInt64(keyBlock.count))
  let keyBlockInfoCompressed = block(type: 2, payload: keyBlockInfo)

  let keySectionMetadataStart = data.count
  data.appendUInt64BE(1)
  data.appendUInt64BE(UInt64(entries.count))
  data.appendUInt64BE(UInt64(keyBlockInfo.count))
  data.appendUInt64BE(UInt64(keyBlockInfoCompressed.count))
  data.appendUInt64BE(UInt64(keyBlockCompressed.count))
  data.appendUInt32BE(adler32(Array(data[keySectionMetadataStart...])))
  data += keyBlockInfoCompressed
  data += keyBlockCompressed

  let recordPayloads: [[UInt8]]
  if let recordSplitAt, recordSplitAt > 0, recordSplitAt < recordBytes.count {
    recordPayloads = [
      Array(recordBytes[..<recordSplitAt]),
      Array(recordBytes[recordSplitAt...]),
    ]
  } else {
    recordPayloads = [recordBytes]
  }
  let recordBlocks = recordPayloads.map { block(type: recordCompression, payload: $0) }
  var recordBlockInfo: [UInt8] = []
  for (block, payload) in zip(recordBlocks, recordPayloads) {
    recordBlockInfo.appendUInt64BE(UInt64(block.count))
    recordBlockInfo.appendUInt64BE(UInt64(payload.count))
  }

  data.appendUInt64BE(UInt64(recordBlocks.count))
  data.appendUInt64BE(UInt64(entries.count))
  data.appendUInt64BE(UInt64(recordBlockInfo.count))
  data.appendUInt64BE(UInt64(recordBlocks.reduce(0) { $0 + $1.count }))
  data += recordBlockInfo
  for recordBlock in recordBlocks {
    data += recordBlock
  }

  return Data(data)
}

private func block(type: UInt32, payload: [UInt8]) -> [UInt8] {
  var result: [UInt8] = []
  result.appendUInt32LE(type)
  result.appendUInt32BE(adler32(payload))
  switch type {
  case 1:
    if payload == [UInt8](repeating: 0x61, count: 100) {
      result += [
        0x02, 0x61, 0x61, 0x61, 0x61, 0x61, 0x20, 0x2b, 0x10, 0x00, 0x00,
        0x01, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61,
        0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x11, 0x00,
        0x00,
      ]
    } else {
      precondition((1...238).contains(payload.count))
      result.append(UInt8(17 + payload.count))
      result += payload
      result += [0x11, 0x00, 0x00]
    }
  case 2:
    result += zlibCompress(payload)
  default:
    result += payload
  }
  return result
}

private func firstRecordBlockOffset(in data: [UInt8]) -> Int {
  let headerSize = Int(data.readUInt32BE(at: 0))
  let keyMetadataOffset = 4 + headerSize + 4
  let keyBlockInfoSize = Int(data.readUInt64BE(at: keyMetadataOffset + 24))
  let keyBlockSize = Int(data.readUInt64BE(at: keyMetadataOffset + 32))
  let recordSectionOffset = keyMetadataOffset + 44 + keyBlockInfoSize + keyBlockSize
  let recordBlockInfoSize = Int(data.readUInt64BE(at: recordSectionOffset + 16))
  return recordSectionOffset + 32 + recordBlockInfoSize
}

private func zlibCompress(_ bytes: [UInt8]) -> [UInt8] {
  var destinationLength = compressBound(uLong(bytes.count))
  var destination = [UInt8](repeating: 0, count: Int(destinationLength))
  let status = bytes.withUnsafeBytes { source in
    destination.withUnsafeMutableBytes { output in
      compress2(
        output.bindMemory(to: Bytef.self).baseAddress,
        &destinationLength,
        source.bindMemory(to: Bytef.self).baseAddress,
        uLong(bytes.count),
        Z_BEST_SPEED
      )
    }
  }
  precondition(status == Z_OK)
  return Array(destination[..<Int(destinationLength)])
}

extension Array where Element == UInt8 {
  fileprivate func readUInt32BE(at offset: Int) -> UInt32 {
    (UInt32(self[offset]) << 24)
      | (UInt32(self[offset + 1]) << 16)
      | (UInt32(self[offset + 2]) << 8)
      | UInt32(self[offset + 3])
  }

  fileprivate func readUInt64BE(at offset: Int) -> UInt64 {
    let high = UInt64(readUInt32BE(at: offset))
    let low = UInt64(readUInt32BE(at: offset + 4))
    return (high << 32) | low
  }

  fileprivate mutating func writeUInt32BE(_ value: UInt32, at offset: Int) {
    self[offset] = UInt8((value >> 24) & 0xff)
    self[offset + 1] = UInt8((value >> 16) & 0xff)
    self[offset + 2] = UInt8((value >> 8) & 0xff)
    self[offset + 3] = UInt8(value & 0xff)
  }

  fileprivate mutating func writeUInt64BE(_ value: UInt64, at offset: Int) {
    self[offset] = UInt8((value >> 56) & 0xff)
    self[offset + 1] = UInt8((value >> 48) & 0xff)
    self[offset + 2] = UInt8((value >> 40) & 0xff)
    self[offset + 3] = UInt8((value >> 32) & 0xff)
    self[offset + 4] = UInt8((value >> 24) & 0xff)
    self[offset + 5] = UInt8((value >> 16) & 0xff)
    self[offset + 6] = UInt8((value >> 8) & 0xff)
    self[offset + 7] = UInt8(value & 0xff)
  }

  fileprivate mutating func appendUInt16BE(_ value: UInt16) {
    append(UInt8((value >> 8) & 0xff))
    append(UInt8(value & 0xff))
  }

  fileprivate mutating func appendUInt32BE(_ value: UInt32) {
    append(UInt8((value >> 24) & 0xff))
    append(UInt8((value >> 16) & 0xff))
    append(UInt8((value >> 8) & 0xff))
    append(UInt8(value & 0xff))
  }

  fileprivate mutating func appendUInt32LE(_ value: UInt32) {
    append(UInt8(value & 0xff))
    append(UInt8((value >> 8) & 0xff))
    append(UInt8((value >> 16) & 0xff))
    append(UInt8((value >> 24) & 0xff))
  }

  fileprivate mutating func appendUInt64BE(_ value: UInt64) {
    append(UInt8((value >> 56) & 0xff))
    append(UInt8((value >> 48) & 0xff))
    append(UInt8((value >> 40) & 0xff))
    append(UInt8((value >> 32) & 0xff))
    append(UInt8((value >> 24) & 0xff))
    append(UInt8((value >> 16) & 0xff))
    append(UInt8((value >> 8) & 0xff))
    append(UInt8(value & 0xff))
  }

  fileprivate mutating func appendSized(_ value: String, encoding: String.Encoding) {
    let bytes = [UInt8](value.data(using: encoding)!)
    appendUInt16BE(UInt16(bytes.count / (encoding.isUTF16 ? 2 : 1)))
    self += bytes
    self += Array(repeating: 0, count: encoding.isUTF16 ? 2 : 1)
  }
}

extension String {
  fileprivate var utf16LittleEndianBytes: [UInt8] {
    utf16.flatMap { codeUnit in
      [
        UInt8(codeUnit & 0xff),
        UInt8((codeUnit >> 8) & 0xff),
      ]
    }
  }
}

extension String.Encoding {
  fileprivate var isUTF16: Bool {
    self == .utf16 || self == .utf16LittleEndian || self == .utf16BigEndian
  }
}

private func adler32(_ bytes: [UInt8]) -> UInt32 {
  let modulo: UInt32 = 65_521
  var a: UInt32 = 1
  var b: UInt32 = 0

  for byte in bytes {
    a = (a + UInt32(byte)) % modulo
    b = (b + a) % modulo
  }

  return (b << 16) | a
}
