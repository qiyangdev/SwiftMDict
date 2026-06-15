import Foundation

/// Errors produced while opening or reading an MDict container.
public enum MDictError: Error, Equatable, Sendable {
  /// The container structure or decoded data is invalid.
  case invalidFormat(String)

  /// A header, metadata section, or compressed block failed validation.
  case integrityCheckFailed(section: String)

  /// The container ended before the requested bytes were available.
  case truncatedData(offset: Int, needed: Int, available: Int)

  /// A declared or observed resource exceeded the configured limit.
  case limitExceeded(resource: String, limit: UInt64, actual: UInt64)

  /// The container uses a valid MDict feature this library does not support.
  case unsupported(String)

  /// No entry matched the requested term.
  case entryNotFound(String)

  /// An entry created by another ``MDict`` instance was supplied.
  case foreignEntry

  /// An option value is outside its accepted range.
  case invalidOptions(String)
}

/// Metadata parsed from an MDict XML header.
public struct MDictHeader: Equatable, Sendable {
  /// The original decoded XML header text.
  public let rawText: String

  /// Header attributes keyed by their MDict names.
  public let attributes: [String: String]

  /// Whether the container stores dictionary definitions or resources.
  public let kind: MDictContainerKind

  private let effectiveEncodingName: String

  init(
    rawText: String,
    attributes: [String: String],
    kind: MDictContainerKind,
    effectiveEncodingName: String
  ) {
    self.rawText = rawText
    self.attributes = attributes
    self.kind = kind
    self.effectiveEncodingName = effectiveEncodingName
  }

  /// The MDict engine version declared by the container.
  public var generatedByEngineVersion: Double {
    Double(attributes["GeneratedByEngineVersion"] ?? "") ?? 0
  }

  /// The effective key and record text encoding.
  public var encodingName: String {
    effectiveEncodingName
  }

  /// The optional dictionary title.
  public var title: String? {
    attributes["Title"]
  }

  /// The optional dictionary description.
  public var description: String? {
    attributes["Description"]
  }
}

/// A term or resource path and the size of its associated record.
///
/// Entries are owned by the ``MDict`` instance that created them. Passing an
/// entry to another dictionary's record APIs throws ``MDictError/foreignEntry``.
public struct MDictEntry: Equatable, Sendable {
  /// The original term or resource path stored in the container.
  public let term: String

  /// The uncompressed record length, in bytes.
  public let byteCount: UInt64

  fileprivate let dictionaryID: UUID
  fileprivate let index: Int

  fileprivate init(
    term: String,
    byteCount: UInt64,
    dictionaryID: UUID,
    index: Int
  ) {
    precondition(index >= 0, "MDict entry indices cannot be negative.")
    self.term = term
    self.byteCount = byteCount
    self.dictionaryID = dictionaryID
    self.index = index
  }
}

/// The bytes associated with an ``MDictEntry``.
public struct MDictRecord: Equatable, Sendable {
  /// The entry that owns this record.
  public let entry: MDictEntry

  /// The uncompressed record bytes.
  public let data: Data

  private let dictionaryEncoding: String.Encoding

  fileprivate init(
    entry: MDictEntry,
    data: Data,
    dictionaryEncoding: String.Encoding
  ) {
    self.entry = entry
    self.data = data
    self.dictionaryEncoding = dictionaryEncoding
  }

  /// Decodes the record using the container's declared encoding.
  ///
  /// - Returns: The decoded text, or `nil` if the bytes are not valid in that
  ///   encoding.
  public func text() -> String? {
    String(data: data, encoding: dictionaryEncoding)
  }

  /// Decodes the record using an explicit Foundation string encoding.
  public func text(encoding: String.Encoding) -> String? {
    String(data: data, encoding: encoding)
  }
}

/// A parsed MDict 2.x dictionary or resource archive.
///
/// Header metadata, keys, and record ranges are parsed eagerly. Record blocks
/// are decompressed lazily and retained by the configured bounded cache.
public final class MDict: Sendable {
  /// The parsed container header.
  public let header: MDictHeader

  /// Entries in their original container order.
  public let entries: [MDictEntry]

  /// The options used to open this container.
  public let options: MDictOptions

