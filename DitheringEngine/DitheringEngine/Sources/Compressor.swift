//
//  Compressor.swift
//  DitheringEngine
//
//  Created by APPLE on 2025/1/2.
//
//  本模块提供 SDK 使用的裸 LZSS 字节格式。
//  该格式与 minilzo（lzo1x_1_compress / lzo1x_decompress）字节格式不兼容；
//  与采用 minilzo 的设备通信时，应使用通信双方约定的 minilzo 编解码器。
//

import Foundation

/// 裸 LZSS 解码过程中检测到的格式错误或输出约束冲突。
public enum CompressionError: Error, Sendable, Equatable {
    /// 标志字节之后没有任何字面量或匹配项。
    case emptyTokenGroup
    /// 标志位声明了字面量，但输入未提供对应字节。
    case truncatedLiteral
    /// 匹配项不足两个编码字节。
    case truncatedMatch
    /// 匹配距离为零，或超过已解码的数据长度。
    case distanceOutOfRange
    /// 期望长度或输出上限为负数。
    case invalidSizeLimit
    /// 输出长度超过期望长度，或解码结束时未达到期望长度。
    case sizeMismatch
    /// 追加下一个字面量或完整匹配将超过输出上限。
    case outputLimitExceeded
}

extension Data {
    /// 将数据压缩为裸 LZSS 格式，空输入产生空输出。
    ///
    /// 搜索窗口为 4096 字节，可编码的回溯距离为 1...4095，匹配长度为 3...18 字节。
    /// 每组包含一个标志字节及最多八个编码项，标志位按最低位到最高位的顺序解释：
    /// 1 表示一个字节的字面量，0 表示两个字节的匹配项。末组未使用的标志位为零。
    /// 匹配项以大端顺序保存 `(distance << 4) | (length - 3)`。
    ///
    /// 此格式不包含原始长度和校验和，接收端需要独立取得这些信息以验证完整性。
    public func compress() -> Data {
        let src = [UInt8](self)
        guard !src.isEmpty else { return Data() }

        let windowSize = 4096
        let maxMatch = 18
        let minMatch = 3
        var out: [UInt8] = []
        var i = 0

        while i < src.count {
            var flags: UInt8 = 0
            var tokens: [UInt8] = []
            for bit in 0..<8 {
                guard i < src.count else { break }

                var bestLen = 0
                var bestDist = 0
                if i + minMatch <= src.count {
                    let start = Swift.max(0, i - (windowSize - 1))
                    for j in start..<i {
                        var len = 0
                        // 允许匹配区间与当前输入区间重叠，解码端通过逐字节回溯重建重复序列。
                        while len < maxMatch,
                              i + len < src.count,
                              src[j + len] == src[i + len] {
                            len += 1
                        }
                        if len > bestLen {
                            bestLen = len
                            bestDist = i - j
                        }
                        if bestLen == maxMatch { break }
                    }
                }

                if bestLen >= minMatch, bestDist <= 4095 {
                    let packed = UInt16((bestDist << 4) | (bestLen - minMatch))
                    tokens.append(UInt8(packed >> 8))
                    tokens.append(UInt8(packed & 0xFF))
                    i += bestLen
                } else {
                    tokens.append(src[i])
                    flags |= (1 << bit)
                    i += 1
                }
            }
            out.append(flags)
            out.append(contentsOf: tokens)
        }
        return Data(out)
    }

    /// 解压裸 LZSS 数据，并验证编码结构及可选的输出长度约束。
    ///
    /// 末组可以不足八个编码项，但未使用的高位标志必须为零。
    /// 空输入表示空输出，仍会应用期望长度检查。
    /// - Parameters:
    ///   - expectedSize: 可选的原始字节数，必须非负；解码结果必须与之完全一致。
    ///   - maxOutputSize: 可选的输出字节数上限，必须非负；在追加数据前检查。
    /// - Returns: 解码后的原始字节。
    /// - Throws: 结构损坏、匹配距离无效或输出约束不满足时抛出 ``CompressionError``。
    /// - Note: 裸格式没有长度或校验和；未传 expectedSize 时，部分发生在编码项边界的截断无法识别。
    public func decompress(expectedSize: Int? = nil, maxOutputSize: Int? = nil) throws -> Data {
        guard expectedSize.map({ $0 >= 0 }) ?? true,
              maxOutputSize.map({ $0 >= 0 }) ?? true else {
            throw CompressionError.invalidSizeLimit
        }
        let src = [UInt8](self)
        var out: [UInt8] = []
        var i = 0

        // 以减法比较剩余额度，避免先求追加后的总长度而产生整数溢出。
        func checkAdditionalSize(_ additionalSize: Int, currentSize: Int) throws {
            if let maxOutputSize, additionalSize > maxOutputSize - currentSize {
                throw CompressionError.outputLimitExceeded
            }
            if let expectedSize, additionalSize > expectedSize - currentSize {
                throw CompressionError.sizeMismatch
            }
        }

        while i < src.count {
            let flags = src[i]
            i += 1
            for bit in 0..<8 {
                guard i < src.count else {
                    guard bit > 0 else { throw CompressionError.emptyTokenGroup }
                    guard flags >> bit == 0 else { throw CompressionError.truncatedLiteral }
                    break
                }
                if flags & (1 << bit) != 0 {
                    try checkAdditionalSize(1, currentSize: out.count)
                    out.append(src[i])
                    i += 1
                } else {
                    guard i + 1 < src.count else { throw CompressionError.truncatedMatch }
                    let packed = (UInt16(src[i]) << 8) | UInt16(src[i + 1])
                    i += 2
                    let distance = Int(packed >> 4)
                    let length = Int(packed & 0x0F) + 3
                    guard distance > 0, distance <= out.count else {
                        throw CompressionError.distanceOutOfRange
                    }
                    try checkAdditionalSize(length, currentSize: out.count)
                    // 每次追加后重新定位回溯起点，支持 length 大于 distance 的重叠匹配。
                    for _ in 0..<length {
                        out.append(out[out.count - distance])
                    }
                }
            }
        }
        if let expectedSize, out.count != expectedSize { throw CompressionError.sizeMismatch }
        return Data(out)
    }
}
