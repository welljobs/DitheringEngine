import Testing
import Foundation
import DitheringEngine

struct DiffusionReferenceTests {
    // 参考实现为整幅图像分配误差平面，与处理器的三行 SIMD 环形缓冲独立。
    private func reference(_ input: [SIMD3<UInt8>], width: Int, height: Int,
                           algorithm: DitherAlgorithm) -> [UInt8] {
        let matrix: [[Int]]
        let divisor: Float
        switch algorithm {
        case .atkinson:
            matrix = [[0,0,0,1,1], [0,1,1,1,0], [0,0,1,0,0]]; divisor = 8
        case .floydSteinberg, .atkinsonPlus:
            matrix = [[0,0,0,7,0], [0,3,5,1,0]]; divisor = 16
        case .jjn:
            matrix = [[0,0,0,7,5], [3,5,7,5,3], [1,3,5,3,1]]; divisor = 48
        case .stucki:
            matrix = [[0,0,0,8,4], [2,4,8,4,2], [1,2,4,2,1]]; divisor = 42
        case .color: return []
        }
        let palette = ColorTemplate.bwry.palette
        var errors = Array(repeating: [Float](repeating: 0, count: input.count), count: 3)
        var indices: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let current = (0..<3).map { min(max(Float(input[i][$0]) + errors[$0][i], 0), 255) }
                var selected = 0
                var best = Float.infinity
                for (index, candidate) in palette.enumerated() {
                    let mean = (Float(candidate.x) + current[0]) / 2
                    let delta = (0..<3).map { Float(candidate[$0]) - current[$0] }
                    let distance = (2 + mean/256) * delta[0] * delta[0] + 4 * delta[1] * delta[1]
                        + (2 + (255-mean)/256) * delta[2] * delta[2]
                    if distance < best { best = distance; selected = index }
                }
                indices.append(UInt8(selected))
                for (dy, row) in matrix.enumerated() {
                    for (column, coefficient) in row.enumerated() where coefficient != 0 {
                        let nx = x + column - 2, ny = y + dy
                        if nx < 0 || nx >= width || ny >= height { continue }
                        let weight = Float(coefficient) / divisor
                        for component in 0..<3 {
                            errors[component][ny * width + nx] +=
                                (current[component] - Float(palette[selected][component])) * weight
                        }
                    }
                }
            }
        }
        return indices
    }

    @Test func rowRingMatchesIndependentFullImageDiffusionAtEdges() async throws {
        for (width, height) in [(1,1), (1,9), (9,1), (3,4), (7,5), (17,13)] {
            var colors: [SIMD3<UInt8>] = []
            for i in 0..<(width * height) {
                let red = UInt8((i * 71 + 13) % 256)
                let green = UInt8((i * 37 + 97) % 256)
                let blue = UInt8((i * 19 + 43) % 256)
                colors.append(SIMD3(red, green, blue))
            }
            let pixels = colors.flatMap { [$0.z, $0.y, $0.x, UInt8(255)] }
            let image = ImageBuffer(width: width, height: height, bytesPerRow: width * 4,
                                    bytesPerPixel: 4, pixels: pixels)
            for algorithm in DitherAlgorithm.allCases where algorithm != .color {
                let frame = try await Dithering.dither(image: image,
                    configuration: .forDevice(template: .bwry, scan: .horizontal), algorithm: algorithm)
                #expect(frame.indices == reference(colors, width: width, height: height, algorithm: algorithm))
            }
        }
    }
}
