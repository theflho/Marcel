import SwiftUI

/// Marcel's mascot: a little round brioche wearing a beret.
/// Pure SwiftUI shapes (no UIKit) so the same file also renders the app icon on macOS.
struct MarcelAvatar: View {
    var size: CGFloat = 48
    /// Gentle bounce while Marcel is answering.
    var isThinking = false

    @State private var bounce = false
    @State private var blink = false

    private static let crust = Color(red: 0.96, green: 0.86, blue: 0.69)
    private static let crustShade = Color(red: 0.90, green: 0.74, blue: 0.52)
    private static let beret = Color(red: 0.20, green: 0.25, blue: 0.40)
    private static let ink = Color(red: 0.22, green: 0.16, blue: 0.12)
    private static let blush = Color(red: 0.98, green: 0.58, blue: 0.56)

    var body: some View {
        let s = size
        ZStack {
            // Body
            Ellipse()
                .fill(LinearGradient(colors: [Self.crust, Self.crustShade], startPoint: .top, endPoint: .bottom))
                .frame(width: s * 0.86, height: s * 0.74)
                .overlay(
                    Ellipse()
                        .fill(.white.opacity(0.35))
                        .frame(width: s * 0.30, height: s * 0.12)
                        .offset(x: -s * 0.18, y: -s * 0.20)
                        .blur(radius: s * 0.02)
                )
                .offset(y: s * 0.10)

            // Face
            Group {
                HStack(spacing: s * 0.20) {
                    eye
                    eye
                }
                .offset(y: s * 0.06)

                HStack(spacing: s * 0.36) {
                    cheek
                    cheek
                }
                .offset(y: s * 0.17)

                Smile()
                    .stroke(Self.ink, style: StrokeStyle(lineWidth: max(1, s * 0.03), lineCap: .round))
                    .frame(width: s * 0.10, height: s * 0.05)
                    .offset(y: s * 0.17)
            }

            // Beret
            ZStack {
                Capsule()
                    .fill(Self.beret)
                    .frame(width: s * 0.05, height: s * 0.10)
                    .offset(x: s * 0.04, y: -s * 0.13)
                Ellipse()
                    .fill(Self.beret)
                    .frame(width: s * 0.62, height: s * 0.24)
                Ellipse()
                    .fill(.white.opacity(0.12))
                    .frame(width: s * 0.30, height: s * 0.07)
                    .offset(x: -s * 0.08, y: -s * 0.05)
            }
            .rotationEffect(.degrees(-10))
            .offset(x: s * 0.04, y: -s * 0.24)
        }
        .frame(width: s, height: s)
        .offset(y: bounce ? -s * 0.04 : 0)
        .animation(isThinking ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true) : .default, value: bounce)
        .onChange(of: isThinking, initial: true) { _, thinking in bounce = thinking }
        .task {
            // Occasional blink.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.5...5)))
                withAnimation(.easeInOut(duration: 0.08)) { blink = true }
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(.easeInOut(duration: 0.08)) { blink = false }
            }
        }
        .accessibilityHidden(true)
    }

    private var eye: some View {
        Capsule()
            .fill(Self.ink)
            .frame(width: size * 0.06, height: blink ? size * 0.015 : size * 0.10)
    }

    private var cheek: some View {
        Ellipse()
            .fill(Self.blush.opacity(0.55))
            .frame(width: size * 0.11, height: size * 0.06)
    }
}

private struct Smile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.6))
        return path
    }
}

#Preview {
    HStack(spacing: 24) {
        MarcelAvatar(size: 48)
        MarcelAvatar(size: 120, isThinking: true)
    }
    .padding()
}
