#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol YCVideoRenderDelegate <NSObject>
/// 视频帧渲染回调
/// @param yData Y分量数据
/// @param uData U分量数据
/// @param vData V分量数据
/// @param width 视频宽度
/// @param height 视频高度
/// @param yStride Y跨度
/// @param uStride U跨度
/// @param vStride V跨度
- (void)renderVideoFrameY:(const uint8_t *)yData
                        U:(const uint8_t *)uData
                        V:(const uint8_t *)vData
                    width:(int)width
                   height:(int)height
                  yStride:(int)yStride
                  uStride:(int)uStride
                  vStride:(int)vStride;
@end

@interface YCCorePlayer : NSObject

@property (nonatomic, weak) id<YCVideoRenderDelegate> videoDelegate;

/// 准备播放
/// @param filePath 本地文件路径
/// @param dirtyLength 脏数据长度 (如果无加密，传 0)
/// @param aesKey AES Key (如果无加密，传 nil)
/// @param aesIV AES IV (如果无加密，传 nil)
- (void)prepareToPlay:(NSString *)filePath dirtyLength:(int)dirtyLength aesKey:(nullable NSData *)aesKey aesIV:(nullable NSData *)aesIV;

/// 停止并释放资源
- (void)stop;

@end

NS_ASSUME_NONNULL_END
