import Testing
import Foundation
import CoreGraphics
import DitheringEngine

struct ImageSafetyRegressionTests {
    private func image(width: Int, height: Int, bgra: [UInt8]) -> ImageBuffer {
        ImageBuffer(width: width, height: height, bytesPerRow: width * 4,
                    bytesPerPixel: 4, pixels: bgra)
    }
    private func descriptor(_ image: ImageBuffer) throws -> CImageDescriptor {
        try CImageDescriptor(width: image.width, height: image.height, bytesPerRow: image.bytesPerRow,
                             bytesPerPixel: image.bytesPerPixel, pixels: image.pixels)
    }

    @Test func invalidLayoutsThrowInsteadOfTrapping() async {
        let invalid = [
            ImageBuffer(width: 0, height: 1, bytesPerRow: 0, bytesPerPixel: 4, pixels: []),
            ImageBuffer(width: 1, height: -1, bytesPerRow: 4, bytesPerPixel: 4, pixels: []),
            ImageBuffer(width: 1, height: 1, bytesPerRow: 1, bytesPerPixel: 1, pixels: [255]),
            ImageBuffer(width: 1, height: 1, bytesPerRow: 3, bytesPerPixel: 3, pixels: [0,0,0]),
            ImageBuffer(width: 2, height: 1, bytesPerRow: 4, bytesPerPixel: 4, pixels: [0,0,0,255]),
            ImageBuffer(width: 1, height: 2, bytesPerRow: 4, bytesPerPixel: 4, pixels: [0,0,0,255]),
            ImageBuffer(width: Int.max, height: 2, bytesPerRow: Int.max, bytesPerPixel: 4, pixels: []),
            ImageBuffer(width: 1, height: Int.max, bytesPerRow: 4, bytesPerPixel: 4, pixels: [])
        ]
        for input in invalid {
            #expect(throws: DitherError.self) { _ = try descriptor(input) }
            await #expect(throws: DitherError.self) {
                _ = try await Dithering.dither(image: input, configuration: .blackWhite, algorithm: .color)
            }
            await #expect(throws: DitherError.self) {
                for try await _ in Dithering.ditherStream(image: input, configuration: .blackWhite,
                                                          algorithm: .atkinson) {}
            }
        }
    }

    @Test func invalidDeviceCodesAndOversizedPalettesThrow() async {
        let input = image(width: 1, height: 1, bgra: [255,255,255,255])
        let invalid = [
            DitherConfiguration(palette: ColorTemplate.bw.palette, colorValues: [0,2],
                                combine: .single, scan: .horizontal),
            DitherConfiguration(palette: ColorTemplate.bw.palette, colorValues: [0,4],
                                combine: .complex, scan: .horizontal),
            DitherConfiguration(palette: ColorTemplate.bw.palette, colorValues: [0,0],
                                combine: .color4, scan: .horizontal),
            DitherConfiguration(palette: Array(repeating: SIMD3<UInt8>(0,0,0), count: 257),
                                colorValues: Array(repeating: 0, count: 257),
                                combine: .color4, scan: .horizontal)
        ]
        for config in invalid {
            await #expect(throws: DitherError.self) {
                _ = try await Dithering.dither(image: input, configuration: config, algorithm: .atkinson)
            }
        }
        let reversed = DitherConfiguration(palette: Array(ColorTemplate.bw.palette.reversed()), colorValues: [1,0],
                                           combine: .single, scan: .horizontal)
        await #expect(throws: DitherError.self) {
            _ = try await Dithering.dither(image: input, configuration: reversed, algorithm: .color)
        }
    }

    @Test func previewAndCopyPreserveRedAndBlueWithPadding() throws {
        let input = ImageBuffer(width: 2, height: 1, bytesPerRow: 12, bytesPerPixel: 4,
                                pixels: [0,0,255,255, 255,0,0,255, 0,0,0,0])
        let original = try descriptor(input)
        for candidate in [original, original.makeCopy()] {
            let normalized = try CImageDescriptor(imageRef: #require(candidate.makeCGImage()))
            #expect(normalized.colorAt(x: 0, y: 0) == SIMD3<UInt8>(255,0,0))
            #expect(normalized.colorAt(x: 1, y: 0) == SIMD3<UInt8>(0,0,255))
        }
        let copy = original.makeCopy()
        copy.setColor(x: 0, y: 0, SIMD3(255,255,255))
        #expect(original.colorAt(x: 0, y: 0) == SIMD3<UInt8>(255,0,0))
        #expect(copy.colorAt(x: 0, y: 0) == SIMD3<UInt8>(255,255,255))
    }

    @Test func transparentPixelsUseConfiguredBackgroundAndOpaquePreview() async throws {
        let input = image(width: 3, height: 1, bgra: [0,0,0,0, 64,64,64,64, 0,0,64,64])
        let white = DitherConfiguration.forDevice(template: .bw, scan: .horizontal, flipHorizontal: true)
        let black = DitherConfiguration.forDevice(template: .bw, scan: .horizontal, flipHorizontal: true,
                                                   backgroundColor: SIMD3(0,0,0))
        for algorithm in DitherAlgorithm.allCases {
            let frame = try await Dithering.dither(image: input, configuration: white, algorithm: algorithm)
            #expect(Array(frame.indices.prefix(2)) == [1,1])
            let preview = try #require(frame.preview)
            #expect(stride(from: 3, to: preview.pixels.count, by: 4).allSatisfy { preview.pixels[$0] == 255 })
        }
        let blackFrame = try await Dithering.dither(image: input, configuration: black, algorithm: .color)
        #expect(blackFrame.indices == [0,0,0])
    }

    @Test func overlappingCallsAndExternalResetCannotMixFrames() async throws {
        let redPixels = (0..<16).flatMap { _ in [UInt8](arrayLiteral: 0,0,255,255) }
        let shared = try descriptor(image(width: 8, height: 2, bgra: redPixels))
        let ready = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let first = Task.detached {
            try await Dithering.dither(descriptor: shared,
                configuration: .forDevice(template: .bwr, scan: .horizontal), algorithm: .atkinson) { p in
                if p.completedRows == 1 {
                    ready.signal()
                    _ = resume.wait(timeout: .now() + 10)
                }
            }
        }
        let paused = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: ready.wait(timeout: .now() + 10) == .success)
            }
        }
        defer { resume.signal() }
        #expect(paused)
        shared.release()
        let mono = try await Dithering.dither(descriptor: shared, configuration: .blackWhite, algorithm: .color)
        resume.signal()
        let color = try await first.value
        #expect(color.indices == Array(repeating: UInt8(2), count: 16))
        #expect(mono.indices == Array(repeating: UInt8(0), count: 16))
        #expect(color.preview?.colorAt(x: 0, y: 1) == SIMD3<UInt8>(255,0,0))
        #expect(mono.preview?.colorAt(x: 0, y: 1) == SIMD3<UInt8>(0,0,0))
    }

    @Test func concurrentPixelAccessAndCopiesKeepCompleteSnapshots() async throws {
        let shared = try descriptor(image(width: 1, height: 1, bgra: [0,0,0,0]))
        let allowedPixels: [[UInt8]] = [[0,0,0,0], [0,0,255,255], [255,0,0,255]]
        let allowedColors: [SIMD3<UInt8>] = [SIMD3(0,0,0), SIMD3(255,0,0), SIMD3(0,0,255)]
        let consistent = await withTaskGroup(of: Bool.self) { group in
            for color in allowedColors.dropFirst() {
                group.addTask {
                    for _ in 0..<256 {
                        shared.setColor(x: 0, y: 0, color)
                        await Task.yield()
                    }
                    return true
                }
            }
            group.addTask {
                for _ in 0..<256 {
                    shared.release()
                    await Task.yield()
                }
                return true
            }
            for _ in 0..<3 {
                group.addTask {
                    for _ in 0..<256 {
                        let snapshot = shared.effectedPixels
                        let color = shared.colorAt(x: 0, y: 0)
                        let copy = shared.makeCopy()
                        let copiedPixels = copy.effectedPixels
                        await Task.yield()
                        // 快照须包含一次完整像素写入；副本不随共享描述符的后续操作变化。
                        guard allowedPixels.contains(snapshot), allowedColors.contains(color),
                              allowedPixels.contains(copiedPixels),
                              copy.effectedPixels == copiedPixels else { return false }
                    }
                    return true
                }
            }
            var consistent = true
            for await result in group { consistent = consistent && result }
            return consistent
        }
        #expect(consistent)
        #expect(shared.originPixels == [0,0,0,0])
    }

    @Test func concurrentPublicationAndResetExposeOnlyCompleteFrames() async throws {
        let input = image(width: 8, height: 8, bgra: Array(repeating: 0, count: 8 * 8 * 4))
        let shared = try descriptor(input)
        let white = DitherConfiguration.forDevice(template: .bw, scan: .horizontal)
        let black = DitherConfiguration.forDevice(template: .bw, scan: .horizontal,
                                                   backgroundColor: SIMD3(0,0,0))
        let whitePixels = Array(repeating: UInt8(255), count: input.pixels.count)
        let blackPixels = (0..<64).flatMap { _ in [UInt8](arrayLiteral: 0,0,0,255) }
        let allowedFrames = [input.pixels, whitePixels, blackPixels]
        let consistent = try await withThrowingTaskGroup(of: Bool.self) { group in
            for configuration in [white, black] {
                group.addTask {
                    for _ in 0..<16 {
                        let frame = try await Dithering.dither(descriptor: shared,
                                                               configuration: configuration, algorithm: .color)
                        guard frame.preview?.pixels == (configuration.backgroundColor.x == 0
                                                         ? blackPixels : whitePixels) else { return false }
                        await Task.yield()
                    }
                    return true
                }
            }
            group.addTask {
                for _ in 0..<128 {
                    shared.release()
                    await Task.yield()
                }
                return true
            }
            for _ in 0..<3 {
                group.addTask {
                    for _ in 0..<128 {
                        // 整帧发布与重置均不能向读取者暴露部分替换的数组。
                        guard allowedFrames.contains(shared.effectedPixels),
                              allowedFrames.contains(shared.makeCopy().effectedPixels) else { return false }
                        await Task.yield()
                    }
                    return true
                }
            }
            var consistent = true
            for try await result in group { consistent = consistent && result }
            return consistent
        }
        #expect(consistent)
        #expect(shared.originPixels == input.pixels)
    }

    @Test func cancellationDoesNotPublishPartialPreview() async throws {
        let pixels = (0..<64).flatMap { _ in [UInt8](arrayLiteral: 96,96,96,255) }
        let shared = try descriptor(image(width: 8, height: 8, bgra: pixels))
        let before = shared.effectedPixels
        let task = Task {
            try await Dithering.dither(descriptor: shared, configuration: .blackWhite,
                                         algorithm: .floydSteinberg) { p in
                if p.completedRows == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(shared.effectedPixels == before)
    }

    @Test func streamBuffersLatestProgressAndFinalFrame() async throws {
        let input = image(width: 1, height: 512,
                           bgra: (0..<512).flatMap { _ in [UInt8](arrayLiteral: 0,0,0,0) })
        let descriptor = try descriptor(input)
        let stream = Dithering.ditherStream(descriptor: descriptor, configuration: .blackWhite,
                                            algorithm: .color)
        // 完整结果发布前，描述符预览保持原始透明度；发布后的量化预览不透明。
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while descriptor.effectedPixels[3] != 255 && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(descriptor.effectedPixels[3] == 255)
        var eventCount = 0
        var final: DitheredFrame?
        var lastProgress = 0
        for try await event in stream {
            eventCount += 1
            switch event {
            case .progress(let progress): lastProgress = progress.completedRows
            case .finished(let frame): final = frame
            }
        }
        #expect(eventCount <= 2)
        #expect(lastProgress == 512)
        #expect(final?.indices.count == 512)
    }

    @Test func legacyConfigurationJSONDefaultsToWhiteBackground() throws {
        let encoded = try JSONEncoder().encode(DitherConfiguration.blackWhite)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "backgroundColor")
        let decoded = try JSONDecoder().decode(DitherConfiguration.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.backgroundColor == SIMD3<UInt8>(255,255,255))
    }
}
