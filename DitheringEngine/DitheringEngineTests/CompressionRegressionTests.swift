import Foundation
import Testing
@testable import DitheringEngine

struct CompressionRegressionTests {
    @Test func preservesExistingWireFormatAndOverlappingMatches() throws {
        #expect(Data("ABC".utf8).compress() == Data([0x07, 65, 66, 67]))
        let repeated = Data(repeating: 65, count: 19)
        #expect(repeated.compress() == Data([0x01, 65, 0x00, 0x1F]))
        #expect(try Data([0x01, 65, 0x00, 0x1F]).decompress() == repeated)
    }

    @Test func acceptsPartialFinalTokenGroups() throws {
        for count in 0...32 {
            let sample = Data((0..<count).map { UInt8($0) })
            #expect(try sample.compress().decompress(expectedSize: count) == sample)
        }
    }

    @Test func rejectsMissingLiteralsAndEmptyTokenGroups() {
        #expect(throws: CompressionError.truncatedLiteral) {
            try Data([0x03, 65]).decompress()
        }
        #expect(throws: CompressionError.emptyTokenGroup) {
            try Data([0x00]).decompress()
        }
        #expect(throws: CompressionError.emptyTokenGroup) {
            try Data([0xFF]).decompress()
        }
        // 8 个字面量之后仅有标志字节，缺少对应标记的数据。
        #expect(throws: CompressionError.emptyTokenGroup) {
            try Data([0xFF, 1, 2, 3, 4, 5, 6, 7, 8, 0x00]).decompress()
        }
    }

    @Test func rejectsInvalidMatches() {
        #expect(throws: CompressionError.truncatedMatch) {
            try Data([0x01, 65, 0x00]).decompress()
        }
        #expect(throws: CompressionError.distanceOutOfRange) {
            try Data([0x00, 0x00, 0x10]).decompress()
        }
        #expect(throws: CompressionError.distanceOutOfRange) {
            try Data([0x01, 65, 0x00, 0x00]).decompress()
        }
    }

    @Test func expectedSizeDetectsOtherwiseAmbiguousTruncation() throws {
        // 在最后一个匹配标记的边界截断，仍可得到合法但输出较短的数据流。
        let truncated = Data([0x01, 65])
        #expect(try truncated.decompress() == Data([65]))
        #expect(throws: CompressionError.sizeMismatch) {
            try truncated.decompress(expectedSize: 19)
        }
        #expect(throws: CompressionError.sizeMismatch) {
            try Data([0x01, 65, 0x00, 0x1F]).decompress(expectedSize: 18)
        }
    }

    @Test func enforcesOutputLimitsBeforeAppendingMatches() throws {
        let compressed = Data([0x01, 65, 0x00, 0x1F])
        #expect(throws: CompressionError.outputLimitExceeded) {
            try compressed.decompress(maxOutputSize: 18)
        }
        #expect(throws: CompressionError.outputLimitExceeded) {
            try Data([0x01, 65]).decompress(maxOutputSize: 0)
        }
        #expect(try compressed.decompress(expectedSize: 19, maxOutputSize: 19).count == 19)
        #expect(try Data().decompress(expectedSize: 0, maxOutputSize: 0).isEmpty)
        #expect(throws: CompressionError.invalidSizeLimit) {
            try compressed.decompress(expectedSize: -1)
        }
        #expect(throws: CompressionError.invalidSizeLimit) {
            try compressed.decompress(maxOutputSize: -1)
        }
    }
}
