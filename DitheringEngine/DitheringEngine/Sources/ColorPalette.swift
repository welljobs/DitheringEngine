//
//  ColorPalette.swift
//  DitheringEngine
//
//  Created by APPLE on 2024/12/28.
//

import Foundation

/// 基于有序颜色集合进行最近色量化的调色板。
///
/// 查询采用连续 redmean 距离，颜色分量按 0...255 范围解释；等距时优先选择靠前的条目。
public struct ColorPalette<Color: ImageColor>: Sendable {
    let type: PaletteType

    // 缓存身份包含完整有序条目；空集合不进行索引查询。
    private func pickColorFrom<T: ImageColor>(collection: ColorCollection<Color>, basedOn color: SIMD3<T>, cache: ClosestColor<T, Color>?) -> SIMD3<Color> {
        guard !collection.entries.isEmpty else { return .zero }
        let index: Int
        if let cache {
            index = cache.resolveIndex(for: color.floatSIMD3, palette: collection.entries) {
                collection.closestIndex(to: color)
            }
        } else {
            index = collection.closestIndex(to: color)
        }
        return collection.entries[index]
    }

    /// 返回最接近输入颜色的调色板条目；空调色板返回零颜色。
    ///
    /// 可选缓存支持在多个调色板之间并发共享，手动登记的颜色映射不影响匹配结果。
    public func pickColor<T: ImageColor>(basedOn color: SIMD3<T>, cache: ClosestColor<T, Color>? = nil) -> SIMD3<Color> {
        switch type {
        case .collection(let collection):
            return pickColorFrom(collection: collection, basedOn: color, cache: cache)
        }
    }

    /// 返回最接近输入颜色的条目索引，匹配规则与 ``pickColor(basedOn:cache:)`` 一致。
    ///
    /// 空调色板返回占位值 0，调用方须先检查 ``uniqueColors``。
    public func pickIndex<T: ImageColor>(basedOn color: SIMD3<T>) -> Int {
        switch type {
        case .collection(let collection):
            return collection.closestIndex(to: color)
        }
    }

    /// 调色板条目总数，包含重复颜色；此属性不执行去重。
    public var uniqueColors: Int {
        switch type {
        case .collection(let collection):
            return collection.count
        }
    }

    /// 按原顺序返回 UInt8 RGB 颜色条目。
    ///
    /// Float 分量向零截断；调用方须保证数值有限且可表示为 UInt8，此方法不执行范围收敛。
    public func colors() -> [SIMD3<UInt8>] {
        switch type {
        case .collection(let collection):
            return collection.entries.map { $0.uInt8SIMD3 }
        }
    }
}

extension ColorPalette {
    /// 从给定颜色集合构造调色板，保留条目顺序及重复颜色。
    public static func from(collection: ColorCollection<Color>) -> ColorPalette<Color> {
        ColorPalette(type: .collection(collection))
    }
}
extension ColorPalette {
    /// 调色板的颜色来源。
    public enum PaletteType: Sendable {
        /// 由有序颜色集合提供条目。
        case collection(ColorCollection<Color>)
    }
}
