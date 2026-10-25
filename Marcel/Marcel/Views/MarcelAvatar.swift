import SwiftUI

/// Marcel's mascot: a sleepy sloth wearing a beret.
struct MarcelAvatar: View {
    var size: CGFloat = 48
    var mood: MarcelMood = .tree
    /// Gentle bounce while Marcel is answering.
    var isThinking = false
    /// The light ring and shadow; off where the mascot sits straight on the background.
    var framed = true
    /// The animal alone, cut out of its scene (no circle, no background).
    var cutout = false

    @State private var bounce = false

    var body: some View {
        picture
            .offset(y: bounce ? -size * 0.04 : 0)
            .animation(isThinking ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true) : .default, value: bounce)
            .onChange(of: isThinking, initial: true) { _, thinking in bounce = thinking }
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: mood)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var picture: some View {
        if cutout {
            Image(mood.imageName + "-cutout")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.18), radius: size * 0.05, y: size * 0.02)
        } else {
            Image(mood.imageName)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.circle)
                .overlay(Circle().strokeBorder(framed ? Theme.surface : .clear, lineWidth: max(1.5, size * 0.04)))
                .shadow(color: .black.opacity(framed ? 0.12 : 0), radius: size * 0.08, y: size * 0.03)
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        MarcelAvatar(size: 48)
        MarcelAvatar(size: 120, mood: .coffee, isThinking: true)
    }
    .padding()
}

/// Menu items to choose a conversation's illustration, or let Marcel pick from the topic.
struct MoodPicker: View {
    @Environment(ChatStore.self) private var store
    let conversation: Conversation

    var body: some View {
        Picker("Illustration", selection: Binding(
            get: { conversation.mood },
            set: { store.setMood(conversation.id, $0) }
        )) {
            Label("Automatique", systemImage: "sparkles").tag(MarcelMood?.none)
            ForEach(MarcelMood.allCases) { mood in
                Label {
                    Text(mood.label)
                } icon: {
                    Image(mood.imageName + "-cutout")
                }
                .tag(MarcelMood?.some(mood))
            }
        }
    }
}
