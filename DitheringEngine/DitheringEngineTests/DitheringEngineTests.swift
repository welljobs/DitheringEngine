//
//  DitheringEngineTests.swift
//  DitheringEngineTests
//
//  覆盖：颜色模板、最近色缓存、阈值、权重表、三种位打包、扫描/翻转、
//        异步接口与 AsyncThrowingStream、压缩互逆。
//

import Testing
import Foundation
import CoreGraphics
import simd
import DitheringEngine

struct DitheringEngineTests {
    private func makeImage(width: Int, height: Int,
                           colors: [SIMD3<UInt8>]) -> ImageBuffer {
        let bpp = 4
        let row = width * bpp
        var pixels = [UInt8](repeating: 0, count: row * height)
        for i in 0..<(width * height) {
            let c = colors[i]
            let base = (i / width) * row + (i % width) * bpp
            pixels[base + 0] = c.z
            pixels[base + 1] = c.y
            pixels[base + 2] = c.x
            pixels[base + 3] = 255
        }
        return ImageBuffer(width: width, height: height,
                           bytesPerRow: row, bytesPerPixel: bpp, pixels: pixels)
    }

    // MARK: - 颜色模板与数据格式

    @Test func colorTemplateValues() {
        #expect(ColorTemplate.bw.colorValues == [0, 1])
        #expect(ColorTemplate.bwr.colorValues == [0, 1, 3])
        #expect(ColorTemplate.bwy.colorValues == [0, 1, 2])
        #expect(ColorTemplate.bwry.colorValues == [0, 1, 3, 2])
        #expect(ColorTemplate.bw.combine == .single)
        #expect(ColorTemplate.bwr.combine == .complex)
        #expect(ColorTemplate.bwry.combine == .color4)
        #expect(ColorTemplate.bwr.palette[2] == SIMD3<UInt8>(x: 255, y: 0, z: 0))
    }

    @Test func algorithmDescriptions() {
        #expect(DitherAlgorithm.atkinson.description == "Atkinson")
        #expect(DitherAlgorithm.floydSteinberg.description == "Floyd-Steinberg")
        #expect(DitherAlgorithm.color.description == "Color (色阶)")
        #expect(String(describing: DitherAlgorithm.jjn) == "JJN (Jarvis-Judice-Ninke)")
        #expect(DitherAlgorithm.allCases.count == 6)
    }

    @Test func templateAndScanDescriptions() {
        #expect(String(describing: ColorTemplate.bwr) == "黑白红")
        #expect(ColorTemplate.bwry.description == "黑白红黄")
        #expect(String(describing: ScanMode.horizontal) == "水平扫描")
        #expect(ScanMode.vertical.description == "垂直扫描")
        #expect(String(describing: CombineMode.single) == "单色 (1bpp)")
        #expect(CombineMode.complex.description == "双平面 (1bpp×2)")
        #expect(CombineMode.color4.description == "四色 (2bpp)")
    }

    @Test func algorithmWeights() {
        #expect(DitherAlgorithm.atkinson.weights.count == 6)
        #expect(DitherAlgorithm.floydSteinberg.weights.count == 4)
        #expect(DitherAlgorithm.jjn.weights.count == 12)
        #expect(DitherAlgorithm.stucki.weights.count == 12)
        #expect(DitherAlgorithm.atkinsonPlus.weights == DitherAlgorithm.floydSteinberg.weights)
        #expect(DitherAlgorithm.color.weights.isEmpty)
    }

