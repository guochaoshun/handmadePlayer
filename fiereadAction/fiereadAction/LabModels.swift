import Foundation

struct LabReport: Codable {
    let runDirectoryPath: String
    let dirtyBytesLength: Int
    let aesHeaderBytesLength: Int
    let files: [LabInputFileReport]
}

struct LabInputFileReport: Codable {
    let inputFileName: String
    let inputFilePath: String
    let inputBytes: Int
    let variants: [LabVariantReport]
}

struct LabVariantReport: Codable {
    let scheme: String
    let outputFileName: String
    let outputFilePath: String
    let outputBytes: Int
    let deltaBytes: Int
    let writeTimeMs: Double
}

struct Stopwatch {
    private let start: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    func elapsedMilliseconds() -> Double {
        return (CFAbsoluteTimeGetCurrent() - self.start) * 1000.0
    }
}