  private let id: UUID
  private let encoding: String.Encoding
  private let data: Data
  private let parsedEntries: [ParsedEntry]
  private let recordBlocks: [RecordBlock]
  private let keyNormalizer: KeyNormalizer
  private let exactEntryIndex: [String: EntryLocations]
  private let prefixEntryIndex: [String: [Int]]
  private let recordBlockCache: RecordBlockCache

  /// Opens an MDict file.
  ///
  /// - Throws: ``MDictError`` for invalid or unsupported container data, or a
  ///   Foundation file-reading error.
  public convenience init(
    contentsOf url: URL,
    options: MDictOptions = MDictOptions()
  ) throws {
    let readingOptions: Data.ReadingOptions =
      options.fileLoading == .mappedIfSafe
      ? .mappedIfSafe
      : []
    let data = try Data(contentsOf: url, options: readingOptions)
    try self.init(data: data, options: options)
  }

  /// Opens an MDict file from a file-system path.
  public convenience init(
    path: String,
    options: MDictOptions = MDictOptions()
  ) throws {
    try self.init(contentsOf: URL(fileURLWithPath: path), options: options)
  }

  /// Opens an MDict container from bytes already in memory.
  public init(
    data: Data,
    options: MDictOptions = MDictOptions()
  ) throws {
    guard options.decompressedBlockCacheCount >= 0 else {
      throw MDictError.invalidOptions("Cache count cannot be negative.")
    }
    guard options.decompressedBlockCacheBytes >= 0 else {
      throw MDictError.invalidOptions("Cache byte limit cannot be negative.")
    }

    var parser = MDictParser(data: data, limits: options.limits)
    let parsed = try parser.parse()
    let id = UUID()
    let normalizer = KeyNormalizer(header: parsed.header)

    self.id = id
    self.header = parsed.header
    self.options = options
    self.encoding = parsed.encoding
    self.data = parsed.data
    self.parsedEntries = parsed.entries
    self.recordBlocks = parsed.recordBlocks
    self.keyNormalizer = normalizer
    self.entries = parsed.entries.enumerated().map { index, entry in
      MDictEntry(
        term: entry.term,
        byteCount: entry.recordLength,
        dictionaryID: id,
        index: index
      )
    }
    self.exactEntryIndex =
      options.indexing == .none
      ? [:]
      : Self.makeExactEntryIndex(parsed.entries, normalizer: normalizer)
    self.prefixEntryIndex =
      options.indexing == .exactAndPrefix
      ? Self.makePrefixEntryIndex(parsed.entries, normalizer: normalizer)
      : [:]
    self.recordBlockCache = RecordBlockCache(
      countLimit: options.decompressedBlockCacheCount,
      byteLimit: options.decompressedBlockCacheBytes
    )
  }

  /// Opens an MDict file on a detached task.
  ///
  /// Use this helper from actor-isolated UI code to avoid parsing the file on
  /// the caller's executor.
  public static func open(
    contentsOf url: URL,
    options: MDictOptions = MDictOptions()
  ) async throws -> MDict {
    try await Task.detached {
      try MDict(contentsOf: url, options: options)
    }.value
  }

  /// Returns every record whose key matches a term.
  ///
  /// Matching applies the container's `KeyCaseSensitive` and `StripKey`
  /// semantics. Duplicate keys produce multiple records in file order.
  ///
  /// - Throws: ``MDictError/entryNotFound(_:)`` when no key matches.
  public func lookup(_ term: String) throws -> [MDictRecord] {
    let normalizedTerm = keyNormalizer.normalize(term)
    let indices: [Int]

    if options.indexing == .none {
      indices = parsedEntries.indices.filter {
        keyNormalizer.normalize(parsedEntries[$0].term) == normalizedTerm
      }
    } else {
      guard let locations = exactEntryIndex[normalizedTerm] else {
        throw MDictError.entryNotFound(term)
      }
      indices = locations.indices
    }

    guard !indices.isEmpty else {
      throw MDictError.entryNotFound(term)
    }
    return try indices.map { try record(for: entries[$0]) }
  }

  /// Reads the record associated with an entry.
  ///
  /// - Throws: ``MDictError/foreignEntry`` if the entry belongs to another
  ///   dictionary, or an integrity error if decompression fails.
  public func record(for entry: MDictEntry) throws -> MDictRecord {
    guard entry.dictionaryID == id,
      parsedEntries.indices.contains(entry.index),
      entries[entry.index] == entry
    else {
      throw MDictError.foreignEntry
    }

    return MDictRecord(
      entry: entry,
      data: try recordData(for: entry),
      dictionaryEncoding: encoding
    )
  }

