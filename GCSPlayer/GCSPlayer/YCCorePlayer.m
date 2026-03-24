#import "YCCorePlayer.h"
#import "YCAudioPlayer.h"
#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libswscale/swscale.h>
#import <libswresample/swresample.h>
#import <libavutil/avutil.h>
#import <libavutil/time.h>
#import <CommonCrypto/CommonCrypto.h>
#import <QuartzCore/QuartzCore.h>
#import <fcntl.h>
#import <unistd.h>

// -----------------------------------------------------------------------------
// [防盗链协议说明] 加密文件的物理结构模型
// -----------------------------------------------------------------------------
// 为了实现高性能的防盗链，我们对原始 MP4 进行了 "格式破坏 + 局部加密" 的混合处理。
// 最终生成的物理文件在磁盘上的结构如下（以脏数据=30字节，加密区=1024字节为例）：
//
// 物理文件起始点 (Offset: 0)
// |
// |--- 第 1 段：脏数据区 (Dirty Data)
// |    长度: dirtyLength (如 30 字节)
// |    内容: 完全随机的无意义噪音。
// |    作用: 破坏 MP4 的格式特征 (Magic Number)，让普通播放器打开即报错。
// |    状态: 明文（不参与 AES 加密）。
// |
// 物理偏移量 (Offset: 30) = 逻辑偏移量 (Offset: 0) <--- FFmpeg 以为的 "文件开头"
// |
// |--- 第 2 段：加密区 (Encrypted Header)
// |    长度: 1024 字节 (1KB)
// |    内容: 原本 MP4 最开头的 1KB 真实数据，被 AES-CTR 加密后的密文。
// |    作用: 即使黑客跳过了脏数据，依然无法解析出关键的 moov/ftyp 盒子。
// |    状态: 密文。
// |
// 物理偏移量 (Offset: 1054) = 逻辑偏移量 (Offset: 1024)
// |
// |--- 第 3 段：明文区 (Plaintext Body)
// |    长度: 剩余的所有字节
// |    内容: 原本 MP4 剩下的所有音视频帧数据。
// |    作用: 保持大文件主体不变，极大节省加密和解密的耗时。
// |    状态: 明文。
// |
// 物理文件结尾 (EOF)
// -----------------------------------------------------------------------------

// --- 自定义 IO 上下文结构体 ---
// 这个结构体是我们传递给 FFmpeg 底层读取回调的 "上下文环境"。
// 里面保存了真实物理文件的描述符(fd)、加密参数以及脏数据的长度。
typedef struct YCIOContext {
    int fd;                 // 物理文件的文件描述符
    int64_t fileSize;       // 物理文件的总大小
    int dirtyLength;        // 头部脏数据的长度（需要跳过的字节数）
    uint8_t key[32];        // AES-CTR 的密钥 (最大支持 256bit，即 32 字节)
    int keyLength;          // 实际密钥长度 (16, 24 或 32)
    uint8_t iv[16];         // AES-CTR 的初始向量 (固定 16 字节)
    BOOL isEncrypted;       // 是否开启了解密逻辑
    
    // 【终极优化：明文缓存】
    // 既然明确知道加密区只有 1KB，我们在初始化时就一次性解密并缓存在这里。
    // 后续 FFmpeg 只要读这前 1KB 的数据，直接从这里 memcpy，彻底告别重复解密和 I/O 开销！
    uint8_t decryptedHeaderCache[1024]; 
} YCIOContext;

