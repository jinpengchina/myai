import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// A folded ribbon and its detached point. All coordinates are in a 100-unit square.
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}
func writeMark(at url: URL, pixels: Int, icon: Bool = false) throws {
    let alpha: CGImageAlphaInfo = icon ? .noneSkipLast : .premultipliedLast
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: pixels * 4, space: space, bitmapInfo: alpha.rawValue)!
    let scale = CGFloat(pixels) / 100
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)
    if icon {
        context.setFillColor(color(37, 25, 57))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    }
    context.saveGState()
    context.move(to: CGPoint(x: 24, y: 46))
    context.addLine(to: CGPoint(x: 46, y: 69))
    context.addLine(to: CGPoint(x: 76, y: 35))
    context.setLineWidth(14)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    let ribbon = CGGradient(colorsSpace: space, colors: [color(255, 116, 135), color(188, 149, 255)] as CFArray,
                            locations: [0, 1])!
    context.drawLinearGradient(ribbon, start: CGPoint(x: 22, y: 55), end: CGPoint(x: 77, y: 43),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    context.setFillColor(color(255, 180, 156))
    context.fillEllipse(in: CGRect(x: 35.5, y: 24, width: 12, height: 12))
    let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(writer, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try writeMark(at: directory.appendingPathComponent("icon.png"), pixels: 1024, icon: true)
for size in [408, 81, 66] {
    try writeMark(at: directory.appendingPathComponent("mark-\(size).png"), pixels: size)
}
