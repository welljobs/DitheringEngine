import CoreGraphics
import Foundation
import Synchronization

/// 使用 8 位颜色分量的图像描述符，为抖动入口使用的具体类型。
public typealias CImageDescriptor = ImageDescriptor<UInt8>

/// 保存不可变原图、图像布局及可并发读取的预览快照。
///
/// 原图和预览均使用 sRGB、8 位预乘 BGRA。泛型颜色参数不改变底层字节格式。
/// 抖动始终从 ``originPixels`` 开始，并使用每次调用独立的工作缓冲；
/// 处理完成后在锁内一次性发布完整预览，处理期间不会逐像素改写此描述符。
///
/// 不可变元数据及持有预览状态的 `Mutex` 共同满足编译器检查的 `Sendable` 约束。
/// 并发调用共享描述符时，预览反映最近一次发布的结果；每次调用对应的预览应从 ``DitheredFrame`` 读取。
public final class ImageDescriptor<Color: ImageColor>: Sendable {
    public let width: Int
    public let height: Int
    public let bitsPerComponent: Int
    public let bitsPerPixel: Int
    public let bytesPerPixel: Int
    public let bytesPerRow: Int
    /// 颜色分量总数，即 `width * height * 4`，包含透明度分量，不包含行尾填充。
    public let count: Int
    /// 像素总数，即 `width * height`。
    public let size: Int
    public let colorSpace: CGColorSpace?
    public let bitmapInfo: CGBitmapInfo
    public let shouldInterpolate: Bool
    public let intent: CGColorRenderingIntent
    /// 构造时保存的原始字节，包含行尾填充；预览修改和抖动处理均不改变此数组。
    public let originPixels: [UInt8]

    private let previewPixels: Mutex<[UInt8]>

    /// 最近发布的预览字节快照；构造后初始值为原始图像字节。
    ///
    /// 返回值具有数组的值语义；读取后修改本地数组不会改变描述符。
    /// 可通过 ``setColor(x:y:_:)`` 修改预览像素，或通过 ``release()`` 恢复原始预览。
    public var effectedPixels: [UInt8] {
        previewPixels.withLock { $0 }
    }

    /// 校验并保存 sRGB、8 位预乘 BGRA 原始字节，允许行尾填充。
    ///
    /// 宽高必须大于零，`bytesPerPixel` 必须为 4，`bytesPerRow` 至少为 `width * 4`，
    /// `pixels` 至少包含 `bytesPerRow * height` 个字节；调用者负责保证颜色分量已经预乘透明度。
    /// - Throws: 不支持的像素格式、无效尺寸、尺寸计算溢出或缓冲不足时抛出 ``DitherError``。
    public init(width: Int, height: Int, bytesPerRow: Int,
                bytesPerPixel: Int, pixels: [UInt8]) throws {
        let layout = try ImageLayout(width: width, height: height, bytesPerRow: bytesPerRow,
                                     bytesPerPixel: bytesPerPixel, availableBytes: pixels.count)
        self.width = width
        self.height = height
        self.bitsPerComponent = 8
        self.bitsPerPixel = 32
        self.bytesPerPixel = 4
        self.bytesPerRow = bytesPerRow
        self.count = layout.componentCount
        self.size = layout.pixelCount
        self.colorSpace = ImageLayout.colorSpace
        self.bitmapInfo = ImageLayout.bitmapInfo
        self.shouldInterpolate = false
        self.intent = .defaultIntent
        self.originPixels = pixels
        self.previewPixels = Mutex(pixels)
    }

