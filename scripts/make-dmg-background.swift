#!/usr/bin/env swift
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("Usage: make-dmg-background.swift <output.png>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let width = 660
let height = 420
let canvasSize = NSSize(width: width, height: height)

func renderBackground(scale: Int, to outputURL: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width * scale,
        pixelsHigh: height * scale,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fputs("Failed to create DMG background canvas\n", stderr)
        exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    // Draw text and paths at their native backing resolution, in the same logical layout.
    context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    let bounds = NSRect(origin: .zero, size: canvasSize)
    NSColor(calibratedWhite: 0.975, alpha: 1).setFill()
    bounds.fill()

    let glow = NSGradient(
        starting: NSColor(calibratedRed: 0.91, green: 0.95, blue: 1.0, alpha: 0.7),
        ending: NSColor(calibratedWhite: 0.975, alpha: 0)
    )
    glow?.draw(in: NSRect(x: 0, y: 235, width: 660, height: 185), angle: 90)

    let titleStyle = NSMutableParagraphStyle()
    titleStyle.alignment = .center

    let title = "Drag Sayo to Applications"
    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
        .paragraphStyle: titleStyle
    ]
    title.draw(in: NSRect(x: 80, y: 338, width: 500, height: 36), withAttributes: titleAttributes)

    let subtitle = "将 Sayo 拖入右侧 Applications 文件夹，即可完成安装。"
    let subtitleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.43, alpha: 1),
        .paragraphStyle: titleStyle
    ]
    subtitle.draw(in: NSRect(x: 80, y: 311, width: 500, height: 22), withAttributes: subtitleAttributes)

    let arrowColor = NSColor(calibratedRed: 0.16, green: 0.40, blue: 0.32, alpha: 1)
    arrowColor.setStroke()
    arrowColor.setFill()

    let line = NSBezierPath()
    line.lineWidth = 6
    line.lineCapStyle = .round
    line.move(to: NSPoint(x: 278, y: 188))
    line.curve(
        to: NSPoint(x: 392, y: 188),
        controlPoint1: NSPoint(x: 315, y: 188),
        controlPoint2: NSPoint(x: 352, y: 188)
    )
    line.stroke()

    let arrowHead = NSBezierPath()
    arrowHead.move(to: NSPoint(x: 392, y: 188))
    arrowHead.line(to: NSPoint(x: 371, y: 204))
    arrowHead.line(to: NSPoint(x: 371, y: 172))
    arrowHead.close()
    arrowHead.fill()

    let dragStyle = NSMutableParagraphStyle()
    dragStyle.alignment = .center
    let dragAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: arrowColor,
        .paragraphStyle: dragStyle
    ]
    "DRAG TO INSTALL".draw(in: NSRect(x: 270, y: 207, width: 130, height: 18), withAttributes: dragAttributes)

    // Preserve 660 × 420 points in both PNGs (72 DPI and 144 DPI respectively).
    bitmap.size = canvasSize
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Failed to render DMG background\n", stderr)
        exit(1)
    }

    try png.write(to: outputURL, options: .atomic)
}

try renderBackground(scale: 1, to: outputURL)
let retinaURL = outputURL.deletingLastPathComponent()
    .appendingPathComponent(outputURL.deletingPathExtension().lastPathComponent + "@2x.png")
try renderBackground(scale: 2, to: retinaURL)
