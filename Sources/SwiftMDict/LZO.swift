// SPDX-License-Identifier: Apache-2.0
// Adapted and modified from Aircompressor's LzoRawDecompressor.
// Copyright 2019 Airlift authors.
// Licensed under the Apache License, Version 2.0.
// https://github.com/airlift/aircompressor

import Foundation

enum LZO1X {
  static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
    guard expectedSize >= 0 else {
      throw MDictError.invalidFormat("LZO output size is negative.")
    }
    guard !data.isEmpty else {
      guard expectedSize == 0 else {
        throw MDictError.invalidFormat("LZO block is empty.")
      }
      return Data()
    }

    var decoder = Decoder(input: [UInt8](data), outputSize: expectedSize)
    return Data(try decoder.decode())
  }
}

extension LZO1X {
  fileprivate struct Decoder {
    let input: [UInt8]
    var output: [UInt8]
    var inputOffset = 0
    var outputOffset = 0

    init(input: [UInt8], outputSize: Int) {
      self.input = input
      self.output = [UInt8](repeating: 0, count: outputSize)
    }

    mutating func decode() throws -> [UInt8] {
      while inputOffset < input.count {
        try decodeStream()
      }

      guard outputOffset == output.count else {
        throw MDictError.invalidFormat(
          "LZO output size mismatch: expected \(output.count), decoded \(outputOffset)."
        )
      }
      return output
    }

    mutating func decodeStream() throws {
      var isFirstCommand = true
      var previousLiteralLength = 0

      while true {
        let command = try readByte()
        let decoded = try decodeCommand(
          command,
          isFirstCommand: isFirstCommand,
          previousLiteralLength: previousLiteralLength
        )

        if decoded.isEndMarker {
          return
        }

        isFirstCommand = false
        if decoded.matchLength > 0 {
          try copyMatch(
            distance: decoded.matchOffset + 1,
            count: decoded.matchLength
          )
        }
        try copyLiterals(decoded.literalLength)
        previousLiteralLength = decoded.literalLength
      }
    }

    mutating func decodeCommand(
      _ command: Int,
      isFirstCommand: Bool,
      previousLiteralLength: Int
    ) throws -> Command {
      if command & 0xf0 == 0 {
        return try decodeLowCommand(
          command,
          previousLiteralLength: previousLiteralLength
        )
      }

      if isFirstCommand, command > 17 {
        let literalLength = command - 17
        return Command(literalLength: literalLength)
      }

      if command & 0xf0 == 0x10 {
        var matchLength = command & 0x07
        if matchLength == 0 {
          matchLength = try variableLength(seed: 0x07)
        }
        matchLength += 2

        let trailer = try readUInt16LittleEndian()
        var matchOffset = (command & 0x08) << 11
        matchOffset += trailer >> 2
        if matchOffset == 0 {
          return .endMarker
        }
        matchOffset += 0x3fff

        return Command(
          matchLength: matchLength,
          matchOffset: matchOffset,
          literalLength: trailer & 0x03
        )
      }

      if command & 0xe0 == 0x20 {
        var matchLength = command & 0x1f
        if matchLength == 0 {
          matchLength = try variableLength(seed: 0x1f)
        }
        matchLength += 2

        let trailer = try readUInt16LittleEndian()
        return Command(
          matchLength: matchLength,
          matchOffset: trailer >> 2,
          literalLength: trailer & 0x03
        )
      }

      if command & 0xc0 != 0 {
        let matchLength = ((command & 0xe0) >> 5) + 1
        let matchOffset =
          ((command & 0x1c) >> 2)
          | (try readByte() << 3)
        return Command(
          matchLength: matchLength,
          matchOffset: matchOffset,
          literalLength: command & 0x03
        )
      }

      throw malformedCommand(command)
    }

    mutating func decodeLowCommand(
      _ command: Int,
      previousLiteralLength: Int
    ) throws -> Command {
      if previousLiteralLength == 0 {
        var literalLength = command & 0x0f
        if literalLength == 0 {
          literalLength = try variableLength(seed: 0x0f)
        }
        return Command(literalLength: literalLength + 3)
      }

      let trailer = try readByte()
      let encodedOffset =
        ((command & 0x0c) >> 2)
        | (trailer << 2)

      if previousLiteralLength <= 3 {
        return Command(
          matchLength: 2,
          matchOffset: encodedOffset,
          literalLength: command & 0x03
        )
      }

      return Command(
        matchLength: 3,
        matchOffset: encodedOffset | 0x0800,
        literalLength: command & 0x03
      )
    }

    mutating func variableLength(seed: Int) throws -> Int {
      var length = seed
      while true {
        let next = try readByte()
        if next != 0 {
          return length + next
        }
        let (extended, overflow) = length.addingReportingOverflow(255)
        guard !overflow else {
          throw MDictError.invalidFormat("LZO length overflow.")
        }
        length = extended
      }
    }

    mutating func copyLiterals(_ count: Int) throws {
      guard count >= 0,
        count <= input.count - inputOffset,
        count <= output.count - outputOffset
      else {
        throw MDictError.invalidFormat("LZO literal run exceeds block bounds.")
      }

      output[outputOffset..<(outputOffset + count)] =
        input[inputOffset..<(inputOffset + count)]
      inputOffset += count
      outputOffset += count
    }

    mutating func copyMatch(distance: Int, count: Int) throws {
      guard distance > 0,
        distance <= outputOffset,
        count >= 0,
        count <= output.count - outputOffset
      else {
        throw MDictError.invalidFormat("LZO match exceeds block bounds.")
      }

      var sourceOffset = outputOffset - distance
      for _ in 0..<count {
        output[outputOffset] = output[sourceOffset]
        outputOffset += 1
        sourceOffset += 1
      }
    }

    mutating func readByte() throws -> Int {
      guard inputOffset < input.count else {
        throw MDictError.invalidFormat("LZO input ended unexpectedly.")
      }
      defer { inputOffset += 1 }
      return Int(input[inputOffset])
    }

    mutating func readUInt16LittleEndian() throws -> Int {
      let low = try readByte()
      let high = try readByte()
      return low | (high << 8)
    }

    func malformedCommand(_ command: Int) -> MDictError {
      MDictError.invalidFormat(
        "Invalid LZO command 0x\(String(command, radix: 16, uppercase: false))."
      )
    }
  }

  fileprivate struct Command {
    let matchLength: Int
    let matchOffset: Int
    let literalLength: Int
    let isEndMarker: Bool

    init(
      matchLength: Int = 0,
      matchOffset: Int = 0,
      literalLength: Int = 0,
      isEndMarker: Bool = false
    ) {
      self.matchLength = matchLength
      self.matchOffset = matchOffset
      self.literalLength = literalLength
      self.isEndMarker = isEndMarker
    }

    static let endMarker = Command(isEndMarker: true)
  }
}
