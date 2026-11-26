import AppKit
import CoreGraphics

// Cornelia icon generator: a friendly cow in a flat, chunky mascot style.
// Usage: swift make-icon.swift <out-dir>
// Writes icon_1024.png plus AppIcon.iconset for iconutil.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let S: CGFloat = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Apple style continuous-corner rounded rect (the "squircle" used by macOS and iOS icons).
func squircle(_ r: CGRect, radius rad: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let rr = min(rad, min(r.width, r.height) / 2 / 1.52866483)
    // One corner described in a local frame: edge comes in along +x, leaves along +y.
    let pts: [(CGFloat, CGFloat)] = [
        (-1.52866483, 0),
        (-1.08849323, 0), (-0.86840689, 0), (-0.63149399, 0.07491100),
        (-0.37282392, 0.16905899), (-0.16905899, 0.37282392), (-0.07491100, 0.63149399),
        (0, 0.86840689), (0, 1.08849323), (0, 1.52866483),
    ]
    // corner origin and axis directions, walking clockwise in a y-up space starting bottom-right
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: r.maxX, y: r.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),   // bottom right
        (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),  // top right
        (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)), // top left
        (CGPoint(x: r.minX, y: r.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),  // bottom left
    ]
    for (i, (o, ax, ay)) in corners.enumerated() {
        func pt(_ v: (CGFloat, CGFloat)) -> CGPoint {
            CGPoint(x: o.x + (ax.dx * v.0 + ay.dx * v.1) * rr, y: o.y + (ax.dy * v.0 + ay.dy * v.1) * rr)
        }
        if i == 0 { p.move(to: pt(pts[0])) } else { p.addLine(to: pt(pts[0])) }
        p.addCurve(to: pt(pts[3]), control1: pt(pts[1]), control2: pt(pts[2]))
        p.addCurve(to: pt(pts[6]), control1: pt(pts[4]), control2: pt(pts[5]))
        p.addCurve(to: pt(pts[9]), control1: pt(pts[7]), control2: pt(pts[8]))
    }
    p.closeSubpath()
    return p
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// Palette
let ink = color(0x2B2A33)
let hide = color(0xFFFCF7)
let hideShade = color(0xEFE8DE)
let patch = color(0x2E2C35)
let pink = color(0xF6A9B8)
let pinkDeep = color(0xE07A90)
let horn = color(0xF4DDA8)
let outline: CGFloat = 12

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
}

func rotated(_ path: CGPath, _ angle: CGFloat, around c: CGPoint) -> CGPath {
    var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).translatedBy(x: -c.x, y: -c.y)
    return path.copy(using: &t)!
}

func fillStroke(_ ctx: CGContext, _ path: CGPath, _ fill: CGColor, width: CGFloat = outline) {
    ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath()
    ctx.addPath(path); ctx.setStrokeColor(ink); ctx.setLineWidth(width); ctx.setLineJoin(.round); ctx.strokePath()
}

/// Head: a soft, slightly bottom-heavy bean, like a mascot's body-head.
func headPath() -> CGPath {
    let p = CGMutablePath()
    // y-down coordinates
    p.move(to: CGPoint(x: 512, y: 270))
    p.addCurve(to: CGPoint(x: 790, y: 560), control1: CGPoint(x: 700, y: 270), control2: CGPoint(x: 790, y: 390))
    p.addCurve(to: CGPoint(x: 512, y: 860), control1: CGPoint(x: 790, y: 760), control2: CGPoint(x: 690, y: 860))
    p.addCurve(to: CGPoint(x: 234, y: 560), control1: CGPoint(x: 334, y: 860), control2: CGPoint(x: 234, y: 760))
    p.addCurve(to: CGPoint(x: 512, y: 270), control1: CGPoint(x: 234, y: 390), control2: CGPoint(x: 324, y: 270))
    p.closeSubpath()
    return p
}

