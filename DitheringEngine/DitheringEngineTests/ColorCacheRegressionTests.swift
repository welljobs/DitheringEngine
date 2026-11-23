import Testing
import Foundation
import DitheringEngine

struct ColorCacheRegressionTests {
    private let black = SIMD3<UInt8>(0, 0, 0)
    private let white = SIMD3<UInt8>(255, 255, 255)
    private let red = SIMD3<UInt8>(255, 0, 0)

    private func makeImage(_ colors: [SIMD3<UInt8>]) -> ImageBuffer {
        let pixels: [UInt8] = colors.flatMap { [$0.z, $0.y, $0.x, UInt8(255)] }
        return ImageBuffer(width: colors.count, height: 1, bytesPerRow: colors.count * 4,
                           bytesPerPixel: 4, pixels: pixels)
    }

    @Test func emptyCachePreservesFractionalDiffusionBoundary() async throws {
        // 首像素向次像素扩散 127 × 7/16 的误差，次像素变为 127.5625。
        // 127 与 127.5625 位于阈值 127.5 两侧，缓存键须保留小数部分。
        let image = makeImage([SIMD3(127, 127, 127), SIMD3(72, 72, 72)])
        let config = DitherConfiguration.forDevice(template: .bw, scan: .horizontal,
                                                   flipHorizontal: true)
        let plain = try await Dithering.dither(image: image, configuration: config,
                                               algorithm: .floydSteinberg)
        let cached = try await Dithering.dither(image: image, configuration: config,
                                                algorithm: .floydSteinberg,
                                                cache: ClosestColor<UInt8, UInt8>())
        #expect(plain.indices == [0, 1])
        #expect(cached.indices == plain.indices)
        #expect(cached.packed == plain.packed)
    }

    @Test func cacheCanBeReusedAcrossDevicePalettes() async throws {
        let cache = ClosestColor<UInt8, UInt8>()
        let image = makeImage([red])
        let bw = DitherConfiguration.forDevice(template: .bw, scan: .horizontal)
        let bwr = DitherConfiguration.forDevice(template: .bwr, scan: .horizontal)
        _ = try await Dithering.dither(image: image, configuration: bw,
                                       algorithm: .floydSteinberg, cache: cache)
        let cached = try await Dithering.dither(image: image, configuration: bwr,
                                                algorithm: .floydSteinberg, cache: cache)
        let plain = try await Dithering.dither(image: image, configuration: bwr,
                                               algorithm: .floydSteinberg)
        #expect(plain.indices == [2])
        #expect(cached.indices == plain.indices)
        #expect(cached.packed == plain.packed)
    }

    @Test func paletteOrderIsPartOfTheCachedIndexIdentity() async throws {
        let cache = ClosestColor<UInt8, UInt8>()
        let image = makeImage([white])
        let forward = DitherConfiguration(palette: [black, white], colorValues: [0, 1],
                                          combine: .single, scan: .horizontal)
        let reversed = DitherConfiguration(palette: [white, black], colorValues: [1, 0],
                                           combine: .single, scan: .horizontal)
        let first = try await Dithering.dither(image: image, configuration: forward,
                                               algorithm: .atkinson, cache: cache)
        let second = try await Dithering.dither(image: image, configuration: reversed,
                                                algorithm: .atkinson, cache: cache)
        #expect(first.indices == [1])
        #expect(second.indices == [0])
        #expect(first.packed == second.packed)
    }

    @Test func manualMappingsDoNotOverrideNearestColorCalculation() async throws {
        let cache = ClosestColor<UInt8, UInt8>()
        cache.register(paletteColor: white, asAMatchTo: black)
        let palette = ColorPalette<UInt8>.from(collection: ColorCollection(entries: [black, white]))
        #expect(cache.getPaletteColor(for: black) == white)
        #expect(palette.pickColor(basedOn: black, cache: cache) == black)
        let frame = try await Dithering.dither(image: makeImage([black]),
                                               configuration: .blackWhite,
                                               algorithm: .floydSteinberg, cache: cache)
        #expect(frame.indices == [0])
    }

    @Test func floatViewSharesSubsequentWritesInBothDirections() {
        let cache = ClosestColor<UInt8, UInt8>()
        let floatView = cache.toFloatingWithoutCopy()
        cache.register(paletteColor: black, asAMatchTo: SIMD3(12, 34, 56))
        #expect(floatView.getPaletteColor(for: SIMD3(12, 34, 56)) == black)
        floatView.register(paletteColor: white, asAMatchTo: SIMD3(67, 89, 10))
        #expect(cache.getPaletteColor(for: SIMD3(67, 89, 10)) == white)

        floatView.register(paletteColor: red, asAMatchTo: SIMD3(12.5, 34, 56))
        #expect(floatView.getPaletteColor(for: SIMD3(12.5, 34, 56)) == red)
        #expect(cache.getPaletteColor(for: SIMD3(12, 34, 56)) == black)
    }

