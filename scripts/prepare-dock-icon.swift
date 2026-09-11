import AppKit
import QuartzCore

enum DockIconError: Error, CustomStringConvertible {
    case usage
    case invalidImage
    case renderingFailed

    var description: String {
        switch self {
        case .usage: "Usage: swift scripts/prepare-dock-icon.swift <square-source.png> <output.imageset>"
        case .invalidImage: "The source must be a readable square image."
        case .renderingFailed: "Could not render the Dock icon."
        }
    }
}

func renderDockIcon(_ source: CGImage, pixels: Int) throws -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { throw DockIconError.renderingFailed }

    // macOS app icons occupy an 824-point tile inside a 1024-point transparent canvas.
    let scale = CGFloat(pixels) / 1_024
    let canvas = CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels))
    let tileFrame = canvas.insetBy(dx: 100 * scale, dy: 100 * scale)
    let root = CALayer()
    root.frame = canvas
    root.contentsScale = 1

    let shadow = CALayer()
    shadow.frame = tileFrame
    shadow.backgroundColor = NSColor.black.cgColor
    shadow.cornerRadius = 185 * scale
    shadow.cornerCurve = .continuous
    shadow.shadowColor = NSColor.black.cgColor
    shadow.shadowOpacity = 0.18
    shadow.shadowRadius = 12 * scale
    shadow.shadowOffset = CGSize(width: 0, height: -4 * scale)
    root.addSublayer(shadow)

    let tile = CALayer()
    tile.frame = tileFrame
    tile.cornerRadius = 185 * scale
    tile.cornerCurve = .continuous
    tile.masksToBounds = true
    tile.contents = source
    tile.contentsGravity = .resizeAspect
    tile.minificationFilter = .trilinear
    root.addSublayer(tile)
    root.render(in: context)

    guard let rendered = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
        throw DockIconError.renderingFailed
    }
    return png
}

do {
    guard CommandLine.arguments.count == 3 else { throw DockIconError.usage }
    let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: sourceURL)),
          bitmap.pixelsWide == bitmap.pixelsHigh,
          let source = bitmap.cgImage else { throw DockIconError.invalidImage }
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    for (pixels, name) in [(512, "runtime_running.png"), (1_024, "runtime_running@2x.png")] {
        let png = try renderDockIcon(source, pixels: pixels)
        try png.write(to: outputURL.appendingPathComponent(name), options: .atomic)
        print("Generated \(name): \(pixels)x\(pixels), with transparent padding and continuous corners")
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