  /// Reads the uncompressed bytes associated with an entry.
  public func recordData(for entry: MDictEntry) throws -> Data {
    guard entry.dictionaryID == id,
      parsedEntries.indices.contains(entry.index),
      entries[entry.index] == entry
    else {
      throw MDictError.foreignEntry
    }

    let parsedEntry = parsedEntries[entry.index]
    let start = parsedEntry.recordOffset
    let end = try start.checkedAdding(
      parsedEntry.recordLength,
      context: "Record range for '\(entry.term)'"
    )

    if start == end {
      return Data()
    }

    var result = Data()
    result.reserveCapacity(try parsedEntry.recordLength.checkedInt(context: "Record length"))

    var blockIndex = firstRecordBlock(endingAfter: start)
    while blockIndex < recordBlocks.endIndex {
      let block = recordBlocks[blockIndex]
      guard block.decompressedOffset < end else {
        break
      }

      let decompressed = try decompressedRecordBlock(at: blockIndex)
      let overlapStart = max(start, block.decompressedOffset)
      let overlapEnd = min(end, block.decompressedEndOffset)
      let localStart = try (overlapStart - block.decompressedOffset).checkedInt(
        context: "Record local start"
      )
      let localEnd = try (overlapEnd - block.decompressedOffset).checkedInt(
        context: "Record local end"
      )
      result.append(decompressed[localStart..<localEnd])
      blockIndex += 1
    }

    guard UInt64(result.count) == parsedEntry.recordLength else {
      throw MDictError.invalidFormat(
        "Record range for '\(entry.term)' is outside record block bounds."
      )
    }
    return result
  }

  /// Reads the first record matching a term as binary data.
  public func data(for term: String) throws -> Data {
    guard let record = try lookup(term).first else {
      throw MDictError.entryNotFound(term)
    }
    return record.data
  }

  /// Reads the first record matching a term as text.
  ///
  /// The record is decoded using the container's declared encoding.
  public func text(for term: String) throws -> String {
    let records = try lookup(term)
    guard let first = records.first, let text = first.text() else {
      throw MDictError.invalidFormat(
        "Record for '\(term)' could not be decoded as \(header.encodingName)."
      )
    }
    return text
  }

  /// Returns entries whose normalized keys begin with a prefix.
  ///
  /// Results preserve file order and apply the container's
  /// `KeyCaseSensitive` and `StripKey` semantics.
  ///
  /// - Parameters:
  ///   - prefix: The prefix to normalize and match. An empty normalized prefix
  ///     returns the first entries.
  ///   - limit: The maximum number of entries to return.
  public func entries(
    matchingPrefix prefix: String,
    limit: Int = 20
  ) -> [MDictEntry] {
    guard limit > 0 else {
      return []
    }
    guard !prefix.isEmpty else {
      return Array(entries.prefix(limit))
    }

    let normalizedPrefix = keyNormalizer.normalize(prefix)
    guard !normalizedPrefix.isEmpty else {
      return Array(entries.prefix(limit))
    }

    let candidateIndices: any Sequence<Int>
    if options.indexing == .exactAndPrefix {
      let indexedPrefix = String(normalizedPrefix.prefix(3))
      candidateIndices = prefixEntryIndex[indexedPrefix] ?? []
    } else {
      candidateIndices = parsedEntries.indices
    }

    var matches: [MDictEntry] = []
    matches.reserveCapacity(min(limit, entries.count))
    for index in candidateIndices {
      let normalizedTerm = keyNormalizer.normalize(parsedEntries[index].term)
      if normalizedTerm.hasPrefix(normalizedPrefix) {
        matches.append(entries[index])
        if matches.count == limit {
          break
        }
      }
    }
    return matches
  }

  private static func makeExactEntryIndex(
    _ entries: [ParsedEntry],
    normalizer: KeyNormalizer
  ) -> [String: EntryLocations] {
    var result: [String: EntryLocations] = [:]
    result.reserveCapacity(entries.count)

    for (index, entry) in entries.enumerated() {
      let key = normalizer.normalize(entry.term)
      switch result[key] {
      case nil:
        result[key] = .single(index)
      case .single(let existing):
        result[key] = .multiple([existing, index])
      case .multiple(var existing):
        existing.append(index)
        result[key] = .multiple(existing)
      }
    }
    return result
  }

