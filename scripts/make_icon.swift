// Генератор иконки приложения: rounded-square + большая «T».
// Запуск:  swift scripts/make_icon.swift assets/AppIcon.icns /tmp/AppIcon-preview.png
//
// Рисуем вручную через AppKit — без внешних зависимостей и бинарных исходников:
// иконку можно поправить парой чисел в этом файле и пересобрать.

import AppKit
import Foundation

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "assets/AppIcon.icns"
let previewPath = args.count > 2 ? args[2] : nil

// MARK: - Дизайн

struct Design {
    /// Поля вокруг плашки (доля от стороны холста).
    static let margin: CGFloat = 0.085
    /// Радиус скругления (доля от стороны плашки), ≈ squircle у macOS.
    static let corner: CGFloat = 0.235
    /// Размер литеры относительно плашки.
    static let letter: CGFloat = 0.60

    static let top = NSColor(srgbRed: 0.478, green: 0.396, blue: 1.000, alpha: 1)     // #7A65FF
    static let bottom = NSColor(srgbRed: 0.243, green: 0.161, blue: 0.780, alpha: 1)  // #3E29C7
}

func roundedFont(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let side = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    context.cgContext.setShouldAntialias(true)

    // Плашка
    let margin = side * Design.margin
    let plate = NSRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)
    let radius = plate.width * Design.corner
    let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // Мягкая тень под плашкой
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = side * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Градиент
    let gradient = NSGradient(starting: Design.top, ending: Design.bottom)!
    gradient.draw(in: shape, angle: -90)

    // Блик сверху слева
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let highlight = NSGradient(
        starting: NSColor.white.withAlphaComponent(0.22),
        ending: NSColor.white.withAlphaComponent(0)
    )!
    highlight.draw(
        fromCenter: NSPoint(x: plate.minX + plate.width * 0.3, y: plate.maxY),
        radius: 0,
        toCenter: NSPoint(x: plate.minX + plate.width * 0.3, y: plate.maxY),
        radius: plate.width * 0.95,
        options: []
    )
    NSGraphicsContext.restoreGraphicsState()

    // Внутренняя обводка
    let border = NSBezierPath(roundedRect: plate.insetBy(dx: side * 0.004, dy: side * 0.004),
                              xRadius: radius, yRadius: radius)
    border.lineWidth = max(1, side * 0.006)
    NSColor.white.withAlphaComponent(0.18).setStroke()
    border.stroke()

    // Литера T
    let fontSize = plate.width * Design.letter
    let font = roundedFont(fontSize, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let glyph = NSAttributedString(string: "T", attributes: attributes)
    let bounds = glyph.size()
    let origin = NSPoint(
        x: plate.midX - bounds.width / 2,
        // оптическое центрирование: чуть выше геометрического центра
        y: plate.midY - bounds.height / 2 + plate.height * 0.015
    )

    NSGraphicsContext.saveGraphicsState()
    let textShadow = NSShadow()
    textShadow.shadowColor = Design.bottom.withAlphaComponent(0.55)
    textShadow.shadowBlurRadius = side * 0.02
    textShadow.shadowOffset = NSSize(width: 0, height: -side * 0.008)
    textShadow.set()
    glyph.draw(at: origin)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Сборка .iconset → .icns

let fm = FileManager.default
let workDir = fm.temporaryDirectory.appendingPathComponent("TranscribatorIcon-\(UUID().uuidString)")
let iconset = workDir.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// (имя файла, пиксели) — то, что ожидает iconutil
let variants: [(String, Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

var cache: [Int: NSBitmapImageRep] = [:]
for (name, pixels) in variants {
    let rep = cache[pixels] ?? drawIcon(pixels: pixels)
    cache[pixels] = rep
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
}

if let previewPath {
    let preview = cache[512] ?? drawIcon(pixels: 512)
    try preview.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: previewPath))
}

let icnsURL = URL(fileURLWithPath: outPath)
try? fm.createDirectory(at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

try? fm.removeItem(at: workDir)
let size = (try? fm.attributesOfItem(atPath: icnsURL.path)[.size] as? Int) ?? 0
print("иконка: \(icnsURL.path) (\(size ?? 0) байт)")
