//
//  generate_icon.swift
//  PCBuds
//
//  Offline, deterministic macOS app-icon renderer.
//
//  Core Graphics only: no fonts, no filters, no blur. Every shape is analytic
//  and every colour is fixed, so the same toolchain and SDK produce
//  byte-identical PNGs on every machine and CI can verify reproducibility.
//
//  Design (Apple HIG app-icon grid):
//    - 1024 px canvas; 824 px full-bleed rounded-rect body, corner radius 185.
//    - Body gradient #3A3F4A → #1C1F24 with a 1.5 % white top highlight only.
//      No outline ring, no bevel, no drop shadow: macOS 26/27 supplies the
//      glass treatment for Dock and Launchpad itself.
//    - Glyph: one symmetric pair of mirrored TWS earbuds (rounded head, tapered
//      stem, oval nozzle tip), paper white, ~52 % of the body width.
//    - Accent: one cyan arc per side, cancelled by a thin slash. Under 15 % of
//      the glyph area and ≥ 2 px at 16 px.
//    - No letters, no glow, no fine detail.
//
//  Usage:
//    swift Scripts/icon/generate_icon.swift              # write assets
//    swift Scripts/icon/generate_icon.swift --preview    # also write /tmp previews
//
import AppKit
import Foundation

// MARK: - Design constants (1024 px design space, origin top-left)

private enum Design {
    static let canvas: CGFloat = 1024
    static let bodySize: CGFloat = 824
    static let bodyTop: CGFloat = 100
    static let bodyCorner: CGFloat = 185

    /// Glyph: two mirrored TWS buds, ~52 % of the body width, centred.
    static let glyphCentreX: CGFloat = 512
    static let glyphCentreY: CGFloat = 512
    /// Head centres sit this far either side of the glyph centre.
    static let budAnchorX: CGFloat = 136
    static let budTilt: CGFloat = 10 * .pi / 180

    /// Bud in local space (+y down), head centred on the origin: a round head
    /// with a wide enough rim that the stem can join it without a corner, and a
    /// capsule stem running down from that rim.
    static let headRadiusX: CGFloat = 82
    static let headRadiusY: CGFloat = 88
    static let stemWidth: CGFloat = 74
    /// Y of the stem tip, measured from the head centre.
    static let stemBottomY: CGFloat = 258
    /// A soft bump on the inner flank, so the bud reads as an earbud.
    static let nozzleRadiusX: CGFloat = 24
    static let nozzleRadiusY: CGFloat = 16
    static let nozzleOffset = CGPoint(x: -70, y: 6)

    /// Waves: two thin concentric arcs hugging each bud's outboard edge.
    static let waveCentreY: CGFloat = 60
    static let waveRadii: (CGFloat, CGFloat) = (108, 142)
    static let waveStart: CGFloat = 118 * .pi / 180
    static let waveEnd: CGFloat = 206 * .pi / 180
    static let waveLine: CGFloat = 16
}

private enum Ink {
    static let bodyTop = CGColor(srgbRed: 0x3A / 255, green: 0x3F / 255, blue: 0x4A / 255, alpha: 1)
    static let bodyBottom = CGColor(srgbRed: 0x1C / 255, green: 0x1F / 255, blue: 0x24 / 255, alpha: 1)
    static let topHighlight = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.015)
    static let paper = CGColor(srgbRed: 0xF7 / 255, green: 0xFA / 255, blue: 0xFF / 255, alpha: 1)
    static let accent = CGColor(srgbRed: 0x4F / 255, green: 0xB3 / 255, blue: 0xFF / 255, alpha: 1)
    static let well = CGColor(gray: 0.10, alpha: 1)
}

// MARK: - Geometry

/// Apple's icon body: a rounded rect with circular corners at HIG radius.
private func bodyPath(rect: CGRect, corner: CGFloat) -> CGPath {
    let r = min(corner, min(rect.width, rect.height) / 2)
    let k: CGFloat = 0.5523
    let c = r * k
    let x0 = rect.minX, y0 = rect.minY, x1 = rect.maxX, y1 = rect.maxY
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x0 + r, y: y0))
    p.addLine(to: CGPoint(x: x1 - r, y: y0))
    p.addCurve(to: CGPoint(x: x1, y: y0 + r),
               control1: CGPoint(x: x1 - r + c, y: y0),
               control2: CGPoint(x: x1, y: y0 + r - c))
    p.addLine(to: CGPoint(x: x1, y: y1 - r))
    p.addCurve(to: CGPoint(x: x1 - r, y: y1),
               control1: CGPoint(x: x1, y: y1 - r + c),
               control2: CGPoint(x: x1 - r + c, y: y1))
    p.addLine(to: CGPoint(x: x0 + r, y: y1))
    p.addCurve(to: CGPoint(x: x0, y: y1 - r),
               control1: CGPoint(x: x0 + r - c, y: y1),
               control2: CGPoint(x: x0, y: y1 - r + c))
    p.addLine(to: CGPoint(x: x0, y: y0 + r))
    p.addCurve(to: CGPoint(x: x0 + r, y: y0),
               control1: CGPoint(x: x0, y: y0 + r - c),
               control2: CGPoint(x: x0 + r - c, y: y0))
    p.closeSubpath()
    return p
}

