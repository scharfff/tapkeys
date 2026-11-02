// Renders the background of the installer DMG window: a light grey vertical gradient,
// a thin dark grey arrow between the two icon slots and a short hint.
// The background is light on purpose: Finder draws icon labels on a background picture in
// black whatever the system appearance is, so a dark picture makes them unreadable.
// Writes Resources/dmg-background.png (600 x 400) and Resources/dmg-background@2x.png (1200 x 800).
// Run from the repository root: swift scripts/make_dmg_background.swift
//
// The slots must match scripts/make_dmg.sh: icons are centered at (150, 185) and (450, 185)
// in window points, measured from the top left corner of the window content.

import AppKit

let width: CGFloat = 600
let height: CGFloat = 400
let iconY: CGFloat = 185
let leftSlot: CGFloat = 150
let rightSlot: CGFloat = 450
let iconSize: CGFloat = 128

func render(scale: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // Size in points stays 600 x 400, so the 2x image gets 144 dpi and Finder treats it as Retina.
    // The graphics context then maps points to pixels by itself, no manual scaling is needed.
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    let nsContext = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsContext
    let ctx = nsContext.cgContext

    // Core Graphics counts y from the bottom; the layout above counts from the top.
    func y(_ top: CGFloat) -> CGFloat { height - top }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Background: light grey, a little darker at the bottom. Black Finder labels stay readable.
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0xf4 / 255, green: 0xf4 / 255, blue: 0xf4 / 255, alpha: 1),
        CGColor(srgbRed: 0xde / 255, green: 0xde / 255, blue: 0xde / 255, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

    // Arrow between the icons: a thin shaft with an open chevron head.
    let start = leftSlot + iconSize / 2 + 28
    let end = rightSlot - iconSize / 2 - 28
    let arrowColor = CGColor(srgbRed: 0.36, green: 0.36, blue: 0.38, alpha: 1)
    ctx.setStrokeColor(arrowColor)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: start, y: y(iconY)))
    ctx.addLine(to: CGPoint(x: end, y: y(iconY)))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: end - 15, y: y(iconY - 15)))
    ctx.addLine(to: CGPoint(x: end, y: y(iconY)))
    ctx.addLine(to: CGPoint(x: end - 15, y: y(iconY + 15)))
    ctx.strokePath()

    // Hint at the bottom, centered.
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let hint = NSAttributedString(string: "Drag to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.32, green: 0.32, blue: 0.34, alpha: 1),
        .kern: 0.4,
        .paragraphStyle: paragraph,
    ])
    hint.draw(in: NSRect(x: 0, y: y(352), width: width, height: 20))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: URL(fileURLWithPath: "Resources/dmg-background.png"))
try render(scale: 2).write(to: URL(fileURLWithPath: "Resources/dmg-background@2x.png"))
print("Wrote Resources/dmg-background.png and Resources/dmg-background@2x.png")
