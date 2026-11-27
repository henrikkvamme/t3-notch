// Draws the background of the DMG window: the drag-to-Applications layout.
//   swift scripts/dmg-background.swift Resources   -> dmg-background.png and dmg-background@2x.png
// scripts/make-dmg.sh puts them in the DMG. Run this again after a change and commit the images.
// The positions here must match the icon positions in scripts/dmg-settings.py.
import AppKit
import SwiftUI

enum Layout {
    static let size = CGSize(width: 660, height: 400)
    /// Icon centres, in points from the top left, as Finder places them.
    static let app = CGPoint(x: 180, y: 196)
    static let applications = CGPoint(x: 480, y: 196)
    static let iconSize: CGFloat = 128
}

/// The island: a black pill that hangs from the top edge, like the notch grown open.
struct Island: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(red: 0.25, green: 0.95, blue: 0.5))
                .frame(width: 8, height: 8)
                .shadow(color: Color(red: 0.25, green: 0.95, blue: 0.5).opacity(0.9), radius: 4)
            Text("Drag T3 Notch into Applications")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 22)
        .frame(height: 40)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20, style: .continuous)
                .fill(.black)
        )
    }
}

/// A quiet arrow from the app to the Applications folder.
struct Arrow: View {
    var body: some View {
        let gap = Layout.iconSize / 2 + 34
        let from = Layout.app.x + gap, to = Layout.applications.x - gap, y = Layout.app.y
        Path { p in
            p.move(to: CGPoint(x: from, y: y))
            p.addLine(to: CGPoint(x: to, y: y))
            p.move(to: CGPoint(x: to - 9, y: y - 9))
            p.addLine(to: CGPoint(x: to, y: y))
            p.addLine(to: CGPoint(x: to - 9, y: y + 9))
        }
        .stroke(Color(white: 0.45).opacity(0.55), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }
}

struct Background: View {
    var body: some View {
        ZStack(alignment: .top) {
            // The light backdrop of the app icon, so the icon sits on its own colours.
            LinearGradient(colors: [Color(white: 0.985), Color(red: 0.87, green: 0.88, blue: 0.92)],
                           startPoint: .top, endPoint: .bottom)
            Island()
            Arrow()
        }
        .frame(width: Layout.size.width, height: Layout.size.height)
    }
}

@MainActor
func render(scale: CGFloat, to url: URL) {
    let renderer = ImageRenderer(content: Background())
    renderer.scale = scale
    guard let image = renderer.cgImage else { fatalError("could not render the background") }
    let rep = NSBitmapImageRep(cgImage: image)
    // 72 dpi at 1x and 144 dpi at 2x, so Finder draws both at the same size in points.
    rep.size = Layout.size
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("could not encode PNG") }
    try! png.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    render(scale: 1, to: out.appendingPathComponent("dmg-background.png"))
    render(scale: 2, to: out.appendingPathComponent("dmg-background@2x.png"))
}
print("wrote \(out.path)")
