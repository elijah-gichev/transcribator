import AppKit
import ApplicationServices
import CoreGraphics

/// Вставка текста в активное приложение.
enum TextInjector {
    /// Есть ли разрешение Accessibility (нужно для синтетических нажатий).
    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func insert(
        _ text: String,
        mode: InsertionConfig,
        completion: (() -> Void)? = nil
    ) {
        guard !text.isEmpty else { return }
        let payload = mode.trailingSpace ? text + " " : text
        let pasteboard = NSPasteboard.general

        switch mode.mode {
        case "clipboard":
            pasteboard.clearContents()
            pasteboard.setString(payload, forType: .string)
            completion?()

        case "paste":
            let previous = mode.restoreClipboard ? snapshot(of: pasteboard) : nil
            pasteboard.clearContents()
            pasteboard.setString(payload, forType: .string)

            guard hasAccessibility() else {
                // Без Accessibility вставить не сможем — текст хотя бы в буфере.
                NSSound.beep()
                completion?()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                postCommandV()
                if let previous {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        restore(previous, to: pasteboard)
                        completion?()
                    }
                } else {
                    completion?()
                }
            }

        default:
            completion?()
        }
    }

    // MARK: - Private

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // kVK_ANSI_V
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        let captured: [[NSPasteboard.PasteboardType: Data]] = items.map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            return entry
        }
        return PasteboardSnapshot(items: captured)
    }

    private static func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
