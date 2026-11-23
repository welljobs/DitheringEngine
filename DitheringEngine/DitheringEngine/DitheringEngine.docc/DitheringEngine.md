# ``DitheringEngine``

面向电子纸的颜色量化、误差扩散抖动与像素数据打包 SDK。

## Overview

SDK 基于 Swift 6 实现，最低支持 iOS 18 和 macOS 15。``Dithering`` 提供异步图像处理与进度流接口，``ImageProcessor`` 执行颜色量化，``ImageDescriptor`` 管理不可变原图及由 `Synchronization.Mutex` 保护的预览快照。

### 图像输入

``ImageBuffer`` 的原始像素布局为 sRGB、8 位预乘 BGRA，每像素 4 字节，支持行尾填充。`ImageBuffer(cgImage:)` 负责颜色空间及像素格式归一化；原始字节构造器的输入由 `validate()` 或处理入口检查。

``CImageDescriptor`` 的原始字节构造器校验尺寸、步长、像素格式和数据长度，调用时须使用 `try`。``ImageDescriptor/originPixels`` 表示不可变原始像素，``ImageDescriptor/effectedPixels`` 返回预览快照。

透明像素先合成到 ``DitherConfiguration/backgroundColor``，默认背景为白色，量化结果的像素均不透明。

### 处理接口

```swift
import DitheringEngine

let input = try ImageBuffer(cgImage: cgImage)
let configuration = DitherConfiguration.forDevice(
    template: .bwr,
    scan: .horizontal,
    flipHorizontal: true
)
let cache = ClosestColor<UInt8, UInt8>()
let frame = try await Dithering.dither(
    image: input,
    configuration: configuration,
    algorithm: .floydSteinberg,
    cache: cache
)
let preview = frame.makeCGImage()
let deviceBytes = frame.packed
```

处理接口同时提供 `image:` 和 `descriptor:` 两种输入形式。``DitheredFrame/indices`` 按原图逐行存储调色板索引，``DitheredFrame/packed`` 存储设备格式字节。预览和索引保持原图坐标方向，扫描和翻转配置仅作用于打包数据。

共享预览直接保存在 `Mutex<[UInt8]>` 中，通过 `withLock` 读取、修改及发布。每次处理使用独立的工作像素和误差缓冲。`Dithering.dither` 在量化、打包及发布前取消检查均成功后发布完整预览。处理失败或在发布前检测到取消时，不更新描述符预览。

同一描述符可供多个任务处理，其预览表示最近一次发布的结果。各次调用的预览及配置由返回帧独立持有，需要特定调用的图像时，使用 `frame.makeCGImage()` 或 `frame.preview`。

### 进度与取消

```swift
for try await event in Dithering.ditherStream(
    image: input,
    configuration: configuration,
    algorithm: .stucki
) {
    switch event {
    case .progress(let progress):
        print(progress.fraction)
    case .finished(let frame):
        print(frame.packed.count)
    }
}
```

``DitherProgress`` 记录已完成的量化行数；进度达到 1 表示量化完成，最终打包结果由 `.finished` 事件提供。异步流最多缓冲两个待消费事件，消费者较慢时可能跳过中间进度，正常结束时保留最终进度与成品帧。

图像处理及位打包执行协作取消检查。流终止时，底层任务收到取消请求。提前停止消费时，应取消消费任务或释放流；仅退出循环不保证立即取消底层任务。

### 算法与颜色匹配

``DitherAlgorithm`` 的原始值对应设备协议算法编号：

| 算法 | 编号 | 扩散规则 |
| --- | --- | --- |
| `.atkinson` | `1` | 6 点扩散，每点权重为 1/8，权重和为 3/4 |
| `.color` | `2` | 固定颜色阈值分类，不扩散误差 |
| `.floydSteinberg` | `3` | 4 点扩散，权重分母为 16 |
| `.jjn` | `4` | Jarvis–Judice–Ninke，12 点扩散，权重分母为 48 |
| `.stucki` | `5` | 12 点扩散，权重分母为 42 |
| `.atkinsonPlus` | `6` | 使用 Floyd–Steinberg 权重 |