// -----------------------------------------------------------------------------
// [核心拦截] FFmpeg 读取数据回调 (Read Callback)
// 当 FFmpeg 解析器（如 MP4 解复用器）需要读取数据时，它不会直接读文件，而是调用这个函数。
// opaque: 就是上面定义的 YCIOContext 指针
// buf: FFmpeg 提供的空内存，我们需要把读到/解密后的数据塞进去
// buf_size: FFmpeg 想要读取的字节数
// 返回值: 实际读取的字节数，如果读到文件末尾返回 AVERROR_EOF
// -----------------------------------------------------------------------------
static int read_packet(void *opaque, uint8_t *buf, int buf_size) {
    YCIOContext *ctx = (YCIOContext *)opaque;
    
    // 1. [事前拍照法] 在读取前，计算当前的 "逻辑偏移量"
    //
    // 关于 lseek(fd, offset, whence) 的硬核知识：
    // 作用：移动或获取底层文件描述符(fd)的读写指针位置。
    // 入参：
    //   - fd: 文件描述符
    //   - offset: 偏移的字节数（这里传 0）
    //   - whence: 基准点。SEEK_CUR 表示"以当前位置为基准"
    // 返回值：执行操作后，指针距离文件开头(物理 0)的绝对字节数。
    //
    // 所以：lseek(fd, 0, SEEK_CUR) 是一个 C 语言中极其经典的 Hacker 用法。
    // 意思是："从当前位置移动 0 个字节"，它的实际效果就是【不移动指针，但返回当前指针所在的物理绝对位置】。
    //
    // 逻辑偏移量 = 物理绝对位置 - 脏数据长度 -> 对 FFmpeg 伪装出来的位置（让 FFmpeg 以为它在读一个没有脏数据的纯净文件，从 0 开始）
    int64_t logicalOffset = lseek(ctx->fd, 0, SEEK_CUR) - ctx->dirtyLength;
    
    // -------------------------------------------------------------------------
    // 【缓存命中判断】
    // -------------------------------------------------------------------------
    if (ctx->isEncrypted && logicalOffset < 1024) {
        // 如果 FFmpeg 想要读取的数据落在了前 1KB 的缓存区内
        
        // 计算本次能从缓存中提供多少数据（不能越界超过 1024）
        int availableCacheLen = (int)(1024 - logicalOffset);
        int copyLen = MIN(buf_size, availableCacheLen);
        
        // 直接从内存缓存中拷贝，零 I/O，零解密开销！
        memcpy(buf, ctx->decryptedHeaderCache + logicalOffset, copyLen);
        
        // 既然我们手动提供了数据，必须把底层的物理文件指针也同步向后推移 copyLen
        // 否则物理指针和逻辑指针就脱节了
        lseek(ctx->fd, copyLen, SEEK_CUR);
        
        // 【关于 "短读 (Short Read)" 策略的硬核知识】
        // 假设 FFmpeg 这次索要 32KB (buf_size=32768)，但我们的缓存只剩下 24 字节了，怎么办？要不要去磁盘里把剩下的 32744 字节读出来拼在一起？
        // 答案是：绝对不要拼接！直接返回 24 即可。这就是 POSIX 标准中经典的 "短读 (Short Read)" 现象。
        // 
        // 短读策略的优势：
        // 1. 在操作系统底层（如读取网络 Socket 或 Pipe），短读是常态，调用方永远不能假定 read() 会返回它要求的完整大小。
        // 2. FFmpeg 的底层 I/O (aviobuf.c) 设计极其健壮。当我们只返回 24 字节时，FFmpeg 会心领神会地收下这 24 字节，然后自动发起第二次 read_packet 请求去要剩下的部分。
        // 3. 避免了在一次回调中处理极其复杂的边界情况（比如缓存读成功了，但接着去读磁盘时发生了错误，此时该返回什么？）。
        //
        // 总结：利用框架的健壮性，采用短读策略，代码最精简、最安全。
        return copyLen;
    }
    
    // -------------------------------------------------------------------------
    // 【正常磁盘读取分支】
    // 当没有加密，或者读取位置超过了 1024 时，走最纯粹的透传读取
    // -------------------------------------------------------------------------
    int bytesRead = (int)read(ctx->fd, buf, buf_size);
    if (bytesRead <= 0) {
        return AVERROR_EOF; // 读完了
    }
    
    return bytesRead;
}

// -----------------------------------------------------------------------------
// [核心拦截] FFmpeg 寻址回调 (Seek Callback)
// 当 FFmpeg 需要跳转（比如解析 MP4 moov 树，或者用户拖动进度条）时，调用此函数。
// offset: 逻辑偏移量
// whence: 跳转模式。FFmpeg 会传入以下 4 种模式之一：
//   1. SEEK_SET: 绝对定位。把指针移动到距离"逻辑文件开头" offset 字节处。
//   2. SEEK_CUR: 相对定位。把指针移动到距离"当前位置" offset 字节处。
//   3. SEEK_END: 尾部定位。把指针移动到距离"文件末尾" offset 字节处（offset 通常为负数）。
//   4. AVSEEK_SIZE: (FFmpeg 魔改模式) 不移动指针，仅仅询问"这个逻辑文件总共有多大"。
// 返回值: 最终的逻辑偏移量，或者文件总大小。
// -----------------------------------------------------------------------------
static int64_t seek_packet(void *opaque, int64_t offset, int whence) {
    YCIOContext *ctx = (YCIOContext *)opaque;
    
    // FFmpeg 特殊用法：询问文件有多大。我们告诉它：物理大小减去脏数据大小。
    if (whence == AVSEEK_SIZE) {
        return ctx->fileSize - ctx->dirtyLength;
    }
    
    int64_t targetPhysicalOffset = offset;
    
    // 逻辑偏移 -> 物理偏移 的转换
    if (whence == SEEK_SET) {
        // 绝对定位：FFmpeg 想跳到逻辑 0，实际上我们要跳到物理的 dirtyLength
        targetPhysicalOffset = offset + ctx->dirtyLength;
    } else if (whence == SEEK_END) {
        // 尾部相对定位
        targetPhysicalOffset = ctx->fileSize + offset;
    }
    // SEEK_CUR (当前位置相对定位) 直接透传给底层 lseek，因为相对位移是一致的
    
    // 执行底层物理跳转，并把物理结果转换回逻辑偏移量返回给 FFmpeg
    return lseek(ctx->fd, targetPhysicalOffset, whence) - ctx->dirtyLength;
}

// --- Player 实现 ---
@interface YCCorePlayer () <YCAudioPlayerDelegate> {
    AVFormatContext *_formatContext;        // FFmpeg 解复用上下文（用于剥离 MP4）
    AVCodecContext *_videoCodecContext;     // 视频解码器上下文
    AVCodecContext *_audioCodecContext;     // 音频解码器上下文
    
    AVIOContext *_avioContext;              // 自定义 IO 上下文 (包装了 read_packet)
    YCIOContext *_ycIOContext;              // 我们自己定义的物理层信息
    
    int _videoStreamIndex;                  // 视频流在 MP4 中的索引
    int _audioStreamIndex;                  // 音频流在 MP4 中的索引
    
