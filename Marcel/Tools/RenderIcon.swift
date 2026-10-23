import SwiftUI
import AppKit

@MainActor func render(_ view: some View, to path: String, size: CGFloat) {
    let renderer = ImageRenderer(content: view.frame(width: size, height: size))
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

@main struct Render { @MainActor static func main() {
let out = CommandLine.arguments[1]
    // App icon: opaque, soft sky background, mascot centred.
    let icon = ZStack {
        LinearGradient(colors: [Color(red: 0.86, green: 0.93, blue: 1.0), Color(red: 0.98, green: 0.95, blue: 0.90)],
                       startPoint: .top, endPoint: .bottom)
        MarcelAvatar(size: 760).offset(y: 30)
    }
    render(icon, to: out + "/AppIcon.png", size: 1024)
    render(ZStack { Color.white; MarcelAvatar(size: 300) }, to: out + "/preview.png", size: 320)
}
}
