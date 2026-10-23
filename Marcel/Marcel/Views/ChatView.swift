import SwiftUI

struct ChatView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showMissions = false
    @State private var showIdeas = false
    @State private var showSidebar = false
    @GestureState private var drawerDrag: CGFloat = 0
    @FocusState private var composerFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.86, 360)
            let offset = showSidebar ? min(0, drawerDrag) : -width
            ZStack(alignment: .leading) {
                chat
                Color.black
                    .opacity(showSidebar ? 0.25 * (1 + offset / width) : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(showSidebar)
                    .onTapGesture { closeSidebar() }
                    .accessibilityHidden(true)
                SidebarView(onClose: closeSidebar, onOpenSettings: {
                    closeSidebar()
                    showSettings = true
                })
                .frame(width: width)
                .background {
                    UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28)
                        .fill(Theme.background)
                        .shadow(color: .black.opacity(showSidebar ? 0.15 : 0), radius: 20)
                        .ignoresSafeArea()
                }
                .offset(x: offset)
                .accessibilityHidden(!showSidebar)
            }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .updating($drawerDrag) { value, state, _ in
                        if showSidebar { state = value.translation.width }
                    }
                    .onEnded { value in
                        if showSidebar, value.translation.width < -width / 3 { closeSidebar() }
                    },
                isEnabled: showSidebar
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showMissions) {
            MissionsView()
        }
        .sheet(isPresented: $showIdeas) {
            NavigationStack {
                IdeasView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("OK") { showIdeas = false }
                        }
                    }
            }
        }
    }

    private func closeSidebar() {
        withAnimation(.snappy(duration: 0.3)) { showSidebar = false }
    }

    private var chat: some View {
        messages
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    if store.emergencyActive {
                        EmergencyBanner()
                    } else {
                        ServerStatusBanner(status: store.serverStatus)
                    }
                }
                .background {
                    // Messages fade out under the header instead of colliding with it.
                    LinearGradient(stops: [.init(color: Theme.background, location: 0.75),
                                           .init(color: Theme.background.opacity(0), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .padding(.bottom, -16)
                        .ignoresSafeArea(edges: .top)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if let proposal = store.goalProposals.first, !store.emergencyActive {
                        GoalProposalCard(goal: proposal)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    ComposerView(focused: $composerFocused)
                }
                .animation(.snappy, value: store.goalProposals)
                .background {
                    LinearGradient(stops: [.init(color: Theme.background.opacity(0), location: 0),
                                           .init(color: Theme.background, location: 0.35)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .task(id: scenePhase) {
                // Poll reachability only while the app is in the foreground.
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await store.checkServer()
                    try? await Task.sleep(for: .seconds(store.serverStatus == .reachable ? 30 : 8))
                }
            }
    }

    private var header: some View {
        ZStack(alignment: .top) {
            HStack {
                Button {
                    composerFocused = false
                    withAnimation(.snappy(duration: 0.3)) { showSidebar = true }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(Theme.surface, in: .circle)
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                }
                .tint(.primary)
                .accessibilityLabel("Menu")
                Spacer()
                Button {
                    composerFocused = false
                    showIdeas = true
                } label: {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(Theme.surface, in: .circle)
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                        .overlay(alignment: .topTrailing) {
                            let unseen = store.unseenIdeas
                            if unseen > 0 {
                                Text("\(unseen)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(Color.accentColor, in: .circle)
                                    .offset(x: 2, y: -2)
                            }
                        }
                }
                .tint(.primary)
                .accessibilityLabel(store.unseenIdeas > 0 ? "Idées, \(store.unseenIdeas) nouvelle(s)" : "Idées")
                Button {
                    composerFocused = false
                    showMissions = true
                } label: {
                    Image(systemName: "checklist")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(Theme.surface, in: .circle)
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                        .overlay(alignment: .topTrailing) {
                            let running = store.runningReplies
                            if running > 0 {
                                Text("\(running)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(Color.accentColor, in: .circle)
                                    .offset(x: 2, y: -2)
                            }
                        }
                }
                .tint(.primary)
                .accessibilityLabel(store.runningReplies > 0 ? "Missions, \(store.runningReplies) en cours" : "Missions")
            }
            .padding(.horizontal)
            .padding(.top, 4)

            Menu {
                MoodPicker(conversation: store.conversation)
            } label: {
                VStack(spacing: -6) {
                    MarcelAvatar(size: 60, mood: store.conversation.displayMood, isThinking: store.isStreaming)
                    Text("Marcel")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.surface, in: .capsule)
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                }
            }
            .tint(.primary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(store.isStreaming ? "Marcel écrit" : "Marcel")
            .accessibilityAddTraits(.isHeader)
        }
        .padding(.bottom, 8)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.conversation.messages.isEmpty {
                        EmptyChatView()
                    }
                    ForEach(store.conversation.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if let error = store.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.conversation.messages.last?.content) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: store.conversation.messages.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.goalProposals.first?.id) {
                // The proposal card grows the bottom inset: keep the end of the reply visible.
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct EmptyChatView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image("MarcelHero")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: 300)
                .frame(height: 200)
                .clipShape(.rect(cornerRadius: 28))
                .accessibilityHidden(true)
                .padding(.bottom, 8)
            Text("Bonjour, je suis Marcel.")
                .font(.title3.weight(.semibold))
            Text("Demande-moi quelque chose. Les missions continuent sur le serveur, même quand l'app est fermée.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 60)
    }
}

/// Shown while the emergency stop is on, with a way out.
private struct EmergencyBanner: View {
    @Environment(ChatStore.self) private var store
    @State private var resuming = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text("Arrêt d'urgence actif")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                Text("Aucune requête n'est envoyée.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                resuming = true
                Task {
                    await store.emergencyResume()
                    resuming = false
                }
            } label: {
                if resuming {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text("Reprendre").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .disabled(resuming)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        // Opaque, so messages scrolling underneath don't show through.
        .background(Theme.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.red.opacity(0.35)))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(.horizontal)
        .padding(.bottom, 6)
    }
}

private struct ServerStatusBanner: View {
    let status: ServerStatus

    var body: some View {
        if status == .unreachable || status == .unauthorized {
            Label(status == .unauthorized
                  ? "Jeton refusé — vérifie-le dans les réglages."
                  : "Serveur inaccessible — vérifie Tailscale. Conversations en cache consultables.",
                  systemImage: status == .unauthorized ? "key.slash" : "wifi.exclamationmark")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(.orange.opacity(0.14), in: .rect(cornerRadius: 14))
                .padding(.horizontal)
                .padding(.bottom, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

#Preview {
    ChatView().environment(ChatStore(settings: ServerSettings()))
}
