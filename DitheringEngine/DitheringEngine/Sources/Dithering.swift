//
//  Dithering.swift
//  DitheringEngine
//
//  Created by APPLE on 2024/12/27.
//  Swift 6 实现的误差扩散抖动与位打包引擎。
//  基于本 SDK 既有颜色体系：ImageColor / Thresholds / ColorCollection / ColorPalette。
//  遵循电子纸设备的调色板色值约定、扫描顺序和像素打包格式。
//

@preconcurrency import CoreGraphics
import Foundation
import simd

// MARK: - 基础类型

/// 设备像素的位打包方式；每行或每列独立补齐到字节边界。
public enum CombineMode: String, Sendable, Codable, CustomStringConvertible {
    case single    // 单平面，每像素 1 位。
    case complex   // 两个每像素 1 位的平面先分别打包，再按 A、B 顺序串联。
    case color4    // 每像素 2 位，每字节容纳 4 个像素。

    public var description: String {
        switch self {
        case .single: return "单色 (1bpp)"
        case .complex: return "双平面 (1bpp×2)"
        case .color4: return "四色 (2bpp)"
        }
    }
}

/// 设备数据的扫描方向，仅影响位打包，不改变量化索引和预览的坐标顺序。
public enum ScanMode: String, Sendable, Codable, CustomStringConvertible {
    case horizontal
    case vertical

    public var description: String {
        switch self {
        case .horizontal: return "水平扫描"
        case .vertical: return "垂直扫描"
        }
    }
}

/// 设备屏幕的颜色编号，用于选择阈值模式中的颜色分类规则。
public enum ColorCode: String, Sendable, Codable {
    case bw = "20"
    case bwr = "30"
    case bwy = "31"
    case bwry = "40"
}

/// 设备颜色模板，提供匹配的调色板、设备色值及位打包方式。
///
/// 调色板按黑、白、第三色、第四色排列，颜色按 RGB 顺序存入 `SIMD3(x: r, y: g, z: b)`。
/// 模板设备色值为黑 `0`（00）、白 `1`（01）、红 `3`（11）、黄 `2`（10）。
public enum ColorTemplate: String, Sendable, Codable, CaseIterable, CustomStringConvertible {
    case bw = "20"
    case bwr = "30"
    case bwy = "31"
    case bwry = "40"

    public var colorCode: ColorCode { ColorCode(rawValue: rawValue)! }

    public var combine: CombineMode {
        switch self {
        case .bw: return .single
        case .bwr, .bwy: return .complex
        case .bwry: return .color4
        }
    }

    public var palette: [SIMD3<UInt8>] {
        switch self {
        case .bw:
            return [SIMD3<UInt8>(x: 0, y: 0, z: 0), SIMD3<UInt8>(x: 255, y: 255, z: 255)]
        case .bwr:
            return [SIMD3<UInt8>(x: 0, y: 0, z: 0), SIMD3<UInt8>(x: 255, y: 255, z: 255),
                    SIMD3<UInt8>(x: 255, y: 0, z: 0)]
        case .bwy:
            return [SIMD3<UInt8>(x: 0, y: 0, z: 0), SIMD3<UInt8>(x: 255, y: 255, z: 255),
                    SIMD3<UInt8>(x: 255, y: 255, z: 0)]
        case .bwry:
            return [SIMD3<UInt8>(x: 0, y: 0, z: 0), SIMD3<UInt8>(x: 255, y: 255, z: 255),
                    SIMD3<UInt8>(x: 255, y: 0, z: 0), SIMD3<UInt8>(x: 255, y: 255, z: 0)]
        }
    }

    public var colorValues: [UInt8] {
        switch self {
        case .bw: return [0, 1]
        case .bwr: return [0, 1, 3]
        case .bwy: return [0, 1, 2]
        case .bwry: return [0, 1, 3, 2]
        }
    }

    public var description: String {
        switch self {
        case .bw: return "黑白"
        case .bwr: return "黑白红"
        case .bwy: return "黑白黄"
        case .bwry: return "黑白红黄"
        }
    }
}

