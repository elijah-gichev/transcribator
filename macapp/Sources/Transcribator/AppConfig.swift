import Foundation

// MARK: - Конфиг (JSON в ~/Library/Application Support/Transcribator/config.json)

struct HotkeyConfig: Codable {
    /// 61 = Right Option (⌥), 58 = Left Option, 54 = Right Command, 63 = Fn, 96 = F5
    var keyCode: Int = 61
    var mode: String = "hold" // hold | toggle
}

struct InsertionConfig: Codable {
    var mode: String = "paste" // paste | clipboard
    var restoreClipboard: Bool = true
    var trailingSpace: Bool = true
}

struct HistoryConfig: Codable {
    var enabled: Bool = true
    var path: String = "~/Library/Application Support/Transcribator/history.txt"
}

struct BackendConfig: Codable {
    var model: String = "v3_e2e_rnnt"
    var device: String = "auto" // auto | mps | cpu
    /// Пустая строка = найти автоматически.
    var pythonPath: String = ""
    var scriptPath: String = ""
}

struct AppConfig: Codable {
    var hotkey = HotkeyConfig()
    var insertion = InsertionConfig()
    var history = HistoryConfig()
    var backend = BackendConfig()
    var playSounds: Bool = true
    var maxRecordingSeconds: Double = 300
}

// MARK: - Хранилище

final class ConfigStore {
    static let shared = ConfigStore()

    var config = AppConfig()
    private let url: URL

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Transcribator", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        url = Self.supportDirectory.appendingPathComponent("config.json")
        load()
        if !FileManager.default.fileExists(atPath: url.path) {
            save() // создаём файл с дефолтами, чтобы его можно было править руками
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        config = Self.decodeMergingDefaults(data)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func reload() {
        load()
    }

    /// Декодирует JSON, подставляя недостающие поля из дефолтов (устойчиво к ручным правкам).
    private static func decodeMergingDefaults(_ data: Data) -> AppConfig {
        let decoder = JSONDecoder()
        guard
            let baseData = try? JSONEncoder().encode(AppConfig()),
            let baseObject = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any],
            let loadedObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return (try? decoder.decode(AppConfig.self, from: data)) ?? AppConfig()
        }

        let merged = deepMerge(base: baseObject, override: loadedObject)
        guard
            let mergedData = try? JSONSerialization.data(withJSONObject: merged),
            let config = try? decoder.decode(AppConfig.self, from: mergedData)
        else {
            return AppConfig()
        }
        return config
    }

    private static func deepMerge(base: [String: Any], override: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in override {
            if
                let baseDict = base[key] as? [String: Any],
                let overrideDict = value as? [String: Any]
            {
                result[key] = deepMerge(base: baseDict, override: overrideDict)
            } else {
                result[key] = value
            }
        }
        return result
    }
}
