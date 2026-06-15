import CZlib
import Foundation

enum MDictCompression {
  static func decodeBlock(_ block: Data, expectedSize: Int) throws -> Data {
    guard block.count >= 8 else {
      throw MDictError.truncatedData(offset: 0, needed: 8, available: block.count)
    }

    var reader = BinaryReader(block)
    let info = try reader.readUInt32LE()
    let checksum = try reader.readUInt32BE()
    let payload = block.subdata(in: 8..<block.count)
    let compressionMethod = info & 0x0f
    let encryptionMethod = (info >> 4) & 0x0f

    guard encryptionMethod == 0 else {
      throw MDictError.unsupported("Encrypted MDict blocks are not supported.")
    }

    let decompressed: Data
    switch compressionMethod {
    case 0:
      guard payload.count == expectedSize else {
        throw MDictError.invalidFormat(
          "Uncompressed block size mismatch. Expected \(expectedSize), got \(payload.count).")
      }
      decompressed = payload
    case 1:
      decompressed = try LZO1X.decompress(payload, expectedSize: expectedSize)
    case 2:
      decompressed = try inflateZlib(payload, expectedSize: expectedSize)
    default:
      throw MDictError.unsupported("Unknown MDict compression type \(compressionMethod).")
    }

    guard MDictChecksum.adler32(decompressed) == checksum else {
      throw MDictError.integrityCheckFailed(section: "compressed block")
    }
    return decompressed
  }

  private static func inflateZlib(_ payload: Data, expectedSize: Int) throws -> Data {
    if expectedSize == 0 {
      return Data()
    }
    var output = Data(count: expectedSize)
    var outputLength = uLongf(expectedSize)
    let status = payload.withUnsafeBytes { source in
      output.withUnsafeMutableBytes { destination in
        uncompress(
          destination.bindMemory(to: Bytef.self).baseAddress,
          &outputLength,
          source.bindMemory(to: Bytef.self).baseAddress,
          uLong(payload.count)
        )
      }
    }

    guard status == Z_OK, outputLength == expectedSize else {
      throw MDictError.invalidFormat(
        "Could not inflate zlib block. Expected \(expectedSize), got \(outputLength), status \(status)."
      )
    }
    return output
  }
}