    BOOL _isStop;
    NSThread *_readThread;                  // 专门负责读取磁盘文件并拆包的线程
    NSThread *_videoDecodeThread;           // 专门负责解码视频和音视频同步的线程
    
    // 简易 Packet 队列 (生产者-消费者模型)
    // 生产：readThread 读出数据放入队列
    // 消费：videoDecodeThread 和 audioRenderCallback 取出数据进行解码
    NSMutableArray<NSValue *> *_videoPacketQueue;
    NSMutableArray<NSValue *> *_audioPacketQueue;
    NSCondition *_videoCondition;           // 视频队列锁
    NSCondition *_audioCondition;           // 音频队列锁
    
    // 音频重采样上下文
    SwrContext *_swrContext;
    YCAudioPlayer *_audioPlayer;            // 封装的 AudioUnit 播放器
    
    // 音视频同步核心：主时钟 (Master Clock)
    // 我们采用 "视频同步到音频" 的策略，这里记录当前音频播放到了哪个时间点
    double _audioClock; 
}
@end

@implementation YCCorePlayer

- (instancetype)init {
    if (self = [super init]) {
        _videoPacketQueue = [NSMutableArray array];
        _audioPacketQueue = [NSMutableArray array];
        _videoCondition = [[NSCondition alloc] init];
        _audioCondition = [[NSCondition alloc] init];
    }
    return self;
}

