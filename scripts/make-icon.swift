// Renders the app icon (ballot "X" on a South African flag-coloured squircle) into an .iconset.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit
import SwiftUI

struct Icon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(AngularGradient(colors: [Color(red: 0, green: 0.48, blue: 0.30),
                                               Color(red: 1, green: 0.71, blue: 0.07),
                                               Color(red: 0.87, green: 0.22, blue: 0.19),
                                               Color(red: 0, green: 0.14, blue: 0.58),
                                               Color(red: 0, green: 0.48, blue: 0.30)],
                                      center: .center, angle: .degrees(200)))
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.18), .black.opacity(0.25)], startPoint: .top, endPoint: .bottom))
            Image(systemName: "xmark")
                .font(.system(size: 380, weight: .black))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        }
        .frame(width: 824, height: 824)          // Apple's macOS icon grid: 824 pt body on a 1024 canvas
        .shadow(color: .black.opacity(0.28), radius: 20, y: 12)
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func render(to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let cg = renderer.cgImage else { throw NSError(domain: "icon", code: 1) }
    let master = NSImage(cgImage: cg, size: NSSize(width: 1024, height: 1024))
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
        }
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try MainActor.assumeIsolated { try render(to: out) }