/// One TWS bud as a single closed outline: an egg-shaped head whose lower
/// flanks sweep continuously into a short, rounded stem.
private func budPath() -> CGPath {
    // Head: an ellipse, full width at its own centre line.
    let rX = Design.headRadiusX
    let rY = Design.headRadiusY
    // Stem: a capsule whose shoulders meet the head tangentially.
    let half = Design.stemWidth / 2
    // The tangent point on the head sits where the ellipse's flank matches the
    // stem flank, so head and stem join without a corner.
    let shoulderY = rY * sqrt(max(0, 1 - pow(half / rX, 2)))
    let stemTopY = shoulderY
    let tipY = Design.stemBottomY

    // Bezier controls that approximate the ellipse's shoulder smoothly.
    let k: CGFloat = 0.5523
    let path = CGMutablePath()

    // Start at the head's right shoulder, trace the head CCW over the top.
    path.move(to: CGPoint(x: half, y: stemTopY))
    // Right side of the head, up from the shoulder to the top.
    path.addCurve(to: CGPoint(x: 0, y: -rY),
                  control1: CGPoint(x: half + (rX - half) * 0.62, y: stemTopY - (stemTopY + rY) * 0.30),
                  control2: CGPoint(x: rX * k, y: -rY))
    path.addCurve(to: CGPoint(x: -half, y: stemTopY),
                    control1: CGPoint(x: -rX * k, y: -rY),
                    control2: CGPoint(x: -half - (rX - half) * 0.62, y: stemTopY - (stemTopY + rY) * 0.30))
    // Left stem flank down, round the tip, up the right flank.
    path.addLine(to: CGPoint(x: -half, y: tipY - half))
    // Rounded tip: a downward-facing semicircle, so the stem ends as a capsule
    // rather than in the concave bite an upward arc would leave.
    path.addArc(center: CGPoint(x: 0, y: tipY - half), radius: half,
                startAngle: .pi, endAngle: 0, clockwise: true)
    path.addLine(to: CGPoint(x: half, y: stemTopY))
    path.closeSubpath()
    return path
}

/// Two concentric arcs on the bud's outboard side, in bud-local space.
private func wavePaths() -> [CGPath] {
    let centre = CGPoint(x: 0, y: Design.waveCentreY)
    return [Design.waveRadii.0, Design.waveRadii.1].map { radius in
        let arc = CGMutablePath()
        // Open toward +y (down/outboard); mirrored per side by `place`.
        arc.addArc(center: centre, radius: radius,
                   startAngle: Design.waveStart, endAngle: Design.waveEnd,
                   clockwise: false)
        return arc
    }
}

/// Bud-local space → design space, for the bud on the right (`isRight`) or left.
///
/// The glyph is drawn in a flipped context (y grows downwards), so a plain
/// horizontal offset would place the right-side bud at a positive x — that is
/// what `isRight` encodes. The mirrored bud also flips about its own head centre
/// and tilts the opposite way, so the pair reads as a left and a right earbud.
private func budTransform(isRight: Bool) -> CGAffineTransform {
    let anchorX = Design.glyphCentreX + (isRight ? Design.budAnchorX : -Design.budAnchorX)
    let angle = isRight ? Design.budTilt : -Design.budTilt
    return CGAffineTransform(rotationAngle: angle)
        .concatenating(CGAffineTransform(scaleX: isRight ? -1 : 1, y: 1))
        .concatenating(CGAffineTransform(translationX: anchorX, y: Design.glyphCentreY))
}

// MARK: - Render

private func makeContext(pixels: Int) -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels,
                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

