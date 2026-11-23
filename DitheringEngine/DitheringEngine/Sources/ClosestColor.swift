//
//  ClosestColor.swift
//  DitheringEngine
//
//  Created by APPLE on 2024/12/28.
//

import Synchronization

/// 以各分量的 Float 位模式作为键，保留最近色计算使用的小数精度。
private struct ClosestColorKey: Hashable, Sendable {
    let red: UInt32
    let green: UInt32
    let blue: UInt32

    init(_ color: SIMD3<Float>) {
        red = color.x.bitPattern
        green = color.y.bitPattern
        blue = color.z.bitPattern
    }
}

/// 匹配策略是缓存身份的一部分，采用其他距离公式的结果不能共用该身份。
private enum ClosestColorMetric: Hashable, Sendable {
    case continuousRedmeanV1
}

/// 缓存保存调色板索引；条目内容和顺序共同决定身份及等距颜色的选择顺序。
private struct ClosestColorPalette<Output: ImageColor>: Hashable, Sendable {
    let entries: [SIMD3<Output>]
    let metric = ClosestColorMetric.continuousRedmeanV1
}

/// 全部共享可变数据集中存入 Mutex 的受保护状态。
private struct ClosestColorState<Output: ImageColor>: Sendable {
    var manualColors: [ClosestColorKey: SIMD3<Output>] = [:]
    var paletteIndices: [ClosestColorPalette<Output>: [ClosestColorKey: Int]] = [:]
    var prepopulatedPalette: ClosestColorPalette<Output>?
}

/// 不同输入类型的视图共享此存储对象，状态仅通过 withLock 同步访问。
/// 手动颜色映射与按调色板隔离的索引表分别保存，避免手动写入干预最近色计算。
private final class ClosestColorStorage<Output: ImageColor>: Sendable {
    let state = Mutex(ClosestColorState<Output>())
}

/// 支持并发共享的 RGB 最近色缓存，颜色分量按 0...255 范围解释。
///
/// 引擎查询按精确浮点颜色、完整有序调色板及颜色距离策略隔离。
/// ``register(paletteColor:asAMatchTo:)`` 与 ``getPaletteColor(for:)`` 提供独立的手动映射，
/// 不参与引擎的最近色判定。缓存条目按需保存，生命周期与共享存储一致。
public final class ClosestColor<Input: ImageColor, Output: ImageColor>: Sendable {
    private let storage: ClosestColorStorage<Output>

    /// 创建空缓存；整数和非整数颜色均可按需写入。
    public init() {
        storage = ClosestColorStorage()
    }

    private init(storage: ClosestColorStorage<Output>) {
        self.storage = storage
    }

    /// 按给定调色板预填充整个整数 RGB 立方体（16,777,216 项）。
    ///
    /// 此方法同步计算所有匹配并占用大量内存。空调色板返回空缓存；
    /// 非空调色板的整数颜色可直接命中，误差扩散产生的非整数颜色仍按需缓存。
    /// 预填充结果也可通过 ``getPaletteColor(for:)`` 查询。
    public static func populateWitColors(fromLUT collection: ColorCollection<Output>) -> ClosestColor<Input, Output> {
        let cache = ClosestColor<Input, Output>()
        guard !collection.entries.isEmpty else { return cache }
        let palette = ClosestColorPalette(entries: collection.entries)
        var indices: [ClosestColorKey: Int] = [:]
        indices.reserveCapacity(256 * 256 * 256)
        for r in 0..<256 {
            for g in 0..<256 {
                for b in 0..<256 {
                    let color = SIMD3<Float>(Float(r), Float(g), Float(b))
                    indices[ClosestColorKey(color)] = collection.closestIndex(to: color)
                }
            }
        }
        cache.storage.state.withLock { state in
            state.paletteIndices[palette] = indices
            state.prepopulatedPalette = palette
        }
        return cache
    }

    /// 登记手动颜色映射，相同输入颜色的后续登记覆盖此前的手动值。
    ///
    /// 不验证目标颜色是否属于某个调色板，也不将该映射用于引擎的最近色判定。
    public func register(paletteColor: SIMD3<Output>, asAMatchTo color: SIMD3<Input>) {
        let key = ClosestColorKey(color.floatSIMD3)
        storage.state.withLock { state in
            state.manualColors[key] = paletteColor
        }
    }

    /// 优先查询手动映射，其次查询构造时预填充的调色板，均未命中时返回 nil。
    ///
    /// 引擎按需生成的其他调色板缓存不会通过此接口暴露。
    public func getPaletteColor(for color: SIMD3<Input>) -> SIMD3<Output>? {
        let key = ClosestColorKey(color.floatSIMD3)
        return storage.state.withLock { state in
            if let registered = state.manualColors[key] { return registered }
            guard let palette = state.prepopulatedPalette,
                  let index = state.paletteIndices[palette]?[key],
                  palette.entries.indices.contains(index) else { return nil }
            return palette.entries[index]
        }
    }

    /// 查询当前连续 redmean 策略下的精确索引；未命中时由调用方计算并登记。
    ///
    /// compute 必须按给定调色板顺序使用同一距离公式，并返回有效索引。
    /// 计算在锁外执行，并发未命中允许重复计算；查询和写入均在锁内完成。
    func resolveIndex(for color: SIMD3<Float>, palette: [SIMD3<Output>],
                      compute: () -> Int) -> Int {
        let identity = ClosestColorPalette(entries: palette)
        let key = ClosestColorKey(color)
        let cached = storage.state.withLock { state in
            state.paletteIndices[identity]?[key]
        }
        if let cached { return cached }

        let index = compute()
        storage.state.withLock { state in
            state.paletteIndices[identity, default: [:]][key] = index
        }
        return index
    }

    /// 返回共享同一存储的 Float 输入视图，两个视图的后续写入互相可见。
    ///
    /// UInt8 颜色与数值相同的整数 Float 颜色使用同一键；非整数 Float 颜色保留独立键。
    public func toFloatingWithoutCopy() -> ClosestColor<Float, Output> where Input == UInt8 {
        ClosestColor<Float, Output>(storage: storage)
    }
}