- (void)prepareToPlay:(NSString *)filePath dirtyLength:(int)dirtyLength aesKey:(NSData *)aesKey aesIV:(NSData *)aesIV {
    _isStop = NO;
    _audioClock = 0.0;
    
    _formatContext = avformat_alloc_context();
    
    // -------------------------------------------------------------------------
    // 1. 设置自定义 IO (核心魔法)
    // -------------------------------------------------------------------------
    _ycIOContext = malloc(sizeof(YCIOContext));
    _ycIOContext->fd = open([filePath UTF8String], O_RDONLY);
    if (_ycIOContext->fd < 0) {
        NSLog(@"[YCCorePlayer] 无法打开文件物理路径");
        return;
    }
    // 获取真实文件大小，并将文件指针跳过脏数据
    _ycIOContext->fileSize = lseek(_ycIOContext->fd, 0, SEEK_END);
    lseek(_ycIOContext->fd, dirtyLength, SEEK_SET); 
    
    _ycIOContext->dirtyLength = dirtyLength;
    _ycIOContext->isEncrypted = (aesKey != nil && aesIV != nil);
    if (_ycIOContext->isEncrypted) {
        memcpy(_ycIOContext->key, aesKey.bytes, aesKey.length);
        _ycIOContext->keyLength = (int)aesKey.length;
        memcpy(_ycIOContext->iv, aesIV.bytes, MIN(16, aesIV.length));
        
        // 【初始化时一次性解密并缓存】
        uint8_t fullEncryptedData[1024];
        read(_ycIOContext->fd, fullEncryptedData, 1024);
        
        size_t outLen = 0;
        CCCryptorStatus status = CCCrypt(kCCDecrypt, 
                                         kCCAlgorithmAES, 
                                         kCCModeCTR | kCCModeOptionCTR_BE,
                                         _ycIOContext->key, _ycIOContext->keyLength,
                                         _ycIOContext->iv,
                                         fullEncryptedData, 1024,
                                         _ycIOContext->decryptedHeaderCache, 1024,
                                         &outLen);
        if (status != kCCSuccess) {
            NSLog(@"[YCCorePlayer] 初始解密失败！");
        }
        
        // 记得把物理指针拨回到明文逻辑数据的起点（即物理文件的 dirtyLength 处）
        // 这样 read_packet 第一次调用时才能无缝衔接
        lseek(_ycIOContext->fd, dirtyLength, SEEK_SET);
    }
    
    // 给 FFmpeg 分配一个 32KB 的读取缓冲区 ("空盆子")，必须使用 av_malloc 分配
    uint8_t *avioBuffer = (uint8_t *)av_malloc(32768);
    
    // avio_alloc_context：将底层数据读取的控制权，从 FFmpeg 原生系统接管到我们手写的回调函数中。
    // 参数说明：
    // 1. avioBuffer: FFmpeg 用于暂存读取数据的内部缓冲区
    // 2. 32768: 缓冲区大小 (32KB 是官方推荐的默认最佳性能值)
    // 3. 0: 表示这是一个只读 (Read-Only) 上下文；若为 1 则表示可写
    // 4. _ycIOContext: 透传给回调函数的 "黑盒" (opaque)，包含 fd 和解密信息
    // 5. read_packet: 负责读取数据的函数指针
    // 6. NULL: 负责写入数据的函数指针 (我们不需要写)
    // 7. seek_packet: 负责寻址跳转的函数指针
    _avioContext = avio_alloc_context(avioBuffer, 32768, 0, _ycIOContext, read_packet, NULL, seek_packet);
    
    // 最关键的一步：将我们定制的 IO 上下文 (pb: Protocol Buffer) 强行塞给格式总管。
    // 这样后续 FFmpeg 解析时，就不会自己去读硬盘，而是无脑调用我们的 read_packet。
    _formatContext->pb = _avioContext;
    
    // -------------------------------------------------------------------------
    // 2. 打开文件 (解复用 Demuxing)
    // -------------------------------------------------------------------------
    // "ycenc://custom" 只是一个假名字，因为底层的 IO 已经被我们接管了
    int ret = avformat_open_input(&_formatContext, "ycenc://custom", NULL, NULL);
    if (ret != 0) {
        NSLog(@"[YCCorePlayer] avformat_open_input 失败: %d", ret);
        return;
    }
    
    // 探测文件内部的流信息 (非常关键！)
    // 为什么必须探测？
    // avformat_open_input 只是读取了文件的容器头部（如 MP4 的 moov），它只知道这里有视频和音频。
    // 但往往头部信息是不全的。如果不调用 find_stream_info，你可能拿不到：
    // 1. 视频的真实宽高、像素格式、帧率 (FPS) 和 时间基 (Time Base，用于音视频同步)。
    // 2. 解码极其依赖的 "extradata"（比如 H.264 的 SPS/PPS 序列参数集，没有它解码器根本打不开）。
    // find_stream_info 会在底层悄悄"试读"甚至"试解码"开头的几个 Packet，把这些关键信息探测出来并填入 Context 中。
    avformat_find_stream_info(_formatContext, NULL);
    
    // -------------------------------------------------------------------------
    // 3. 寻找音视频流并初始化对应的解码器工作台 (AVCodecContext)
    // -------------------------------------------------------------------------
    // 一个 MP4 文件就像一条多车道高速公路，里面可能包含视频流、音频流、字幕流。
    // 我们需要遍历所有流，找到我们需要的视频车道和音频车道，并记录它们的索引 (Index)。
    _videoStreamIndex = -1;
    _audioStreamIndex = -1;
    for (int i = 0; i < _formatContext->nb_streams; i++) {
        AVStream *stream = _formatContext->streams[i];
        
        // 找到了第一条视频流
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && _videoStreamIndex == -1) {
            _videoStreamIndex = i;
            // 为这条视频流搭建专属的解码工作台
            _videoCodecContext = [self setupCodecContext:stream];
            
        // 找到了第一条音频流
        } else if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && _audioStreamIndex == -1) {
            _audioStreamIndex = i;
            // 为这条音频流搭建专属的解码工作台
            _audioCodecContext = [self setupCodecContext:stream];
        }
    }
    
    // -------------------------------------------------------------------------
    // 4. 设置音频播放器 (AudioUnit) 和 重采样上下文 (SwrContext)
    // -------------------------------------------------------------------------
    // 完整的音频播放链路包含三步：
    // 1. 解码：使用 _audioCodecContext 将 AAC 解码为粗糙的 PCM（可能是 48kHz, Float32, 平面格式）。
    // 2. 重采样：使用 _swrContext 将粗糙的 PCM 翻译成硬件要求的标准 PCM（44.1kHz, S16, 交错格式）。
    // 3. 播放：初始化 YCAudioPlayer，等待底层喇叭硬件主动来拉取数据发声。
    if (_audioCodecContext) {
        [self setupAudioPlayer];
    }
    
    // -------------------------------------------------------------------------
    // 5. 启动流水线线程
    // -------------------------------------------------------------------------
    // 读文件线程 (Demux Thread)
    // 为什么需要单独的读线程？
    // 读取本地文件或网络流是一个 I/O 密集型操作，随时可能因为磁盘寻道或网络波动发生阻塞。
    // 如果把读取操作放在主线程，会直接卡死 UI；如果和解码放在同一个线程，读数据的阻塞会导致解码器饿死（没数据可解），进而导致播放卡顿。
    _readThread = [[NSThread alloc] initWithTarget:self selector:@selector(readLoop) object:nil];
    _readThread.name = @"YCPlayer_ReadThread";
    [_readThread start];
    
    // 视频解码与渲染线程 (Video Decode Thread)
    // 为什么需要单独的解码线程？
    // 视频解码（如 H.264 转 YUV）是一个极其耗时的 CPU 密集型操作。
    // 它必须独立于读线程，形成“生产者（读线程）- 消费者（解码线程）”的经典模型，利用 PacketQueue 作为缓冲。
    // （注：音频解码没有单开线程，是因为在本架构中，音频由底层 AudioUnit 的实时高优回调线程直接驱动，在回调里顺手做了解码和重采样）
    if (_videoCodecContext) {
        _videoDecodeThread = [[NSThread alloc] initWithTarget:self selector:@selector(videoDecodeLoop) object:nil];
        _videoDecodeThread.name = @"YCPlayer_VideoDecodeThread";
        [_videoDecodeThread start];
    }
}

- (AVCodecContext *)setupCodecContext:(AVStream *)stream {
    // 1. 找师傅：根据流的编码类型 (如 H.264/AAC)，去 FFmpeg 的注册库里找对应的解码器 (AVCodec)
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) return NULL;
    
    // 2. 建工作台：为这个解码器分配一个上下文环境 (AVCodecContext)
    AVCodecContext *codecCtx = avcodec_alloc_context3(codec);
    if (!codecCtx) return NULL;
    
    // 3. 抄图纸：将从文件头部探测到的编码参数 (如视频宽高、音频采样率等) 拷贝到工作台上
    avcodec_parameters_to_context(codecCtx, stream->codecpar);
    
    // 如果是视频，强制要求输出 YUV420P 以避免硬解返回不支持的 PixelBuffer 格式导致崩溃
    if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
        // 这里暂时不启用 hw_device_ctx，强制走软解，以保证我们能拿到 YUV420P 数据
        // 如果要支持 VideoToolbox，需要额外配置 AVBufferRef *hw_device_ctx
    }
    
    // 4. 正式开工：打开解码器，准备接收数据
    if (avcodec_open2(codecCtx, codec, NULL) < 0) {
        avcodec_free_context(&codecCtx);
        return NULL;
    }
    return codecCtx;
}

