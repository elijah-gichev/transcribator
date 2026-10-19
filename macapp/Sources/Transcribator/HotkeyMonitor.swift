import AppKit
import CoreGraphics

/// Глобальный перехват клавиши (push-to-talk).
///
/// Две стратегии:
/// 1. `NSEvent.addGlobalMonitorForEvents` — требует только «Универсальный доступ» (Accessibility),
///    а он всё равно нужен для вставки текста. Используется, если доступ уже есть.
/// 2. `CGEventTap` — требует «Мониторинг ввода» (Input Monitoring).
final class HotkeyMonitor {
    /// Нажатие/отпускание клавиши. Вызывается на главном потоке.
    var onEdge: ((Bool) -> Void)?
    /// Не удалось стартовать — почти всегда нет прав.
    var onFailure: ((String) -> Void)?

    private(set) var isRunning = false
    private(set) var mechanism = "none"

    private var keyCode: Int64 = 61
    private var isDown = false
    private var globalMonitor: Any?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static func modifierFlag(for keyCode: Int64) -> CGEventFlags? {
        switch keyCode {
        case 58, 61: return .maskAlternate
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    static func keyName(for keyCode: Int64) -> String {
        let names: [Int64: String] = [
            58: "Left ⌥", 61: "Right ⌥", 54: "Right ⌘", 55: "Left ⌘",
            56: "Left ⇧", 60: "Right ⇧", 59: "Left ⌃", 62: "Right ⌃",
            63: "Fn", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return names[keyCode] ?? "keyCode \(keyCode)"
    }

    // MARK: - Запуск / остановка

    @discardableResult
    func start(keyCode: Int, onFailure: @escaping (String) -> Void) -> Bool {
        stop()
        self.keyCode = Int64(keyCode)
        isDown = false
        onFailure_ = onFailure

        // 1. Accessibility → NSEvent-монитор (одно разрешение на всё приложение).
        if AXIsProcessTrusted(), startNSEventMonitor() {
            mechanism = "nsevent"
            isRunning = true
            return true
        }

        // 2. Input Monitoring → CGEventTap.
        if CGPreflightListenEventAccess(), startEventTap() {
            mechanism = "cgeventtap"
            isRunning = true
            return true
        }

        mechanism = "none"
        return false
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        source = nil
        tap = nil
        isRunning = false
        mechanism = "none"
    }

    private var onFailure_: ((String) -> Void)?

    // MARK: - Стратегия 1: NSEvent (Accessibility)

    private func startNSEventMonitor() -> Bool {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
        }
        return globalMonitor != nil
    }

    private func handleNSEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            guard Int64(event.keyCode) == keyCode,
                  let flag = Self.modifierFlag(for: keyCode)
            else { return }
            let down = event.modifierFlags.contains(NSEvent.ModifierFlags(rawValue: UInt(flag.rawValue)))
            guard down != isDown else { return }
            isDown = down
            fire(down)

        case .keyDown, .keyUp:
            guard Int64(event.keyCode) == keyCode else { return }
            if event.type == .keyDown, event.isARepeat { return }
            let down = event.type == .keyDown
            guard down != isDown else { return }
            isDown = down
            fire(down)

        default:
            return
        }
    }

    // MARK: - Стратегия 2: CGEventTap (Input Monitoring)

    private func startEventTap() -> Bool {
        let isModifier = Self.modifierFlag(for: keyCode) != nil
        var mask: CGEventMask = 0
        if isModifier {
            mask |= CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        } else {
            mask |= CGEventMask(1 << CGEventType.keyDown.rawValue)
            mask |= CGEventMask(1 << CGEventType.keyUp.rawValue)
        }
        mask |= CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
        mask |= CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handleTapEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .tapDisabledByUserInput:
            onFailure_?("система отключила перехват — проверьте разрешения")
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == keyCode,
                  let flag = Self.modifierFlag(for: keyCode)
            else { return }
            let down = event.flags.contains(flag)
            guard down != isDown else { return }
            isDown = down
            fire(down)
        case .keyDown, .keyUp:
            guard event.getIntegerValueField(.keyboardEventKeycode) == keyCode else { return }
            if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            let down = type == .keyDown
            guard down != isDown else { return }
            isDown = down
            fire(down)
        default:
            return
        }
    }

    private func fire(_ down: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onEdge?(down)
        }
    }
}