    /// 通过 Core Graphics 绘制，将支持的输入格式转换为 sRGB、8 位预乘 BGRA。
    ///
    /// 保留输入透明度，行字节数为 `width * 4`；背景合成由抖动配置决定。
    /// - Throws: 布局无效或无法创建绘图上下文时抛出 ``DitherError``。
    public convenience init(imageRef: CGImage) throws {
        let width = imageRef.width
        let height = imageRef.height
        let (row, overflow) = width.multipliedReportingOverflow(by: 4)
        guard !overflow else { throw DitherError.invalidDimensions }
        let layout = try ImageLayout(width: width, height: height, bytesPerRow: row,
                                     bytesPerPixel: 4, availableBytes: Int.max)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: row,
                                      space: ImageLayout.colorSpace,
                                      bitmapInfo: ImageLayout.bitmapInfo.rawValue),
              let data = context.data else { throw DitherError.invalidImageData }
        context.draw(imageRef, in: CGRect(x: 0, y: 0, width: width, height: height))
        try self.init(width: width, height: height, bytesPerRow: row, bytesPerPixel: 4,
                      pixels: [UInt8](Data(bytes: data, count: layout.byteCount)))
    }

    private init(copying source: ImageDescriptor, preview: [UInt8]) {
        width = source.width
        height = source.height
        bitsPerComponent = source.bitsPerComponent
        bitsPerPixel = source.bitsPerPixel
        bytesPerPixel = source.bytesPerPixel
        bytesPerRow = source.bytesPerRow
        count = source.count
        size = source.size
        colorSpace = source.colorSpace
        bitmapInfo = source.bitmapInfo
        shouldInterpolate = source.shouldInterpolate
        intent = source.intent
        originPixels = source.originPixels
        previewPixels = Mutex(preview)
    }

    /// 复制图像元数据、原图及调用时刻的预览快照；副本后续修改独立于原描述符。
    public func makeCopy() -> ImageDescriptor {
        ImageDescriptor(copying: self, preview: effectedPixels)
    }

    /// 将预览恢复为原始字节；不释放原图，不取消正在运行的抖动任务。
    ///
    /// 正在处理的任务仍可能在完成后发布其结果。
    public func release() {
        publish(pixels: originPixels)
    }

    /// 从预览快照按 RGB 顺序读取预乘颜色分量；无效坐标返回 `(0, 0, 0)`。
    ///
    /// 此方法不合成背景；尚未量化的透明图像可能返回小于非预乘颜色的分量值。
    public func colorAt(x: Int, y: Int) -> SIMD3<UInt8> {
        guard x >= 0, y >= 0, x < width, y < height else { return .zero }
        return previewPixels.withLock { pixels in
            let base = y * bytesPerRow + x * 4
            return SIMD3(pixels[base + 2], pixels[base + 1], pixels[base])
        }
    }

    /// 将 RGB 颜色写入预览，并将该像素透明度设为 255；无效坐标不执行写入。
    ///
    /// 此操作不改变原图；后续抖动仍从原图开始。
    public func setColor(x: Int, y: Int, _ color: SIMD3<UInt8>) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        previewPixels.withLock { pixels in
            let base = y * bytesPerRow + x * 4
            pixels[base] = color.z
            pixels[base + 1] = color.y
            pixels[base + 2] = color.x
            pixels[base + 3] = 255
        }
    }

    /// 将调用时刻的完整预览快照转换为图像；创建失败时返回 `nil`。
    ///
    /// 并发使用描述符时，此快照不一定对应某个特定调用的结果；可使用 ``DitheredFrame/makeCGImage()`` 获取对应帧的预览。
    public func makeCGImage() -> CGImage? {
        ImageBuffer(width: width, height: height, bytesPerRow: bytesPerRow,
                    bytesPerPixel: 4, pixels: effectedPixels).makeCGImage()
    }

    /// 供处理器使用的不可变原图视图，不读取可变预览状态。
    var originalImage: ImageBuffer {
        ImageBuffer(width: width, height: height, bytesPerRow: bytesPerRow,
                    bytesPerPixel: 4, pixels: originPixels)
    }

    /// 在锁内替换整个预览缓冲，使读取者只能获得发布前或发布后的完整快照。
    func publish(pixels: [UInt8]) {
        previewPixels.withLock { $0 = pixels }
    }
}
