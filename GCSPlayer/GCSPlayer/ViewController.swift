//
//  ViewController.swift
//  GCSPlayer
//
//  Created by 郭朝顺 on 2026/3/22.
//

import UIKit

class ViewController: UIViewController {

    var player: YCMediaPlayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .white
        
        // 1. 初始化播放器
        self.player = YCMediaPlayer()
        
        // 2. 设置渲染视图
        if let renderView = self.player?.renderView {
            renderView.frame = CGRect(x: 0, y: 100, width: self.view.bounds.width, height: 300)
            self.view.addSubview(renderView)
        }
        
        // 3. 测试文件路径 (需要替换为真实的测试文件路径)
        let testFilePath = Bundle.main.path(forResource: "banjun_encrypted", ofType: "mp4") ?? ""
        
        // 4. 配置解密参数 (需要替换为生成测试文件时使用的真实参数)
        let dirtyLength = 30 // 脏数据长度为 30
        
        // 使用项目中默认的 AES Key 和 IV (参考 AESCTR.swift / FileVariantWriter.swift)
        let defaultAESKey: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                                      0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F]
        let defaultAESIV: [UInt8] = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
                                     0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF]
        
        let keyData = Data(defaultAESKey)
        let ivData = Data(defaultAESIV)
        
        // 5. 开始播放 (注: 需要确保 testFilePath 存在)
        self.player?.play(filePath: testFilePath, dirtyLength: dirtyLength, aesKey: keyData, aesIV: ivData)
    }
}