private func renderIcon(pixels: Int) -> CGImage {
    let ctx = makeContext(pixels: pixels)
    let scale = CGFloat(pixels) / Design.canvas
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: Design.canvas)
    ctx.scaleBy(x: 1, y: -1)

    let body = CGRect(x: (Design.canvas - Design.bodySize) / 2,
                      y: Design.bodyTop,
                      width: Design.bodySize,
                      height: Design.bodySize)

    // Full-bleed body: graphite gradient, one 1.5 % white top highlight, no
    // outline ring, no bevel, no shadow.
    ctx.saveGState()
    ctx.addPath(bodyPath(rect: body, corner: Design.bodyCorner))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [Ink.bodyTop, Ink.bodyBottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: body.midX, y: body.minY),
                           end: CGPoint(x: body.midX, y: body.maxY), options: [])
    let highlight = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [Ink.topHighlight, CGColor(gray: 1, alpha: 0)] as CFArray,
                               locations: [0, 1])!
    ctx.drawLinearGradient(highlight,
                           start: CGPoint(x: body.midX, y: body.minY),
                           end: CGPoint(x: body.midX, y: body.minY + Design.bodySize * 0.28),
                           options: [])
    ctx.restoreGState()

    let bud = budPath()
    let waves = wavePaths()

    // Explicit sides: one bud left, one bud right, whatever the transform name says.
    for sideRight in [false, true] {
        let placement = budTransform(isRight: sideRight)

        // Waves hug the outboard edge of the bud; noise being absorbed.
        ctx.saveGState()
        ctx.concatenate(placement)
        ctx.setLineCap(.round)
        for (index, detector) in waves.enumerated() {
            ctx.addPath(detector)
            ctx.setLineWidth(index == 0 ? Design.waveLine : Design.waveLine * 0.75)
            ctx.setStrokeColor(index == 0 ? Ink.accent : Ink.paper)
            ctx.strokePath()
        }
        ctx.restoreGState()

        // The bud: head, stem and ear-tip overlap in the same white, so the
        // combined shape is continuous with no band or scar across the joint.
        ctx.saveGState()
        ctx.concatenate(placement)
        ctx.addPath(bud)
        ctx.setFillColor(Ink.paper)
        ctx.fillPath()
        ctx.restoreGState()
    }

    guard let image = ctx.makeImage() else {
        fatalError("Core Graphics returned no image for \(pixels) px")
    }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw IconError.pngEncodingFailed(url)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: url)
}

// MARK: - Asset layout

private struct ICNSVariant {
    let name: String
    let pixels: Int
}

private let icnsVariants: [ICNSVariant] = [
    ICNSVariant(name: "icon_16x16", pixels: 16),
    ICNSVariant(name: "icon_16x16@2x", pixels: 32),
    ICNSVariant(name: "icon_32x32", pixels: 32),
    ICNSVariant(name: "icon_32x32@2x", pixels: 64),
    ICNSVariant(name: "icon_128x128", pixels: 128),
    ICNSVariant(name: "icon_128x128@2x", pixels: 256),
    ICNSVariant(name: "icon_256x256", pixels: 256),
    ICNSVariant(name: "icon_256x256@2x", pixels: 512),
    ICNSVariant(name: "icon_512x512", pixels: 512),
    ICNSVariant(name: "icon_512x512@2x", pixels: 1024)
]

private let previewSizes = [16, 32, 48, 128]

private enum IconError: Error, CustomStringConvertible {
    case pngEncodingFailed(URL)
    case icnsFailed(Int32)

    var description: String {
        switch self {
        case .pngEncodingFailed(let url): return "could not encode PNG at \(url.path)"
        case .icnsFailed(let status): return "iconutil exited with status \(status)"
        }
    }
}

/// Repo root, resolvable from any working directory.
private func repoRoot() -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var candidate = cwd
    for _ in 0..<8 {
        if FileManager.default.fileExists(atPath:
            candidate.appendingPathComponent("Scripts/icon/generate_icon.swift").path) {
            return candidate
        }
        candidate = candidate.deletingLastPathComponent()
    }
    return cwd
}

private func runIconutil(from iconset: URL, to output: URL) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return -1
    }
}

// MARK: - Entry point
//
// A Swift script owns its top-level entry point, so the pipeline runs from the
// last statement rather than behind `@main`.

private func generate() throws {
    let preview = CommandLine.arguments.contains("--preview")
    let root = repoRoot()
    let resources = root.appendingPathComponent("Resources", isDirectory: true)
    let iconDir = resources.appendingPathComponent("icon", isDirectory: true)
    let icnsURL = resources.appendingPathComponent("AppIcon.icns")

    let masterURL = iconDir.appendingPathComponent("AppIcon-1024.png")
    try writePNG(renderIcon(pixels: 1024), to: masterURL)
    print("master: \(masterURL.path)")

    let iconset = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("PCBuds-AppIcon.iconset", isDirectory: true)
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for variant in icnsVariants {
        try writePNG(renderIcon(pixels: variant.pixels),
                     to: iconset.appendingPathComponent(variant.name + ".png"))
    }
    try? FileManager.default.removeItem(at: icnsURL)
    let status = runIconutil(from: iconset, to: icnsURL)
    guard status == 0 else { throw IconError.icnsFailed(status) }
    print("icns: \(icnsURL.path)")

    if preview {
        let dir = URL(fileURLWithPath: "/tmp/pcbuds-icon-preview", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for size in previewSizes {
            try writePNG(renderIcon(pixels: size),
                         to: dir.appendingPathComponent("preview-\(size).png"))
        }
        print("preview: /tmp/pcbuds-icon-preview/preview-{16,32,48,128}.png")
    }
}

do {
    try generate()
} catch {
    FileHandle.standardError.write(Data("generate_icon failed\n".utf8))
    exit(1)
}
