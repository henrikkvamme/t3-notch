// Renders the T3 Notch app icon. The chosen design is B on the light background.
//   swift scripts/icon.swift <out-dir> icon    -> icon-1024.png (then scripts/make-icns.sh)
//   swift scripts/icon.swift <out-dir>         -> designs.png, the backgrounds side by side
import AppKit
import SwiftUI

/// The macOS icon grid: a 1024 canvas with an 824 rounded square inset by 100.
struct IconCanvas<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .frame(width: 824, height: 824)
            .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
            .frame(width: 1024, height: 1024)
    }
}

/// The island: a black pill hanging from the top edge, like the notch grown open.
struct Island: View {
    var width: CGFloat = 520
    var height: CGFloat = 150
    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: height / 2, bottomTrailingRadius: height / 2, style: .continuous)
            .fill(.black)
            .frame(width: width, height: height)
            .overlay(alignment: .top) {
                // A thin top-edge highlight so it reads on dark backgrounds.
                UnevenRoundedRectangle(bottomLeadingRadius: height / 2, bottomTrailingRadius: height / 2, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 3)
            }
    }
}

struct GlowDot: View {
    var color: Color
    var size: CGFloat = 64
    var body: some View {
        Circle().fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.9), radius: size * 0.45)
            .shadow(color: color.opacity(0.6), radius: size * 0.9)
    }
}

/// A: the island on a dusk gradient, the green status dot beside it.
struct DesignA: View {
    var body: some View {
        IconCanvas {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.38), Color(red: 0.45, green: 0.22, blue: 0.55),
                                        Color(red: 0.98, green: 0.58, blue: 0.42)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Island(width: 440, height: 150)
                GlowDot(color: Color(red: 0.25, green: 0.95, blue: 0.5), size: 54)
                    .offset(x: 290, y: 48)
            }
        }
    }
}

/// B: the island open with a reply line and a caret, on a chosen background.
struct DesignB<Background: View>: View {
    let background: Background
    init(@ViewBuilder background: () -> Background) { self.background = background() }

    var body: some View {
        IconCanvas {
            ZStack(alignment: .top) {
                background
                VStack(spacing: 0) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 120, bottomTrailingRadius: 120, style: .continuous)
                        .fill(.black)
                        .overlay {
                            VStack(alignment: .leading, spacing: 34) {
                                HStack(spacing: 22) {
                                    GlowDot(color: Color(red: 0.25, green: 0.95, blue: 0.5), size: 34)
                                    Capsule().fill(.white.opacity(0.9)).frame(width: 300, height: 30)
                                }
                                Capsule().fill(.white.opacity(0.35)).frame(width: 470, height: 24)
                                Capsule().fill(.white.opacity(0.35)).frame(width: 380, height: 24)
                                RoundedRectangle(cornerRadius: 38, style: .continuous)
                                    .fill(.white.opacity(0.12))
                                    .frame(width: 560, height: 92)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Color(red: 0.35, green: 0.62, blue: 1.0)).frame(width: 10, height: 52).padding(.leading, 40)
                                    }
                            }
                            .padding(.top, 70)
                        }
                        .frame(width: 680, height: 520)
                }
            }
        }
    }
}

/// C: minimal mark. A white squircle, the black island, and the dot.
struct DesignC: View {
    var body: some View {
        IconCanvas {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.99), Color(white: 0.88)], startPoint: .top, endPoint: .bottom)
                Island(width: 420, height: 160)
                    .offset(x: -40, y: 250)
                GlowDot(color: Color(red: 0.16, green: 0.78, blue: 0.38), size: 64)
                    .offset(x: 250, y: 298)
            }
        }
    }
}

/// Lighter backgrounds for design B.
enum B {
    /// Soft white, like a light desktop.
    static var light: some View {
        LinearGradient(colors: [Color(white: 0.99), Color(red: 0.86, green: 0.87, blue: 0.91)], startPoint: .top, endPoint: .bottom)
    }
    /// The dusk gradient, lightened to pastel.
    static var pastel: some View {
        LinearGradient(colors: [Color(red: 0.78, green: 0.80, blue: 0.98), Color(red: 0.90, green: 0.78, blue: 0.95),
                                Color(red: 1.0, green: 0.86, blue: 0.78)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// A bright sky blue, like a default wallpaper.
    static var sky: some View {
        LinearGradient(colors: [Color(red: 0.55, green: 0.78, blue: 1.0), Color(red: 0.32, green: 0.55, blue: 0.98)],
                       startPoint: .top, endPoint: .bottom)
    }
}

@MainActor
func render(_ view: some View, to url: URL) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : ".", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    switch args.count > 2 ? args[2] : "all" {
    case "A": render(DesignA(), to: out.appendingPathComponent("icon-1024.png"))
    case "icon", "B1": render(DesignB { B.light }, to: out.appendingPathComponent("icon-1024.png"))
    case "B2": render(DesignB { B.pastel }, to: out.appendingPathComponent("icon-1024.png"))
    case "B3": render(DesignB { B.sky }, to: out.appendingPathComponent("icon-1024.png"))
    case "C": render(DesignC(), to: out.appendingPathComponent("icon-1024.png"))
    default:
        render(HStack(spacing: 0) {
            DesignB { B.light }; DesignB { B.pastel }; DesignB { B.sky }
        }.background(Color(white: 0.5)), to: out.appendingPathComponent("designs.png"))
    }
}
print("wrote \(out.path)")
