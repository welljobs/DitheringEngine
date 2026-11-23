//
//  ImageColor.swift
//  DitheringEngine
//
//  Created by APPLE on 2024/12/28.
//

import simd

/// RGB 颜色分量及其数值转换约定，SDK 提供 UInt8 和 Float 两种实现。
///
/// 颜色数值按 0...255 范围解释，Float 不采用 0...1 归一化表示。
/// SIMD 底层存储同样满足 Sendable，支持以值形式跨并发上下文传递三分量颜色。
public protocol ImageColor: SIMDScalar, Codable, Hashable, Sendable where SIMD4Storage: Sendable {
    /// 返回颜色类型的零值。
    static var zero: Self { get }

    /// 返回用于距离计算和误差累加的 Float 数值，不执行归一化。
    var floatValue: Float { get }

    /// 返回 UInt8 数值；标准 Float 实现向零截断，不执行范围收敛。
    /// 调用方须保证 Float 数值有限，且截断结果可由 UInt8 表示。
    var uInt8Value: UInt8 { get }

    /// 返回 Int 数值；标准 Float 实现向零截断，要求结果可由 Int 表示。
    var intValue: Int { get }
}
// Float 保留算法计算精度；整数转换遵循 Swift 的范围前置条件。
extension Float: ImageColor {
    /// 返回分量本身。
    public var floatValue: Float {
        self
    }
    /// 向零截断为 UInt8，非有限数或超出可表示范围的值触发 Swift 转换前置条件。
    public var uInt8Value: UInt8 {
        UInt8(self)
    }
    /// 向零截断为 Int，非有限数或超出可表示范围的值触发 Swift 转换前置条件。
    public var intValue: Int {
        Int(self)
    }
}
// UInt8 与 Float、Int 之间的以下转换均不改变分量数值。
extension UInt8: ImageColor {
    /// 无损转换为 Float。
    public var floatValue: Float {
        Float(self)
    }
    /// 返回分量本身。
    public var uInt8Value: UInt8 {
        self
    }
    /// 无损转换为 Int。
    public var intValue: Int {
        Int(self)
    }
}

// 三分量颜色统一采用 x=红、y=绿、z=蓝的 RGB 顺序。
extension SIMD3 where Scalar: ImageColor {
    /// 返回三个分量均为零的颜色。
    static var zero: SIMD3<Scalar> { SIMD3(.zero, .zero, .zero) }

    /// 逐分量转换为 Float RGB 数值。
    var floatSIMD3: SIMD3<Float> {
        return SIMD3<Float>(x: x.floatValue, y: y.floatValue, z: z.floatValue)
    }

    /// 逐分量转换为 UInt8，沿用标量转换的截断及范围前置条件。
    var uInt8SIMD3: SIMD3<UInt8> {
        return SIMD3<UInt8>(x: x.uInt8Value, y: y.uInt8Value, z: z.uInt8Value)
    }
}
extension SIMD3 {
    /// RGB 约定中的红色分量，对应 x。
    var red: Scalar {
        get { self.x }
        set(value) { self.x = value }
    }

    /// RGB 约定中的绿色分量，对应 y。
    var green: Scalar {
        get { self.y }
        set(value) { self.y = value }
    }

    /// RGB 约定中的蓝色分量，对应 z。
    var blue: Scalar {
        get { self.z }
        set(value) { self.z = value }
    }
}
/// 色阶模式的分量阈值，分别配合红色、黄色和白色的比较规则使用。
struct Thresholds {
    /// 红通道须大于 160，绿、蓝通道须小于 128。
    static let red: SIMD3<UInt8> = SIMD3<UInt8>(0xA0, 0x80, 0x80)
    /// 红、绿通道须大于 160，蓝通道须小于 128。
    static let yellow: SIMD3<UInt8> = SIMD3<UInt8>(0xA0, 0xA0, 0x80)
    /// 白色要求三个通道均大于或等于 80。
    static let white: SIMD3<UInt8> = SIMD3<UInt8>(0x50, 0x50, 0x50)
}
infix operator ><< : ComparisonPrecedence
infix operator >>< : ComparisonPrecedence

extension SIMD3 where Scalar == UInt8 {
    /// 判断三个分量是否依次满足 lhs.x > rhs.x、lhs.y < rhs.y、lhs.z < rhs.z。
    public static func ><< (lhs: SIMD3<UInt8>, rhs: SIMD3<UInt8>) -> Bool {
        return lhs.x > rhs.x && lhs.y < rhs.y && lhs.z < rhs.z
    }
    /// 判断三个分量是否依次满足 lhs.x > rhs.x、lhs.y > rhs.y、lhs.z < rhs.z。
    public static func >>< (lhs: SIMD3<UInt8>, rhs: SIMD3<UInt8>) -> Bool {
        return lhs.x > rhs.x && lhs.y > rhs.y && lhs.z < rhs.z
    }
    /// 逐分量大于比较，所有分量均大于时返回 true。
    public static func > (lhs: SIMD3<UInt8>, rhs: SIMD3<UInt8>) -> Bool {
        return lhs.x > rhs.x && lhs.y > rhs.y && lhs.z > rhs.z
    }

    /// 逐分量小于比较，所有分量均小于时返回 true。
    public static func < (lhs: SIMD3<UInt8>, rhs: SIMD3<UInt8>) -> Bool {
        return lhs.x < rhs.x && lhs.y < rhs.y && lhs.z < rhs.z
    }

    /// 逐分量大于等于比较，所有分量均满足时返回 true。
    public static func >= (lhs: SIMD3<UInt8>, rhs: SIMD3<UInt8>) -> Bool {
        return lhs.x >= rhs.x && lhs.y >= rhs.y && lhs.z >= rhs.z
    }

    /// 逐分量小于等于比较，所有分量均满足时返回 true。
    public static func <= (lhs: SIMD3<UInt8>, rhs: SIMD3<UInt8>) -> Bool {
        return lhs.x <= rhs.x && lhs.y <= rhs.y && lhs.z <= rhs.z
    }
}