/// 不可变的量化、背景合成及设备编码配置。
///
/// 构造时保存输入；处理入口通过 ``validate(for:)`` 校验配置。
/// 调色板颜色与原始图像均按 sRGB 分量处理，扫描方向和翻转仅用于设备位打包。
public struct DitherConfiguration: Sendable, Codable {
    /// RGB 调色板；误差扩散算法允许自定义颜色，阈值模式要求与颜色编号对应的模板顺序一致。
    public let palette: [SIMD3<UInt8>]
    /// 与调色板索引一一对应的设备色值；单平面取 0...1，其余模式取 0...3，且不可重复。
    public let colorValues: [UInt8]
    public let combine: CombineMode
    public let scan: ScanMode
    public let colorCode: ColorCode
    /// 水平扫描时，`false` 表示镜像、`true` 表示保持 x 顺序；垂直扫描时，`true` 才表示镜像。
    public let flipHorizontal: Bool
    /// 为 `true` 时反转 y 坐标；仅影响设备位打包。
    public let flipVertical: Bool
    /// 量化前与预乘像素合成的不透明 RGB 背景，默认为白色。
    public let backgroundColor: SIMD3<UInt8>

    /// 保存自定义配置；调色板、设备色值及算法适配性由处理入口统一校验。
    public init(palette: [SIMD3<UInt8>], colorValues: [UInt8], combine: CombineMode,
                scan: ScanMode, colorCode: ColorCode = .bw,
                flipHorizontal: Bool = false, flipVertical: Bool = false,
                backgroundColor: SIMD3<UInt8> = SIMD3(255, 255, 255)) {
        self.palette = palette
        self.colorValues = colorValues
        self.combine = combine
        self.scan = scan
        self.colorCode = colorCode
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.backgroundColor = backgroundColor
    }

    /// 从设备模板创建匹配的调色板、设备色值及打包配置，透明区域默认合成到白底。
    public static func forDevice(template: ColorTemplate, scan: ScanMode,
                                 flipHorizontal: Bool = false,
                                 flipVertical: Bool = false,
                                 backgroundColor: SIMD3<UInt8> = SIMD3(255, 255, 255)) -> DitherConfiguration {
        DitherConfiguration(palette: template.palette,
                            colorValues: template.colorValues,
                            combine: template.combine,
                            scan: scan,
                            colorCode: template.colorCode,
                            flipHorizontal: flipHorizontal,
                            flipVertical: flipVertical, backgroundColor: backgroundColor)
    }

    private enum CodingKeys: String, CodingKey {
        case palette, colorValues, combine, scan, colorCode, flipHorizontal, flipVertical, backgroundColor
    }

    /// 解码配置；未提供 `backgroundColor` 字段时使用白色背景。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        palette = try values.decode([SIMD3<UInt8>].self, forKey: .palette)
        colorValues = try values.decode([UInt8].self, forKey: .colorValues)
        combine = try values.decode(CombineMode.self, forKey: .combine)
        scan = try values.decode(ScanMode.self, forKey: .scan)
        colorCode = try values.decode(ColorCode.self, forKey: .colorCode)
        flipHorizontal = try values.decode(Bool.self, forKey: .flipHorizontal)
        flipVertical = try values.decode(Bool.self, forKey: .flipVertical)
        backgroundColor = try values.decodeIfPresent(SIMD3<UInt8>.self, forKey: .backgroundColor)
            ?? SIMD3(255, 255, 255)
    }

    /// 校验调色板、设备色值及指定算法的配置约束。
    ///
    /// 调色板不能为空且索引必须能由 `UInt8` 表示，设备色值须与调色板等长、互不重复并适合所选位宽。
    /// 阈值模式额外要求调色板与颜色编号对应的 ``ColorTemplate`` 完全一致。
    /// - Throws: 配置不满足约束时抛出 ``DitherError``。
    public func validate(for algorithm: DitherAlgorithm) throws {
        guard !palette.isEmpty else { throw DitherError.emptyPalette }
        guard palette.count <= 256 else {
            throw DitherError.incompatiblePalette("Palette indices must fit in UInt8")
        }
        guard colorValues.count == palette.count else { throw DitherError.colorValuesMismatch }
        let maximumValue: UInt8 = combine == .single ? 1 : 3
        guard colorValues.allSatisfy({ $0 <= maximumValue }),
              Set(colorValues).count == colorValues.count else {
            throw DitherError.invalidColorValues
        }
        if algorithm == .color {
            // 阈值分类直接使用黑、白、红、黄的语义索引，因此要求模板中的颜色及顺序一致。
            guard let template = ColorTemplate(rawValue: colorCode.rawValue), palette == template.palette else {
                throw DitherError.incompatiblePalette("Threshold mode requires the colorCode template palette order")
            }
        }
    }

    /// 黑白单平面、水平扫描、白色背景的配置；默认水平扫描包含 x 镜像。
    public static let blackWhite = DitherConfiguration.forDevice(template: .bw, scan: .horizontal)
}

