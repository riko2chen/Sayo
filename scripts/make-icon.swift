import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Sources/SayoUI/Resources/SayoLogo.png")
guard let source = NSImage(contentsOf: sourceURL) else {
    fputs("Unable to load selected logo at \(sourceURL.path)\n", stderr)
    exit(1)
}
let directory = root.appendingPathComponent(".build/Sayo.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let side = CGFloat(size)
        let iconScale: CGFloat = 0.80
        let inset = side * (1 - iconScale) / 2
        let rect = NSRect(x: inset, y: inset, width: side * iconScale, height: side * iconScale)
        let cornerRadius = side * 0.21 * (iconScale / 0.88)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        source.draw(in: rect, from: NSRect(origin: .zero, size: source.size), operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let file = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(file))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", directory.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }
