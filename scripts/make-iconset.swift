import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-iconset.swift <source-png> <output-iconset>\n".utf8))
    exit(2)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let iconsetURL = URL(fileURLWithPath: arguments[2], isDirectory: true)

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("failed to read icon source: \(sourceURL.path)\n".utf8))
    exit(1)
}

try FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let targets: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

func resizedPNG(size: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw NSError(domain: "SystemGuardIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to create bitmap context"])
    }

    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: size, height: size))

    guard let resized = context.makeImage() else {
        throw NSError(domain: "SystemGuardIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "failed to create resized image"])
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "SystemGuardIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "failed to create PNG destination"])
    }

    CGImageDestinationAddImage(destination, resized, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "SystemGuardIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "failed to write PNG"])
    }

    return data as Data
}

for target in targets {
    let png = try resizedPNG(size: target.0)
    try png.write(to: iconsetURL.appendingPathComponent(target.1))
}
