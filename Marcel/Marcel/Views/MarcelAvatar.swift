import SwiftUI

/// Marcel's face, drawn in code like Grok Bot's bots: the sloth's mask (two dark slits for eyes)
/// and his black beret, on a head whose shape and colour tell the bots apart. Like Grok Bot's, the
/// face is never still (it breathes, blinks, looks around) and says what the bot is doing: each state
/// has its pose (lean, lift, squash, gaze) and its motion.
struct MarcelAvatar: View {
    var size: CGFloat = 48
    /// The bot it stands for; nil for Marcel.
    var bot: String?
    var state: BotFace = .idle
    /// The dark tile behind the head; off where the head sits straight on the background.
    var tile = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// "Done" shows a moment when the work ends, then the face rests.
    @State private var justDone = false

    private var look: BotLook { BotLook(bot) }
    private var face: BotFace { justDone && state == .idle ? .done : state }
    /// Design units: the drawing is made on an 80 × 80 grid centred on 0.
    private func u(_ value: CGFloat) -> CGFloat { value * size / 80 }

    var body: some View {
        // Still when the iPhone asks for less motion: the pose alone says the state.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            drawing(BotPose(face, time: time, seed: look.seed), time: time)
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.45, bounce: 0.35), value: face)
        .onChange(of: state) { old, new in
            guard old.isBusy && new == .idle else { return }
            justDone = true
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                justDone = false
            }
        }
        .accessibilityHidden(true)
    }

    private func drawing(_ pose: BotPose, time: Double) -> some View {
        ZStack {
            if tile {
                RoundedRectangle(cornerRadius: u(22), style: .continuous)
                    .fill(Color(hex: 0x16161B))
            }
            // Working: Grok Bot's purple, a ring with a dot going round (its "orbit" morph).
            ZStack {
                RoundedRectangle(cornerRadius: u(28), style: .continuous)
                    .strokeBorder(Color(hex: 0x8B6CF6), lineWidth: u(3))
                    .frame(width: u(72), height: u(66))
                Circle()
                    .fill(Color(hex: 0xC9B8FF))
                    .frame(width: u(6), height: u(6))
                    .offset(x: u(35 * cos(time * 3.4)), y: u(32 * sin(time * 3.4)))
            }
            .offset(y: u(3))
            .opacity(face == .working ? 1 : 0)
            .scaleEffect(face == .working ? 1 : 0.9)
            head(pose)
                .scaleEffect(x: 2 - pose.squash, y: pose.squash, anchor: .bottom)
                .rotationEffect(.degrees(pose.rot))
                .offset(x: u(pose.tx), y: u(pose.ty))
            // Sleeping: a "z" rises and fades.
            let rise = (time * 0.45).truncatingRemainder(dividingBy: 1)
            Text("z")
                .font(.system(size: u(13), weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .offset(x: u(24 + rise * 4), y: u(-22 - rise * 12))
                .opacity(face == .sleeping ? 1 - rise : 0)
        }
    }

    private func head(_ pose: BotPose) -> some View {
        let shift = look.faceShift
        return ZStack {
            DesignShape(path: look.shape.path, size: size, rounded: look.shape.rounded)
                .fill(look.color)
            if look.shape.rounded {
                DesignShape(path: look.shape.path, size: size, rounded: true)
                    .stroke(look.color, style: StrokeStyle(lineWidth: u(8), lineJoin: .round))
            }
            Ellipse()
                .fill(Color(hex: 0xF1E2C8))
                .frame(width: u(look.faceSize.width * 2), height: u(look.faceSize.height * 2))
                .offset(y: u(6 + shift))
            eyes(pose).offset(y: u(shift))
            Ellipse()
                .fill(Color(hex: 0x2A1E18))
                .frame(width: u(7), height: u(5))
                .offset(y: u(11 + shift))
            beret
        }
    }

    private func eyes(_ pose: BotPose) -> some View {
        let stripe: CGFloat = switch face {
        case .working, .reading: 7
        case .waiting, .listening: 11
        case .failed: 5
        case .sleeping: 3
        default: 9
        }
        let pupil: CGFloat = switch face {
        case .working, .reading: 2
        case .waiting, .listening: 3.6
        case .blocked, .failed: 2.2
        default: 2.6
        }
        let closed = pose.blink || face == .sleeping
        return ZStack {
            Capsule()
                .fill(Color(hex: 0x3A2A20))
                .frame(width: u(19), height: u(face == .blocked ? 5 : stripe))
                .rotationEffect(.degrees(18))
                .offset(x: u(-13.5), y: u(0.5))
            Capsule()
                .fill(Color(hex: 0x3A2A20))
                .frame(width: u(19), height: u(stripe))
                .rotationEffect(.degrees(-18))
                .offset(x: u(13.5), y: u(0.5))
            Group {
                Circle()
                    .frame(width: u(pupil * 2), height: u(pupil * 2))
                    .offset(x: u(-9 + pose.gaze.x), y: u(pose.gaze.y))
                    .opacity(face == .blocked ? 0 : 1)
                Circle()
                    .frame(width: u(pupil * 2), height: u(pupil * 2))
                    .offset(x: u(9 + pose.gaze.x), y: u(pose.gaze.y))
            }
            .foregroundStyle(.white)
            .scaleEffect(y: closed ? 0.1 : 1)
            .opacity(face == .done || face == .sleeping ? 0 : 1)
            // Done: the eyes smile.
            DesignShape(path: BotLook.smilingEyes, size: size)
                .stroke(.white, style: StrokeStyle(lineWidth: u(2.4), lineCap: .round))
                .opacity(face == .done ? 1 : 0)
        }
    }

    private var beret: some View {
        let hat = look.beret
        return ZStack {
            Ellipse()
                .frame(width: u(hat.radii.width * 2), height: u(hat.radii.height * 2))
                .rotationEffect(.degrees(hat.angle))
                .offset(x: u(hat.center.x), y: u(hat.center.y))
            Circle()
                .frame(width: u(5), height: u(5))
                .offset(x: u(hat.center.x - 3), y: u(hat.center.y - 9 * hat.radii.height / 8))
        }
        .foregroundStyle(Color(hex: 0x0B0B0E))
    }
}

/// What a bot is doing, shown on its face like Grok Bot's avatars (their lifecycle states).
nonisolated enum BotFace: Equatable {
    case idle, listening, thinking, searching, reading, writing, working, waiting, blocked, done, failed, sleeping

    /// Busy: when it stops, the face shows "done" a moment.
    var isBusy: Bool { [.thinking, .searching, .reading, .writing, .working].contains(self) }
}

/// Where the head is at a given time, made like Grok Bot's poses: a lean, a sideways move, a lift, a
/// squash, where the eyes look, and whether they blink. Each state moves in its own way.
nonisolated struct BotPose {
    var rot = 0.0
    var tx = 0.0
    var ty = 0.0
    var squash = 1.0
    var gaze = CGPoint.zero
    var blink = false

    init(_ face: BotFace, time t: Double, seed: Double) {
        let breath = sin(t * 1.6 + seed * 6)
        switch face {
        case .idle:
            rot = sin(t * 0.9 + seed * 6) * 1.5
            ty = breath * 0.6
            squash = 1 + breath * 0.012
            gaze = CGPoint(x: sin(t * 0.37 + seed * 9) * 1.6, y: sin(t * 0.23 + seed) * 0.6)
        case .listening:
            // Leans in, a little lifted, eyes on you.
            rot = 4; tx = 1; ty = -1.5
            squash = 1.02 + breath * 0.01
        case .thinking:
            rot = -7 + sin(t * 1.2) * 2
            gaze = CGPoint(x: -1.5, y: -2)
        case .searching:
            // Looks one way then the other.
            rot = sin(t * 2.4) * 5
            gaze = CGPoint(x: sin(t * 3) * 3.5, y: -0.5)
        case .reading:
            // Eyes go along a line, then back to the start of the next.
            let line = (t * 0.8).truncatingRemainder(dividingBy: 1)
            rot = 3; ty = 1
            gaze = CGPoint(x: line * 6 - 3, y: 1)
        case .writing:
            rot = sin(t * 6) * 1.5
            ty = -abs(sin(t * 6)) * 0.8
            gaze = CGPoint(x: sin(t * 1.5) * 1.5, y: 1.5)
        case .working:
            rot = sin(t * 3) * 2
            squash = 1 + sin(t * 6) * 0.02
            gaze = CGPoint(x: 0, y: 0.5)
        case .waiting:
            // A small hop every two seconds, to catch the eye.
            let beat = (t + seed).truncatingRemainder(dividingBy: 2.2)
            ty = beat < 0.36 ? -sin(beat / 0.36 * .pi) * 4 : 0
            squash = beat < 0.36 ? 1.03 : 1
        case .blocked:
            rot = 8; tx = 2
        case .failed:
            // Droops.
            rot = -6; ty = 3
            squash = 0.97
            gaze = CGPoint(x: 0, y: 1.5)
        case .done:
            rot = sin(t * 4) * 3
            ty = -abs(sin(t * 4)) * 1.5
        case .sleeping:
            rot = -4; ty = 1
            squash = 1 + sin(t * 0.8) * 0.03
        }
        // Blinks every few seconds, at its own pace, except when its eyes are closed or smiling.
        if ![.sleeping, .done, .blocked].contains(face) {
            let period = 3.6 + seed * 1.7
            blink = (t + seed * 5).truncatingRemainder(dividingBy: period) < 0.13
        }
    }
}

/// How a bot looks: Marcel and each built-in bot have their own head; a bot the user created gets
/// one picked from its id, the same on every launch.
nonisolated struct BotLook {
    enum Head: CaseIterable {
        case square, circle, clover, house, heart, flower, star

        var rounded: Bool { self == .house || self == .star }

        var path: Path {
            var path = Path()
            switch self {
            case .square:
                path.addRoundedRect(in: CGRect(x: -30, y: -24, width: 60, height: 54), cornerSize: CGSize(width: 22, height: 22))
            case .circle:
                path.addEllipse(in: CGRect(x: -31, y: -28, width: 62, height: 62))
            case .clover:
                for (x, y) in [(-14.0, -9.0), (14, -9), (-14, 17), (14, 17)] {
                    path.addEllipse(in: CGRect(x: x - 18, y: y - 18, width: 36, height: 36))
                }
                path.addEllipse(in: CGRect(x: -22, y: -18, width: 44, height: 44))
            case .house:
                path.move(to: CGPoint(x: 0, y: -26))
                path.addLines([CGPoint(x: 30, y: -4), CGPoint(x: 30, y: 28), CGPoint(x: -30, y: 28), CGPoint(x: -30, y: -4)])
                path.closeSubpath()
            case .heart:
                path.move(to: CGPoint(x: 0, y: 34))
                path.addCurve(to: CGPoint(x: -14, y: -26), control1: CGPoint(x: -42, y: 8), control2: CGPoint(x: -38, y: -30))
                path.addCurve(to: CGPoint(x: 0, y: -15), control1: CGPoint(x: -6, y: -25), control2: CGPoint(x: -2, y: -20))
                path.addCurve(to: CGPoint(x: 14, y: -26), control1: CGPoint(x: 2, y: -20), control2: CGPoint(x: 6, y: -25))
                path.addCurve(to: CGPoint(x: 0, y: 34), control1: CGPoint(x: 38, y: -30), control2: CGPoint(x: 42, y: 8))
                path.closeSubpath()
            case .flower:
                for (x, y) in [(24.0, 3.0), (17, 20), (0, 27), (-17, 20), (-24, 3), (-17, -14), (0, -21), (17, -14)] {
                    path.addEllipse(in: CGRect(x: x - 12, y: y - 12, width: 24, height: 24))
                }
                path.addEllipse(in: CGRect(x: -26, y: -23, width: 52, height: 52))
            case .star:
                let points = (0..<10).map { index -> CGPoint in
                    let angle = Double(index) * .pi / 5 - .pi / 2
                    let radius: Double = index.isMultiple(of: 2) ? 31 : 19
                    return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius + 5)
                }
                path.addLines(points)
                path.closeSubpath()
            }
            return path
        }
    }

    struct Beret {
        var center = CGPoint(x: -4, y: -24)
        var radii = CGSize(width: 24, height: 8)
        var angle: Double = -10
    }

    let shape: Head
    let color: Color
    /// From 0 to 1, the same on every launch: each bot moves and blinks at its own pace.
    let seed: Double
    var faceSize = CGSize(width: 22, height: 17)
    var faceShift: CGFloat = 0
    var beret = Beret()

    init(_ bot: String?) {
        seed = Double((bot ?? "marcel").unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 1000) / 1000
        switch bot {
        case nil:
            shape = .square; color = Color(hex: 0xC98B55)
        case "planning":
            shape = .circle; color = Color(hex: 0x5B8DEF)
        case "pointage":
            shape = .clover; color = Color(hex: 0x3FB27F)
        case "recrutements":
            shape = .house; color = Color(hex: 0xE07A4F)
            faceShift = 2
            beret = Beret(center: CGPoint(x: -2, y: -27), radii: CGSize(width: 20, height: 7))
        case "mails":
            shape = .heart; color = Color(hex: 0x4FB3C9)
            faceSize = CGSize(width: 21, height: 16)
            faceShift = -1
            beret = Beret(center: CGPoint(x: -14, y: -28), radii: CGSize(width: 16, height: 6), angle: -14)
        case "veille":
            shape = .flower; color = Color(hex: 0xE5B93C)
            beret = Beret(center: CGPoint(x: -4, y: -29))
        case let id?:
            // Not String.hashValue: it changes on every launch.
            let seed = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            let heads: [Head] = [.star, .circle, .clover, .heart, .flower, .house]
            let colors: [UInt32] = [0xF28C38, 0x9AD14B, 0x6FD3C1, 0xD9534F, 0xB08A6E, 0x7A8CF0]
            shape = heads[seed % heads.count]
            color = Color(hex: colors[(seed / heads.count) % colors.count])
            if shape == .house { faceShift = 2; beret = Beret(center: CGPoint(x: -2, y: -27), radii: CGSize(width: 20, height: 7)) }
            if shape == .heart { faceShift = -1; beret = Beret(center: CGPoint(x: -14, y: -28), radii: CGSize(width: 16, height: 6), angle: -14) }
        }
    }

    static var smilingEyes: Path {
        var path = Path()
        path.move(to: CGPoint(x: -12, y: 1.5))
        path.addQuadCurve(to: CGPoint(x: -6, y: 1.5), control: CGPoint(x: -9, y: -2))
        path.move(to: CGPoint(x: 6, y: 1.5))
        path.addQuadCurve(to: CGPoint(x: 12, y: 1.5), control: CGPoint(x: 9, y: -2))
        return path
    }
}

