import Foundation
import Security

struct FileVariantWriter {
    // 以 64KB 为单位做流式拷贝，避免大文件一次性读入内存
    static let ioBufferSize: Int = 64 * 1024
    // 实验用固定 Key/IV：用于可复现对比，不作为安全方案推荐
    static let defaultAESKey: Data = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F])
    static let defaultAESIV: Data = Data([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF])

    static func fileSizeBytes(at url: URL) throws -> Int {
        let attributes: [FileAttributeKey: Any] = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size: NSNumber = attributes[.size] as? NSNumber else {
            throw NSError(domain: "FileVariantWriter", code: 1)
        }
        return size.intValue
    }

    static func writePrependDirtyVariant(inputURL: URL, outputDirectoryURL: URL, dirtyBytesLength: Int) throws -> LabVariantReport {
        let outputURL: URL = self.outputURL(inputURL: inputURL, outputDirectoryURL: outputDirectoryURL, scheme: "头部写入脏数据")
        let randomData: Data = try self.randomBytes(length: dirtyBytesLength)
        
        // 1. 准备环境：复制文件（不在耗时统计内）
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: inputURL, to: outputURL)
        
        // 2. 开始统计真实的“文件局部修改”耗时
        let stopwatch: Stopwatch = Stopwatch()
        
        let outputHandle: FileHandle = try FileHandle(forUpdating: outputURL)
        defer { try? outputHandle.close() }

        // 对于真实的“头部插入”，因为文件系统不支持直接插入，所以必须要搬运后面的所有数据。
        // 为了统计出在目标文件上“写入 1KB，再把剩下所有内容接上去”的耗时：
        // 既然 outputURL 已经包含了原文件，最稳妥的做法就是截断到 0，写入脏数据，然后再将原文件的内容拷贝过来。
        // 这样既能实现原数据的保留，又包含了把原数据全量写入的耗时，体现了“在头部插入必定需要全量写”的代价。
        try outputHandle.truncateFile(atOffset: 0)
        try outputHandle.write(contentsOf: randomData)
        try self.copyFile(from: inputURL, to: outputHandle)
        
        // 确保写盘完成再结束计时
        try outputHandle.synchronize()
        let elapsedMs = stopwatch.elapsedMilliseconds()
        
        let outputBytes: Int = try self.fileSizeBytes(at: outputURL)
        let inputBytes: Int = try self.fileSizeBytes(at: inputURL)
        return LabVariantReport(
            scheme: "头部写入脏数据",
            outputFileName: outputURL.lastPathComponent,
            outputFilePath: outputURL.path,
            outputBytes: outputBytes,
            deltaBytes: outputBytes - inputBytes,
            writeTimeMs: elapsedMs
        )
    }

    /// 黑科技 2：利用 Bundle 机制（目录伪装法）实现 O(1) 的“头部绑定脏数据”
    /// 核心思想：不修改原文件内容，而是创建一个专属后缀的文件夹（Bundle），
    /// 将脏数据作为独立文件存入，同时利用 APFS 的 Clone 特性极速拷入原文件。
    static func writeBundlePseudoHeaderVariant(inputURL: URL, outputDirectoryURL: URL, dirtyBytesLength: Int) throws -> LabVariantReport {
        // 产物将是一个文件夹，后缀名使用 .mybundle 伪装
        let baseName: String = inputURL.deletingPathExtension().lastPathComponent
        let bundleURL: URL = outputDirectoryURL.appendingPathComponent("\(baseName)__伪装Bundle.mybundle")
        let randomData: Data = try self.randomBytes(length: dirtyBytesLength)
        
        // 1. 准备环境：清理旧目录（不在耗时统计内）
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            try FileManager.default.removeItem(at: bundleURL)
        }
        
        // 2. 开始统计真实的“打包组合”耗时
        let stopwatch: Stopwatch = Stopwatch()
        
        // 创建 Bundle 文件夹
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true, attributes: nil)
        
        // 在 Bundle 内部写入脏数据头部文件
        let headerURL: URL = bundleURL.appendingPathComponent("header.dat")
        try randomData.write(to: headerURL, options: .atomic)
        
        // 在 Bundle 内部克隆原文件内容
        // 这里是 O(1) 的魔法所在：FileManager.copyItem 在 APFS 上默认使用 Clone（写时复制），
        // 无论文件多大，都只是瞬间复制了文件系统的 inode 指针，不发生实际的 I/O 搬运。
        let contentURL: URL = bundleURL.appendingPathComponent("content.data")
        try FileManager.default.copyItem(at: inputURL, to: contentURL)
        
        let elapsedMs = stopwatch.elapsedMilliseconds()
        
        // 统计 Bundle 的总体积（脏数据大小 + 原文件大小）
        let headerBytes: Int = try self.fileSizeBytes(at: headerURL)
        let contentBytes: Int = try self.fileSizeBytes(at: contentURL)
        let outputBytes: Int = headerBytes + contentBytes
        
        let inputBytes: Int = try self.fileSizeBytes(at: inputURL)
        return LabVariantReport(
            scheme: "伪装Bundle(O(1)头部)",
            outputFileName: bundleURL.lastPathComponent,
            outputFilePath: bundleURL.path,
            outputBytes: outputBytes,
            deltaBytes: outputBytes - inputBytes,
            writeTimeMs: elapsedMs
        )
    }

    static func writeAppendDirtyVariant(inputURL: URL, outputDirectoryURL: URL, dirtyBytesLength: Int) throws -> LabVariantReport {
        let outputURL: URL = self.outputURL(inputURL: inputURL, outputDirectoryURL: outputDirectoryURL, scheme: "尾部写入脏数据")
        let randomData: Data = try self.randomBytes(length: dirtyBytesLength)
        
        // 1. 准备环境：复制文件
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: inputURL, to: outputURL)

        // 2. 开始统计
        let stopwatch: Stopwatch = Stopwatch()
        
        let outputHandle: FileHandle = try FileHandle(forUpdating: outputURL)
        defer { try? outputHandle.close() }

        // 真正的尾部追加：直接 seek 到末尾写入
        try outputHandle.seekToEnd()
        try outputHandle.write(contentsOf: randomData)
        
        try outputHandle.synchronize()
        let elapsedMs = stopwatch.elapsedMilliseconds()

        let outputBytes: Int = try self.fileSizeBytes(at: outputURL)
        let inputBytes: Int = try self.fileSizeBytes(at: inputURL)
        return LabVariantReport(
            scheme: "尾部写入脏数据",
            outputFileName: outputURL.lastPathComponent,
            outputFilePath: outputURL.path,
            outputBytes: outputBytes,
            deltaBytes: outputBytes - inputBytes,
            writeTimeMs: elapsedMs
        )
    }

    static func writeAESCTREncryptHeaderVariant(inputURL: URL, outputDirectoryURL: URL, headerBytesLength: Int, key: Data = Self.defaultAESKey, iv: Data = Self.defaultAESIV) throws -> LabVariantReport {
        let outputURL: URL = self.outputURL(inputURL: inputURL, outputDirectoryURL: outputDirectoryURL, scheme: "头部加密")
        let inputBytes: Int = try self.fileSizeBytes(at: inputURL)
        let headerLength: Int = min(headerBytesLength, max(0, inputBytes))

        // 1. 准备环境：复制文件
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: inputURL, to: outputURL)

        // 2. 开始统计：读取头部、加密、覆盖写回
        let stopwatch: Stopwatch = Stopwatch()
        
        let outputHandle: FileHandle = try FileHandle(forUpdating: outputURL)
        defer { try? outputHandle.close() }

        // 读取原文件头部
        try outputHandle.seek(toOffset: 0)
        let headerData: Data = try outputHandle.read(upToCount: headerLength) ?? Data()
        // 加密
        let encryptedHeader: Data = try AESCTR.encrypt(data: headerData, key: key, iv: iv)

        // 写入加密后的头部覆盖
        try outputHandle.seek(toOffset: 0)
        try outputHandle.write(contentsOf: encryptedHeader)
        
        try outputHandle.synchronize()
        let elapsedMs = stopwatch.elapsedMilliseconds()

        let outputBytes: Int = try self.fileSizeBytes(at: outputURL)
        return LabVariantReport(
            scheme: "头部加密",
            outputFileName: outputURL.lastPathComponent,
            outputFilePath: outputURL.path,
            outputBytes: outputBytes,
            deltaBytes: outputBytes - inputBytes,
            writeTimeMs: elapsedMs
        )
    }

    static func writeAESCTRDecryptRestoreVariant(encryptedVariantURL: URL, originalInputURL: URL, outputDirectoryURL: URL, headerBytesLength: Int, key: Data = Self.defaultAESKey, iv: Data = Self.defaultAESIV) throws -> LabVariantReport {
        let outputURL: URL = self.outputURL(inputURL: originalInputURL, outputDirectoryURL: outputDirectoryURL, scheme: "头部解密(还原)")
        let encryptedBytes: Int = try self.fileSizeBytes(at: encryptedVariantURL)
        let headerLength: Int = min(headerBytesLength, max(0, encryptedBytes))

        // 1. 准备环境：复制加密后的文件
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: encryptedVariantURL, to: outputURL)

        // 2. 开始统计
        let stopwatch: Stopwatch = Stopwatch()
        
        let outputHandle: FileHandle = try FileHandle(forUpdating: outputURL)
        defer { try? outputHandle.close() }

        // 读取加密文件的头部
        try outputHandle.seek(toOffset: 0)
        let encryptedHeaderData: Data = try outputHandle.read(upToCount: headerLength) ?? Data()
        // 解密
        let restoredHeader: Data = try AESCTR.decrypt(data: encryptedHeaderData, key: key, iv: iv)

        // 写入还原后的头部覆盖
        try outputHandle.seek(toOffset: 0)
        try outputHandle.write(contentsOf: restoredHeader)
        
        try outputHandle.synchronize()
        let elapsedMs = stopwatch.elapsedMilliseconds()

        let outputBytes: Int = try self.fileSizeBytes(at: outputURL)
        let originalBytes: Int = try self.fileSizeBytes(at: originalInputURL)
        return LabVariantReport(
            scheme: "头部解密(还原)",
            outputFileName: outputURL.lastPathComponent,
            outputFilePath: outputURL.path,
            outputBytes: outputBytes,
            deltaBytes: outputBytes - originalBytes,
            writeTimeMs: elapsedMs
        )
    }

    static func outputURL(inputURL: URL, outputDirectoryURL: URL, scheme: String) -> URL {
        // 命名规则：原文件名 + "__" + 方案标识；扩展名尽量保持不变，便于你用系统工具直接打开
        let baseName: String = inputURL.deletingPathExtension().lastPathComponent
        let ext: String = inputURL.pathExtension
        let fileName: String
        if ext.isEmpty == true {
            fileName = "\(baseName)__\(scheme)"
        } else {
            fileName = "\(baseName)__\(scheme).\(ext)"
        }
        return outputDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private static func createEmptyFile(at url: URL) throws {
        // 统一“先删后建”，确保重复运行不会因为旧文件残留导致误判
        if FileManager.default.fileExists(atPath: url.path) == true {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    private static func randomBytes(length: Int) throws -> Data {
        // 使用系统安全随机源生成脏数据（更贴近“真实噪声”）
        if length <= 0 {
            return Data()
        }

        var data: Data = Data(count: length)
        let status: Int32 = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress: UnsafeMutableRawPointer = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, length, baseAddress)
        }

        if status != errSecSuccess {
            throw NSError(domain: "FileVariantWriter", code: Int(status))
        }

        return data
    }

    private static func copyFile(from inputURL: URL, to outputHandle: FileHandle) throws {
        let inputHandle: FileHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inputHandle.close() }

        try self.copyFile(from: inputHandle, startingAt: 0, to: outputHandle)
    }

    private static func copyFile(from inputHandle: FileHandle, startingAt offset: UInt64, to outputHandle: FileHandle) throws {
        // 从指定偏移开始流式读取并写入，避免一次性加载到内存
        try inputHandle.seek(toOffset: offset)
        while true {
            var isEOF = false
            autoreleasepool {
                if let chunk = try? inputHandle.read(upToCount: self.ioBufferSize), !chunk.isEmpty {
                    try? outputHandle.write(contentsOf: chunk)
                } else {
                    isEOF = true
                }
            }
            if isEOF {
                break
            }
        }
    }
}
