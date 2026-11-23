import Foundation
import simd

/// 执行背景合成、颜色量化和误差扩散，提供不包含设备位打包的处理入口。
public enum ImageProcessor {
    /// 从描述符的不可变原图生成逐像素调色板索引，完成后发布完整预览。
    ///
    /// 返回索引按 `y * width + x` 的行优先顺序排列，不受输出扫描方向或翻转配置影响。
    /// 每次调用拥有独立的工作像素和误差缓冲；检测到取消或错误时，不发布该次调用的部分结果。
    ///
    /// - Parameters:
    ///   - descriptor: 持有不可变原图并接收完整预览的描述符。
    ///   - configuration: 调色板、背景合成及设备编码配置。
    ///   - algorithm: 本次处理采用的量化与误差扩散算法。
    ///   - cache: 可选的最近色缓存，仅用于误差扩散算法的颜色查询。
    ///   - progress: 每处理完一行同步调用一次；不保证在主 actor 执行，UI 更新需由调用者调度。
    /// - Throws: 输入或配置校验错误，或协作式取消产生的 `CancellationError`。
    public static func process(
        descriptor: CImageDescriptor,
        configuration: DitherConfiguration,
        algorithm: DitherAlgorithm,
        cache: ClosestColor<UInt8, UInt8>? = nil,
        progress: (@Sendable (DitherProgress) -> Void)? = nil
    ) async throws -> [UInt8] {
        let result = try await render(image: descriptor.originalImage, configuration: configuration,
                                      algorithm: algorithm, cache: cache, progress: progress)
        try Task.checkCancellation()
        descriptor.publish(pixels: result.preview.pixels)
        return result.indices
    }

    /// 单次处理的索引与独立预览；生成此结果不改变共享描述符。
    struct Result: Sendable {
        let indices: [UInt8]
        let preview: ImageBuffer
    }

    /// 使用调用私有的工作缓冲量化图像，不改变输入或共享描述符。
    static func render(
        image: ImageBuffer,
        configuration: DitherConfiguration,
        algorithm: DitherAlgorithm,
        cache: ClosestColor<UInt8, UInt8>?,
        progress: (@Sendable (DitherProgress) -> Void)?
    ) async throws -> Result {
        try image.validate()
        try configuration.validate(for: algorithm)
        try Task.checkCancellation()

        let width = image.width
        let height = image.height
        let palette = configuration.palette
        let colorPalette = ColorPalette<UInt8>.from(collection: ColorCollection(entries: palette))
        let weights = algorithm.weights
        // 误差核最远到达后续两行，使用三行循环缓冲保留浮点误差；阈值模式不分配误差缓冲。
        var errors = [SIMD3<Float>](repeating: .zero, count: weights.isEmpty ? 0 : width * 3)
        var pixels = image.pixels
        var indices = [UInt8]()
        indices.reserveCapacity(width * height)
        let background = SIMD3<Float>(Float(configuration.backgroundColor.x),
                                      Float(configuration.backgroundColor.y),
                                      Float(configuration.backgroundColor.z))

        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                if x.isMultiple(of: 256) { try Task.checkCancellation() }
                let base = y * image.bytesPerRow + x * 4
                // 输入颜色已预乘透明度，按“预乘颜色 + 背景色 × (1 - 透明度)”合成不透明颜色。
                let alphaRemainder = Float(255 - pixels[base + 3]) / 255
                let source = SIMD3<Float>(Float(pixels[base + 2]), Float(pixels[base + 1]),
                                           Float(pixels[base])) + background * alphaRemainder
                let errorIndex = (y % 3) * width + x
                let error = errors.isEmpty ? .zero : errors[errorIndex]
                if !errors.isEmpty { errors[errorIndex] = .zero }
                let adjusted = source + error
                let current = SIMD3<Float>(clamp(adjusted.x), clamp(adjusted.y), clamp(adjusted.z))
                let selected: Int
                if algorithm == .color {
                    selected = thresholdIndex(color: SIMD3<UInt8>(UInt8(current.x), UInt8(current.y),
                                                                  UInt8(current.z)),
                                              colorCode: configuration.colorCode)
                } else if let cache {
                    selected = cache.resolveIndex(for: current, palette: palette) {
                        colorPalette.pickIndex(basedOn: current)
                    }
                } else {
                    selected = colorPalette.pickIndex(basedOn: current)
                }
                indices.append(UInt8(selected))
                let chosen = palette[selected]
                pixels[base] = chosen.z
                pixels[base + 1] = chosen.y
                pixels[base + 2] = chosen.x
                pixels[base + 3] = 255
                let quantizationError = current - SIMD3<Float>(Float(chosen.x), Float(chosen.y),
                                                                Float(chosen.z))
                for weight in weights {
                    let nx = x + weight.x
                    let ny = y + weight.y
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    errors[(ny % 3) * width + nx] += quantizationError * weight.value
                }
            }
            progress?(DitherProgress(completedRows: y + 1, totalRows: height))
        }
        try Task.checkCancellation()
        return Result(indices: indices,
                      preview: ImageBuffer(width: width, height: height, bytesPerRow: image.bytesPerRow,
                                           bytesPerPixel: 4, pixels: pixels))
    }

    private static func clamp(_ value: Float) -> Float { min(max(value, 0), 255) }

    private static func thresholdIndex(color: SIMD3<UInt8>, colorCode: ColorCode) -> Int {
        switch colorCode {
        case .bw: break
        case .bwr:
            if color ><< Thresholds.red { return 2 }
        case .bwy:
            if color >>< Thresholds.yellow { return 2 }
        case .bwry:
            if color ><< Thresholds.red { return 2 }
            if color >>< Thresholds.yellow { return 3 }
        }
        return color >= Thresholds.white ? 1 : 0
    }
}