// MARK: - 算法与权重

/// 颜色量化模式；原始值为算法编号，具体扩散核由 ``weights`` 定义。
public enum DitherAlgorithm: String, Sendable, CaseIterable, Codable, CustomStringConvertible {
    case atkinson = "1"
    case color = "2"
    case floydSteinberg = "3"
    case jjn = "4"
    case stucki = "5"
    case atkinsonPlus = "6"

    /// 误差扩散目标相对当前像素的坐标偏移及分配比例。
    public struct Weight: Sendable, Hashable {
        public let x: Int
        public let y: Int
        public let value: Float
        public init(x: Int, y: Int, value: Float) {
            self.x = x; self.y = y; self.value = value
        }
    }

    /// 扩散权重；x 向右为正、y 向下为正，数组顺序即误差累加顺序。
    ///
    /// Atkinson 分配总误差的 6/8；Floyd–Steinberg、JJN 和 Stucki 的权重和为 1。
    /// `.atkinsonPlus` 使用 Floyd–Steinberg 权重；`.color` 采用阈值分类，不扩散误差。
    public var weights: [Weight] {
        switch self {
        case .atkinson:
            return [Weight(x: 1, y: 0, value: 1/8), Weight(x: 2, y: 0, value: 1/8),
                    Weight(x: -1, y: 1, value: 1/8), Weight(x: 0, y: 1, value: 1/8),
                    Weight(x: 1, y: 1, value: 1/8), Weight(x: 0, y: 2, value: 1/8)]
        case .jjn:
            return [Weight(x: 1, y: 0, value: 7/48), Weight(x: 2, y: 0, value: 5/48),
                    Weight(x: -2, y: 1, value: 3/48), Weight(x: -1, y: 1, value: 5/48),
                    Weight(x: 0, y: 1, value: 7/48), Weight(x: 1, y: 1, value: 5/48),
                    Weight(x: 2, y: 1, value: 3/48), Weight(x: -2, y: 2, value: 1/48),
                    Weight(x: -1, y: 2, value: 3/48), Weight(x: 0, y: 2, value: 5/48),
                    Weight(x: 1, y: 2, value: 3/48), Weight(x: 2, y: 2, value: 1/48)]
        case .stucki:
            return [Weight(x: 1, y: 0, value: 8/42), Weight(x: 2, y: 0, value: 4/42),
                    Weight(x: -2, y: 1, value: 2/42), Weight(x: -1, y: 1, value: 4/42),
                    Weight(x: 0, y: 1, value: 8/42), Weight(x: 1, y: 1, value: 4/42),
                    Weight(x: 2, y: 1, value: 2/42), Weight(x: -2, y: 2, value: 1/42),
                    Weight(x: -1, y: 2, value: 2/42), Weight(x: 0, y: 2, value: 4/42),
                    Weight(x: 1, y: 2, value: 2/42), Weight(x: 2, y: 2, value: 1/42)]
        case .floydSteinberg, .atkinsonPlus:
            return [Weight(x: 1, y: 0, value: 7/16), Weight(x: -1, y: 1, value: 3/16),
                    Weight(x: 0, y: 1, value: 5/16), Weight(x: 1, y: 1, value: 1/16)]
        case .color:
            return []
        }
    }

    public var isErrorDiffusion: Bool { self != .color }

    public var description: String {
        switch self {
        case .atkinson: return "Atkinson"
        case .color: return "Color (色阶)"
        case .floydSteinberg: return "Floyd-Steinberg"
        case .jjn: return "JJN (Jarvis-Judice-Ninke)"
        case .stucki: return "Stucki"
        case .atkinsonPlus: return "Atkinson Plus"
        }
    }
}



