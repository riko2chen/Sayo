#!/usr/bin/env swift
import Foundation
import ImageIO

guard CommandLine.arguments.count == 2,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      CGImageSourceGetCount(source) == 2 else {
    fputs("DMG background must contain both 1× and 2× representations\n", stderr)
    exit(1)
}

for (index, scale) in [1, 2].enumerated() {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          let dpiWidth = properties[kCGImagePropertyDPIWidth] as? Double,
          let dpiHeight = properties[kCGImagePropertyDPIHeight] as? Double,
          width == 660 * scale, height == 420 * scale,
          abs(dpiWidth - Double(72 * scale)) < 0.1,
          abs(dpiHeight - Double(72 * scale)) < 0.1 else {
        fputs("DMG background has incorrect pixels or logical size for \(scale)×\n", stderr)
        exit(1)
    }
}
print("Verified DMG background: 660×420 at 1× and 1320×840 at 2×, both 660×420 points")
