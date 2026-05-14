import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: crop_icon.swift input.png output.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let image = NSImage(contentsOf: inputURL) else {
    fputs("Could not load input image.\n", stderr)
    exit(1)
}

var proposedRect = NSRect(origin: .zero, size: image.size)
guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
    fputs("Could not create CGImage.\n", stderr)
    exit(1)
}

let width = cgImage.width
let height = cgImage.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
let colorSpace = CGColorSpaceCreateDeviceRGB()
var source = [UInt8](repeating: 0, count: height * bytesPerRow)

guard let sourceContext = CGContext(
    data: &source,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Could not create source context.\n", stderr)
    exit(1)
}

sourceContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

let whiteThreshold: UInt8 = 225
let alphaThreshold: UInt8 = 20

func sourceOffset(x: Int, y: Int) -> Int {
    y * bytesPerRow + x * bytesPerPixel
}

func isBackground(x: Int, y: Int) -> Bool {
    let offset = sourceOffset(x: x, y: y)
    let red = source[offset]
    let green = source[offset + 1]
    let blue = source[offset + 2]
    let alpha = source[offset + 3]
    return alpha < alphaThreshold || (red > whiteThreshold && green > whiteThreshold && blue > whiteThreshold)
}

var minX = width
var minY = height
var maxX = -1
var maxY = -1

for y in 0..<height {
    for x in 0..<width where !isBackground(x: x, y: y) {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}

guard maxX >= minX, maxY >= minY else {
    fputs("Could not find artwork to crop.\n", stderr)
    exit(1)
}

let artworkWidth = maxX - minX + 1
let artworkHeight = maxY - minY + 1
let artworkSide = max(artworkWidth, artworkHeight)
let zoomInset = Int(Double(artworkSide) * 0.075)
let cropSide = min(max(artworkSide - zoomInset * 2, 1), max(width, height))
let centerX = (minX + maxX) / 2
let centerY = (minY + maxY) / 2
let cropX = max(0, min(centerX - cropSide / 2, width - cropSide))
let cropY = max(0, min(centerY - cropSide / 2, height - cropSide))

let finalSide = 1024
let finalBytesPerRow = finalSide * bytesPerPixel
var output = [UInt8](repeating: 0, count: finalSide * finalBytesPerRow)

let iconSide = 860
let iconInset = (finalSide - iconSide) / 2
let cornerRadius = 182.0

func roundedRectAlpha(x: Int, y: Int) -> UInt8 {
    let localX = Double(x - iconInset)
    let localY = Double(y - iconInset)
    let side = Double(iconSide)

    guard localX >= 0, localY >= 0, localX < side, localY < side else {
        return 0
    }

    let cx = localX < cornerRadius ? cornerRadius : (localX > side - cornerRadius ? side - cornerRadius : localX)
    let cy = localY < cornerRadius ? cornerRadius : (localY > side - cornerRadius ? side - cornerRadius : localY)
    let distance = hypot(localX - cx, localY - cy)

    if distance <= cornerRadius - 1 {
        return 255
    }
    if distance >= cornerRadius + 1 {
        return 0
    }

    let coverage = max(0, min(1, cornerRadius + 1 - distance)) / 2
    return UInt8(coverage * 255)
}

for y in 0..<finalSide {
    for x in 0..<finalSide {
        let maskAlpha = roundedRectAlpha(x: x, y: y)
        guard maskAlpha > 0 else { continue }

        let localX = x - iconInset
        let localY = y - iconInset
        let sx = cropX + min(cropSide - 1, localX * cropSide / iconSide)
        let sy = cropY + min(cropSide - 1, localY * cropSide / iconSide)
        let inputOffset = sourceOffset(x: sx, y: sy)
        let outputOffset = y * finalBytesPerRow + x * bytesPerPixel

        if isBackground(x: sx, y: sy) {
            output[outputOffset] = 0
            output[outputOffset + 1] = 0
            output[outputOffset + 2] = 0
            output[outputOffset + 3] = 0
        } else {
            output[outputOffset] = source[inputOffset]
            output[outputOffset + 1] = source[inputOffset + 1]
            output[outputOffset + 2] = source[inputOffset + 2]
            output[outputOffset + 3] = UInt8((UInt16(source[inputOffset + 3]) * UInt16(maskAlpha)) / 255)
        }
    }
}

guard let outputContext = CGContext(
    data: &output,
    width: finalSide,
    height: finalSide,
    bitsPerComponent: 8,
    bytesPerRow: finalBytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
), let outputImage = outputContext.makeImage() else {
    fputs("Could not create output image.\n", stderr)
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: outputImage)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Could not encode output PNG.\n", stderr)
    exit(1)
}

try png.write(to: outputURL, options: [.atomic])
print("Cropped icon written to \(outputURL.path)")
