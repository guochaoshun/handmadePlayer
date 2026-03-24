import Foundation
import Security
import CommonCrypto

// 提取必要的类和方法以在命令行中运行

// --- AESCTR ---
struct AESCTR {
    static func encrypt(data: Data, key: Data, iv: Data) throws -> Data {
        return try self.crypt(operation: CCOperation(kCCEncrypt), data: data, key: key, iv: iv)
    }

    static func decrypt(data: Data, key: Data, iv: Data) throws -> Data {
        return try self.crypt(operation: CCOperation(kCCDecrypt), data: data, key: key, iv: iv)
    }

    private static func crypt(operation: CCOperation, data: Data, key: Data, iv: Data) throws -> Data {
        var outLength: Int = 0
        var outData = Data(count: data.count)
        let outDataCount = outData.count // Copy to a local variable to avoid overlapping access

        let status = outData.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCModeOptionCTR_BE), // CTR 模式，不需要 padding
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            outBytes.baseAddress, outDataCount,
                            &outLength
                        )
                    }
                }
            }
        }

        if status == kCCSuccess {
            outData.count = outLength
            return outData
        } else {
            throw NSError(domain: "AESCTRError", code: Int(status), userInfo: nil)
        }
    }
}

// --- FileVariantWriter ---
struct FileVariantWriter {
    static let ioBufferSize: Int = 64 * 1024
    static let defaultAESKey: Data = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F])
    static let defaultAESIV: Data = Data([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF])

    static func createEncryptedFileWithDirtyHeader(inputURL: URL, outputURL: URL, dirtyBytesLength: Int, encryptLength: Int) throws {
        // 1. 生成脏数据
        var randomData = Data(count: dirtyBytesLength)
        let status = randomData.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, dirtyBytesLength, buffer.baseAddress!)
        }
        if status != errSecSuccess {
            throw NSError(domain: "RandomError", code: Int(status))
        }

        // 2. 读取需要加密的 1KB 原始数据
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        let dataToEncrypt = try inputHandle.read(upToCount: encryptLength) ?? Data()
        
        // 3. 对这 1KB 数据进行 AES-CTR 加密
        let encryptedData = try AESCTR.encrypt(data: dataToEncrypt, key: defaultAESKey, iv: defaultAESIV)

        // 4. 创建新文件并写入
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        
        // 4.1 写入 30 字节脏数据
        try outputHandle.write(contentsOf: randomData)
        
        // 4.2 写入 1KB 加密数据
        try outputHandle.write(contentsOf: encryptedData)
        
        // 4.3 将剩余的原始数据拷贝过来
        try inputHandle.seek(toOffset: UInt64(encryptLength))
        while true {
            var isEOF = false
            autoreleasepool {
                if let chunk = try? inputHandle.read(upToCount: ioBufferSize), !chunk.isEmpty {
                    try? outputHandle.write(contentsOf: chunk)
                } else {
                    isEOF = true
                }
            }
            if isEOF { break }
        }
        
        try inputHandle.close()
        try outputHandle.synchronize()
        try outputHandle.close()
        
        print("Successfully created encrypted file at: \(outputURL.path)")
    }
}

// --- Main ---
let inputPath = "/Users/uxin/Desktop/无名高地/fileReadAction/fiereadAction/file/banjun.mp4"
let outputPath = "/Users/uxin/Desktop/无名高地/fileReadAction/GCSPlayer/GCSPlayer/banjun_encrypted.mp4"

let inputURL = URL(fileURLWithPath: inputPath)
let outputURL = URL(fileURLWithPath: outputPath)

do {
    try FileVariantWriter.createEncryptedFileWithDirtyHeader(inputURL: inputURL, outputURL: outputURL, dirtyBytesLength: 30, encryptLength: 1024)
} catch {
    print("Error: \(error)")
}
