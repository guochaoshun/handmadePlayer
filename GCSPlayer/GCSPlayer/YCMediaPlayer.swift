import Foundation
import UIKit

/// 播放器代理
public protocol YCMediaPlayerDelegate: AnyObject {
    func mediaPlayerDidFinish(_ player: YCMediaPlayer)
}

/// Swift 层的播放器接口，负责调度 Objective-C 的 YCCorePlayer 和 UI 的 YCMetalView
public class YCMediaPlayer: NSObject {
    
    private let corePlayer: YCCorePlayer
    public let renderView: YCMetalView
    public weak var delegate: YCMediaPlayerDelegate?
    
    public override init() {
        self.corePlayer = YCCorePlayer()
        self.renderView = YCMetalView(frame: .zero)
        super.init()
        self.corePlayer.videoDelegate = self
    }
    
    /// 准备并开始播放（支持加密视频）
    /// - Parameters:
    ///   - filePath: 本地 MP4 路径
    ///   - dirtyLength: 头部脏数据长度，无脏数据传 0
    ///   - aesKey: AES-CTR 128 位密钥 (16字节)
    ///   - aesIV: AES-CTR 初始向量 (16字节)
    public func play(filePath: String, dirtyLength: Int = 0, aesKey: Data? = nil, aesIV: Data? = nil) {
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[YCMediaPlayer] 文件不存在: \(filePath)")
            return
        }
        
        self.corePlayer.prepare(toPlay: filePath, dirtyLength: Int32(dirtyLength), aesKey: aesKey, aesIV: aesIV)
    }
    
    /// 停止播放
    public func stop() {
        self.corePlayer.stop()
    }
}

// 接收来自 C/ObjC 的 YUV 帧，并交给 MetalView 渲染
extension YCMediaPlayer: YCVideoRenderDelegate {
    public func renderVideoFrameY(_ yData: UnsafePointer<UInt8>,
                                  u uData: UnsafePointer<UInt8>,
                                  v vData: UnsafePointer<UInt8>,
                                  width: Int32,
                                  height: Int32,
                                  yStride: Int32,
                                  uStride: Int32,
                                  vStride: Int32) {
        
        self.renderView.display(yData: yData,
                                uData: uData,
                                vData: vData,
                                width: Int(width),
                                height: Int(height),
                                yStride: Int(yStride),
                                uStride: Int(uStride),
                                vStride: Int(vStride))
    }
}
