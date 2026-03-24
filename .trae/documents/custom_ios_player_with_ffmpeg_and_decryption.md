# 播放器从零手搓与加密播放改造计划

## 1. 目标与范围 (Summary)
本项目旨在从零开始，基于 FFmpeg 手搓一个精简版的 iOS 视频播放器，专门用于播放本地 MP4 文件（包含 H.264 视频和 AAC 音频）。所有相关代码及构建脚本将统一放置于目录：`/Users/uxin/Desktop/无名高地/fileReadAction/GCSPlayer`。
在完成基础播放器（涵盖解复用、音频解码与播放、视频解码与 Metal 渲染、音视频同步）后，我们将为其接入自定义的 I/O 模块，实现**跳过动态长度头部脏数据**以及**对头部 1KB 数据进行实时 AES-CTR 解密**的功能。

## 2. 现状分析 (Current State Analysis)

* **代码库基础**：目前项目中无 FFmpeg 库，也无现成的播放器源码，一切需从头搭建。

* **加密方式确认**：经过检索，项目中使用了 `AES-CTR` 模式（无填充 `ccNoPadding`）进行文件头加密（参考 `AESCTR.swift`）。由于 CTR 模式是流式加密，这为我们实现文件任意位置的 Seek 和局部解密提供了极大的便利（不需要像 CBC 那样依赖前一个 block）。

* **语言边界**：FFmpeg 是纯 C 库，iOS 业务层是 Swift。需要引入 Objective-C/C 作为中间桥接层。

## 3. 实施步骤 (Proposed Changes)

### 第一阶段：手搓基础播放器 (5步走)

**第一步：跑通 FFmpeg 编译**

* **产出**：编写一个 Shell 脚本 `build_ffmpeg.sh`。

* **内容**：自动下载 FFmpeg 源码，配置极简的编译选项（仅开启 mp4 demuxer、h264 decoder、aac decoder、swresample、swscale 等必需模块，以减小体积和加快编译）。

* **目标架构**：编译输出支持 `arm64` (真机) 和 `x86_64/arm64` (模拟器) 的静态库或 `.xcframework`。

**第二步：只解不播 (Demuxing)**

* **产出**：建立 `YCCorePlayer` (Objective-C) 桥接类和 `YCMediaPlayer` (Swift) 接口类。

* **内容**：使用 `avformat_open_input` 打开本地 MP4 文件，通过 `av_read_frame` 循环读取数据包 (Packet)。

* **验证**：在控制台正确打印出每一帧的类型（音频/视频）、PTS（显示时间戳）和 Size，然后释放。

**第三步：只播声音 (Audio Decode & Playback)**

* **产出**：音频解码模块 + `AudioUnit` 播放模块。

* **内容**：

  1. 使用 `avcodec_send_packet` / `avcodec_receive_frame` 将 AAC Packet 解码为 PCM Frame。
  2. 使用 `swr_convert` 将解码后的 PCM 统一重采样为 iOS `AudioUnit` 偏好的格式（如 44.1kHz, 16bit, 立体声交错格式）。
  3. 配置 `AUGraph` 或 `AudioQueue`，在音频回调中不断消耗 PCM 数据发声。

**第四步：只播画面 (Video Decode & Metal Render)**

* **产出**：视频解码模块 + `Metal` 渲染视图 (`YCMetalView`)。

* **内容**：

  1. 解码 H.264 Packet 为 YUV420P Frame。
  2. 使用 Metal 编写 Shader（Fragment Shader 中实现 YUV 到 RGB 的矩阵转换）。
  3. 将 Y、U、V 三个分量作为 Texture 传递给 GPU 进行渲染。

* **状态**：此时不考虑时间戳，解码一帧画一帧，画面会呈现“快进”效果。

**第五步：世纪大合体 (A/V Sync)**

* **产出**：音视频同步主时钟 (Master Clock)。

* **内容**：

  1. 以**音频时钟**为基准（Audio Master Clock）：记录当前音频播放到的 PTS。
  2. 视频渲染线程在绘制前，比较当前视频帧的 PTS 与音频时钟。
  3. 如果视频太快，则 `usleep` 等待；如果视频太慢，则丢弃当前视频帧（Drop Frame）以追赶音频。

### 第二阶段：防盗链与解密改造 (Transparent I/O)

**1. 接口设计**

* 在初始化播放器时，由外界（Swift层）传入三个关键参数：

  * `dirtyDataLength`: 脏数据长度 (Int)

  * `aesKey`: AES-CTR 密钥 (Data)

  * `aesIV`: AES-CTR 初始向量 (Data)

**2. 自定义 AVIOContext**

* 不使用 FFmpeg 默认的文件打开方式，而是使用 `avio_alloc_context` 创建一个自定义的 I/O 上下文。

* **底层文件操作**：使用 POSIX 的 `open`, `read`, `lseek` 打开物理文件。

* **逻辑寻址转换 (Seek)**：

  * 上层 FFmpeg 请求偏移量 `offset` 时，我们将实际文件指针移至 `offset + dirtyDataLength`。

* **透明解密读取 (Read)**：

  * 上层 FFmpeg 请求读取 `size` 字节时，我们从物理文件的当前位置读取。

  * 如果请求的逻辑数据范围落在 `[0, 1024)` 区间内，我们在 C 代码中直接调用 Apple 原生的 `<CommonCrypto/CommonCrypto.h>` 中的 `CCCryptor`，使用传入的 Key 和 IV 进行 AES-CTR 实时解密。

  * 将解密后的明文（或原本的明文）填充给 FFmpeg 的 buffer。

## 4. 假设与决策 (Assumptions & Decisions)
- **代码存放目录**：所有手搓播放器的相关源码、FFmpeg 编译脚本以及头文件，统一放置在 `/Users/uxin/Desktop/无名高地/fileReadAction/GCSPlayer` 目录下，与现有项目逻辑保持良好的物理隔离。
- **极简原则**：为了确保你能完全掌控代码，FFmpeg 编译脚本和播放器架构将采用最基础、最直白的多线程模型（如 `pthread` 或 `NSThread`），不引入过多的设计模式，专注于跑通流水线。

* **加密策略对齐**：由于项目使用的是 `AES-CTR` 模式，解密 1KB 内的任意一段数据只需要知道其在密文中的偏移量即可独立解密，这完美契合 `AVIOContext` 可能会分块读取文件头的特性。

* **内存安全**：C 与 Swift 混编时，内存管理是重灾区，所有 `AVPacket` 和 `AVFrame` 必须确保成对的 `av_packet_unref` 和 `av_frame_free`。

## 5. 验证步骤 (Verification Steps)

1. 运行 `build_ffmpeg.sh`，检查是否成功生成 `libavcodec.a`, `libavformat.a` 等库。
2. 运行纯净版本地 MP4，验证画面和声音是否正常同步播放。
3. 运行现有的 `FileVariantWriter.swift` 中的方法，生成一个带有脏数据和 AES-CTR 加密头部的测试 MP4。
4. 将该测试 MP4、脏数据长度、Key、IV 传给手搓播放器，验证是否能够秒开且播放正常（无花屏、无杂音）。

