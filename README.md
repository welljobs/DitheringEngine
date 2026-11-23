# DitheringEngine

DitheringEngine 是面向电子纸图像处理的 Swift SDK，提供颜色量化、误差扩散抖动、图像预览和设备像素数据打包功能。

## 环境要求

| 组件 | Swift | iOS | macOS |
| --- | --- | --- | --- |
| SDK | 6.0 及以上 | 18 及以上 | 15 及以上 |
| 交互示例 | 6.0 及以上 | 18 及以上 | 15 及以上 |
| Swift Testing 测试宿主 | 6.0 及以上 | — | 15 及以上 |

SDK 使用 Swift 6 严格并发检查，通过 `Synchronization.Mutex` 管理共享状态。交互示例依赖 Observation 框架。工程中的 visionOS 目标及 Swift Package 声明最低为 visionOS 2.1。

## 集成方式

### Swift Package Manager

在 Xcode 的“Add Package Dependencies”中输入仓库地址：

```text
https://github.com/welljobs/DitheringEngine.git
```

依赖规则选择 `Branch` 并填写 `main`，将 `DitheringEngine` 库产品添加到应用目标。

本地开发时，也可以通过“Add Local Package”选择本目录。

### Framework 工程

打开 `DitheringEngine/DitheringEngine.xcodeproj`，选择共享方案 `DitheringEngineFramework` 构建框架。

### 示例工程

打开 `Example/Example.xcodeproj`。示例工程通过本地 Swift Package 引用 SDK，可用于选择算法和颜色模板、查看处理进度、比较图像、查看设备字节预览及保存处理图像。真机运行时，在 Signing & Capabilities 中选择开发者团队。

## 基本用法

```swift
import DitheringEngine

let input = try ImageBuffer(cgImage: cgImage)
let configuration = DitherConfiguration.forDevice(
    template: .bwr,
    scan: .horizontal,
    flipHorizontal: true
)
let frame = try await Dithering.dither(
    image: input,
    configuration: configuration,
    algorithm: .floydSteinberg
)
let preview = frame.makeCGImage()
let deviceBytes = frame.packed
```

`frame.indices` 按原图逐行存储调色板索引；`frame.packed` 按设备配置存储像素编码。扫描方向和翻转设置仅影响打包数据，预览保持原图坐标方向。

## 输入与颜色约定

- 原始像素采用 sRGB 颜色空间下的 8 位预乘 BGRA，每像素 4 字节，允许行尾填充。
- `ImageBuffer(cgImage:)` 将图像转换为统一布局。原始字节构造器保存输入，`validate()` 或处理入口执行尺寸、步长及数据长度校验。
- `CImageDescriptor` 的原始字节构造器执行校验并可能抛出错误，调用时使用 `try`。
- 透明像素先合成到 `DitherConfiguration.backgroundColor`，默认背景为白色；量化预览的像素均不透明。

```swift
let descriptor = try CImageDescriptor(
    width: width,
    height: height,
    bytesPerRow: bytesPerRow,
    bytesPerPixel: 4,
    pixels: bgraBytes
)
```

## 算法与设备配置

| 算法 | 编号 | 量化方式 |
| --- | --- | --- |
| `.atkinson` | `1` | Atkinson，6 点误差扩散，权重和为 3/4 |
| `.color` | `2` | 固定颜色阈值分类，不扩散误差 |
| `.floydSteinberg` | `3` | Floyd–Steinberg，4 点误差扩散 |
| `.jjn` | `4` | Jarvis–Judice–Ninke，12 点误差扩散 |
| `.stucki` | `5` | Stucki，12 点误差扩散 |
| `.atkinsonPlus` | `6` | 使用 Floyd–Steinberg 权重的协议算法编号 |

误差扩散模式使用连续 redmean 距离选择最近颜色，采用浮点误差累加，超出图像边界的扩散项直接忽略。

