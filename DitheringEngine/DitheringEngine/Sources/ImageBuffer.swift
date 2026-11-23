import CoreGraphics
import Foundation

/// 不可变的 8 位预乘 BGRA 图像缓冲，支持行尾填充字节。
///
/// 每个像素按蓝、绿、红、透明度顺序存储，各颜色分量已经乘以透明度；
/// 不透明像素的透明度为 255。原始字节按 sRGB 解释，不自动识别通道顺序或颜色空间。
/// 原始字节构造器仅保存输入，使用前可调用 ``validate()`` 检查布局；抖动入口也会执行布局校验。
public struct ImageBuffer: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bytesPerPixel: Int
    public let pixels: [UInt8]

    /// 保存原始字节及布局，不执行格式转换或布局校验。
    ///
    /// 有效布局要求宽高均大于零、每像素 4 字节、行字节数至少为 `width * 4`，
    /// 且缓冲至少包含 `bytesPerRow * height` 个字节。调用者负责提供预乘 BGRA 分量。
    public init(width: Int, height: Int, bytesPerRow: Int,
                bytesPerPixel: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bytesPerPixel = bytesPerPixel
        self.pixels = pixels
    }

    /// 将 Core Graphics 支持的图像转换为 sRGB、8 位预乘 BGRA，保留透明度。
    ///
    /// 量化时再按 ``DitherConfiguration/backgroundColor`` 合成不透明背景。
    public init(cgImage: CGImage) throws {
        let descriptor = try CImageDescriptor(imageRef: cgImage)
        self = descriptor.originalImage
    }

    /// 校验尺寸、每像素字节数、行步长和缓冲长度，并检查尺寸计算是否溢出。
    ///
    /// 此方法不检查颜色分量是否满足预乘关系，也不检查行尾填充字节的内容。
    /// - Throws: 布局无效时抛出 ``DitherError``。
    public func validate() throws {
        _ = try ImageLayout(width: width, height: height, bytesPerRow: bytesPerRow,
                            bytesPerPixel: bytesPerPixel, availableBytes: pixels.count)
    }

    /// 按 RGB 顺序读取预乘颜色分量，不执行背景合成或去预乘。
    ///
    /// 坐标以像素为单位；无效坐标或布局返回 `(0, 0, 0)`。
    public func colorAt(x: Int, y: Int) -> SIMD3<UInt8> {
        guard x >= 0, y >= 0, x < width, y < height,
              (try? validate()) != nil else { return .zero }
        let base = y * bytesPerRow + x * bytesPerPixel
        return SIMD3(pixels[base + 2], pixels[base + 1], pixels[base])
    }

    /// 按当前预乘 BGRA 字节生成保留透明度的 sRGB 图像；布局无效或创建失败时返回 `nil`。
    public func makeCGImage() -> CGImage? {
        guard (try? validate()) != nil,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: ImageLayout.colorSpace,
                       bitmapInfo: ImageLayout.bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// 原始像素入口共享的布局校验与溢出检查。
struct ImageLayout {
    let pixelCount: Int
    let componentCount: Int
    let byteCount: Int

    static var colorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
    static var bitmapInfo: CGBitmapInfo {
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
    }

    init(width: Int, height: Int, bytesPerRow: Int, bytesPerPixel: Int,
         availableBytes: Int) throws {
        guard width > 0, height > 0 else { throw DitherError.invalidDimensions }
        guard bytesPerPixel == 4 else { throw DitherError.unsupportedPixelFormat }
        let (minimumRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, bytesOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        let (pixelCount, pixelsOverflow) = width.multipliedReportingOverflow(by: height)
        let (componentCount, componentsOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !rowOverflow, !bytesOverflow, !pixelsOverflow, !componentsOverflow,
              bytesPerRow >= minimumRow else { throw DitherError.invalidDimensions }
        guard availableBytes >= byteCount else { throw DitherError.invalidImageData }
        self.pixelCount = pixelCount
        self.componentCount = componentCount
        self.byteCount = byteCount
    }
}
