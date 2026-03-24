#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@protocol YCAudioPlayerDelegate <NSObject>
/// 音频播放器请求数据
/// @param data 存放PCM数据的指针
/// @param length 需要的字节数
/// @return 实际返回的字节数
- (int)readAudioData:(uint8_t *)data length:(int)length;
@end

@interface YCAudioPlayer : NSObject

@property (nonatomic, weak) id<YCAudioPlayerDelegate> delegate;

/// 初始化音频播放器
/// @param sampleRate 采样率 (如 44100)
/// @param channels 通道数 (如 2)
- (instancetype)initWithSampleRate:(Float64)sampleRate channels:(UInt32)channels;

- (void)play;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
