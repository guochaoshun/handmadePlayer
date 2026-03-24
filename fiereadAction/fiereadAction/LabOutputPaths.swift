import Foundation

struct LabOutputPaths {
    static func createRunDirectory() throws -> URL {
        let documentsURL: URL = try self.documentsDirectoryURL()
        let baseURL: URL = documentsURL.appendingPathComponent("fiereadAction-lab", isDirectory: true)
        
        // 每次运行前，先清理旧的实验目录，只保留本次最新的文件夹
        if FileManager.default.fileExists(atPath: baseURL.path) {
            try? FileManager.default.removeItem(at: baseURL)
        }
        
        let runURL: URL = baseURL.appendingPathComponent(self.timestampString(), isDirectory: true)
        try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
        return runURL
    }

    static func reportTextURL(in runDirectoryURL: URL) -> URL {
        return runDirectoryURL.appendingPathComponent("report.txt", isDirectory: false)
    }

    static func reportJSONURL(in runDirectoryURL: URL) -> URL {
        return runDirectoryURL.appendingPathComponent("report.json", isDirectory: false)
    }

    static func reportCSVURL(in runDirectoryURL: URL) -> URL {
        return runDirectoryURL.appendingPathComponent("report.csv", isDirectory: false)
    }

    static func documentsDirectoryURL() throws -> URL {
        guard let url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "LabOutputPaths", code: 1)
        }
        return url
    }

    private static func timestampString() -> String {
        let formatter: DateFormatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}

