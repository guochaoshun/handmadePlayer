//
//  ViewController.swift
//  fiereadAction
//
//  Created by 郭朝顺 on 2026/3/19.
//

import UIKit

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // 主流程：启动后后台跑一遍“文件三方案”实验，生成变体文件并输出报告
        self.runFileLab()

    }

    func mergeAction() {
        let path1 = Bundle.main.path(forResource: "2KB", ofType: "png")!
        let url1 = URL(fileURLWithPath: path1)
        var data1 = try! Data.init(contentsOf: url1)

        let path2 = Bundle.main.path(forResource: "视频638M", ofType: "mov")!
        let url2 = URL(fileURLWithPath: path2)
        let data2 = try! Data.init(contentsOf: url2)

        data1.append(data2) // 提前在内存里拼好，避免干扰后续的磁盘测试

        let docURL = try! LabOutputPaths.documentsDirectoryURL()
        let targetURL1 = docURL.appendingPathComponent("mergeFile_NoSync", isDirectory: false)
        let targetURL2 = docURL.appendingPathComponent("mergeFile_WithSync", isDirectory: false)

        // 确保环境干净
        try? FileManager.default.removeItem(at: targetURL1)
        try? FileManager.default.removeItem(at: targetURL2)

        print("--- 开始测试：无 atomic，不加 synchronize ---")
        let start1 = CACurrentMediaTime()
        try! data1.write(to: targetURL1, options: [])
        let end1 = CACurrentMediaTime()
        print("write 耗时 (无 sync): \(end1 - start1) 秒")

        // 为了防止前一个测试的后台落盘抢占 I/O，我们强制等待一下
        print("休眠 2 秒，等待前一个任务的底层缓存刷完...")
        Thread.sleep(forTimeInterval: 2.0)

        print("--- 开始测试：无 atomic，加上 synchronize ---")
        let start2 = CACurrentMediaTime()
        try! data1.write(to: targetURL2, options: [])
        let writeReturnTime = CACurrentMediaTime()

        // 强制落盘
        let handle = try! FileHandle(forWritingTo: targetURL2)
        try! handle.synchronize() // 强制内核把缓存刷入物理硬盘
        handle.closeFile()

        let end2 = CACurrentMediaTime()
        print("write 接口返回耗时: \(writeReturnTime - start2) 秒")
        print("强制 sync() 耗时: \(end2 - writeReturnTime) 秒")
        print("总耗时 (含 sync): \(end2 - start2) 秒")
        print("------------------------------------------\n")


    }

    private func runFileLab() {
        // 实验参数：脏数据长度、AES 头部处理长度（单位：字节）
        let dirtyBytesLength: Int = 1024
        let aesHeaderBytesLength: Int = 1024

        do {
            // 1) 直接使用你指定的 Bundle 里的样本（注意大小写扩展名）
            let fileInfos: [(name: String, ext: String)] = [
                ("2KB", "png"),
                ("16KB", "png"),
                ("57KB", "png"),
                ("116KB", "png"),
                ("554KB", "png"),
                ("6100KB", "PNG"),
                ("banjun", "mp4"),
                ("17679260338258", "mp4"),
                ("视频79M", "mov"),
                ("视频159M", "mov"),
                ("视频319M", "mov"),
                ("视频638M", "mov"),
            ]
            
            var sampleURLs: [URL] = []
            for info in fileInfos {
                if let path = Bundle.main.path(forResource: info.name, ofType: info.ext) {
                    sampleURLs.append(URL(fileURLWithPath: path))
                } else {
                    print("未找到资源文件: \(info.name).\(info.ext)")
                }
            }
            
            // 2) 在 Documents 下创建一次实验输出目录（按时间戳分隔，避免覆盖历史结果）
            let runDirectoryURL: URL = try LabOutputPaths.createRunDirectory()

            var fileReports: [LabInputFileReport] = []
            fileReports.reserveCapacity(sampleURLs.count)

            for sampleURL in sampleURLs {
                autoreleasepool {
                    // 3) 对每个样本文件生成三种方案的变体，并额外生成“方案3的还原文件”用于你对比验证
                    do {
                        let inputBytes: Int = try FileVariantWriter.fileSizeBytes(at: sampleURL)

                        // 方案1：头部写入脏数据（最慢，O(N) 全量 I/O）
                        let prependReport: LabVariantReport = try FileVariantWriter.writePrependDirtyVariant(
                            inputURL: sampleURL,
                            outputDirectoryURL: runDirectoryURL,
                            dirtyBytesLength: dirtyBytesLength
                        )

                        // 方案1-衍生：Bundle 目录伪装法头部写入（黑科技，O(1) 克隆）
                        // let bundlePseudoReport: LabVariantReport = try FileVariantWriter.writeBundlePseudoHeaderVariant(
                        //     inputURL: sampleURL,
                        //     outputDirectoryURL: runDirectoryURL,
                        //     dirtyBytesLength: dirtyBytesLength
                        // )

                        let appendReport: LabVariantReport = try FileVariantWriter.writeAppendDirtyVariant(
                            inputURL: sampleURL,
                            outputDirectoryURL: runDirectoryURL,
                            dirtyBytesLength: dirtyBytesLength
                        )

                        let encryptReport: LabVariantReport = try FileVariantWriter.writeAESCTREncryptHeaderVariant(
                            inputURL: sampleURL,
                            outputDirectoryURL: runDirectoryURL,
                            headerBytesLength: aesHeaderBytesLength
                        )

                        let encryptedVariantURL: URL = URL(fileURLWithPath: encryptReport.outputFilePath)
                        let restoreReport: LabVariantReport = try FileVariantWriter.writeAESCTRDecryptRestoreVariant(
                            encryptedVariantURL: encryptedVariantURL,
                            originalInputURL: sampleURL,
                            outputDirectoryURL: runDirectoryURL,
                            headerBytesLength: aesHeaderBytesLength
                        )

                        // 4) 汇总每个输入文件的统计：体积变化、写入耗时、输出路径（便于你用系统工具打开验证）
                        let inputReport: LabInputFileReport = LabInputFileReport(
                            inputFileName: sampleURL.lastPathComponent,
                            inputFilePath: sampleURL.path,
                            inputBytes: inputBytes,
                            variants: [prependReport,
//                                       bundlePseudoReport,
                                       appendReport,
                                       encryptReport,
                                       restoreReport]
                        )
                        fileReports.append(inputReport)
                    } catch {
                        print("处理文件 \(sampleURL.lastPathComponent) 失败: \(error)")
                    }
                }
            }

            // 5) 生成本次实验的报告，并同时输出 JSON/TXT（人可读 + 机器可读）
            let report: LabReport = LabReport(
                runDirectoryPath: runDirectoryURL.path,
                dirtyBytesLength: dirtyBytesLength,
                aesHeaderBytesLength: aesHeaderBytesLength,
                files: fileReports
            )

            try self.writeReportFiles(report: report, runDirectoryURL: runDirectoryURL)
            self.printConsoleSummary(report: report)
        } catch {
            print("FileLab failed: \(error)")
        }
    }

    private func writeReportFiles(report: LabReport, runDirectoryURL: URL) throws {
        // 报告落盘：report.json（机器可读）+ report.txt（便于直接查看/复制路径）+ report.csv（表格）
        let jsonURL: URL = LabOutputPaths.reportJSONURL(in: runDirectoryURL)
        let txtURL: URL = LabOutputPaths.reportTextURL(in: runDirectoryURL)
        let csvURL: URL = LabOutputPaths.reportCSVURL(in: runDirectoryURL)

        let encoder: JSONEncoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData: Data = try encoder.encode(report)
        try jsonData.write(to: jsonURL, options: [.atomic])

        let text: String = self.buildTextReport(report: report)
        try text.write(to: txtURL, atomically: true, encoding: .utf8)
        
        let csv: String = self.buildCSVReport(report: report)
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        // countStyle = .file 会以 1000 为底（1KB = 1000Bytes），macOS 访达就是用这个。
        // 如果想按 1024 为底算（1KB = 1024Bytes，部分系统工具显示方式），需要改为 .memory
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func formatTime(_ ms: Double) -> String {
        if ms >= 1000.0 {
            let seconds = ms / 1000.0
            return String(format: "%.3fs", seconds)
        } else {
            return String(format: "%.3fms", ms)
        }
    }

    private func buildCSVReport(report: LabReport) -> String {
        var lines: [String] = []
        // CSV 表头
        lines.append("输入文件,原始大小,方案名称,写入耗时")
        
        for file in report.files {
            let inputSizeStr = self.formatBytes(file.inputBytes)
            for variant in file.variants {
                let timeStr = self.formatTime(variant.writeTimeMs)
                // CSV 移除输出文件路径、输出大小、增量大小
                let line = "\(file.inputFileName),\(inputSizeStr),\(variant.scheme),\(timeStr)"
                lines.append(line)
            }
            // 每个文件之间添加一个空行，方便阅读
            lines.append("")
        }
        
        return lines.joined(separator: "\n")
    }

    private func buildTextReport(report: LabReport) -> String {
        // TXT 报告结构：先写全局参数，再逐个输入文件列出各方案的输出大小/增量/耗时/路径
        var lines: [String] = []
        lines.append("runDirectoryPath: \(report.runDirectoryPath)")
        lines.append("dirtyBytesLength: \(report.dirtyBytesLength)")
        lines.append("aesHeaderBytesLength: \(report.aesHeaderBytesLength)")
        lines.append("")

        for file in report.files {
            lines.append("INPUT: \(file.inputFileName)")
            lines.append("  inputBytes: \(file.inputBytes)")
            lines.append("  inputPath: \(file.inputFilePath)")

            for variant in file.variants {
                lines.append("  VARIANT: \(variant.scheme)")
                lines.append("    outputBytes: \(variant.outputBytes)  deltaBytes: \(variant.deltaBytes)  writeTime: \(self.formatTime(variant.writeTimeMs))")
                lines.append("    outputPath: \(variant.outputFilePath)")
            }

            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func printConsoleSummary(report: LabReport) {
        print("FileLab done. Output directory: \(report.runDirectoryPath)")
        print("")
        print("========== report.csv ==========")
        print("")

        print(self.buildCSVReport(report: report))
        print("================================")
    }
}

/**

 csv格式的结论.

 file:///Users/uxin/Desktop/%E6%97%A0%E5%90%8D%E9%AB%98%E5%9C%B0/fileReadAction/.trae/performance_chart.html


 输入文件,原始大小,方案名称,写入耗时
 2KB.png,2 KB,头部写入脏数据,2.631ms
 2KB.png,2 KB,尾部写入脏数据,0.698ms
 2KB.png,2 KB,头部加密,1.203ms
 2KB.png,2 KB,头部解密(还原),9.373ms

 16KB.png,17 KB,头部写入脏数据,23.006ms
 16KB.png,17 KB,尾部写入脏数据,0.803ms
 16KB.png,17 KB,头部加密,0.652ms
 16KB.png,17 KB,头部解密(还原),0.590ms

 57KB.png,59 KB,头部写入脏数据,1.021ms
 57KB.png,59 KB,尾部写入脏数据,0.714ms
 57KB.png,59 KB,头部加密,0.267ms
 57KB.png,59 KB,头部解密(还原),0.488ms

 116KB.png,127 KB,头部写入脏数据,0.998ms
 116KB.png,127 KB,尾部写入脏数据,0.247ms
 116KB.png,127 KB,头部加密,0.261ms
 116KB.png,127 KB,头部解密(还原),0.484ms

 554KB.png,520 KB,头部写入脏数据,4.896ms
 554KB.png,520 KB,尾部写入脏数据,0.526ms
 554KB.png,520 KB,头部加密,0.547ms
 554KB.png,520 KB,头部解密(还原),0.511ms

 6100KB.PNG,6.1 MB,头部写入脏数据,23.930ms
 6100KB.PNG,6.1 MB,尾部写入脏数据,0.863ms
 6100KB.PNG,6.1 MB,头部加密,0.766ms
 6100KB.PNG,6.1 MB,头部解密(还原),0.670ms

 banjun.mp4,5.5 MB,头部写入脏数据,26.359ms
 banjun.mp4,5.5 MB,尾部写入脏数据,0.642ms
 banjun.mp4,5.5 MB,头部加密,0.493ms
 banjun.mp4,5.5 MB,头部解密(还原),0.801ms

 17679260338258.mp4,39.9 MB,头部写入脏数据,190.940ms
 17679260338258.mp4,39.9 MB,尾部写入脏数据,0.371ms
 17679260338258.mp4,39.9 MB,头部加密,1.943ms
 17679260338258.mp4,39.9 MB,头部解密(还原),6.847ms

 视频79M.mov,79.8 MB,头部写入脏数据,446.006ms
 视频79M.mov,79.8 MB,尾部写入脏数据,0.385ms
 视频79M.mov,79.8 MB,头部加密,1.834ms
 视频79M.mov,79.8 MB,头部解密(还原),8.452ms

 视频159M.mov,159.6 MB,头部写入脏数据,866.681ms
 视频159M.mov,159.6 MB,尾部写入脏数据,1.004ms
 视频159M.mov,159.6 MB,头部加密,1.636ms
 视频159M.mov,159.6 MB,头部解密(还原),143.439ms

 视频319M.mov,319.2 MB,头部写入脏数据,2.762s
 视频319M.mov,319.2 MB,尾部写入脏数据,1.086ms
 视频319M.mov,319.2 MB,头部加密,1.691ms
 视频319M.mov,319.2 MB,头部解密(还原),23.533ms

 视频638M.mov,638.5 MB,头部写入脏数据,5.038s
 视频638M.mov,638.5 MB,尾部写入脏数据,23.211ms
 视频638M.mov,638.5 MB,头部加密,22.875ms
 视频638M.mov,638.5 MB,头部解密(还原),144.467ms

 */