/// 单次处理的不可变成品帧，包含逻辑像素索引、设备字节流及可选的独立预览。
public struct DitheredFrame: Sendable {
    /// 按 `y * width + x` 的行优先顺序排列的调色板索引，不应用设备扫描与翻转。
    public let indices: [UInt8]
    /// 按配置扫描、翻转并打包的设备字节；不包含压缩数据、尺寸或配置头。
    public let packed: Data
    public let width: Int
    public let height: Int
    /// 本次调用对应的不透明 BGRA 预览，独立于共享描述符最近发布的结果。
    public let preview: ImageBuffer?
    /// 生成设备字节时使用的配置；手动构造帧时可省略。
    public let configuration: DitherConfiguration?

    /// 保存调用者提供的帧数据；不校验索引、设备字节及尺寸是否一致。
    ///
    /// ``Dithering`` 生成的帧包含预览和配置；手动构造时两者均可为 `nil`。
    public init(indices: [UInt8], packed: Data, width: Int, height: Int,
                preview: ImageBuffer? = nil, configuration: DitherConfiguration? = nil) {
        self.indices = indices
        self.packed = packed
        self.width = width
        self.height = height
        self.preview = preview
        self.configuration = configuration
    }

    /// 从本帧的独立预览生成图像；未提供预览或创建失败时返回 `nil`。
    public func makeCGImage() -> CGImage? { preview?.makeCGImage() }
}

/// 行处理进度；全部行完成表示量化结束，设备位打包可能仍在执行。
public struct DitherProgress: Sendable {
    public let completedRows: Int
    public let totalRows: Int
    public var fraction: Double { totalRows == 0 ? 1 : Double(completedRows) / Double(totalRows) }

    public init(completedRows: Int, totalRows: Int) {
        self.completedRows = completedRows
        self.totalRows = totalRows
    }
}

/// 流式处理事件；进度允许合并，成品帧在量化和位打包均完成后发送。
public enum DitherEvent: Sendable {
    case progress(DitherProgress)
    case finished(DitheredFrame)
}

/// 图像布局或量化配置不满足处理契约时产生的错误。
public enum DitherError: Error, Sendable {
    /// 缓冲不足，或无法创建图像、绘图上下文或有效的像素数据。
    case invalidImageData
    /// 调色板为空。
    case emptyPalette
    /// 设备色值数量与调色板数量不一致。
    case colorValuesMismatch
    /// 尺寸或行步长无效，或尺寸计算溢出。
    case invalidDimensions
    /// 原始字节布局声明的每像素字节数不是 4。
    case unsupportedPixelFormat
    /// 设备色值重复或超过所选位宽能够表示的范围。
    case invalidColorValues
    /// 调色板索引范围或颜色顺序不适合指定算法。
    case incompatiblePalette(String)
}

// MARK: - 引擎

/// 从图像生成调色板索引、量化预览及设备位打包数据的高层入口。
public enum Dithering {
    /// 从描述符的不可变原图生成成品帧，完成量化和位打包后一次性发布完整预览。
    ///
    /// 每次调用使用独立工作缓冲；检测到取消或错误时不发布部分处理结果。
    /// 多个调用共享描述符时，描述符保留最近发布的预览，各调用的确切结果由返回帧持有。
    /// 进度回调只报告量化行数，达到 100% 时设备位打包可能尚未完成。
    ///
    /// - Parameters:
    ///   - descriptor: 持有不可变原图并接收完整预览的描述符。
    ///   - configuration: 调色板、背景合成及设备编码配置。
    ///   - algorithm: 本次处理采用的量化与误差扩散算法。
    ///   - cache: 可选的最近色缓存；可在调用间复用，不用于阈值模式。
    ///   - progress: 每行量化完成后同步调用；不保证在主 actor 执行，UI 更新需由调用者调度。
    /// - Throws: 图像或配置校验错误，或协作式取消产生的 `CancellationError`。
    public static func dither(
        descriptor: CImageDescriptor,
        configuration: DitherConfiguration,
        algorithm: DitherAlgorithm,
        cache: ClosestColor<UInt8, UInt8>? = nil,
        progress: (@Sendable (DitherProgress) -> Void)? = nil
    ) async throws -> DitheredFrame {
        let result = try await ImageProcessor.render(
            image: descriptor.originalImage, configuration: configuration,
            algorithm: algorithm, cache: cache, progress: progress)
        let packed = try BytePacker.pack(indices: result.indices, width: descriptor.width,
                                         height: descriptor.height, configuration: configuration)
        try Task.checkCancellation()
        descriptor.publish(pixels: result.preview.pixels)
        return DitheredFrame(indices: result.indices, packed: packed,
                             width: descriptor.width, height: descriptor.height,
                             preview: result.preview, configuration: configuration)
    }