/// A path drawn on the 80 × 80 design grid, scaled to the avatar's size.
private nonisolated struct DesignShape: Shape {
    let path: Path
    let size: CGFloat
    var rounded = false

    func path(in rect: CGRect) -> Path {
        let scale = size / 80
        return path.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: scale, y: scale))
    }
}

private nonisolated extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension ChatStore {
    /// What a bot is doing right now, for its face: working while a step runs, thinking while it
    /// writes, waiting when something awaits the user's go-ahead, blocked when it failed or Marcel
    /// is stopped.
    func face(of conversation: Conversation) -> BotFace {
        if emergencyActive { return .blocked }
        let last = conversation.messages.last
        if isStreaming(conversation.id) {
            guard let last else { return .thinking }
            if let step = last.actions.last(where: { $0.status == "running" }) {
                return BotFace(step: step.name ?? step.id)
            }
            return last.content.isEmpty ? .thinking : .writing
        }
        guard let last else { return .sleeping }
        if last.role == .assistant {
            if last.status == .failed { return .failed }
            if last.actions.contains(where: { $0.awaitsApproval && !last.declined.contains($0.id) }) { return .waiting }
        }
        // Untouched for a week: it sleeps, like a Grok Bot whose computer hibernates.
        return last.createdAt < .now.addingTimeInterval(-7 * 86_400) ? .sleeping : .idle
    }

    /// The face of a bot in the menu: that of its latest conversation.
    func face(ofBot id: String?) -> BotFace {
        conversations.filter { $0.assistantID == id && !$0.isPrivate }
            .max { ($0.messages.last?.createdAt ?? .distantPast) < ($1.messages.last?.createdAt ?? .distantPast) }
            .map(face(of:)) ?? (emergencyActive ? .blocked : .sleeping)
    }
}

extension BotFace {
    /// The face for a step that runs, from its tool's name.
    nonisolated init(step: String) {
        let name = step.lowercased()
        if ["search", "recherche"].contains(where: name.contains) {
            self = .searching
        } else if ["write", "patch", "écriture", "marcel_code"].contains(where: name.contains) {
            self = .writing
        } else if ["read", "lecture", "extract", "marcel_", "skill", "memory", "mail"].contains(where: name.contains) {
            self = .reading
        } else {
            self = .working
        }
    }
}

#Preview {
    let bots: [String?] = [nil, "planning", "pointage", "recrutements", "mails", "veille", "mon-bot"]
    let faces: [BotFace] = [.idle, .listening, .thinking, .searching, .reading, .writing,
                            .working, .waiting, .blocked, .done, .failed, .sleeping]
    VStack(spacing: 12) {
        ForEach(Array(bots.enumerated()), id: \.offset) { _, bot in
            HStack(spacing: 8) {
                ForEach(Array(faces.enumerated()), id: \.offset) { _, face in
                    MarcelAvatar(size: 28, bot: bot, state: face)
                }
            }
        }
    }
    .padding()
}