- (void)setupAudioPlayer {
    // 设置重采样上下文 (SwrContext)
    // 为什么需要重采样？
    // 因为 MP4 里的音频采样率可能是 48000Hz，格式可能是 Float32 (AV_SAMPLE_FMT_FLTP)。
    // 但我们的 AudioUnit 硬件配置只认 44100Hz, 16bit 交错格式 (AV_SAMPLE_FMT_S16)。
    // 所以必须在解码后、送给扬声器前，用 FFmpeg 的 swresample 模块做一次转换。
    AVChannelLayout out_ch_layout;
    av_channel_layout_default(&out_ch_layout, 2); // 强制输出双声道立体声
    
    swr_alloc_set_opts2(&_swrContext,
                        &out_ch_layout, AV_SAMPLE_FMT_S16, 44100, // 目标格式：双声道，S16，44.1kHz
                        &_audioCodecContext->ch_layout, _audioCodecContext->sample_fmt, _audioCodecContext->sample_rate, // 源格式：从解码器上下文中获取
                        0, NULL);
    swr_init(_swrContext);
    
    _audioPlayer = [[YCAudioPlayer alloc] initWithSampleRate:44100 channels:2];
    _audioPlayer.delegate = self;
    [_audioPlayer play];
}

// -----------------------------------------------------------------------------
// [流水线 1] 文件读取与解复用 (Demuxing)
// 从文件中读取 AVPacket (包含压缩的 H.264/AAC 数据)，然后分发到音视频各自的队列中。
// -----------------------------------------------------------------------------
- (void)readLoop {
    AVPacket *packet = av_packet_alloc();
    while (!_isStop) {
        // 从格式上下文中读取一帧压缩数据
        // 疑问：av_read_frame 是怎么做到不多不少正好取出一帧的？帧大小是固定的吗？
        // 答案：视频帧（如 H.264）的大小绝对不是固定的（I帧极大，P/B帧极小），音频帧（如 AAC）大小也可能不同。
        // 它能精准取出一帧，完全归功于“容器（Container）的索引机制”或“流（Stream）的特征码”：
        // 1. 对于 MP4 等“有强索引”的容器：
        //    MP4 头部有一个叫 `stsz` (Sample Size Box) 的表，记录了每一帧的精确字节数。
        //    还有一个叫 `stco` (Chunk Offset Box) 的表，记录了每一帧在文件中的绝对物理偏移量。
        //    av_read_frame 其实是先去查这个表：“第 500 帧在 offset=10240 处，长度是 3500 字节”，然后直接精准 lseek 并 read 出这 3500 字节。
        // 2. 对于 TS/FLV/H.264 裸流 等“无全局索引”的格式：
        //    FFmpeg 只能一边读一边找“特征码（Start Code）”。比如 H.264 的每一帧都以 `00 00 00 01` 或 `00 00 01` 开头。
        //    av_read_frame 会在底层拼命读，直到发现下一个 `00 00 00 01`，就知道上一帧结束了，然后把中间这段切下来作为一帧返回。
        int ret = av_read_frame(_formatContext, packet);
        if (ret == AVERROR_EOF) {
            break; // 文件读完
        }
        if (ret < 0) continue; // 读取出错或重试
        
        // 克隆一份 Packet，因为原始 packet 马上要被复用了
        // 疑问：为什么要克隆？不克隆直接把 packet 塞进数组不行吗？
        // 答案：绝对不行！这涉及到 FFmpeg 底层极其重要的【引用计数（Reference Counting）与内存复用机制】。
        // 1. `packet` 是在 while 循环外面通过 `av_packet_alloc()` 申请的一块内存壳子。
        // 2. 每次调用 `av_read_frame` 时，FFmpeg 并不是给你一块新内存，而是把新读到的数据填进这个老壳子里。
        //    如果你直接把 `packet` 塞进数组，等下一次循环 `av_read_frame` 执行时，你数组里那个 `packet` 指向的数据就会被无情地覆盖篡改掉！
        //    结果就是：你的队列里存了 100 个 packet，但它们指向的永远是最新读出来的那一帧数据。
        // 3. `av_packet_clone` 的作用：
        //    它并不是把几百 KB 的数据重新 `memcpy` 一遍（那样太慢了），而是利用了 C 语言底层的引用计数（Refcount）。
        //    它会创建一个新的壳子，但内部的数据指针依然指向同一块内存，同时把那块内存的“引用计数 +1”。
        //    这样一来，即使外面的 `packet` 被下一次 `read` 刷新了或者被释放了，你塞进队列里的 `copyPkt` 依然安全且独立。
        AVPacket *copyPkt = av_packet_clone(packet);
        
        // 按照流类型，分发到不同的队列中
        if (packet->stream_index == _videoStreamIndex) {
            // 疑问：为什么这里要加锁？NSCondition 的 wait 和 signal 是干嘛的？
            // 答案：这是经典的“生产者-消费者模型”的实现。_readThread 是生产者，_videoDecodeThread 是消费者。
            // 1. [互斥锁 lock]：_videoPacketQueue 是一个普通的 NSMutableArray，不是线程安全的。
            //    现在有两个线程（一个往里塞，一个往外拿）同时操作它，如果不加 lock，App 瞬间就会 Crash。
            [_videoCondition lock];
            
            // 2. [防撑死 wait]：限制队列大小，避免 OOM (如果视频解得太慢，读得太快，内存会被撑爆)
            //    疑问：这里用 while 不会死循环把 CPU 跑满吗？
            //    答案：绝对不会！因为 `[_videoCondition wait]` 不是普通的空转（像 `while(true) {}` 那样）。
            //    当线程执行到 `wait` 时，操作系统会直接把这个线程**剥夺 CPU 调度权，进入休眠状态（Sleeping）**。
            //    此时这个线程消耗的 CPU 是 **0%**。
            //    直到消费者调用了 `signal`，操作系统才会把它唤醒，唤醒后它会再次执行 while 条件判断。
            //    那为什么必须用 while 而不是 if？
            //    因为系统底层有一种现象叫“虚假唤醒（Spurious Wakeup）”，即线程可能在没有收到 signal 的情况下意外醒来。
            //    （追问：虚假唤醒是系统 Bug 吗？如果没有它是不是就能用 if？）
            //    （回答：它绝对不是 Bug，而是操作系统（如 Linux/Unix）为了追求【极致的并发性能】而故意做出的妥协设计！
            //     在多核 CPU 下，当一个 signal 发出时，系统如果要保证“绝对只有一个线程被唤醒且绝对是因为这个 signal”，
            //     内核就需要引入非常重度的全局锁，这会让整个操作系统的线程调度变慢。
            //     于是 POSIX 标准规定：允许条件变量偶尔发生“意外唤醒”，以此换取系统极高的调度性能。
            //     就算没有虚假唤醒，其实也不能用 if。因为如果有【多个消费者】都在等，一个 signal 唤醒了多个消费者（惊群效应），
            //     第一个消费者把数据拿走了，第二个消费者醒来如果不 `while` 重新检查，直接拿就会越界崩溃！）
            //    用 while 可以保证：就算你意外醒了，只要条件（count > 100）还满足，你就给我接着回去睡！
            // 在所有的大厂代码、所有的开源库（不管是 Java、C++ 还是 OC）中，只要看到 wait() ，它的外面 必须且永远 套着一个 while ！
            while (_videoPacketQueue.count > 100 && !_isStop) {
                [_videoCondition wait];
            }
            
            if (!_isStop) {
                // 3. [入队]：安全地把数据塞进队列
                [_videoPacketQueue addObject:[NSValue valueWithPointer:copyPkt]];
                
                // 4. [防饿死 signal]：唤醒消费者
                //    有可能消费者（解码线程）之前发现队列空了，正在那边 `wait` 睡觉。
                //    现在我们新塞进了一个数据，赶紧调 `signal` 踹消费者一脚：“别睡了，来活了，快起来解码！”
                [_videoCondition signal]; 
            } else {
                av_packet_free(&copyPkt);
            }
            // 5. [解锁 unlock]：操作完队列，把锁释放，让消费者可以去拿数据
            [_videoCondition unlock];
        } else if (packet->stream_index == _audioStreamIndex) {
            [_audioCondition lock];
            // 限制队列大小，避免 OOM
            while (_audioPacketQueue.count > 100 && !_isStop) {
                [_audioCondition wait];
            }
            if (!_isStop) {
                [_audioPacketQueue addObject:[NSValue valueWithPointer:copyPkt]];
                [_audioCondition signal]; // 唤醒正在等待的音频解码线程
            } else {
                av_packet_free(&copyPkt);
            }
            [_audioCondition unlock];
        } else {
            // 如果既不是视频也不是音频（比如字幕流），直接丢弃
            av_packet_free(&copyPkt);
        }
        // 解除对 packet 内部数据的引用，准备下一次循环读取
        av_packet_unref(packet);
    }
    av_packet_free(&packet);
}