    /// 校验不可变图像缓冲，并通过同一量化及位打包流程生成成品帧。
    ///
    /// 输入必须是 8 位预乘 BGRA；透明区域按配置背景色合成，返回预览为不透明图像。
    /// 取消、进度及缓存语义与描述符入口一致。
    public static func dither(
        image: ImageBuffer,
        configuration: DitherConfiguration,
        algorithm: DitherAlgorithm,
        cache: ClosestColor<UInt8, UInt8>? = nil,
        progress: (@Sendable (DitherProgress) -> Void)? = nil
    ) async throws -> DitheredFrame {
        let descriptor = try CImageDescriptor(width: image.width, height: image.height,
                                          bytesPerRow: image.bytesPerRow,
                                          bytesPerPixel: image.bytesPerPixel,
                                          pixels: image.pixels)
        return try await dither(descriptor: descriptor, configuration: configuration,
                                algorithm: algorithm, cache: cache, progress: progress)
    }

    /// 创建异步事件流，发送行处理进度，并在量化和位打包成功完成后发送成品帧。
    ///
    /// 流最多缓存两个最新事件；消费缓慢时可跳过中间进度，成功时最后一个事件为成品帧。
    /// 流终止时请求取消底层任务，任务在处理和打包的取消检查点响应。
    /// 停止消费时应取消消费任务或释放流，使流能够终止；单纯退出循环不保证立即取消底层任务。
    /// 成品帧拥有独立预览，描述符仅在完整处理结束后发布预览。
    public static func ditherStream(
        descriptor: CImageDescriptor,
        configuration: DitherConfiguration,
        algorithm: DitherAlgorithm,
        cache: ClosestColor<UInt8, UInt8>? = nil
    ) -> AsyncThrowingStream<DitherEvent, Error> {
        AsyncThrowingStream<DitherEvent, Error>(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let task = Task {
                do {
                    let frame = try await dither(
                        descriptor: descriptor,
                        configuration: configuration,
                        algorithm: algorithm,
                        cache: cache
                    ) { progress in
                        guard !Task.isCancelled else { return }
                        continuation.yield(.progress(progress))
                    }
                    guard !Task.isCancelled else {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    continuation.yield(.finished(frame))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// 使用不可变图像缓冲创建异步事件流；校验错误通过流的错误终止传递。
    ///
    /// 进度合并、成品帧及取消语义与描述符版本一致；透明区域按配置背景色合成。
    public static func ditherStream(
        image: ImageBuffer,
        configuration: DitherConfiguration,
        algorithm: DitherAlgorithm,
        cache: ClosestColor<UInt8, UInt8>? = nil
    ) -> AsyncThrowingStream<DitherEvent, Error> {
        do {
            let descriptor = try CImageDescriptor(width: image.width, height: image.height,
                                                  bytesPerRow: image.bytesPerRow,
                                                  bytesPerPixel: image.bytesPerPixel,
                                                  pixels: image.pixels)
            return ditherStream(descriptor: descriptor, configuration: configuration,
                                algorithm: algorithm, cache: cache)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}

// MARK: - 位打包

/// 按扫描与翻转配置，将逻辑索引转换为设备色值并打包。
///
/// 水平扫描逐行、垂直扫描逐列；各行或列分别从字节最高位开始，不足字节的低位补零。
/// 单平面使用设备色值的最低位；双平面分别使用 A = `(value >> 1) & 1`、B = `value & 1`，
/// 所有 A 平面字节在前、所有 B 平面字节在后；四色模式将 A、B 作为连续两位，每字节容纳 4 像素。
/// 水平扫描在 `flipHorizontal == false` 时镜像 x，垂直扫描在该值为 `true` 时镜像 x；
/// `flipVertical == true` 时两种扫描均反转 y。扫描和翻转不改变成品帧的逻辑索引或预览。
private enum BytePacker {
    static func pack(indices: [UInt8], width: Int, height: Int,
                     configuration: DitherConfiguration) throws -> Data {
        guard width > 0, height > 0, indices.count == width * height else { throw DitherError.invalidImageData }

        let values = configuration.colorValues
        func deviceValue(_ paletteIndex: Int) -> UInt8 {
            paletteIndex >= 0 && paletteIndex < values.count ? values[paletteIndex] : 0
        }

        let groupCount: Int
        let pixelsPerGroup: Int
        switch configuration.scan {
        case .horizontal: groupCount = height; pixelsPerGroup = width
        case .vertical:   groupCount = width;  pixelsPerGroup = height
        }

        /// 将扫描序列下标 i 映射回 indices 的原始坐标 (y*width+x)。
        func sourceIndex(_ i: Int) -> Int {
            let orgA = i / pixelsPerGroup
            let orgB = i % pixelsPerGroup
            let orgX: Int, orgY: Int
            switch configuration.scan {
            case .horizontal: orgX = orgB; orgY = orgA
            case .vertical:   orgX = orgA; orgY = orgB
            }
            let x: Int
            switch configuration.scan {
            case .horizontal:
                x = configuration.flipHorizontal ? orgX : width - 1 - orgX
            case .vertical:
                x = configuration.flipHorizontal ? width - 1 - orgX : orgX
            }
            let y = configuration.flipVertical ? height - 1 - orgY : orgY
            return y * width + x
        }

        switch configuration.combine {
        case .single:
            var out = Data()
            out.reserveCapacity(groupCount * ((pixelsPerGroup + 7) / 8))
            for g in 0..<groupCount {
                try Task.checkCancellation()
                var byte: UInt8 = 0
                for k in 0..<pixelsPerGroup {
                    if k.isMultiple(of: 256) { try Task.checkCancellation() }
                    let value = deviceValue(Int(indices[sourceIndex(g * pixelsPerGroup + k)])) & 1
                    byte |= value << (7 - (k % 8))
                    if k % 8 == 7 { out.append(byte); byte = 0 }
                }
                if pixelsPerGroup % 8 != 0 { out.append(byte) }
            }
            return out

        case .complex:
            var planeA = Data()
            var planeB = Data()
            let capacity = groupCount * ((pixelsPerGroup + 7) / 8)
            planeA.reserveCapacity(capacity)
            planeB.reserveCapacity(capacity)
            for g in 0..<groupCount {
                try Task.checkCancellation()
                var byteA: UInt8 = 0
                var byteB: UInt8 = 0
                for k in 0..<pixelsPerGroup {
                    if k.isMultiple(of: 256) { try Task.checkCancellation() }
                    let value = deviceValue(Int(indices[sourceIndex(g * pixelsPerGroup + k)]))
                    let a = (value & 0x02) >> 1
                    let b = value & 0x01
                    byteA |= a << (7 - (k % 8))
                    byteB |= b << (7 - (k % 8))
                    if k % 8 == 7 {
                        planeA.append(byteA); planeB.append(byteB)
                        byteA = 0; byteB = 0
                    }
                }
                if pixelsPerGroup % 8 != 0 {
                    planeA.append(byteA); planeB.append(byteB)
                }
            }
            var out = Data()
            out.reserveCapacity(planeA.count + planeB.count)
            out.append(planeA)
            out.append(planeB)
            return out

        case .color4:
            var out = Data()
            out.reserveCapacity(groupCount * ((pixelsPerGroup + 3) / 4))
            for g in 0..<groupCount {
                try Task.checkCancellation()
                var byte: UInt8 = 0
                for k in 0..<pixelsPerGroup {
                    if k.isMultiple(of: 256) { try Task.checkCancellation() }
                    let value = deviceValue(Int(indices[sourceIndex(g * pixelsPerGroup + k)]))
                    let a = (value & 0x02) >> 1
                    let b = value & 0x01
                    let shift = 7 - 2 * (k % 4)
                    byte |= (a << shift) | (b << (shift - 1))
                    if k % 4 == 3 { out.append(byte); byte = 0 }
                }
                if pixelsPerGroup % 4 != 0 { out.append(byte) }
            }
            return out
        }
    }
}
