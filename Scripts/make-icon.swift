import AppKit

// make-icon.swift <source.png> <out.png>
// Biến ảnh vuông thô thành icon kiểu macOS: bo góc squircle + lề + ánh sáng nhẹ.

let a = CommandLine.arguments
let srcPath = a.count > 1 ? a[1] : "Branding/AppIcon.PNG"
let dstPath = a.count > 2 ? a[2] : "dist/appicon-processed.png"

guard let srcImg = NSImage(contentsOfFile: srcPath),
      let srcCG = srcImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("make-icon: không đọc được \(srcPath)\n".utf8)); exit(1)
}

let S = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

let inset: CGFloat = 96
let body = CGRect(x: inset, y: inset, width: CGFloat(S) - inset * 2, height: CGFloat(S) - inset * 2)
let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.2237, cornerHeight: body.width * 0.2237, transform: nil)

// Bóng đổ mềm (icon "nổi" trên nền).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: CGColor(gray: 0, alpha: 0.30))
ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

// Nội dung ảnh, clip theo squircle (aspect-fill).
ctx.saveGState()
ctx.addPath(path); ctx.clip()
let iw = CGFloat(srcCG.width), ih = CGFloat(srcCG.height)
let sc = max(body.width / iw, body.height / ih)
let dw = iw * sc, dh = ih * sc
ctx.draw(srcCG, in: CGRect(x: body.midX - dw / 2, y: body.midY - dh / 2, width: dw, height: dh))

// Ánh sáng từ trên xuống (trắng mờ → trong suốt).
let sheen = CGGradient(colorsSpace: cs,
    colors: [CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                       end: CGPoint(x: body.midX, y: body.midY + body.height * 0.04), options: [])
// Tối nhẹ ở đáy cho có chiều sâu.
let vign = CGGradient(colorsSpace: cs,
    colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.20)] as CFArray, locations: [0.55, 1])!
ctx.drawLinearGradient(vign, start: CGPoint(x: body.midX, y: body.maxY),
                       end: CGPoint(x: body.midX, y: body.minY), options: [])
ctx.restoreGState()

// Viền trong mảnh (highlight mép).
ctx.saveGState()
ctx.addPath(path); ctx.clip()
ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(3); ctx.strokePath()
ctx.restoreGState()

guard let out = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { exit(1) }
try! FileManager.default.createDirectory(at: URL(fileURLWithPath: dstPath).deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: dstPath))
print("make-icon: ✅ \(dstPath)")
