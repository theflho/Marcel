import SwiftUI

/// The launch screen, in the app's own style: Marcel's drawn face, asleep on the dark background,
/// wakes up (a hop, the eyes open and smile) while his bots drop in one by one underneath, each with
/// its own head and colour; then "Marcel", "Tes bots se réveillent…" and a thin progress bar.
/// It follows the icon (the same face on the same dark tile). A tap skips it.
struct SplashView: View {
    var onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    /// How long the splash stays (the bots have landed by 1.6 s, the bar fills by 2.3 s).
    private static let duration: Double = 2.6
    /// Marcel's bots, in the order they drop in.
    private static let bots = ["planning", "pointage", "recrutements", "mails", "veille"]

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 390, geometry.size.height / 844)
            TimelineView(.animation(paused: reduceMotion)) { context in
                // With reduced motion, everything is shown at rest.
                let t = reduceMotion ? 10 : context.date.timeIntervalSince(start)
                VStack(spacing: 0) {
                    Spacer()
                    marcel(t: t, scale: scale)
                    title(t: t, scale: scale)
                        .padding(.top, 26 * scale)
                    team(t: t, scale: scale)
                        .padding(.top, 34 * scale)
                    Spacer()
                    footer(t: t, scale: scale)
                        .padding(.bottom, 90 * scale)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(SplashStyle.background.ignoresSafeArea())
        .overlay {
            // A warm glow behind the face, like the icon.
            RadialGradient(colors: [SplashStyle.glow.opacity(0.22), .clear], center: UnitPoint(x: 0.5, y: 0.36),
                           startRadius: 0, endRadius: 260)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .contentShape(.rect)
        .onTapGesture(perform: onFinish)
        .accessibilityHidden(true)
        .task {
            start = .now
            try? await Task.sleep(for: .seconds(reduceMotion ? 1.0 : Self.duration))
            onFinish()
        }
    }

    // MARK: Marcel

    /// Asleep, then he wakes with a hop and smiles once his bots are there.
    private func marcel(t: Double, scale: CGFloat) -> some View {
        let state: BotFace = t < 0.7 ? .sleeping : t < 1.7 ? .listening : .done
        let hop = t > 0.7 && t < 1.05 ? sin((t - 0.7) / 0.35 * .pi) : 0
        return MarcelAvatar(size: 168 * scale, bot: nil, state: state)
            .scaleEffect(SplashStyle.pop(t: t, delay: 0, from: 0.6))
            .offset(y: -14 * scale * hop)
            .opacity(min(1, t / 0.3))
            .shadow(color: .black.opacity(0.45), radius: 24 * scale, y: 14 * scale)
    }

    private func title(t: Double, scale: CGFloat) -> some View {
        let shown = SplashStyle.ease(min(1, max(0, (t - 0.35) / 0.45)))
        return Text("Marcel")
            .font(.system(size: 44 * scale, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .opacity(shown)
            .offset(y: 10 * scale * (1 - shown))
    }

    // MARK: The bots

    /// Each bot drops in with a squash and a bounce, a little after the previous one.
    private func team(t: Double, scale: CGFloat) -> some View {
        HStack(spacing: 10 * scale) {
            ForEach(Array(Self.bots.enumerated()), id: \.offset) { index, bot in
                let delay = 0.75 + 0.12 * Double(index)
                let landed = t > delay + 0.5
                MarcelAvatar(size: 52 * scale, bot: bot, state: landed ? .idle : .waiting)
                    .scaleEffect(SplashStyle.pop(t: t, delay: delay, from: 0.3))
                    .offset(y: -40 * scale * SplashStyle.fall(t: t, delay: delay))
                    .opacity(min(1, max(0, (t - delay) / 0.15)))
            }
        }
    }

    // MARK: Footer

    private func footer(t: Double, scale: CGFloat) -> some View {
        let shown = min(1, max(0, (t - 0.9) / 0.4))
        return VStack(spacing: 18 * scale) {
            Text("Tes bots se réveillent…")
                .font(.system(size: 15 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(SplashStyle.glow)
                    .frame(width: 132 * scale * SplashStyle.fill(t: t))
            }
            .frame(width: 132 * scale, height: 5 * scale)
        }
        .opacity(shown)
    }
}

/// The splash's colours and moves.
private enum SplashStyle {
    /// The icon's tile.
    static let background = Color(red: 0x0E / 255, green: 0x0E / 255, blue: 0x11 / 255)
    /// Marcel's head colour.
    static let glow = Color(red: 0xC9 / 255, green: 0x8B / 255, blue: 0x55 / 255)

    static func ease(_ p: Double) -> Double { 1 - pow(1 - p, 3) }

    /// From `from` to 1 with a springy overshoot, starting at `delay`.
    static func pop(t: Double, delay: Double, from: Double) -> Double {
        let p = min(1, max(0, (t - delay) / 0.45))
        let spring = 1 - pow(2, -9 * p) * cos(p * .pi * 2.6)
        return from + (1 - from) * spring
    }

    /// 1 → 0 as it falls, with a little bounce on landing.
    static func fall(t: Double, delay: Double) -> Double {
        let p = min(1, max(0, (t - delay) / 0.5))
        guard p < 0.6 else { return -0.18 * sin((p - 0.6) / 0.4 * .pi) }
        let q = p / 0.6
        return 1 - q * q
    }

    /// The bar creeps along (30 %, 45 %, 85 %, then full) between 1.0 and 2.3 s.
    static func fill(t: Double) -> Double {
        let steps: [(Double, Double)] = [(1.0, 0), (1.3, 0.30), (1.6, 0.45), (2.0, 0.85), (2.3, 1)]
        guard t > steps[0].0 else { return 0 }
        for (a, b) in zip(steps, steps.dropFirst()) where t <= b.0 {
            let p = (t - a.0) / (b.0 - a.0)
            return a.1 + (b.1 - a.1) * (1 - cos(.pi * p)) / 2
        }
        return 1
    }
}

#Preview {
    SplashView {}
}