误差扩散按原图从左至右、从上至下处理，使用三行浮点误差环形缓冲。颜色分量在匹配前限制到 `0...255`，越出图像边界的扩散项直接忽略。

``ColorCollection`` 使用连续 redmean 距离进行最近色匹配。``ClosestColor`` 将可变缓存状态统一封装在 `Mutex` 中，按精确浮点输入、完整有序调色板及距离策略隔离缓存条目，手工映射不参与算法缓存覆盖。最近色计算在锁外执行，查询和写入在临界区完成。`toFloatingWithoutCopy()` 的返回视图共享原缓存存储。

### 颜色模板与配置校验

``ColorTemplate`` 定义调色板及设备编码，顺序为黑、白、第三色、第四色：

| 模板 | 屏幕码 | 设备色值 | 输出格式 |
| --- | --- | --- | --- |
| `.bw` | `20` | `[0, 1]` | 1 位单平面 |
| `.bwr` | `30` | `[0, 1, 3]` | 两个 1 位平面串联 |
| `.bwy` | `31` | `[0, 1, 2]` | 两个 1 位平面串联 |
| `.bwry` | `40` | `[0, 1, 3, 2]` | 每像素 2 位 |

``DitherConfiguration`` 要求调色板非空、设备色值数量与调色板一致且互不重复。单平面编码范围为 `0...1`，双平面和四色编码范围为 `0...3`。

`.color` 模式使用固定颜色位置判定，调色板必须等于 `colorCode` 对应的模板及其顺序。自定义颜色量化可使用误差扩散算法。

### 扫描、翻转与位打包

水平扫描按行分组，垂直扫描按列分组。每组独立从字节高位开始填充，尾部不足一个字节时补零。

- `.single`：每像素取设备色值的低位，每字节存储 8 个像素。
- `.complex`：分别存储高位 A 平面和低位 B 平面，输出为完整 A 平面后接完整 B 平面。
- `.color4`：每像素存储高位、低位，共 2 位，每字节存储 4 个像素。

水平翻转遵循设备协议约定：

| 扫描方式 | `flipHorizontal = false` | `flipHorizontal = true` |
| --- | --- | --- |
| 水平扫描 | `x = width - 1 - orgX` | `x = orgX` |
| 垂直扫描 | `x = orgX` | `x = width - 1 - orgX` |

两种扫描方式中，`flipVertical = true` 均按 `y = height - 1 - orgY` 映射。

### 压缩格式

`Data.compress()` 与 `Data.decompress()` 使用裸 LZSS：4096 字节滑动窗口、1 至 4095 字节回溯距离、3 至 18 字节匹配长度。每组最多 8 个标记，标志位为 1 时存储字面量，为 0 时存储两字节匹配。

解压支持可选的 `expectedSize` 和 `maxOutputSize`，分别校验解压长度和限制输出大小。裸格式没有原始长度或校验和，无法检测全部截断与内容损坏。

LZSS 与 minilzo / LZO 的数据格式不兼容。与采用 LZO 的设备通信时，应使用设备协议规定的编解码器。

## Topics

### 抖动引擎

- ``Dithering``
- ``DitherAlgorithm``
- ``DitherConfiguration``
- ``ColorTemplate``
- ``DitheredFrame``
- ``DitherEvent``

### 输入、进度与错误

- ``ImageDescriptor``
- ``ImageProcessor``
- ``ImageBuffer``
- ``DitherProgress``
- ``DitherError``
- ``CombineMode``
- ``ScanMode``
- ``ColorCode``
- ``CompressionError``

### 颜色体系

- ``ImageColor``
- ``ColorCollection``
- ``ColorPalette``
- ``ClosestColor``
