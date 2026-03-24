#import "YCAudioPlayer.h"
#import <AVFoundation/AVFoundation.h>

static const AudioUnitElement kOutputBus = 0;

@interface YCAudioPlayer () {
    AudioUnit _audioUnit;
    BOOL _isPlaying;
}
@end

// -----------------------------------------------------------------------------
// [核心组件] AudioUnit 音频渲染器
// AudioUnit 是 iOS 最底层的音频播放接口，它采用 "Pull (拉取)" 模式。
// 即：系统硬件的喇叭需要发声时，会主动调用一个回调函数向我们要 PCM 数据。
// -----------------------------------------------------------------------------

@implementation YCAudioPlayer

- (instancetype)initWithSampleRate:(Float64)sampleRate channels:(UInt32)channels {
    self = [super init];
    if (self) {
        // 1. 设置 AudioSession，告诉 iOS 系统我们要 "播放" 声音
        [self setupAudioSession];
        // 2. 配置 AudioUnit 硬件参数
        [self setupAudioUnitWithSampleRate:sampleRate channels:channels];
    }
    return self;
}

- (void)setupAudioSession {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    // 设置为 Playback 类别，这样即使在静音模式下也能出声，并且支持后台播放（如果配置了Info.plist）
    [session setCategory:AVAudioSessionCategoryPlayback error:&error];
    [session setActive:YES error:&error];
}

- (void)setupAudioUnitWithSampleRate:(Float64)sampleRate channels:(UInt32)channels {
    // 1. 描述 AudioComponent (寻找系统的音频输出组件)
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO; // RemoteIO 是最底层的扬声器/耳机输出接口
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    
    // 2. 获取 AudioComponent 并实例化 AudioUnit
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    AudioComponentInstanceNew(component, &_audioUnit);
    
    // 3. 设置音频数据格式 (极其关键)
    // 我们这里固定向系统提供 S16 (Signed 16-bit) 交错模式 (Interleaved) 的 PCM 数据。
    // 这也是我们让 FFmpeg 的 SwrContext 最终转换出的格式。
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format)); // 必须清零，否则会有随机脏数据导致配置失败
    format.mSampleRate = sampleRate;    // 采样率，例如 44100
    format.mFormatID = kAudioFormatLinearPCM;
    // 注意：如果是交错模式（Interleaved，即左右声道数据交替排列 LRLRLR），就不要设置 NonInterleaved 标志
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mFramesPerPacket = 1;        // PCM 格式一包就是一帧
    format.mChannelsPerFrame = channels; // 通道数，例如 2 (立体声)
    format.mBitsPerChannel = 16;        // 位深，16 bit
    // 计算公式：每帧字节数 = (位深/8) * 通道数。例如 16bit 2声道 = 2 * 2 = 4 字节
    format.mBytesPerFrame = (format.mBitsPerChannel / 8) * format.mChannelsPerFrame;
    format.mBytesPerPacket = format.mBytesPerFrame * format.mFramesPerPacket;
    
    // 将这个格式设置给 AudioUnit 的输入端 (我们要把数据塞进它的 Input)
    AudioUnitSetProperty(_audioUnit,
                         kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Input,
                         kOutputBus,
                         &format,
                         sizeof(format));
    
    // 4. 设置数据回调函数
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = audioRenderCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)self; // 把 self 传进去，方便在 C 函数中调用 OC 方法
    
    // 设置回调作用域为 Global
    AudioUnitSetProperty(_audioUnit,
                         kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Global,
                         kOutputBus,
                         &callbackStruct,
                         sizeof(callbackStruct));
    
    // 5. 初始化硬件
    OSStatus status = AudioUnitInitialize(_audioUnit);
    if (status != noErr) {
        NSLog(@"[YCAudioPlayer] AudioUnitInitialize failed with status %d", (int)status);
    }
}

// -----------------------------------------------------------------------------
// [音频驱动引擎] AudioUnit 渲染回调 (高频调用，绝对不能阻塞！)
// 系统喇叭没数据了，就会疯狂调用这个方法找你要数据。
// ioData->mBuffers[0].mData 就是你要填入 PCM 数据的目标内存。
// -----------------------------------------------------------------------------
static OSStatus audioRenderCallback(void *inRefCon,
                                    AudioUnitRenderActionFlags *ioActionFlags,
                                    const AudioTimeStamp *inTimeStamp,
                                    UInt32 inBusNumber,
                                    UInt32 inNumberFrames,
                                    AudioBufferList *ioData) {
    YCAudioPlayer *player = (__bridge YCAudioPlayer *)inRefCon;
    
    // ioData 包含我们需要填充的缓冲区
    AudioBuffer *buffer = &ioData->mBuffers[0];
    int bytesRequested = buffer->mDataByteSize; // 系统当前索要的字节数
    
    if (player.delegate && [player.delegate respondsToSelector:@selector(readAudioData:length:)]) {
        // 向解码层 (YCCorePlayer) 索要解码并重采样好的 PCM 数据
        int bytesRead = [player.delegate readAudioData:buffer->mData length:bytesRequested];
        buffer->mDataByteSize = bytesRead;
        
        // 如果解码层没给够数据（比如解码慢了，或者处于缓冲状态）
        // 必须用 0 填满剩下的内存，这代表静音。如果不填，系统会播放出极其刺耳的噪音或者直接崩溃。
        if (bytesRead == 0) {
            memset(buffer->mData, 0, bytesRequested);
        }
    } else {
        memset(buffer->mData, 0, bytesRequested);
    }
    
    return noErr;
}

- (void)play {
    if (!_isPlaying && _audioUnit) {
        AudioOutputUnitStart(_audioUnit);
        _isPlaying = YES;
    }
}

- (void)stop {
    if (_isPlaying && _audioUnit) {
        AudioOutputUnitStop(_audioUnit);
        _isPlaying = NO;
    }
}

- (void)dealloc {
    [self stop];
    if (_audioUnit) {
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
    }
}

@end
