// Renders the icon drawing by Scharf L., Resources/AppIcon.svg (the only source of the app icon)
// into build/AppIcon.iconset, packs it into Resources/AppIcon.icns with iconutil
// and writes docs/icon.png (512 x 512) for the README.
// AppKit draws the SVG itself (NSImage reads SVG files on current macOS), so no extra tools are needed.
// Run from the repository root: swift scripts/make_icon.swift

import AppKit

let source = URL(fileURLWithPath: "Resources/AppIcon.svg")
guard let svg = NSImage(contentsOf: source), svg.isValid,
      svg.representations.contains(where: { String(describing: type(of: $0)).contains("SVG") }) else {
    FileHandle.standardError.write("Cannot read \(source.path) as SVG\n".data(using: .utf8)!)
    exit(1)
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    // The SVG is vector data, so each size is drawn from scratch rather than scaled down.
    svg.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
             from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote Resources/AppIcon.icns")

try render(size: 512).write(to: URL(fileURLWithPath: "docs/icon.png"))
print("Wrote docs/icon.png")
