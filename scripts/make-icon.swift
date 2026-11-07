// Renders the Islet app icon and its dark/tinted variants.
//
//   swift scripts/make-icon.swift Islet/Assets.xcassets/AppIcon.appiconset
//
// The trace is an analytic curve (a baseline plus Gaussian bumps), so it has no kinks, and the
// peak's radius of curvature stays well above half the stroke width so the stroke's inner edge
// never folds over itself.

import AppKit
import CoreGraphics
import CoreImage

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let green = (r: 0.18, g: 0.83, b: 0.63)
let amber = (r: 1.00, g: 0.70, b: 0.14)

// Target band, in unit coordinates (y up).
let bandLow: CGFloat = 0.37, bandHigh: CGFloat = 0.59

// Glucose trace: gentle dip, one broad meal peak above the band, settling back into range.
func trace(_ x: CGFloat) -> CGFloat {
    func bump(_ center: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGFloat {
        height * exp(-pow((x - center) / width, 2))
    }
    return 0.445 + bump(0.48, 0.135, 0.24) - bump(0.25, 0.10, 0.04)
}
let xStart: CGFloat = 0.15, xEnd: CGFloat = 0.80

func tracePath() -> CGPath {
    let path = CGMutablePath()
    let steps = 400
    for i in 0...steps {
        let x = xStart + (xEnd - xStart) * CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: x * S, y: trace(x) * S)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    return path
}

let lineWidth = S * 0.046
let end = CGPoint(x: xEnd * S, y: trace(xEnd) * S)

func makeContext() -> CGContext {
    CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// The line and "now" dot alone, on transparent: colored by range, or white for the tinted variant.
func foreground(mono: Bool) -> CGImage {
    let ctx = makeContext()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(lineWidth)
    ctx.addPath(tracePath())
    ctx.replacePathWithStrokedPath()
    ctx.saveGState()
    ctx.clip()
    if mono {
        ctx.setFillColor(c(1, 1, 1))
        ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
    } else {
        // Green inside the band, amber above it, with a short blend at the boundary (as in the app).
        let gradient = CGGradient(colorsSpace: cs, colors: [
            c(green.r, green.g, green.b), c(green.r, green.g, green.b),
            c(amber.r, amber.g, amber.b), c(amber.r, amber.g, amber.b),
        ] as CFArray, locations: [0, bandHigh - 0.01, bandHigh + 0.04, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: S), options: [])
    }
    ctx.restoreGState()

    // "Now" dot: a solid disc that swallows the line's end cap, with a light core.
    let outer = S * 0.050, inner = S * 0.021
    ctx.setFillColor(mono ? c(1, 1, 1) : c(green.r, green.g, green.b))
    ctx.fillEllipse(in: CGRect(x: end.x - outer, y: end.y - outer, width: outer * 2, height: outer * 2))
    if mono {
        ctx.setBlendMode(.clear)
    }
    ctx.setFillColor(c(0.93, 1, 0.97))
    ctx.fillEllipse(in: CGRect(x: end.x - inner, y: end.y - inner, width: inner * 2, height: inner * 2))
    return ctx.makeImage()!
}

/// A soft, color-matched glow made by blurring the foreground itself.
func glow(of image: CGImage, radius: CGFloat) -> CGImage {
    let input = CIImage(cgImage: image)
    let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
    return CIContext(options: [.workingColorSpace: cs]).createCGImage(blurred, from: input.extent)!
}

func drawBand(_ ctx: CGContext, alpha: CGFloat, mono: Bool = false) {
    let color = mono ? c(1, 1, 1, alpha) : c(green.r, green.g, green.b, alpha)
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: 0, y: bandLow * S, width: S, height: (bandHigh - bandLow) * S))
}

func compose(background: Bool, mono: Bool) -> CGImage {
    let ctx = makeContext()
    let full = CGRect(x: 0, y: 0, width: S, height: S)
    if background {
        let bg = CGGradient(colorsSpace: cs, colors: [c(0.025, 0.04, 0.07), c(0.02, 0.12, 0.13)] as CFArray,
                            locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
        let halo = CGGradient(colorsSpace: cs, colors: [c(green.r, green.g, green.b, 0.22), c(green.r, green.g, green.b, 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(halo, startCenter: end, startRadius: 0, endCenter: end, endRadius: S * 0.6, options: [])
    }
    drawBand(ctx, alpha: mono ? 0.16 : 0.11, mono: mono)

    let fg = foreground(mono: mono)
    if !mono {
        ctx.setAlpha(0.85)
        ctx.draw(glow(of: fg, radius: S * 0.028), in: full)
        ctx.setAlpha(0.5)
        ctx.draw(glow(of: fg, radius: S * 0.07), in: full)
        ctx.setAlpha(1)
    }
    ctx.draw(fg, in: full)
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String, to dir: URL, opaque: Bool) {
    var image = image
    if opaque {
        // App Store icons must not have an alpha channel.
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        image = ctx.makeImage()!
    }
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! data.write(to: dir.appending(path: name))
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
// Light (default): full artwork on the dark teal background.
write(compose(background: true, mono: false), "AppIcon.png", to: dir, opaque: true)
// Dark: same artwork on transparent; the system supplies the dark backdrop.
write(compose(background: false, mono: false), "AppIcon-Dark.png", to: dir, opaque: false)
// Tinted: white-on-transparent luminance mask the system colors with the user's tint.
write(compose(background: false, mono: true), "AppIcon-Tinted.png", to: dir, opaque: false)