// -----------------------------------------------------------------------------
// [流水线 2] 视频解码与同步渲染 (Video Decoding & Sync)
// 从视频队列中取出 Packet -> 解码成 YUV Frame -> 与音频时钟对齐 -> 回调给 Metal 渲染
// -----------------------------------------------------------------------------
- (void)videoDecodeLoop {
    AVFrame *frame = av_frame_alloc(); // 存放解码后的 YUV 数据
    
    // 疑问：这些时钟机制是什么？PTS 是什么？
    // 答案：这是播放器最核心的【音视频同步（A/V Sync）机制】。
    // 1. 什么是 PTS？
    //    PTS (Presentation Time Stamp) 翻译过来叫“显示时间戳”。
    //    比如一帧画面的 PTS 是 2.500 秒，意思就是：导演（编码器）规定，当电影播放到第 2.5 秒的时候，这帧画面必须立刻出现在屏幕上！
    // 2. 为什么不能像放幻灯片一样，解出一帧就立刻画一帧？
    //    因为如果解一帧画一帧，CPU 解得快，原本 10 秒的视频可能 2 秒就全画完了（变成快进鬼畜）；如果 CPU 卡了，又会变成慢动作。
    //    更可怕的是，视频和音频是分两条线跑的，如果没有统一的指挥，就会出现“嘴型对不上声音”的灾难。
    // 3. 这里的时钟机制（Audio Master Clock）是怎么工作的？
    //    - 我们认音频为“大哥（基准时钟）”。因为人对声音卡顿极度敏感，对画面掉帧相对迟钝。
    //    - 每次解码出一帧画面，我们拿到它的 PTS（比如这帧该在 5.0 秒显示）。
    //    - 我们去问音频大哥：“大哥，你现在播到第几秒了？”（获取 currentAudioTime）。
    //    - 比较：
    //      - 如果大哥才播到 4.8 秒：说明视频跑太快了，视频线程必须原地 `usleep` 睡 0.2 秒，等大哥赶上来。
    //      - 如果大哥已经播到 5.2 秒了：说明视频太慢了（CPU解不动了），那这帧画面已经过期了，直接丢弃（Drop Frame）！
    //    （追问：视频跑慢时，会直接跳过 5.3, 5.4 的压缩包，直接去解 5.5 的包吗？）
    //    （回答：绝对不能！因为 H.264 是有【帧间依赖】的。5.5 秒的 P 帧可能依赖于 5.3 秒的帧。
    //     如果直接把 5.3 和 5.4 的压缩包扔掉不解，5.5 秒解出来绝对是满屏马赛克（花屏）。
    //     真正的“跳帧（Drop Frame）”策略是：5.3 和 5.4 的包依然要送给 FFmpeg 去**解码（耗 CPU）**，
    //     但解出 YUV 发现过期后，**不送给 Metal 去渲染（省 GPU 和屏幕刷新时间）**。
    //     这就是工业界常说的 "Decode but not Render"。）
            
    // 记录上一帧的显示时间戳和系统时间，用于更精确的帧间延时计算
    double lastFramePts = -1.0;
    double lastFrameTime = -1.0;
    
    while (!_isStop) {
        AVPacket *packet = NULL;
        
        // 1. 从队列中取出一个压缩的视频 Packet
        [_videoCondition lock];
        while (_videoPacketQueue.count == 0 && !_isStop) {
            [_videoCondition wait]; // 队列空了，睡觉等 readLoop 叫醒
        }
        if (_isStop) {
            [_videoCondition unlock];
            break;
        }
        packet = [_videoPacketQueue.firstObject pointerValue];
        [_videoPacketQueue removeObjectAtIndex:0];
        [_videoCondition signal]; // 通知 readLoop 队列有空位了，可以继续读了
        [_videoCondition unlock];
        
        if (packet && _videoCodecContext) {
            // 2. 将压缩数据送入解码器
            int send_ret = avcodec_send_packet(_videoCodecContext, packet);
            if (send_ret == 0 || send_ret == AVERROR(EAGAIN)) {
                
                // 3. 循环拉取解码后的画面 (一帧 Packet 可能会解出多帧 Frame，或者因为 B 帧的存在要等几个 Packet 才出 Frame)
                while (avcodec_receive_frame(_videoCodecContext, frame) == 0) {
                    
                    // --- 音视频同步核心逻辑 ---
                    
                    AVStream *stream = _formatContext->streams[_videoStreamIndex];
                    // 获取当前帧的 PTS (显示时间戳)
                    double pts = frame->best_effort_timestamp == AV_NOPTS_VALUE ? frame->pts : frame->best_effort_timestamp;
                    // 将时间戳乘以时间基 (Time Base)，换算成绝对的秒数
                    pts *= av_q2d(stream->time_base);
                    
                    // diff = 视频时间 - 音频时间
                    double diff = pts - _audioClock;
                    
                    // 情景 A：如果音频时钟还没有走（比如刚开始播放没有声音），或者差值过大（发生 Seek），回退到按视频自身帧率休眠
                    if (_audioClock <= 0 || fabs(diff) > 5.0) {
                        double currentFrameTime = CACurrentMediaTime();
                        if (lastFramePts >= 0 && lastFrameTime >= 0) {
                            double ptsDiff = pts - lastFramePts; // 两帧之间的理论时间差 (比如 0.04 秒)
                            double targetTime = lastFrameTime + ptsDiff; // 这一帧应该在系统时间的什么时候显示
                            double waitTime = targetTime - currentFrameTime; // 还需要等多久
                            if (waitTime > 0 && waitTime < 1.0) {
                                usleep((useconds_t)(waitTime * 1000000));
                            }
                        }
                        lastFramePts = pts;
                        lastFrameTime = CACurrentMediaTime();
                        
                    // 情景 B：视频跑得比音频快 (diff > 0)，让视频线程睡一会儿等音频
                    } else if (diff > 0.01 && diff < 1.0) { 
                        usleep((useconds_t)(diff * 1000000));
                        lastFramePts = pts;
                        lastFrameTime = CACurrentMediaTime();
                        
                    // 情景 C：视频跑得比音频慢 (diff < 0)，即视频落后了
                    } else if (diff < -0.01) {
                        // 工业级做法是：如果是 P/B 帧，直接 drop 丢弃不渲染，继续解下一帧去追赶音频。
                        // 这里作为极简教学，我们只打印日志，并且不进行任何 usleep，让它全速渲染去追赶。
                        NSLog(@"[YCCorePlayer] 视频落后音频 %f 秒，全速解码追赶", diff);
                        lastFramePts = pts;
                        lastFrameTime = CACurrentMediaTime();
                    }
                    
                    // 4. 渲染 YUV 数据
                    if (self.videoDelegate && (frame->format == AV_PIX_FMT_YUV420P || frame->format == AV_PIX_FMT_VIDEOTOOLBOX) && frame->width > 0 && frame->height > 0) {
                        
                        if (frame->format != AV_PIX_FMT_YUV420P) {
                            // 为了简化 Metal 渲染，我们当前强制要求解码器输出 YUV420P 格式
                            continue;
                        }
                        
                        int width = frame->width;
                        int height = frame->height;
                        int yStride = frame->linesize[0]; // Y 分量每行的字节数 (通常大于等于 width，用于内存对齐)
                        int uStride = frame->linesize[1];
                        int vStride = frame->linesize[2];
                        
                        // 【内存安全】
                        // 因为我们将数据丢到主线程去渲染（dispatch_async），而 FFmpeg 马上要在下一轮循环中复用 frame->data。
                        // 如果不拷贝，主线程渲染时就会发生数据撕裂甚至野指针崩溃。
                        // 所以必须在这里把 YUV 三个分量 deep copy 出来。
                        if (yStride > 0 && uStride > 0 && vStride > 0 && height > 0) {
                            uint8_t *yData = malloc(yStride * height);
                            uint8_t *uData = malloc(uStride * height / 2);
                            uint8_t *vData = malloc(vStride * height / 2);
                            
                            if (yData && uData && vData && frame->data[0] && frame->data[1] && frame->data[2]) {
                                memcpy(yData, frame->data[0], yStride * height);
                                memcpy(uData, frame->data[1], uStride * height / 2);
                                memcpy(vData, frame->data[2], vStride * height / 2);
                                
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [self.videoDelegate renderVideoFrameY:yData
                                                                        U:uData
                                                                        V:vData
                                                                    width:width
                                                                   height:height
                                                                  yStride:yStride
                                                                  uStride:uStride
                                                                  vStride:vStride];
                                    // 渲染完毕后，千万别忘了释放我们刚才 malloc 的内存！
                                    free(yData);
                                    free(uData);
                                    free(vData);
                                });
                            } else {
                                if (yData) free(yData);
                                if (uData) free(uData);
                                if (vData) free(vData);
                            }
                        }
                    }
                }
            }
            av_packet_free(&packet);
        }
    }
    av_frame_free(&frame);
}

