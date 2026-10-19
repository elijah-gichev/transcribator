import AppKit
import AVFoundation

final class AppController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let sidecar = ASRSidecar()

    private var settingsWindow: NSWindow?
    private var maxDurationWork: DispatchWorkItem?

    private var lastText = ""
    private var isRecording = false
    private var isTranscribing = false
    private var isTestRecording = false
    private var hotkeyError: String?
    private var permissionTimer: Timer?
    private var progressTimer: Timer?
    private var backendStartedAt: Date?
    private var launchedBackend: (model: String, device: String)?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        updateIcon()

        sidecar.onState = { [weak self] state in
            Log.write("sidecar: \(state.description)")
            self?.rebuildMenu()
            self?.updateIcon()
        }

        startHotkey()
        if !hotkey.isRunning, !CommandLine.arguments.contains("--test-recording") {
            // Единственный способ попасть в список TCC — системный запрос из приложения.
            // Достаточно «Универсального доступа»: он нужен и для клавиши, и для вставки.
            requestAccessibility()
            startPermissionWatchdog()
        }
        startBackend()
        logPermissions()
        requestMicrophoneIfNeeded()
        _ = TextInjector.hasAccessibility() // просто проверяем, без спама диалогом

        if CommandLine.arguments.contains("--test-recording") {
            runSelfTestRecording()
        }
    }

    /// WAV 16 kHz mono int16 — для диагностики записи.
    static func writeWav(_ pcm: [Int16], to url: URL) {
        var data = Data()
        let dataSize = UInt32(pcm.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16000))
        append(UInt32(32000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try? data.write(to: url)
    }

    /// `open build/Transcribator.app --args --test-recording` — самопроверка без UI-кликов.
    private func runSelfTestRecording() {
        Log.write("selftest: waiting for sidecar")
        sidecar.whenReady { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result {
                Log.write("selftest: sidecar failed: \(error.localizedDescription)")
                NSApp.terminate(nil)
                return
            }
            Log.write("selftest: recording 3s")
            self.isTestRecording = true
            self.beginRecording()
            var peak: Float = 0
            self.recorder.onLevel = { level in peak = max(peak, level) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let pcm = self.recorder.stop()
                self.isRecording = false
                Log.write("selftest: captured \(pcm.count / 16) ms, peak=\(String(format: "%.3f", peak))")
                let wavURL = ConfigStore.supportDirectory.appendingPathComponent("selftest.wav")
                Self.writeWav(pcm, to: wavURL)
                Log.write("selftest: wav=\(wavURL.path)")
                self.sidecar.transcribe(pcm: pcm) { transcribeResult in
                    switch transcribeResult {
                    case let .success(text): Log.write("selftest: text=\(text)")
                    case let .failure(error): Log.write("selftest: error=\(error.localizedDescription)")
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - Разрешения

    private func microphoneStatusText() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private func logPermissions() {
        Log.write(
            "permissions: mic=\(microphoneStatusText())"
                + " inputMonitoring=\(CGPreflightListenEventAccess())"
                + " accessibility=\(TextInjector.hasAccessibility())"
        )
    }

    /// Системный запрос микрофона при первом запуске: без него приложения нет в списке TCC.
    private func requestMicrophoneIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        Log.write("mic: requesting access")
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                Log.write("mic: request result=\(granted)")
                self?.logPermissions()
                self?.rebuildMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sidecar.stop()
        hotkey.stop()
    }

    // MARK: - Backend

    private func startBackend() {
        let config = ConfigStore.shared.config.backend
        guard let paths = SidecarPaths.resolve(config) else {
            Log.write("backend: не найдены пути до python/worker.py — запусти scripts/setup_backend.sh")
            sidecar.stop()
            rebuildMenu()
            return
        }
        launchedBackend = (config.model, config.device)
        backendStartedAt = Date()
        Log.write("backend: \(paths.python) \(paths.script) model=\(config.model) device=\(config.device)")
        startProgressTimer()
        sidecar.start(
            python: paths.python,
            script: paths.script,
            model: config.model,
            device: config.device
        )
    }

    /// Перезапускаем бэкенд только если менялись модель/устройство.
    private func backendNeedsRestart() -> Bool {
        let config = ConfigStore.shared.config.backend
        guard let launched = launchedBackend else { return true }
        return launched.model != config.model || launched.device != config.device || !sidecar.isReady
    }

    /// Обновляет меню раз в секунду, пока модель грузится (видно, что процесс жив).
    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if self.sidecar.isReady {
                timer.invalidate()
                self.progressTimer = nil
                self.backendStartedAt = nil
            }
            self.rebuildMenu()
        }
    }

    /// Готова ли модель на диске (иначе её будут качать 220–430 МБ).
    private func modelIsCached(_ model: String) -> Bool {
        let path = ("~/.cache/gigaam/\(model).ckpt" as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Hotkey

    private func startHotkey() {
        let config = ConfigStore.shared.config.hotkey
        hotkey.onEdge = { [weak self] down in
            self?.handleHotkey(down: down)
        }
        let ok = hotkey.start(keyCode: config.keyCode) { _ in }
        hotkeyError = ok ? nil : "нет доступа к перехвату клавиатуры"
        Log.write("hotkey: keyCode=\(config.keyCode) mode=\(config.mode) started=\(ok) via=\(hotkey.mechanism)")
        rebuildMenu()
    }

    private func handleHotkey(down: Bool) {
        switch ConfigStore.shared.config.hotkey.mode {
        case "toggle":
            guard down else { return }
            isRecording ? stopRecording() : startRecording()
        default:
            down ? startRecording() : stopRecording()
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard !isRecording, !isTranscribing else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard granted else {
                        self?.showAlert("Нет доступа к микрофону",
                                        "Разрешите доступ в «Системные настройки → Конфиденциальность → Микрофон».")
                        return
                    }
                    self?.beginRecording()
                }
            }
        default:
            showAlert("Нет доступа к микрофону",
                      "Разрешите доступ в «Системные настройки → Конфиденциальность → Микрофон».")
        }
    }

    private func beginRecording() {
        recorder.onLevel = nil
        do {
            try recorder.start()
        } catch {
            showAlert("Не удалось начать запись", error.localizedDescription)
            return
        }
        isRecording = true
        Log.write("recording: start")
        if ConfigStore.shared.config.playSounds { NSSound(named: "Tink")?.play() }
        updateIcon()

        let limit = ConfigStore.shared.config.maxRecordingSeconds
        if limit > 0 {
            let work = DispatchWorkItem { [weak self] in self?.stopRecording() }
            maxDurationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: work)
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        maxDurationWork?.cancel()
        maxDurationWork = nil

        let pcm = recorder.stop()
        isRecording = false
        Log.write("recording: stop, \(pcm.count / 16) ms")
        if ConfigStore.shared.config.playSounds { NSSound(named: "Pop")?.play() }

        // короче 0.3 c — почти наверняка случайное нажатие
        guard pcm.count > Int(16000 * 0.3) else {
            Log.write("recording: слишком короткая запись, пропуск")
            isTestRecording = false
            updateIcon()
            return
        }

        isTranscribing = true
        updateIcon()

        sidecar.transcribe(pcm: pcm) { [weak self] result in
            guard let self else { return }
            self.isTranscribing = false
            let wasTest = self.isTestRecording
            self.isTestRecording = false
            self.updateIcon()
            switch result {
            case let .success(text):
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else {
                    Log.write("result: пусто (тишина?)")
                    if wasTest { self.showAlert("Тест записи", "Речь не распознана — тишина или слишком тихо.") }
                    self.rebuildMenu()
                    return
                }
                self.lastText = cleaned
                Log.write("result: \(cleaned)")
                if wasTest {
                    self.showAlert("Тест записи", cleaned)
                    self.rebuildMenu()
                    return
                }
                HistoryLog.append(cleaned)
                TextInjector.insert(cleaned, mode: ConfigStore.shared.config.insertion)
                self.rebuildMenu()
            case let .failure(error):
                Log.write("error: \(error.localizedDescription)")
                self.showAlert("Ошибка распознавания", error.localizedDescription)
            }
        }
    }

    // MARK: - UI

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let symbol: String
        let tint: NSColor?
        var tooltip = "Transcribator"

        if isRecording {
            symbol = "mic.fill"
            tint = .systemRed
            tooltip = "Запись… отпустите клавишу"
        } else if isTranscribing {
            symbol = "waveform"
            tint = .systemOrange
            tooltip = "Распознаю…"
        } else if !sidecar.isReady {
            symbol = "hourglass"
            tint = .secondaryLabelColor
            tooltip = sidecar.state.description
        } else if hotkeyError != nil {
            symbol = "exclamationmark.triangle"
            tint = .systemYellow
            tooltip = "Нет доступа к перехвату клавиатуры"
        } else {
            symbol = "mic"
            tint = nil
            tooltip = "Transcribator готов"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        button.toolTip = tooltip
    }

    private func buildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !sidecar.isReady, !sidecar.lastLogLine.isEmpty {
            let progress = NSMenuItem(title: sidecar.lastLogLine, action: nil, keyEquivalent: "")
            progress.isEnabled = false
            menu.addItem(progress)
        }

        let hint = NSMenuItem(title: hintLine(), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let last = NSMenuItem(
            title: lastText.isEmpty ? "Последняя расшифровка: —" : "Копировать: \(trimmed(lastText, 42))",
            action: lastText.isEmpty ? nil : #selector(copyLastText),
            keyEquivalent: ""
        )
        last.target = self
        last.isEnabled = !lastText.isEmpty
        menu.addItem(last)

        let history = NSMenuItem(title: "Открыть историю…", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let request = NSMenuItem(title: "Запросить доступы…", action: #selector(requestAccesses), keyEquivalent: "")
        request.target = self
        menu.addItem(request)

        let reveal = NSMenuItem(title: "Показать приложение в Finder", action: #selector(revealInFinder), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        if hotkeyError != nil || !TextInjector.hasAccessibility() {
            let permissions = NSMenuItem(title: "Открыть настройки приватности…", action: #selector(openPrivacy), keyEquivalent: "")
            permissions.target = self
            menu.addItem(permissions)
        }

        let check = NSMenuItem(title: "Проверить разрешения…", action: #selector(checkPermissions), keyEquivalent: "")
        check.target = self
        menu.addItem(check)

        let relaunch = NSMenuItem(title: "Перезапустить приложение", action: #selector(relaunchApp), keyEquivalent: "")
        relaunch.target = self
        menu.addItem(relaunch)

        let test = NSMenuItem(title: "Тест записи (3 секунды)", action: #selector(testRecording), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        let restart = NSMenuItem(title: "Перезапустить бэкенд", action: #selector(restartBackend), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func rebuildMenu() { buildMenu() }

    private func statusLine() -> String {
        if sidecar.isReady { return "Готов: " + sidecar.state.description }
        if case .starting = sidecar.state, let startedAt = backendStartedAt {
            let elapsed = Int(Date().timeIntervalSince(startedAt).rounded())
            let model = ConfigStore.shared.config.backend.model
            if !modelIsCached(model) {
                return "Скачиваю \(model)… \(elapsed) с (первый раз, 220–430 МБ)"
            }
            return "Загружаю \(model)… \(elapsed) с"
        }
        return sidecar.state.description
    }

    private func hintLine() -> String {
        let config = ConfigStore.shared.config
        let key = HotkeyMonitor.keyName(for: Int64(config.hotkey.keyCode))
        let mode = config.hotkey.mode == "toggle" ? "переключение" : "удержание"
        var text = "\(key) — \(mode)"
        if hotkey.isRunning, hotkey.mechanism == "nsevent" { text += " · Accessibility" }
        if hotkey.isRunning, hotkey.mechanism == "cgeventtap" { text += " · Input Monitoring" }
        if let hotkeyError { text += " · ⚠︎ \(hotkeyError)" }
        if !TextInjector.hasAccessibility() { text += " · ⚠︎ нет Accessibility (вставка не сработает)" }
        return text
    }

    private func trimmed(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Actions

    @objc private func copyLastText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastText, forType: .string)
    }

    @objc private func openHistory() {
        HistoryLog.open()
    }

    @objc private func openSettings() {
        ConfigStore.shared.reload()
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController.make()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openPrivacy() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        ]
        if let last = urls.last, let url = URL(string: last) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func restartBackend() {
        startBackend()
    }

    /// Запись на 3 секунды без горячей клавиши — проверка микрофона и всей цепочки.
    @objc private func testRecording() {
        guard !isRecording, !isTranscribing else { return }
        logPermissions()
        isTestRecording = true
        startRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.stopRecording()
        }
    }

    /// Cистемные диалоги + открытие панелей: только так приложение попадает в списки TCC.
    @objc private func requestAccesses() {
        requestAccessibility()
        NSApp.activate(ignoringOtherApps: true)
        // запасной механизм перехвата — «Мониторинг ввода»
        _ = CGRequestListenEventAccess()
        Log.write("permissions requested: ax=\(AXIsProcessTrusted()) input=\(CGPreflightListenEventAccess())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.openPrivacy()
        }
    }

    private func requestAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        Log.write("permissions: accessibility requested")
    }

    /// Права, выданные в системных настройках, применяются к живому процессу —
    /// поэтому ждём их появления без перезапуска приложения.
    private func startPermissionWatchdog() {
        guard permissionTimer == nil else { return }
        Log.write("permissions: watchdog started")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if self.hotkey.isRunning {
                timer.invalidate()
                self.permissionTimer = nil
                return
            }
            if AXIsProcessTrusted() || CGPreflightListenEventAccess() {
                Log.write("permissions: появились — поднимаю перехват без перезапуска")
                timer.invalidate()
                self.permissionTimer = nil
                self.startHotkey()
            }
        }
    }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func checkPermissions() {
        startHotkey()
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "есть"
        case .notDetermined: microphone = "ещё не запрашивали"
        default: microphone = "нет"
        }
        let inputMonitoring = CGPreflightListenEventAccess() ? "есть" : "нет"
        let accessibility = TextInjector.hasAccessibility() ? "есть" : "нет"

        let alert = NSAlert()
        alert.messageText = "Разрешения"
        alert.informativeText = """
        Микрофон: \(microphone)
        Мониторинг ввода (клавиша): \(inputMonitoring)
        Универсальный доступ (вставка): \(accessibility)

        Если чего-то не хватает — нажмите «Запросить доступы…» (появится системный диалог),
        а если приложения всё равно нет в списке — перетащите Transcribator.app
        из Finder в список (меню → «Показать приложение в Finder»).
        После выдачи прав перезапустите приложение.
        """
        alert.addButton(withTitle: "Ок")
        alert.addButton(withTitle: "Открыть настройки приватности")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            openPrivacy()
        }
        updateIcon()
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func relaunchApp() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while pgrep -f '#{path}/Contents/MacOS' > /dev/null; do sleep 0.2; done; open '#{path}'"
            .replacingOccurrences(of: "#{path}", with: path)]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Вызывается из окна настроек после сохранения.
    func applyConfig() {
        startHotkey()
        if backendNeedsRestart() {
            startBackend()
        }
        updateIcon()
        rebuildMenu()
    }
}
