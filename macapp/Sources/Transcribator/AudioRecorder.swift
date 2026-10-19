import AVFoundation
import Foundation

/// Запись с микрофона сразу в 16 kHz mono int16 (формат модели).
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    private var converter: AVAudioConverter?
    private var storage = Data()
    private let lock = NSLock()
    private(set) var isRecording = false

    /// Уровень сигнала 0…1 для индикации.
    var onLevel: ((Float) -> Void)?

    enum RecorderError: LocalizedError {
        case noInput
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noInput: return "Микрофон не найден или недоступен"
            case let .failed(message): return message
            }
        }
    }

    func start() throws {
        guard !isRecording else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.failed("Не удалось создать конвертер \(inputFormat.sampleRate) Hz → 16 kHz")
        }
        self.converter = converter

        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.failed("Не удалось запустить запись: \(error.localizedDescription)")
        }
        isRecording = true
    }

    /// Останавливает запись и отдаёт PCM (int16, 16 kHz, mono).
    func stop() -> [Int16] {
        guard isRecording else { return [] }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let data = storage
        storage.removeAll(keepingCapacity: false)
        lock.unlock()

        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0 else { return }
        if let channel = output.int16ChannelData {
            let frames = Int(output.frameLength)
            let pointer = UnsafeBufferPointer(start: channel[0], count: frames)
            let peak = pointer.reduce(into: Float(0)) { acc, sample in
                acc = max(acc, abs(Float(sample)) / 32768)
            }
            if let onLevel { DispatchQueue.main.async { onLevel(min(1, peak * 2.5)) } }
            lock.lock()
            storage.append(pointer)
            lock.unlock()
        }
    }
}