// --- Audio Player Delegate ---
- (int)readAudioData:(uint8_t *)data length:(int)length {
    if (_isStop || !_audioCodecContext) {
        memset(data, 0, length);
        return length;
    }
    
    static AVFrame *audioFrame = NULL;
    if (!audioFrame) audioFrame = av_frame_alloc();
    
    int totalBytesRead = 0;
    
    while (totalBytesRead < length && !_isStop) {
        AVPacket *packet = NULL;
        [_audioCondition lock];
        if (_audioPacketQueue.count > 0) {
            packet = [_audioPacketQueue.firstObject pointerValue];
            [_audioPacketQueue removeObjectAtIndex:0];
            [_audioCondition signal]; // 通知 readLoop 队列有空位了
        }
        [_audioCondition unlock];
        
        if (!packet) {
            // 如果队列为空，且解码线程还没结束，可以选择等待一小会
            // 为了避免阻塞 AudioUnit 回调过久导致系统异常，我们只做非常短暂的等待，或者直接 break 填充静音
            break; 
        }
        
        int send_ret = avcodec_send_packet(_audioCodecContext, packet);
        if (send_ret == 0 || send_ret == AVERROR(EAGAIN)) {
            while (avcodec_receive_frame(_audioCodecContext, audioFrame) == 0) {
                // 更新音频时钟
                AVStream *stream = _formatContext->streams[_audioStreamIndex];
                _audioClock = audioFrame->pts * av_q2d(stream->time_base);
                
                // 重采样到 S16 44100Hz 2Ch
                if (_swrContext) {
                    int outSamples = swr_get_out_samples(_swrContext, audioFrame->nb_samples);
                    int outBytes = outSamples * 2 * 2; // 16bit(2 bytes) * 2 channels
                    
                    if (totalBytesRead + outBytes <= length) {
                        uint8_t *outData[1] = { data + totalBytesRead };
                        swr_convert(_swrContext, outData, outSamples, (const uint8_t **)audioFrame->data, audioFrame->nb_samples);
                        totalBytesRead += outBytes;
                    }
                }
            }
        }
        av_packet_free(&packet);
    }
    
    // 补齐静音数据，防止 AudioConverter 报错 "ProduceOutput: produced only 0 of 512 requested packets"
    if (totalBytesRead < length) {
        memset(data + totalBytesRead, 0, length - totalBytesRead);
        totalBytesRead = length;
    }
    
    return totalBytesRead;
}

- (void)stop {
    _isStop = YES;
    [_audioPlayer stop];
    
    [_videoCondition lock];
    [_videoCondition broadcast];
    [_videoCondition unlock];
    
    [_audioCondition lock];
    [_audioCondition broadcast];
    [_audioCondition unlock];
}

@end
