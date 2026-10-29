import AppKit
// Flattens each PNG onto an opaque background of the same size: App Store
// screenshots may not have an alpha channel.
for path in CommandLine.arguments.dropFirst() {
    guard let image = NSImage(contentsOfFile: path), let rep = image.representations.first else { continue }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    var rect = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.draw(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!, in: rect)
    let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
