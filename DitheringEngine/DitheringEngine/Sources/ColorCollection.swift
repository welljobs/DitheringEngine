//
//  ColorCollection.swift
//  DitheringEngine
//
//  Created by APPLE on 2024/12/28.
//

import simd

/// 按条目顺序保存 RGB 颜色的不可变查找表（LUT）。
///
/// 最近色查询采用连续 redmean 距离，颜色分量按 0...255 范围解释，Float 输入可保留小数。
/// 条目顺序决定等距时的优先级；集合不会排序或去除重复颜色。
public struct ColorCollection<Color: ImageColor>: Sendable {
    /// 原始颜色条目，三个分量依次为红、绿、蓝。
    public let entries: [SIMD3<Color>]
    /// 条目总数，包含重复颜色。
    public var count: Int { entries.count }

    /// 保存给定顺序的颜色条目；颜色分量应为有限的 0...255 数值。
    public init(entries: [SIMD3<Color>]) {
        self.entries = entries
    }

    /// 返回连续 redmean 距离最小的条目索引，距离相等时选择最先出现的条目。
    ///
    /// 颜色分量应为有限的 0...255 数值。空集合返回占位值 0，调用方须先检查集合是否为空。
    public func closestIndex<T: ImageColor>(to color: SIMD3<T>) -> Int {
        let target = color.floatSIMD3
        var bestIndex = 0
        var best = Float.infinity
        for (i, entry) in entries.enumerated() {
            let candidate = entry.floatSIMD3
            let redmean = (candidate.x + target.x) / 2
            let difference = candidate - target
            // Riemersma 连续 redmean 公式：以平均红色分量确定权重，
            // 再对各通道差值的平方加权。比较距离时无需计算平方根。
            // https://www.compuphase.com/cmetric.htm
            let coefficients = SIMD3<Float>(2 + redmean / 256,
                                             4,
                                             2 + (255 - redmean) / 256)
            let distance = simd_dot(coefficients, difference * difference)
            if distance < best {
                best = distance
                bestIndex = i
            }
        }
        return bestIndex
    }

    /// 返回与给定 RGB 颜色距离最近的条目；空集合返回三个分量均为零的颜色。
    public func closestColor<T: ImageColor>(to color: SIMD3<T>) -> SIMD3<Color> {
        guard !entries.isEmpty else { return .zero }
        return entries[closestIndex(to: color)]
    }
}