| 颜色模板 | 屏幕码 | 设备色值（按调色板顺序） | 输出格式 |
| --- | --- | --- | --- |
| `.bw` | `20` | 黑 0、白 1 | 1 位单平面 |
| `.bwr` | `30` | 黑 0、白 1、红 3 | 两个 1 位平面串联 |
| `.bwy` | `31` | 黑 0、白 1、黄 2 | 两个 1 位平面串联 |
| `.bwry` | `40` | 黑 0、白 1、红 3、黄 2 | 2 位像素编码 |

自定义配置中，调色板不能为空，设备色值数量须与调色板一致且互不重复。单平面色值范围为 `0...1`，双平面及四色色值范围为 `0...3`。`.color` 模式依赖颜色位置的语义，调色板必须与 `colorCode` 对应的模板及其顺序一致。

### 扫描与位打包

字节内采用高位优先顺序，每行或每列独立打包，尾部不足一个字节时以零填充。双平面按 A 平面、B 平面顺序串联；A 取设备色值的高位，B 取低位。

`flipHorizontal` 遵循设备协议的坐标定义：

| 扫描方式 | `flipHorizontal = false` | `flipHorizontal = true` |
| --- | --- | --- |
| 水平扫描 | 水平镜像 | 保持横坐标 |
| 垂直扫描 | 保持横坐标 | 水平镜像 |

`flipVertical = true` 时，对两种扫描方式均执行垂直镜像。水平扫描按行分组，垂直扫描按列分组。

## 并发与进度

每次处理从不可变原始像素开始，使用独立的工作像素和三行误差缓冲。`Dithering.dither` 在量化、打包及发布前取消检查均成功后，一次性发布描述符预览。

预览像素保存在 `Mutex<[UInt8]>` 中，`effectedPixels`、`setColor` 和 `release` 均通过 `withLock` 访问。`effectedPixels` 返回具有数组值语义的只读快照。多个任务共享描述符时，描述符预览表示最近一次发布的结果；各次调用的结果由 `DitheredFrame` 独立持有，可通过 `frame.preview` 或 `frame.makeCGImage()` 获取。

`ditherStream` 返回 `AsyncThrowingStream`，最多保留两个待消费事件。消费者处理较慢时，中间进度可能被合并；正常完成时保留最终进度和 `.finished` 结果。流终止时取消底层处理任务，图像处理与位打包过程均执行协作取消检查。提前停止消费时，应取消消费任务或释放流；仅退出循环不保证立即取消底层任务。

最近色缓存将手工映射、调色板索引及预填充配置统一封装在 `Mutex` 状态中，按精确浮点输入、完整有序调色板和距离策略区分条目。最近色计算在锁外执行，避免将计算过程纳入临界区。`register` / `getPaletteColor` 使用独立的手工映射空间；`toFloatingWithoutCopy()` 返回共享同一存储的浮点视图。

## 数据压缩

`Data.compress()` 和 `Data.decompress()` 使用裸 LZSS 格式。该格式与 minilzo / LZO 不兼容；EinkAPP 的设备通信使用 `FMCompressUtils` 对应的压缩格式。

```swift
let compressed = deviceBytes.compress()
let restored = try compressed.decompress(
    expectedSize: deviceBytes.count,
    maxOutputSize: maximumAllowedByteCount
)
```

`expectedSize` 校验解压长度，`maxOutputSize` 限制输出大小。裸格式不包含原始长度或校验和，无法识别所有截断及内容损坏；传输完整性校验由通信协议负责。

## 构建与验证

在 SDK 根目录执行：

```sh
swift test
swift test -c release
xcodebuild -project DitheringEngine/DitheringEngine.xcodeproj \
  -scheme DitheringEngineFramework -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Swift 测试覆盖颜色匹配与缓存、扩散参考结果、图像布局、透明度、并发隔离、位打包及压缩格式。

接口及类型说明见 [SDK 参考文档](DitheringEngine/DitheringEngine/DitheringEngine.docc/DitheringEngine.md)。