    @Test func floatCacheSeparatesSubByteNearestColorInputs() {
        let cache = ClosestColor<Float, UInt8>()
        let palette = ColorPalette<UInt8>.from(collection: ColorCollection(entries: [black, white]))
        #expect(palette.pickColor(basedOn: SIMD3<Float>(127, 127, 127), cache: cache) == black)
        #expect(palette.pickColor(basedOn: SIMD3<Float>(127.5625, 127.5625, 127.5625),
                                  cache: cache) == white)
    }

    @Test func sharedViewsSupportConcurrentManualReadsAndWrites() async {
        let byteView = ClosestColor<UInt8, UInt8>()
        let floatView = byteView.toFloatingWithoutCopy()
        let allMatched = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for worker in 0..<32 {
                group.addTask {
                    for sample in 0..<64 {
                        // 各任务写入独立键并触发字典扩容；整数颜色须在两个视图间立即共享。
                        let input = SIMD3<UInt8>(UInt8(worker), UInt8(sample), 17)
                        let floatInput = SIMD3<Float>(Float(worker), Float(sample), 17)
                        let expected = SIMD3<UInt8>(UInt8(worker * 7), UInt8(sample * 3),
                                                    UInt8(worker + sample))
                        if worker.isMultiple(of: 2) {
                            byteView.register(paletteColor: expected, asAMatchTo: input)
                        } else {
                            floatView.register(paletteColor: expected, asAMatchTo: floatInput)
                        }
                        await Task.yield()
                        guard byteView.getPaletteColor(for: input) == expected,
                              floatView.getPaletteColor(for: floatInput) == expected else { return false }

                        // 同时写入相邻的小数键，验证共享存储不会覆盖对应的整数键。
                        let fractionalInput = SIMD3<Float>(Float(worker) + 0.5, Float(sample), 17)
                        let fractionalExpected = SIMD3<UInt8>(255 - expected.x, 255 - expected.y,
                                                              255 - expected.z)
                        floatView.register(paletteColor: fractionalExpected, asAMatchTo: fractionalInput)
                        await Task.yield()
                        guard floatView.getPaletteColor(for: fractionalInput) == fractionalExpected,
                              byteView.getPaletteColor(for: input) == expected else { return false }
                    }
                    return true
                }
            }
            for await matched in group {
                if !matched { return false }
            }
            return true
        }
        #expect(allMatched)
    }

    @Test func continuousRedmeanUsesWeightsOnSquaredDifferences() {
        let collection = ColorCollection(entries: [black, white, red])
        // 纯绿色在连续 redmean 距离下更接近黑色，权重直接乘通道差的平方。
        #expect(collection.closestColor(to: SIMD3<UInt8>(0, 255, 0)) == black)

        // 使用独立的 Double 精度参考计算，覆盖连续红色均值、
        // 通道边界、等距候选及小数输入。
        let entries = [black, white, red, SIMD3<UInt8>(255, 255, 0)]
        let fourColors = ColorCollection(entries: entries)
        let samples: [Float] = [0, 31.25, 80, 127.5625, 160, 223.75, 255]
        for r in samples {
            for g in samples {
                for b in samples {
                    let target = SIMD3<Float>(r, g, b)
                    var expected = 0
                    var best = Double.infinity
                    for (index, candidate) in entries.enumerated() {
                        let mean = (Double(candidate.x) + Double(r)) / 2
                        let dr = Double(candidate.x) - Double(r)
                        let dg = Double(candidate.y) - Double(g)
                        let db = Double(candidate.z) - Double(b)
                        let distance = (2 + mean / 256) * dr * dr + 4 * dg * dg
                            + (2 + (255 - mean) / 256) * db * db
                        if distance < best {
                            best = distance
                            expected = index
                        }
                    }
                    #expect(fourColors.closestIndex(to: target) == expected)
                }
            }
        }
    }

    @Test func sharedCacheIsIsolatedDuringConcurrentPaletteQueries() async {
        let cache = ClosestColor<Float, UInt8>()
        let bw = ColorPalette<UInt8>.from(collection: ColorCollection(entries: [black, white]))
        let bwr = ColorPalette<UInt8>.from(collection: ColorCollection(entries: [black, white, red]))
        let targets = [SIMD3<Float>(255, 0, 0), SIMD3<Float>(0, 255, 0),
                       SIMD3<Float>(127, 127, 127), SIMD3<Float>(127.5625, 127.5625, 127.5625)]
        let allMatched = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for task in 0..<32 {
                group.addTask {
                    let palette = task.isMultiple(of: 2) ? bw : bwr
                    for _ in 0..<25 {
                        for target in targets {
                            guard palette.pickColor(basedOn: target, cache: cache)
                                    == palette.pickColor(basedOn: target) else { return false }
                        }
                    }
                    return true
                }
            }
            for await matched in group {
                if !matched { return false }
            }
            return true
        }
        #expect(allMatched)
    }
}
