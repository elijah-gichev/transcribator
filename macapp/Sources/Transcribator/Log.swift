import Foundation

/// Простой лог в файл + stderr (виден, если запускать бандл из терминала).
enum Log {
    static var url: URL {
        ConfigStore.supportDirectory.appendingPathComponent("app.log")
    }

    private static let queue = DispatchQueue(label: "transcribator.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            try? FileManager.default.createDirectory(
                at: ConfigStore.supportDirectory,
                withIntermediateDirectories: true
            )
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > 2_000_000 {
                    try? handle.truncate(atOffset: 0)
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