    @Test func weightMatricesMatchSpecification() {
        func f(_ n: Int, _ d: Int) -> Float { Float(n) / Float(d) }
        func check(_ algorithm: DitherAlgorithm,
                   _ expected: [(x: Int, y: Int, value: Float)]) {
            let actual = algorithm.weights
            #expect(actual.count == expected.count)
            #expect(zip(actual, expected).allSatisfy {
                $0.0.x == $0.1.x && $0.0.y == $0.1.y && $0.0.value == $0.1.value
            })
        }
        check(.atkinson, [
            (1,0,f(1,8)), (2,0,f(1,8)), (-1,1,f(1,8)), (0,1,f(1,8)), (1,1,f(1,8)), (0,2,f(1,8))
        ])
        check(.floydSteinberg, [
            (1,0,f(7,16)), (-1,1,f(3,16)), (0,1,f(5,16)), (1,1,f(1,16))
        ])
        check(.jjn, [
            (1,0,f(7,48)), (2,0,f(5,48)),
            (-2,1,f(3,48)), (-1,1,f(5,48)), (0,1,f(7,48)), (1,1,f(5,48)), (2,1,f(3,48)),
            (-2,2,f(1,48)), (-1,2,f(3,48)), (0,2,f(5,48)), (1,2,f(3,48)), (2,2,f(1,48))
        ])
        check(.stucki, [
            (1,0,f(8,42)), (2,0,f(4,42)),
            (-2,1,f(2,42)), (-1,1,f(4,42)), (0,1,f(8,42)), (1,1,f(4,42)), (2,1,f(2,42)),
            (-2,2,f(1,42)), (-1,2,f(2,42)), (0,2,f(4,42)), (1,2,f(2,42)), (2,2,f(1,42))
        ])
    }

    @Test func weightSumsMatchTheory() {
        func sum(_ a: DitherAlgorithm) -> Float { a.weights.reduce(0) { $0 + $1.value } }
        func close(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 1e-6 }
        #expect(close(sum(.atkinson), Float(6)/8))
        #expect(close(sum(.floydSteinberg), 1))
        #expect(close(sum(.jjn), 1))
        #expect(close(sum(.stucki), 1))
    }

    // MARK: - 最近色与缓存

    @Test func paletteUsesRedmeanNearest() {
        let palette = ColorPalette<UInt8>.from(
            collection: ColorCollection(entries: [
                SIMD3<UInt8>(0, 0, 0), SIMD3<UInt8>(255, 255, 255), SIMD3<UInt8>(255, 0, 0)
            ]))
        #expect(palette.pickIndex(basedOn: SIMD3<Float>(250, 5, 5)) == 2)
        #expect(palette.pickIndex(basedOn: SIMD3<Float>(10, 10, 10)) == 0)
        #expect(palette.pickIndex(basedOn: SIMD3<Float>(240, 240, 240)) == 1)
    }

    @Test func closestColorCacheRoundTrip() {
        let cache = ClosestColor<UInt8, UInt8>()
        let color = SIMD3<UInt8>(12, 34, 56)
        let matched = SIMD3<UInt8>(0, 0, 0)
        cache.register(paletteColor: matched, asAMatchTo: color)
        #expect(cache.getPaletteColor(for: color) == matched)
        #expect(cache.getPaletteColor(for: SIMD3<UInt8>(1, 2, 3)) == nil)
        let floatView = cache.toFloatingWithoutCopy()
        #expect(floatView.getPaletteColor(for: SIMD3<Float>(12, 34, 56)) == matched)
    }

    // MARK: - 阈值模式（color）

    @Test func colorThresholdSingleMSB() async throws {
        let colors: [SIMD3<UInt8>] = [
            SIMD3(0,0,0), SIMD3(0,0,0),
            SIMD3(255,255,255), SIMD3(255,255,255),
            SIMD3(255,255,255), SIMD3(255,255,255),
            SIMD3(0,0,0), SIMD3(255,255,255)
        ]
        let cfg = DitherConfiguration.forDevice(template: .bw, scan: .horizontal,
                                                flipHorizontal: true)
        let frame = try await Dithering.dither(
            image: makeImage(width: 8, height: 1, colors: colors),
            configuration: cfg, algorithm: .color)
        #expect(frame.packed == Data([0x3D]))
    }

    @Test func colorThresholdTailPadding() async throws {
        let colors: [SIMD3<UInt8>] = [SIMD3(0,0,0), SIMD3(0,0,0), SIMD3(255,255,255)]
        let cfg = DitherConfiguration.forDevice(template: .bw, scan: .horizontal,
                                                flipHorizontal: true)
        let frame = try await Dithering.dither(
            image: makeImage(width: 3, height: 1, colors: colors),
            configuration: cfg, algorithm: .color)
        #expect(frame.packed == Data([0x20]))
    }

    @Test func colorThresholdComplexPlanes() async throws {
        let colors: [SIMD3<UInt8>] = [
            SIMD3(0,0,0), SIMD3(255,255,255),
            SIMD3(255,0,0), SIMD3(255,0,0),
            SIMD3(255,255,255), SIMD3(255,255,255),
            SIMD3(255,255,255), SIMD3(0,0,0)
        ]
        let cfg = DitherConfiguration.forDevice(template: .bwr, scan: .horizontal,
                                                flipHorizontal: true)
        let frame = try await Dithering.dither(
            image: makeImage(width: 8, height: 1, colors: colors),
            configuration: cfg, algorithm: .color)
        #expect(frame.packed == Data([0x30, 0x7E]))
    }

    @Test func colorThresholdColor4() async throws {
        let colors: [SIMD3<UInt8>] = [
            SIMD3(0,0,0), SIMD3(255,255,255), SIMD3(255,0,0), SIMD3(255,255,0),
            SIMD3(0,0,0), SIMD3(255,255,255), SIMD3(255,0,0), SIMD3(255,255,0)
        ]
        let cfg = DitherConfiguration.forDevice(template: .bwry, scan: .horizontal,
                                                flipHorizontal: true)
        let frame = try await Dithering.dither(
            image: makeImage(width: 8, height: 1, colors: colors),
            configuration: cfg, algorithm: .color)
        #expect(frame.packed == Data([0x1E, 0x1E]))
    }

    @Test func horizontalDefaultMirrorsWithoutFlipFlag() async throws {
        // 水平扫描在 flipHorizontal=false 时按 x = width-1-orgX 镜像
        let colors: [SIMD3<UInt8>] = [
            SIMD3(0,0,0), SIMD3(255,255,255),   // 物理 x0=黑, x1=白
        ]
        let cfg = DitherConfiguration.forDevice(template: .bw, scan: .horizontal)
        let frame = try await Dithering.dither(
            image: makeImage(width: 2, height: 1, colors: colors),
            configuration: cfg, algorithm: .color)
        // 镜像后的顺序为白、黑；白色编码占最高位，尾部补零，得到 0x80。
        #expect(frame.packed == Data([0x80]))
    }

    @Test func verticalScanPacksByColumn() async throws {
        let colors: [SIMD3<UInt8>] = [
            SIMD3(0,0,0), SIMD3(0,0,0), SIMD3(255,255,255), SIMD3(255,255,255),
            SIMD3(255,255,255), SIMD3(255,255,255), SIMD3(0,0,0), SIMD3(255,255,255)
        ]
        let cfg = DitherConfiguration.forDevice(template: .bw, scan: .vertical)
        let frame = try await Dithering.dither(
            image: makeImage(width: 1, height: 8, colors: colors),
            configuration: cfg, algorithm: .color)
        #expect(frame.packed == Data([0x3D]))
    }

    // MARK: - 误差扩散与异步接口

    @Test func allAlgorithmsProduceExpectedSize() async throws {
        let colors = (0..<16).map { _ in SIMD3<UInt8>(x: 128, y: 96, z: 64) }
        for algorithm in DitherAlgorithm.allCases {
            let cfg = DitherConfiguration.forDevice(template: .bwr, scan: .horizontal)
            let frame = try await Dithering.dither(
                image: makeImage(width: 8, height: 2, colors: colors),
                configuration: cfg, algorithm: algorithm)
            #expect(frame.indices.count == 16)
            // 双平面格式：每行 8 像素占 1 字节，2 行占 2 字节/平面，总计 4 字节。
            #expect(frame.packed.count == 4)
        }
    }

    @Test func streamEmitsProgressAndFinished() async throws {
        let colors = (0..<8).map { _ in SIMD3<UInt8>(x: 255, y: 255, z: 255) }
        let cfg = DitherConfiguration.forDevice(template: .bw, scan: .horizontal)
        var progressCount = 0
        var result: DitheredFrame?
        for try await event in Dithering.ditherStream(
            image: makeImage(width: 8, height: 1, colors: colors),
            configuration: cfg, algorithm: .atkinson) {
            switch event {
            case .progress: progressCount += 1
            case .finished(let frame): result = frame
            }
        }
        #expect(progressCount == 1)
        #expect(result?.indices.count == 8)
    }

    @Test func descriptorPathAndPreviewWork() async throws {
        // 验证描述符输入、图像量化及高层打包接口的协作。
        let colors: [SIMD3<UInt8>] = [
            SIMD3(0,0,0), SIMD3(255,255,255), SIMD3(255,255,255), SIMD3(0,0,0),
            SIMD3(255,255,255), SIMD3(0,0,0), SIMD3(0,0,0), SIMD3(255,255,255)
        ]
        let image = makeImage(width: 8, height: 1, colors: colors)
        let descriptor = try CImageDescriptor(width: image.width, height: image.height,
                                          bytesPerRow: image.bytesPerRow,
                                          bytesPerPixel: image.bytesPerPixel,
                                          pixels: image.pixels)
        let cfg = DitherConfiguration.forDevice(template: .bw, scan: .horizontal,
                                                flipHorizontal: true)
        let frame = try await Dithering.dither(descriptor: descriptor,
                                               configuration: cfg, algorithm: .atkinson)
        #expect(frame.indices.count == 8)
        #expect(frame.packed.count == 1)
        // 处理成功后，描述符预览包含完整量化结果。
        #expect(descriptor.makeCGImage() != nil)
        // 副本拥有独立预览，release 将预览恢复为原始像素。
        let copy = descriptor.makeCopy()
        copy.release()
        #expect(copy.effectedPixels == copy.originPixels)
    }

    @Test func closestColorCacheAcceleratesProcessor() async throws {
        let colors = (0..<8).map { _ in SIMD3<UInt8>(x: 200, y: 30, z: 30) }
        let image = makeImage(width: 8, height: 1, colors: colors)
        let cfg = DitherConfiguration.forDevice(template: .bwr, scan: .horizontal)
        let cache = ClosestColor<UInt8, UInt8>()
        let frame = try await Dithering.dither(image: image, configuration: cfg,
                                               algorithm: .floydSteinberg, cache: cache)
        #expect(frame.indices.count == 8)
        let withoutCache = try await Dithering.dither(image: image, configuration: cfg,
                                                      algorithm: .floydSteinberg)
        #expect(frame.indices == withoutCache.indices)
        #expect(frame.packed == withoutCache.packed)
    }

    @Test func invalidConfigurationThrows() async throws {
        let colors = [SIMD3<UInt8>(0, 0, 0)]
        let bad = DitherConfiguration(palette: [], colorValues: [],
                                      combine: .single, scan: .horizontal)
        await #expect(throws: DitherError.self) {
            _ = try await Dithering.dither(
                image: makeImage(width: 1, height: 1, colors: colors),
                configuration: bad, algorithm: .color)
        }
    }

    // MARK: - 压缩互逆

    @Test func compressionRoundTrip() throws {
        let samples: [Data] = [
            Data("AABCBBABC".utf8),
            Data([UInt8](repeating: 0x5A, count: 512)),
            Data((0..<256).map { UInt8($0 % 251) }),
            Data()
        ]
        for sample in samples {
            let compressed = sample.compress()
            let restored = try compressed.decompress()
            #expect(restored == sample)
        }
    }

    @Test func compressionFarDistanceDoesNotOverflow() throws {
        // 验证回溯距离接近 4095 时的窗口边界与编码范围。
        var bytes = [UInt8](repeating: 0, count: 5000)
        bytes[0] = 0xAB; bytes[1] = 0xCD; bytes[2] = 0xEF
        bytes[4094] = 0xAB; bytes[4095] = 0xCD; bytes[4096] = 0xEF
        let sample = Data(bytes)
        let restored = try sample.compress().decompress()
        #expect(restored == sample)
    }

    // MARK: - 输入边界与格式校验

    @Test func repeatedDitherOnSameDescriptorIsStable() async throws {
        var colors: [SIMD3<UInt8>] = []
        colors.reserveCapacity(16)
        for i in 0..<16 {
            let r = UInt8(i * 16)
            let g = UInt8(255 - i * 16)
            let b = UInt8(i * 8)
            colors.append(SIMD3<UInt8>(x: r, y: g, z: b))
        }
        let image = makeImage(width: 4, height: 4, colors: colors)
        let descriptor = try CImageDescriptor(width: image.width, height: image.height,
                                          bytesPerRow: image.bytesPerRow,
                                          bytesPerPixel: image.bytesPerPixel,
                                          pixels: image.pixels)
        let cfg = DitherConfiguration.forDevice(template: .bwr, scan: .horizontal)
        let first = try await Dithering.dither(descriptor: descriptor,
                                               configuration: cfg, algorithm: .atkinson)
        let second = try await Dithering.dither(descriptor: descriptor,
                                                configuration: cfg, algorithm: .atkinson)
        #expect(first.indices == second.indices)
        #expect(first.packed == second.packed)
    }

    @Test func tooSmallPaletteThrows() async throws {
        let image = makeImage(width: 2, height: 1, colors: [SIMD3(0,0,0), SIMD3(255,255,255)])
        let cfg = DitherConfiguration(palette: [SIMD3<UInt8>(0,0,0), SIMD3<UInt8>(255,255,255)],
                                      colorValues: [0, 1], combine: .color4,
                                      scan: .horizontal, colorCode: .bwry)
        await #expect(throws: DitherError.self) {
            _ = try await Dithering.dither(image: image, configuration: cfg, algorithm: .color)
        }
    }

    @Test func arbitraryPixelFormatsAreNormalized() throws {
        // 构造 RGBA 排列的 CGImage，验证归一化后颜色分量正确。
        let width = 2, height = 1
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGImage(width: width, height: height,
                               bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: cs,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else {
            Issue.record("无法构造测试图像")
            return
        }
        let descriptor = try CImageDescriptor(imageRef: cg)
        let red = descriptor.colorAt(x: 0, y: 0)
        let blue = descriptor.colorAt(x: 1, y: 0)
        #expect(red.x > 200 && red.y < 50 && red.z < 50)
        #expect(blue.z > 200 && blue.x < 50 && blue.y < 50)
    }
}