  private static func makePrefixEntryIndex(
    _ entries: [ParsedEntry],
    normalizer: KeyNormalizer
  ) -> [String: [Int]] {
    var result: [String: [Int]] = [:]

    for (index, entry) in entries.enumerated() {
      let normalized = normalizer.normalize(entry.term)
      var prefix = ""
      var characters = normalized.makeIterator()
      for _ in 0..<3 {
        guard let character = characters.next() else {
          break
        }
        prefix.append(character)
        result[prefix, default: []].append(index)
      }
    }
    return result
  }

  private func firstRecordBlock(endingAfter offset: UInt64) -> Int {
    var lower = recordBlocks.startIndex
    var upper = recordBlocks.endIndex
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if recordBlocks[middle].decompressedEndOffset <= offset {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }

  private func decompressedRecordBlock(at index: Int) throws -> Data {
    try recordBlockCache.value(for: index) {
      let block = recordBlocks[index]
      return try MDictCompression.decodeBlock(
        data.subdata(in: block.compressedRange),
        expectedSize: block.decompressedSize
      )
    }
  }
}

private struct KeyNormalizer: Sendable {
  let caseSensitive: Bool
  let stripsPunctuation: Bool

  init(header: MDictHeader) {
    self.caseSensitive =
      header.attributes["KeyCaseSensitive"]?
      .caseInsensitiveCompare("yes") == .orderedSame
    self.stripsPunctuation =
      header.kind == .dictionary
      && header.attributes["StripKey"]?
        .caseInsensitiveCompare("yes") == .orderedSame
  }

  func normalize(_ key: String) -> String {
    let cased = caseSensitive ? key : key.lowercased()
    guard stripsPunctuation else {
      return cased
    }
    return String(cased.filter { !Self.isStripped($0) })
  }

  private static func isStripped(_ character: Character) -> Bool {
    switch character {
    case " ", "_", "=", ",", ".", ";", ":", "!", "?", "@", "%", "&", "#",
      "~", "`", "(", ")", "[", "]", "<", ">", "{", "}", "/", "\\", "$", "+",
      "-", "*", "^", "'", "\"", "\t", "|":
      return true
    default:
      return false
    }
  }
}

private enum EntryLocations: Sendable {
  case single(Int)
  case multiple([Int])

  var indices: [Int] {
    switch self {
    case .single(let index):
      return [index]
    case .multiple(let indices):
      return indices
    }
  }
}

private final class RecordBlockCache: @unchecked Sendable {
  private final class Value: NSObject {
    let data: Data

    init(_ data: Data) {
      self.data = data
    }
  }

  private let cache = NSCache<NSNumber, Value>()
  private let lock = NSLock()
  private let isEnabled: Bool

  init(countLimit: Int, byteLimit: Int) {
    self.isEnabled = countLimit > 0 && byteLimit > 0
    cache.countLimit = countLimit
    cache.totalCostLimit = byteLimit
  }

  func value(for index: Int, loader: () throws -> Data) throws -> Data {
    guard isEnabled else {
      return try loader()
    }

    lock.lock()
    defer { lock.unlock() }

    let key = NSNumber(value: index)
    if let cached = cache.object(forKey: key) {
      return cached.data
    }

    let data = try loader()
    cache.setObject(Value(data), forKey: key, cost: data.count)
    return data
  }
}

struct ParsedMDict {
  let header: MDictHeader
  let encoding: String.Encoding
  let entries: [ParsedEntry]
  let recordBlocks: [RecordBlock]
  let data: Data
}

struct ParsedEntry: Sendable {
  let term: String
  let recordOffset: UInt64
  let recordLength: UInt64

  init(term: String, recordOffset: UInt64, recordLength: UInt64 = 0) {
    self.term = term
    self.recordOffset = recordOffset
    self.recordLength = recordLength
  }
}

struct RecordBlock: Sendable {
  let compressedRange: Range<Int>
  let decompressedOffset: UInt64
  let compressedSize: Int
  let decompressedSize: Int

  var decompressedEndOffset: UInt64 {
    decompressedOffset + UInt64(decompressedSize)
  }
}
