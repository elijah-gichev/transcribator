import AppKit

/// История расшифровок — дописываем в текстовый файл.
enum HistoryLog {
    static var defaultURL: URL {
        let raw = ConfigStore.shared.config.history.path
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    static func append(_ text: String) {
        guard ConfigStore.shared.config.history.enabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url = defaultURL
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(trimmed)\n"

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func open() {
        let url = defaultURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.open(url)
    }
}

/// Поиск путей до python-сайдкара и его скрипта.
enum SidecarPaths {
    static func resolve(_ config: BackendConfig) -> (python: String, script: String)? {
        let fm = FileManager.default
        var candidates: [URL] = []

        // 1. приложение-бандл (Transcribator.app/Contents/Resources/...)
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources)
        }
        // 2. репозиторий: идём вверх от бинарника
        var dir = Bundle.main.bundleURL
        for _ in 0..<6 {
            candidates.append(dir)
            dir = dir.deletingLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        func firstExisting(_ relative: String) -> URL? {
            for base in candidates {
                let url = base.appendingPathComponent(relative)
                if fm.fileExists(atPath: url.path) { return url }
            }
            return nil
        }

        let python = config.pythonPath.isEmpty
            ? firstExisting(".venv/bin/python")?.path
            : (config.pythonPath as NSString).expandingTildeInPath
        let script = config.scriptPath.isEmpty
            ? firstExisting("backend/worker.py")?.path
            : (config.scriptPath as NSString).expandingTildeInPath

        guard let python, let script, fm.fileExists(atPath: python), fm.fileExists(atPath: script) else {
            return nil
        }
        return (python, script)
    }
}
