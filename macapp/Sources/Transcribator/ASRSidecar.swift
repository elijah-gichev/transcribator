import Foundation

/// Python-сайдкар с GigaAM: процесс + построчный JSON по pipe.
final class ASRSidecar {
    enum State: Equatable {
        case stopped
        case starting
        case ready(model: String, device: String)
        case failed(String)

        var description: String {
            switch self {
            case .stopped: return "Не запущен"
            case .starting: return "Загружаю модель…"
            case let .ready(model, device): return "Готов — \(model) (\(device))"
            case let .failed(message): return "Ошибка: \(message)"
            }
        }
    }

    private(set) var state: State = .stopped {
        didSet { onState?(state) }
    }

    var onState: ((State) -> Void)?
    private(set) var logLines: [String] = []

    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutBuffer = Data()
    private var pending: [Int: (Result<String, Error>) -> Void] = [:]
    private var nextId = 1
    private var readyWaiters: [(Result<Void, Error>) -> Void] = []

    struct SidecarError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Запуск

    func start(python: String, script: String, model: String, device: String) {
        stop()
        state = .starting

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script, "--model", model, "--device", device]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        // не даём torch забирать все потоки
        env["OMP_NUM_THREADS"] = env["OMP_NUM_THREADS"] ?? "4"
        process.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendLog(text)
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failed = self.state { return }
                self.state = .failed("сайдкар завершился (код \(proc.terminationStatus))")
                self.failAllPending(Self.SidecarError(message: "сайдкар завершился"))
            }
        }

        do {
            try process.run()
        } catch {
            state = .failed("не удалось запустить \(python): \(error.localizedDescription)")
            return
        }

        self.process = process
        stdin = inPipe.fileHandleForWriting
    }

    func stop() {
        process?.terminationHandler = nil
        if let process, process.isRunning {
            try? stdin?.write(contentsOf: Data("{\"cmd\":\"shutdown\"}\n".utf8))
            process.terminate()
        }
        process = nil
        stdin = nil
        stdoutBuffer.removeAll()
        failAllPending(Self.SidecarError(message: "сайдкар остановлен"))
        if state != .stopped { state = .stopped }
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    // MARK: - API

    func whenReady(_ completion: @escaping (Result<Void, Error>) -> Void) {
        if isReady { return completion(.success(())) }
        readyWaiters.append(completion)
    }

    func transcribe(pcm: [Int16], completion: @escaping (Result<String, Error>) -> Void) {
        guard isReady else {
            return completion(.failure(SidecarError(message: "модель ещё не готова")))
        }
        let base64 = pcm.withUnsafeBytes { Data($0) }.base64EncodedString()
        let id = nextId
        nextId += 1
        pending[id] = completion
        let payload: [String: Any] = [
            "id": id,
            "cmd": "transcribe",
            "sample_rate": 16000,
            "pcm_b64": base64,
        ]
        send(payload)
    }

    func ping() {
        send(["id": nextId, "cmd": "ping"])
    }

    // MARK: - Внутреннее

    private func send(_ payload: [String: Any]) {
        guard let stdin else { return }
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            var line = String(data: data, encoding: .utf8)
        else { return }
        line += "\n"
        try? stdin.write(contentsOf: Data(line.utf8))
    }

    private func consume(_ data: Data) {
        var messages: [[String: Any]] = []
        queueLock.lock()
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newlineIndex]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty,
                  let object = (try? JSONSerialization.jsonObject(with: Data(lineData))) as? [String: Any]
            else { continue }
            messages.append(object)
        }
        queueLock.unlock()

        guard !messages.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            messages.forEach { self?.handle($0) }
        }
    }

    private let queueLock = NSLock()

    private func handle(_ message: [String: Any]) {
        if let event = message["event"] as? String {
            switch event {
            case "ready":
                let model = message["model"] as? String ?? "-"
                let device = message["device"] as? String ?? "-"
                state = .ready(model: model, device: device)
                let waiters = readyWaiters
                readyWaiters.removeAll()
                waiters.forEach { $0(.success(())) }
            case "error":
                let text = message["error"] as? String ?? "неизвестная ошибка"
                state = .failed(text)
                let waiters = readyWaiters
                readyWaiters.removeAll()
                waiters.forEach { $0(.failure(Self.SidecarError(message: text))) }
            default:
                break
            }
            return
        }

        guard let id = message["id"] as? Int, let completion = pending.removeValue(forKey: id) else { return }

        if let ok = message["ok"] as? Bool, ok {
            completion(.success(message["text"] as? String ?? ""))
        } else {
            let text = message["error"] as? String ?? "ошибка распознавания"
            completion(.failure(Self.SidecarError(message: text)))
        }
    }

    private func failAllPending(_ error: Error) {
        let callbacks = pending
        pending.removeAll()
        DispatchQueue.main.async {
            callbacks.values.forEach { $0(.failure(error)) }
        }
    }

    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            self.logLines.append(text)
            if self.logLines.count > 400 { self.logLines.removeFirst(self.logLines.count - 400) }
            FileHandle.standardError.write(Data("[sidecar] \(text)".utf8))
        }
    }
}
