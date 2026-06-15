import Foundation

/// The type of content stored in an MDict container.
public enum MDictContainerKind: String, Equatable, Sendable {
  /// An MDX dictionary containing terms and definition records.
  case dictionary

  /// An MDD archive containing resource paths and binary records.
  case resources
}

/// The strategy used to read an MDict file from disk.
public enum MDictFileLoading: Equatable, Sendable {
  /// Ask Foundation to map the file when doing so is safe.
  case mappedIfSafe

  /// Read the complete file into memory.
  case inMemory
}

/// The indexes built when an MDict container is opened.
public enum MDictIndexing: Equatable, Sendable {
  /// Build no indexes and use linear scans for lookup and prefix search.
  case none

  /// Build an exact-term index while using linear prefix searches.
  case exact

  /// Build exact-term and prefix indexes.
  case exactAndPrefix
}

/// Resource limits applied while parsing and reading an MDict container.
///
/// Limits are checked before allocation or decompression where possible. Use
/// lower values when processing untrusted files in constrained environments.
public struct MDictLimits: Equatable, Sendable {
  /// The largest accepted container file, in bytes.
  public var maximumFileSize: UInt64

  /// The largest accepted XML header, in bytes.
  public var maximumHeaderSize: UInt64

  /// The largest accepted number of dictionary or resource entries.
  public var maximumEntryCount: UInt64

  /// The largest accepted number of key or record blocks.
  public var maximumBlockCount: UInt64

  /// The largest accepted compressed block, in bytes.
  public var maximumCompressedBlockSize: UInt64

  /// The largest accepted decompressed block, in bytes.
  public var maximumDecompressedBlockSize: UInt64

  /// The largest declared total decompressed size, in bytes.
  public var maximumTotalDecompressedSize: UInt64

  /// The largest accepted individual record, in bytes.
  public var maximumRecordSize: UInt64

  /// Creates a set of parser and record limits.
  public init(
    maximumFileSize: UInt64 = 2 * 1_024 * 1_024 * 1_024,
    maximumHeaderSize: UInt64 = 2 * 1_024 * 1_024,
    maximumEntryCount: UInt64 = 5_000_000,
    maximumBlockCount: UInt64 = 100_000,
    maximumCompressedBlockSize: UInt64 = 512 * 1_024 * 1_024,
    maximumDecompressedBlockSize: UInt64 = 512 * 1_024 * 1_024,
    maximumTotalDecompressedSize: UInt64 = 16 * 1_024 * 1_024 * 1_024,
    maximumRecordSize: UInt64 = 1 * 1_024 * 1_024 * 1_024
  ) {
    self.maximumFileSize = maximumFileSize
    self.maximumHeaderSize = maximumHeaderSize
    self.maximumEntryCount = maximumEntryCount
    self.maximumBlockCount = maximumBlockCount
    self.maximumCompressedBlockSize = maximumCompressedBlockSize
    self.maximumDecompressedBlockSize = maximumDecompressedBlockSize
    self.maximumTotalDecompressedSize = maximumTotalDecompressedSize
    self.maximumRecordSize = maximumRecordSize
  }
}

/// Configuration for opening, indexing, and caching an MDict container.
public struct MDictOptions: Equatable, Sendable {
  /// The file-reading strategy used by file-based initializers.
  public var fileLoading: MDictFileLoading

  /// The lookup indexes built when the container is opened.
  public var indexing: MDictIndexing

  /// The maximum number of decompressed record blocks retained in memory.
  ///
  /// Set this value or ``decompressedBlockCacheBytes`` to zero to disable the
  /// decompressed-block cache.
  public var decompressedBlockCacheCount: Int

  /// The approximate maximum number of decompressed bytes retained in cache.
  public var decompressedBlockCacheBytes: Int

  /// Parser and record resource limits.
  public var limits: MDictLimits

  /// Creates options for opening an MDict container.
  public init(
    fileLoading: MDictFileLoading = .mappedIfSafe,
    indexing: MDictIndexing = .exactAndPrefix,
    decompressedBlockCacheCount: Int = 16,
    decompressedBlockCacheBytes: Int = 64 * 1_024 * 1_024,
    limits: MDictLimits = MDictLimits()
  ) {
    self.fileLoading = fileLoading
    self.indexing = indexing
    self.decompressedBlockCacheCount = decompressedBlockCacheCount
    self.decompressedBlockCacheBytes = decompressedBlockCacheBytes
    self.limits = limits
  }
}
