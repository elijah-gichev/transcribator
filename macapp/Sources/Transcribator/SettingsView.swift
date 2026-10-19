import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var config = ConfigStore.shared.config
    @State private var saved = false

    private let keyOptions: [(Int, String)] = [
        (61, "Right ⌥ (Option)"),
        (58, "Left ⌥ (Option)"),
        (54, "Right ⌘ (Command)"),
        (63, "Fn"),
        (96, "F5"),
        (97, "F6"),
        (98, "F7"),
    ]

    private let modelOptions = [
        "v3_e2e_rnnt",
        "v3_e2e_ctc",
        "v3_rnnt",
        "v3_ctc",
        "multilingual_ctc",
    ]

    private let deviceOptions = ["auto", "mps", "cpu"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Section("Клавиша") {
                    Picker("Клавиша", selection: $config.hotkey.keyCode) {
                        ForEach(keyOptions, id: \.0) { key, title in
                            Text(title).tag(key)
                        }
                    }
                    Picker("Режим", selection: $config.hotkey.mode) {
                        Text("Удержание (push-to-talk)").tag("hold")
                        Text("Переключение (toggle)").tag("toggle")
                    }
                }

                Section("Вставка") {
                    Picker("Куда", selection: $config.insertion.mode) {
                        Text("В активное приложение (Cmd+V)").tag("paste")
                        Text("Только в буфер обмена").tag("clipboard")
                    }
                    Toggle("Возвращать прежнее содержимое буфера", isOn: $config.insertion.restoreClipboard)
                    Toggle("Добавлять пробел после текста", isOn: $config.insertion.trailingSpace)
                }

                Section("Модель") {
                    Picker("Версия", selection: $config.backend.model) {
                        ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Устройство", selection: $config.backend.device) {
                        ForEach(deviceOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Text("v3_e2e_* — с пунктуацией и числами. rnnt точнее, ctc быстрее.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("История") {
                    Toggle("Писать историю в файл", isOn: $config.history.enabled)
                    TextField("Файл истории", text: $config.history.path)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Поведение") {
                    Toggle("Звуки старта и остановки записи", isOn: $config.playSounds)
                    HStack {
                        Text("Максимум записи, сек")
                        TextField("", value: $config.maxRecordingSeconds, format: .number)
                            .frame(width: 70)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Открыть настройки приватности") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                if saved {
                    Text("Сохранено")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Button("Сохранить") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .frame(width: 520, height: 520)
    }

    private func save() {
        ConfigStore.shared.config = config
        ConfigStore.shared.save()
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
        NotificationCenter.default.post(name: .transcribatorConfigChanged, object: nil)
    }
}

extension Notification.Name {
    static let transcribatorConfigChanged = Notification.Name("transcribatorConfigChanged")
}

enum SettingsWindowController {
    static func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcribator"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        return window
    }
}
