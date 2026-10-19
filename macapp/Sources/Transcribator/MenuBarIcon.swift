import AppKit

/// Иконка в меню-баре: буква «T» тем же гротеском, что и иконка приложения.
enum MenuBarIcon {
    /// Template-изображение: цвет берётся из `contentTintColor` (или из темы меню-бара).
    static func letter(
        _ letter: String = "T",
        canvas: CGFloat = 22,
        fontSize: CGFloat = 17,
        weight: NSFont.Weight = .semibold
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            let base = NSFont.systemFont(ofSize: fontSize, weight: weight)
            let font: NSFont
            if let descriptor = base.fontDescriptor.withDesign(.rounded) {
                font = NSFont(descriptor: descriptor, size: fontSize) ?? base
            } else {
                font = base
            }

            let text = NSAttributedString(
                string: letter,
                attributes: [.font: font, .foregroundColor: NSColor.black]
            )
            let size = text.size()
            text.draw(at: NSPoint(
                x: (canvas - size.width) / 2,
                // чуть выше геометрического центра — так буква оптически ровнее
                y: (canvas - size.height) / 2 + canvas * 0.04
            ))
            return true
        }
        image.isTemplate = true
        return image
    }
}
