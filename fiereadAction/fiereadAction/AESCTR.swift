import Foundation
import CommonCrypto

struct AESCTR {
    // AES-CTR：输入输出长度一致；适合“只替换文件头部 N 字节”而不改变总长度的场景
    static func encrypt(data: Data, key: Data, iv: Data) throws -> Data {
        return try self.crypt(data: data, key: key, iv: iv, operation: CCOperation(kCCEncrypt))
    }

    static func decrypt(data: Data, key: Data, iv: Data) throws -> Data {
        // CTR 模式下加密/解密的计算形式一致，这里仍保留 decrypt 便于调用方表达语义
        return try self.crypt(data: data, key: key, iv: iv, operation: CCOperation(kCCDecrypt))
    }

    private static func crypt(data: Data, key: Data, iv: Data, operation: CCOperation) throws -> Data {
        if data.isEmpty == true {
            return Data()
        }

        // CTR 需要 16 字节 IV；Key 支持 16/24/32 字节（AES-128/192/256）
        if iv.count != kCCBlockSizeAES128 {
            throw NSError(domain: "AESCTR", code: 1)
        }
        if key.count != kCCKeySizeAES128 && key.count != kCCKeySizeAES192 && key.count != kCCKeySizeAES256 {
            throw NSError(domain: "AESCTR", code: 2)
        }

        var cryptor: CCCryptorRef?

        // 使用 CommonCrypto 的 CTR 模式创建 cryptor；这里选择大端计数器（kCCModeOptionCTR_BE）
        let createStatus: CCCryptorStatus = key.withUnsafeBytes { keyBuffer in
            return iv.withUnsafeBytes { ivBuffer in
                return CCCryptorCreateWithMode(
                    operation,
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBuffer.baseAddress,
                    keyBuffer.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }

        guard createStatus == kCCSuccess, let createdCryptor: CCCryptorRef = cryptor else {
            throw NSError(domain: "AESCTR", code: Int(createStatus))
        }
        defer { CCCryptorRelease(createdCryptor) }

        // output 先按输入长度分配，CTR 不会引入 padding，理论上 moved == data.count
        var output: Data = Data(count: data.count)
        var moved: size_t = 0

        let updateStatus: CCCryptorStatus = output.withUnsafeMutableBytes { outBuffer in
            return data.withUnsafeBytes { inBuffer in
                return CCCryptorUpdate(
                    createdCryptor,
                    inBuffer.baseAddress,
                    data.count,
                    outBuffer.baseAddress,
                    outBuffer.count,
                    &moved
                )
            }
        }

        guard updateStatus == kCCSuccess else {
            throw NSError(domain: "AESCTR", code: Int(updateStatus))
        }

        if moved != output.count {
            output.count = moved
        }
        return output
    }
}
