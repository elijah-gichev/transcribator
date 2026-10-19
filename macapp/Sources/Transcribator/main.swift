import AppKit
import ApplicationServices
import AVFoundation

// Диагностика разрешений без запуска UI:
//   build/Transcribator.app/Contents/MacOS/Transcribator --check-permissions
if CommandLine.arguments.contains("--check-permissions") {
    let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    let microphoneText: String
    switch microphone {
    case .authorized: microphoneText = "granted"
    case .denied: microphoneText = "denied"
    case .restricted: microphoneText = "restricted"
    case .notDetermined: microphoneText = "not determined"
    @unknown default: microphoneText = "unknown"
    }
    print("microphone:        \(microphoneText)")
    print("input monitoring:  \(CGPreflightListenEventAccess() ? "granted" : "denied")")
    print("accessibility:     \(AXIsProcessTrusted() ? "granted" : "denied")")
    print("support dir:       \(ConfigStore.supportDirectory.path)")
    print("")
    print("Внимание: запуск из терминала делает ответственным процессом терминал,")
    print("поэтому строка про микрофон здесь может врать. Достоверные значения приложение")
    print("пишет в app.log при каждом старте (через `open`).")
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)

NotificationCenter.default.addObserver(
    forName: .transcribatorConfigChanged,
    object: nil,
    queue: .main
) { _ in
    controller.applyConfig()
}

app.run()
