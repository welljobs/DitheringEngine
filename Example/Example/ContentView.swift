//
//  ContentView.swift
//  Example
//
//  DitheringEngine 交互示例：图像加载、参数选择、异步抖动与预览。
//

import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import DitheringEngine

#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@Observable
@MainActor
final class DitherViewModel {
    var algorithm: DitherAlgorithm = .floydSteinberg
    var template: ColorTemplate = .bwr
    var scan: ScanMode = .horizontal
    var flipHorizontal = true
    var flipVertical = false
    var useCache = true

    var progress: Double = 0
    var isRunning = false
    var status = "就绪"
    var errorMessage: String?

    var originalImage: CGImage?
    var previewImage: CGImage?
    var originalZoom: CGImage?
    var previewZoom: CGImage?
    var resultInfo = ""
    var hexPreview = ""

    private var task: Task<Void, Never>?

    /// 取图像中部的局部区域按最近邻放大，保留抖动点阵细节。
    private func zoomed(_ image: CGImage, side: Int = 96, scale: Int = 4) -> CGImage? {
        let x0 = max(0, (image.width - side) / 2)
        let y0 = max(0, (image.height - side) / 2)
        let rect = CGRect(x: x0, y: y0, width: side, height: side)
        guard let cropped = image.cropping(to: rect) else { return nil }
        let w = side * scale
        guard let ctx = CGContext(data: nil, width: w, height: w,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .none
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: w))
        return ctx.makeImage()
    }

    func loadImage() {
        // 从平台资源包读取内置示例图，并清空上次处理结果。
        #if os(macOS)
        guard let image = NSImage(named: "528x768-08"),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorMessage = "无法加载资源图片 528x768-08"
            return
        }
        #else
        guard let image = UIImage(named: "528x768-08"),
              let cg = image.cgImage else {
            errorMessage = "无法加载资源图片 528x768-08"
            return
        }
        #endif
        originalImage = cg
        originalZoom = zoomed(cg)
        previewImage = nil
        previewZoom = nil
        resultInfo = "已加载 \(cg.width)×\(cg.height)"
        status = "图片已就绪"
        errorMessage = nil
    }

    func run() {
        if originalImage == nil { loadImage() }
        guard let cg = originalImage else { return }
        task?.cancel()
        isRunning = true
        errorMessage = nil
        progress = 0
        previewImage = nil
        previewZoom = nil
        status = "处理中…"

        task = Task { @MainActor in
            do {
                let descriptor = try CImageDescriptor(imageRef: cg)
                let config = DitherConfiguration.forDevice(
                    template: template, scan: scan,
                    flipHorizontal: flipHorizontal, flipVertical: flipVertical)
                let cache: ClosestColor<UInt8, UInt8>? = useCache ? ClosestColor() : nil
                let started = Date()

                var finalFrame: DitheredFrame?
                for try await event in Dithering.ditherStream(
                    descriptor: descriptor, configuration: config,
                    algorithm: algorithm, cache: cache) {
                    switch event {
                    case .progress(let p):
                        progress = p.fraction
                        status = "处理中 \(Int(p.fraction * 100))%"
                    case .finished(let frame):
                        finalFrame = frame
                    @unknown default:
                        break
                    }
                }

                guard let frame = finalFrame else { throw DitherError.invalidImageData }
                previewImage = frame.makeCGImage()
                previewZoom = previewImage.flatMap { zoomed($0) }
                let elapsed = Date().timeIntervalSince(started)
                resultInfo = """
                算法: \(algorithm.rawValue)  \(algorithm) | 模板: \(template.rawValue)  \(template)
                扫描: \(scan.rawValue) \(scan) | 翻转 H=\(flipHorizontal) V=\(flipVertical)
                像素: \(frame.width)×\(frame.height) (\(frame.indices.count))
                输出: \(frame.packed.count) 字节 | 耗时: \(String(format: "%.3f", elapsed))s
                """
                hexPreview = frame.packed.prefix(48).map {
                    String(format: "%02X", $0)
                }.joined(separator: " ") + (frame.packed.count > 48 ? " …" : "")
                progress = 1
                status = "完成"
                isRunning = false
            } catch is CancellationError {
                status = "已取消"
                isRunning = false
            } catch {
                errorMessage = "处理失败: \(error)"
                status = "失败"
                isRunning = false
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func savePNG() {
        guard let cg = previewImage else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dithered-\(algorithm.rawValue)-\(template.rawValue).png")
        let data = cg.pngData()
        try? data?.write(to: url)
        status = "已保存: \(url.lastPathComponent)"
    }
}

extension CGImage {
    func pngData() -> Data? {
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutable as CFMutableData,
                                                          UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, self, nil)
        return CGImageDestinationFinalize(dest) ? mutable as Data : nil
    }
}

struct ContentView: View {
    @State private var model = DitherViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    controls
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                    progressBar
                    images
                    resultPanel
                }
                .padding()
            }
            .navigationTitle("DitheringEngine Demo")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { model.loadImage() }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("参数配置", systemImage: "slider.horizontal.3").font(.headline)
            Picker("算法", selection: $model.algorithm) {
                ForEach(DitherAlgorithm.allCases, id: \.self) { algo in
                    Text(String("\(algo.rawValue) · \(algo)")).tag(algo)
                }
            }
            Picker("模板", selection: $model.template) {
                ForEach(ColorTemplate.allCases, id: \.self) { t in
                    Text(String("\(t.rawValue) · \(t)")).tag(t)
                }
            }
            Picker("扫描", selection: $model.scan) {
                ForEach([ScanMode.horizontal, .vertical], id: \.self) { s in
                    Text(String("\(s.rawValue) · \(s)")).tag(s)
                }
            }
            HStack {
                Toggle("水平翻转", isOn: $model.flipHorizontal)
                Toggle("垂直翻转", isOn: $model.flipVertical)
                Toggle("颜色缓存", isOn: $model.useCache)
            }
            HStack {
                Button(action: model.run) {
                    Label(model.isRunning ? "处理中…" : "开始抖动", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning)

                if model.isRunning {
                    Button("取消", action: model.cancel).buttonStyle(.bordered)
                }
                Button("重新加载", action: model.loadImage).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var progressBar: some View {
        VStack(spacing: 6) {
            HStack { Text(model.status).font(.subheadline); Spacer()
                Text("\(Int(model.progress * 100))%").font(.caption.monospacedDigit()) }
            ProgressView(value: model.progress)
        }
    }

    @ViewBuilder
    private var images: some View {
        HStack(alignment: .top, spacing: 16) {
            imageCard(title: "原图", cg: model.originalImage)
            imageCard(title: "抖动预览", cg: model.previewImage)
        }
        if model.originalZoom != nil || model.previewZoom != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("局部放大 4×（最近邻，展示抖动点阵）")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 16) {
                    zoomCard(title: "原图局部", cg: model.originalZoom)
                    zoomCard(title: "抖动后局部", cg: model.previewZoom)
                }
            }
        }
    }

    @ViewBuilder
    private func zoomCard(title: String, cg: CGImage?) -> some View {
        VStack {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            if let cg {
                #if os(macOS)
                Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
                    .resizable().scaledToFit()
                #else
                Image(uiImage: UIImage(cgImage: cg))
                    .resizable().scaledToFit()
                #endif
            } else {
                Rectangle().fill(.quaternary).aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func imageCard(title: String, cg: CGImage?) -> some View {
        VStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let cg {
                #if os(macOS)
                Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
                    .resizable().scaledToFit()
                #else
                Image(uiImage: UIImage(cgImage: cg))
                    .resizable().scaledToFit()
                #endif
            } else {
                Rectangle().fill(.quaternary).overlay(Text("—")).aspectRatio(0.75, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("输出数据", systemImage: "doc.text").font(.headline)
            Text(model.resultInfo.isEmpty ? "尚未生成" : model.resultInfo)
                .font(.caption.monospacedDigit())
                .textSelection(.enabled)
            if !model.hexPreview.isEmpty {
                Text(model.hexPreview)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            Button("保存 PNG 到临时目录", action: model.savePNG)
                .buttonStyle(.bordered)
                .disabled(model.previewImage == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ContentView()
}