func render(size px: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / S, y: CGFloat(px) / S)
    ctx.interpolationQuality = .high

    // Squircle background (y-up space)
    let body = CGRect(x: 100, y: 112, width: 824, height: 824)
    let shape = squircle(body, radius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.3))
    ctx.addPath(shape); ctx.setFillColor(color(0x000000)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    linear(ctx, [color(0x9EDCFF), color(0x5BB3F5)], from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.minY))

    // Switch to y-down for the character, within the body area.
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)
    // Body sits 112 from the bottom, so in y-down its top is at 88; shift the art to sit in the body.
    ctx.translateBy(x: 0, y: -12)

    // Grass hill
    let hill = CGMutablePath()
    hill.move(to: CGPoint(x: 60, y: 900))
    hill.addCurve(to: CGPoint(x: 964, y: 860), control1: CGPoint(x: 300, y: 790), control2: CGPoint(x: 700, y: 780))
    hill.addLine(to: CGPoint(x: 964, y: 1000)); hill.addLine(to: CGPoint(x: 60, y: 1000)); hill.closeSubpath()
    ctx.addPath(hill); ctx.setFillColor(color(0x7ED67A)); ctx.fillPath()

    // Soft shadow under the head
    ctx.saveGState()
    ctx.addPath(ellipse(512, 848, 205, 22)); ctx.setFillColor(color(0x000000, 0.12)); ctx.fillPath()
    ctx.restoreGState()

    // Character, scaled down slightly around its center for breathing room
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 590); ctx.scaleBy(x: 0.88, y: 0.88); ctx.translateBy(x: -512, y: -590)

    // Horns
    for (x, a) in [(372.0, -0.35), (652.0, 0.35)] {
        let h = CGMutablePath()
        h.move(to: CGPoint(x: x - 34, y: 330))
        h.addCurve(to: CGPoint(x: x + (a < 0 ? -26 : 26), y: 228), control1: CGPoint(x: x - 34, y: 280), control2: CGPoint(x: x + (a < 0 ? -40 : 0), y: 240))
        h.addCurve(to: CGPoint(x: x + 34, y: 330), control1: CGPoint(x: x + (a < 0 ? 0 : 40), y: 240), control2: CGPoint(x: x + 34, y: 280))
        h.closeSubpath()
        fillStroke(ctx, h, horn)
    }

    // Ears
    for (cx, ang) in [(222.0, 0.45), (802.0, -0.45)] {
        let c = CGPoint(x: cx, y: 420)
        fillStroke(ctx, rotated(ellipse(cx, 420, 92, 50), ang, around: c), hide)
        ctx.addPath(rotated(ellipse(cx + (cx < 512 ? 8 : -8), 422, 58, 26), ang, around: c))
        ctx.setFillColor(pink); ctx.fillPath()
    }

    // Head with subtle shading and a black patch
    let head = headPath()
    ctx.addPath(head); ctx.setFillColor(hide); ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(head); ctx.clip()
    // bottom shade
    ctx.addPath(ellipse(512, 940, 380, 200)); ctx.setFillColor(hideShade); ctx.fillPath()
    // patch over the right side
    let spot = CGMutablePath()
    spot.move(to: CGPoint(x: 560, y: 250))
    spot.addCurve(to: CGPoint(x: 820, y: 330), control1: CGPoint(x: 660, y: 240), control2: CGPoint(x: 800, y: 260))
    spot.addLine(to: CGPoint(x: 820, y: 600))
    spot.addCurve(to: CGPoint(x: 700, y: 560), control1: CGPoint(x: 780, y: 610), control2: CGPoint(x: 730, y: 600))
    spot.addCurve(to: CGPoint(x: 600, y: 420), control1: CGPoint(x: 660, y: 520), control2: CGPoint(x: 560, y: 500))
    spot.addCurve(to: CGPoint(x: 560, y: 250), control1: CGPoint(x: 630, y: 350), control2: CGPoint(x: 540, y: 300))
    spot.closeSubpath()
    ctx.addPath(spot); ctx.setFillColor(patch); ctx.fillPath()
    // small spot on the forehead
    ctx.addPath(rotated(ellipse(400, 318, 48, 30), -0.3, around: CGPoint(x: 400, y: 318))); ctx.setFillColor(patch); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(head); ctx.setStrokeColor(ink); ctx.setLineWidth(outline); ctx.strokePath()

    // Eyes: big googly mascot eyes, pupils glancing up and to the side
    for (cx, cy, r) in [(418.0, 470.0, 96.0), (612.0, 462.0, 104.0)] {
        fillStroke(ctx, ellipse(cx, cy, r, r * 1.04), color(0xFFFFFF))
        ctx.addPath(ellipse(cx + r * 0.30, cy - r * 0.10, r * 0.40, r * 0.42)); ctx.setFillColor(ink); ctx.fillPath()
        ctx.addPath(ellipse(cx + r * 0.42, cy - r * 0.25, r * 0.12, r * 0.12)); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    }

    // Muzzle
    let muzzle = ellipse(512, 716, 172, 104)
    fillStroke(ctx, muzzle, pink)
    ctx.addPath(ellipse(512, 686, 128, 42)); ctx.setFillColor(color(0xFFFFFF, 0.25)); ctx.fillPath()
    for nx in [452.0, 572.0] {
        ctx.addPath(rotated(ellipse(nx, 704, 22, 30), nx < 512 ? 0.25 : -0.25, around: CGPoint(x: nx, y: 700)))
        ctx.setFillColor(pinkDeep); ctx.fillPath()
    }
    // Smile with two little teeth
    let smile = CGMutablePath()
    smile.move(to: CGPoint(x: 452, y: 768))
    smile.addQuadCurve(to: CGPoint(x: 572, y: 768), control: CGPoint(x: 512, y: 800))
    ctx.addPath(smile); ctx.setStrokeColor(ink); ctx.setLineWidth(9); ctx.setLineCap(.round); ctx.strokePath()
    let teeth = CGPath(roundedRect: CGRect(x: 488, y: 782, width: 48, height: 34), cornerWidth: 8, cornerHeight: 8, transform: nil)
    fillStroke(ctx, teeth, color(0xFFFFFF), width: 7)
    ctx.move(to: CGPoint(x: 512, y: 786)); ctx.addLine(to: CGPoint(x: 512, y: 814))
    ctx.setLineWidth(5); ctx.strokePath()

    // Blush
    for bx in [314.0, 710.0] {
        ctx.addPath(ellipse(bx, 610, 34, 18)); ctx.setFillColor(color(0xFF8FA6, 0.45)); ctx.fillPath()
    }
    ctx.restoreGState()

    ctx.restoreGState()

    // Hairline edge
    ctx.addPath(squircle(body.insetBy(dx: 1, dy: 1), radius: 184))
    ctx.setStrokeColor(color(0xFFFFFF, 0.15)); ctx.setLineWidth(2); ctx.strokePath()
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
writePNG(render(size: 1024), "\(outDir)/icon_1024.png")
let set = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    writePNG(render(size: size), "\(set)/icon_\(size)x\(size).png")
    writePNG(render(size: size * 2), "\(set)/icon_\(size)x\(size)@2x.png")
}
