import SwiftUI

/// The launch screen (design "Splash – photo"): Marcel asleep on his branch, breathing, "zzz"
/// rising, the colourful letters of "marcel" dropping in one by one with a squash and a bounce,
/// then "Doucement, ça arrive…" and a little progress bar. A tap skips it.
/// Every value comes from the 390 × 844 design and is scaled to the screen.
struct SplashView: View {
    var onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    /// How long the splash stays (the letters land at about 1.5 s, the bar fills by 2.4 s).
    private static let duration: Double = 2.7

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = min(size.width / 390, size.height / 844)
            TimelineView(.animation(paused: reduceMotion)) { context in
                // With reduced motion, everything is shown at rest, without movement.
                let t = reduceMotion ? 10 : context.date.timeIntervalSince(start)
                ZStack(alignment: .topLeading) {
                    Splash.background
                    photo(size: size, scale: scale, t: t)
                    title(t: t, scale: scale)
                        .position(x: size.width / 2, y: size.height * 452 / 844 + 50 * scale)
                    footer(t: t, scale: scale)
                        .position(x: size.width / 2, y: size.height * 700 / 844)
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(.rect)
        .onTapGesture(perform: onFinish)
        .accessibilityHidden(true)
        .task {
            start = .now
            try? await Task.sleep(for: .seconds(reduceMotion ? 1.0 : Self.duration))
            onFinish()
        }
    }

    // MARK: Photo

    private func photo(size: CGSize, scale: CGFloat, t: Double) -> some View {
        let height = size.height * 620 / 844
        // object-fit: cover, object-position 34% 50% (the photo is 3:2).
        let drawnWidth = max(size.width, height * 1.5)
        let shift = (0.5 - 0.34) * (drawnWidth - size.width)
        // Breathing: 1.04 → 1.08 and 3 px up, 3.6 s each way.
        let breath = reduceMotion ? 0 : (1 - cos(2 * .pi * t / 7.2)) / 2
        return ZStack(alignment: .topLeading) {
            Image("MarcelSplash")
                .resizable()
                .scaledToFill()
                .frame(width: drawnWidth, height: height)
                .offset(x: shift)
                .scaleEffect(1.04 + 0.04 * breath, anchor: UnitPoint(x: 0.5, y: 0.32))
                .offset(y: -3 * scale * breath)
                .frame(width: size.width, height: height)
                .clipped()
            if !reduceMotion {
                ForEach(0..<3, id: \.self) { index in
                    sleepyZ(index: index, t: t, scale: scale)
                        .position(x: size.width * 240 / 390, y: height * 164 / 620)
                }
            }
        }
        .frame(width: size.width, height: height)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .opacity(min(1, t / 0.6))
    }

    /// One of the three z's: each rises and grows over 3 s, starting 1 s after the previous one.
    private func sleepyZ(index: Int, t: Double, scale: CGFloat) -> some View {
        let local = t - Double(index)
        let p = local < 0 ? 0 : local.truncatingRemainder(dividingBy: 3) / 3
        let eased = 1 - pow(1 - p, 2)
        let opacity = local < 0 ? 0 : (p < 0.25 ? p / 0.25 : 1 - (p - 0.25) / 0.75)
        return Text(index == 2 ? "Z" : "z")
            .font(.system(size: [20, 26, 32][index] * scale, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .scaleEffect(0.6 + 0.65 * eased)
            .offset(x: 26 * scale * eased, y: -58 * scale * eased)
            .opacity(opacity)
    }

    // MARK: Title

    private func title(t: Double, scale: CGFloat) -> some View {
        HStack(spacing: -2 * scale) {
            ForEach(Array(Splash.letters.enumerated()), id: \.offset) { index, letter in
                let pose = Splash.pose(letter: index, t: t)
                SplashLetter(letter: letter, size: 92 * scale)
                    .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .bottom)
                    .rotationEffect(.degrees(pose.rotation), anchor: .bottom)
                    .offset(y: pose.y * scale)
                    .opacity(pose.opacity)
            }
        }
    }

    // MARK: Footer

    private func footer(t: Double, scale: CGFloat) -> some View {
        let shown = min(1, max(0, (t - 0.9) / 0.5))
        return VStack(spacing: 24 * scale) {
            Text("Doucement, ça arrive…")
                .font(.system(size: 16 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(Splash.subtitle)
            ZStack(alignment: .leading) {
                Capsule().fill(Splash.track)
                Capsule().fill(Splash.accent)
                    .frame(width: 148 * scale * Splash.fill(t: t))
            }
            .frame(width: 148 * scale, height: 8 * scale)
        }
        .opacity(shown)
    }
}

/// A letter of "marcel": its colour, a 6 px extrusion in darker shades, a soft shadow and the
/// glossy highlight on top.
private struct SplashLetter: View {
    let letter: Splash.Letter
    let size: CGFloat

    private var font: Font { .system(size: size, weight: .bold, design: .rounded) }

    var body: some View {
        ZStack {
            ForEach(Array(letter.depth.enumerated().reversed()), id: \.offset) { index, shade in
                Text(letter.character).font(font).foregroundStyle(shade).offset(y: CGFloat(index + 1) * size / 92)
            }
            Text(letter.character)
                .font(font)
                .foregroundStyle(letter.color)
                .overlay {
                    LinearGradient(stops: [.init(color: .white.opacity(0.85), location: 0),
                                           .init(color: .white.opacity(0.35), location: 0.28),
                                           .init(color: .white.opacity(0), location: 0.5),
                                           .init(color: .black.opacity(0), location: 0.72),
                                           .init(color: .black.opacity(0.14), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .mask(Text(letter.character).font(font))
                }
        }
        .shadow(color: letter.glow, radius: 9 * size / 92, y: 14 * size / 92)
        .shadow(color: .black.opacity(0.2), radius: 3 * size / 92, y: 4 * size / 92)
    }
}

/// The design's values: colours, letters and the timing of their moves.
private enum Splash {
    static let background = Color(hex: 0xF6EFE3)
    static let subtitle = Color(hex: 0x6B5444)
    static let track = Color(hex: 0xE6D8C0)
    static let accent = Color(hex: 0x3B2A1F)

    struct Letter {
        let character: String
        let color: Color
        let depth: [Color]
        let glow: Color
    }

    static let letters: [Letter] = [
        Letter(character: "m", color: Color(hex: 0x2F8BFF),
               depth: [0x2672E0, 0x2268D3, 0x1F60C6, 0x1C58B8, 0x1A50AA, 0x17489C].map(Color.init(hex:)),
               glow: Color(red: 20 / 255, green: 40 / 255, blue: 90 / 255, opacity: 0.45)),
        Letter(character: "a", color: Color(hex: 0xFFB52E),
               depth: [0xF2A421, 0xE89A18, 0xDE9012, 0xD4860D, 0xC97C09, 0xBE7206].map(Color.init(hex:)),
               glow: Color(red: 110 / 255, green: 60 / 255, blue: 0, opacity: 0.4)),
        Letter(character: "r", color: Color(hex: 0x9BD83A),
               depth: [0x8CC830, 0x83BD2B, 0x7AB226, 0x71A722, 0x689C1E, 0x5F911A].map(Color.init(hex:)),
               glow: Color(red: 40 / 255, green: 70 / 255, blue: 10 / 255, opacity: 0.4)),
        Letter(character: "c", color: Color(hex: 0xFF7A2F),
               depth: [0xF06A26, 0xE66122, 0xDC591E, 0xD2511A, 0xC74916, 0xBC4213].map(Color.init(hex:)),
               glow: Color(red: 110 / 255, green: 35 / 255, blue: 0, opacity: 0.4)),
        Letter(character: "e", color: Color(hex: 0xFF5FC8),
               depth: [0xF04FB8, 0xE647AE, 0xDC40A4, 0xD2399A, 0xC73290, 0xBC2C86].map(Color.init(hex:)),
               glow: Color(red: 100 / 255, green: 10 / 255, blue: 70 / 255, opacity: 0.4)),
        Letter(character: "l", color: Color(hex: 0x8C4DFF),
               depth: [0x7D40F0, 0x7439E5, 0x6B33DA, 0x632DCF, 0x5B28C3, 0x5323B7].map(Color.init(hex:)),
               glow: Color(red: 50 / 255, green: 15 / 255, blue: 110 / 255, opacity: 0.45)),
    ]

    struct Pose {
        var y: Double = 0
        var scaleX: Double = 1
        var scaleY: Double = 1
        var rotation: Double = 0
        var opacity: Double = 1
    }

    /// Where a letter is at `t` seconds: it falls from 140 px above (squashing as it lands), bounces
    /// 22 px, settles, then bobs gently (each letter out of step with the others).
    static func pose(letter index: Int, t: Double) -> Pose {
        let u = t - (0.25 + 0.09 * Double(index))
        func mix(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }
        switch u {
        case ..<0:
            return Pose(y: -140, scaleX: 0.9, scaleY: 1.1, opacity: 0)
        case ..<0.42:
            let p = u / 0.42
            return Pose(y: -140 * (1 - p * p), scaleX: mix(0.9, 1.22, p * p), scaleY: mix(1.1, 0.72, p * p), opacity: p)
        case ..<0.63:
            let p = 1 - pow(1 - (u - 0.42) / 0.21, 3)
            return Pose(y: -22 * p, scaleX: mix(1.22, 0.92, p), scaleY: mix(0.72, 1.1, p))
        case ..<0.84:
            let p = pow((u - 0.63) / 0.21, 2)
            return Pose(y: -22 * (1 - p), scaleX: mix(0.92, 1.08, p), scaleY: mix(1.1, 0.9, p))
        case ..<1.05:
            let p = (u - 0.84) / 0.21
            return Pose(scaleX: mix(1.08, 1, p), scaleY: mix(0.9, 1, p))
        default:
            // Bob: 0 → (5 px up, −3°, 0.98 × 1.03) → (2°, 1.03 × 0.97), 3.6 s each way.
            let weight = min(1, (u - 1.05) / 0.4)
            let phase = (t + 0.3 * Double(index)).truncatingRemainder(dividingBy: 7.2) / 3.6
            let k = phase <= 1 ? phase : 2 - phase
            let ease = (1 - cos(.pi * k)) / 2
            let pose = ease < 0.5
                ? Pose(y: -5 * ease * 2, scaleX: mix(1, 0.98, ease * 2), scaleY: mix(1, 1.03, ease * 2),
                       rotation: -3 * ease * 2)
                : Pose(y: -5 * (2 - ease * 2), scaleX: mix(0.98, 1.03, ease * 2 - 1),
                       scaleY: mix(1.03, 0.97, ease * 2 - 1), rotation: mix(-3, 2, ease * 2 - 1))
            return Pose(y: pose.y * weight, scaleX: mix(1, pose.scaleX, weight), scaleY: mix(1, pose.scaleY, weight),
                        rotation: pose.rotation * weight)
        }
    }

    /// The bar creeps along like the design (30 %, 38 %, 80 %, then full) between 1.0 and 2.4 s.
    static func fill(t: Double) -> Double {
        let steps: [(Double, Double)] = [(1.0, 0), (1.3, 0.30), (1.6, 0.38), (2.05, 0.80), (2.4, 1)]
        guard t > steps[0].0 else { return 0 }
        for (a, b) in zip(steps, steps.dropFirst()) where t <= b.0 {
            let p = (t - a.0) / (b.0 - a.0)
            return a.1 + (b.1 - a.1) * (1 - cos(.pi * p)) / 2
        }
        return 1
    }
}

private extension Color {
    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

#Preview {
    SplashView {}
}
