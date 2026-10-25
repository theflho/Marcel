import SwiftUI

struct ChatView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showMissions = false
    @State private var showIdeas = false
    @State private var showAssistants = false
    @State private var showSidebar = false
    @State private var showSplash = true
    @GestureState private var drawerDrag: CGFloat = 0
    /// How far the menu has been pulled out from the left edge, while the finger is down.
    @GestureState private var edgeDrag: CGFloat = 0
    @FocusState private var composerFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.86, 360)
            let offset = showSidebar ? min(0, drawerDrag) : -width + min(width, max(0, edgeDrag))
            ZStack(alignment: .leading) {
                chat
                    // Swiping right opens the menu, like in Messages or ChatGPT.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 24)
                            .onEnded { value in
                                let dx = value.translation.width, dy = value.translation.height
                                guard !showSidebar, dx > 70, abs(dy) < dx * 0.6,
                                      value.startLocation.x < geometry.size.width * 0.6 else { return }
                                composerFocused = false
                                withAnimation(.snappy(duration: 0.3)) { showSidebar = true }
                            }
                    )
                // The left edge: the menu follows the finger and opens past a third of its width
                // (the message list doesn't get to take this swipe).
                Color.clear
                    .frame(width: 24)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .updating($edgeDrag) { value, state, _ in state = value.translation.width }
                            .onEnded { value in
                                guard value.translation.width > width / 3
                                        || value.predictedEndTranslation.width > width / 2 else { return }
                                composerFocused = false
                                withAnimation(.snappy(duration: 0.3)) { showSidebar = true }
                            }
                    )
                    .allowsHitTesting(!showSidebar)
                    .accessibilityHidden(true)
                Color.black
                    .opacity(0.25 * (1 + offset / width))
                    .ignoresSafeArea()
                    .allowsHitTesting(showSidebar)
                    .onTapGesture { closeSidebar() }
                    .accessibilityHidden(true)
                SidebarView(onClose: closeSidebar, onOpenSettings: {
                    closeSidebar()
                    showSettings = true
                }, onOpenAssistants: {
                    closeSidebar()
                    showAssistants = true
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
        .overlay {
            if showSplash {
                SplashView { withAnimation(.easeOut(duration: 0.35)) { showSplash = false } }
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onChange(of: store.settingsRequest) { _, route in
            // An error or the token gauge asks for a precise settings screen.
            guard route != nil else { return }
            composerFocused = false
            closeSidebar()
            showSettings = true
        }
        .sheet(isPresented: $showMissions) {
            MissionsView()
        }
        .sheet(isPresented: $showAssistants) {
            AssistantsView { assistant in store.newConversation(assistant: assistant.id) }
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
            .background(Theme.chatBackground.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    if store.emergencyActive {
                        EmergencyBanner()
                    } else {
                        ServerStatusBanner(status: store.serverStatus)
                        if let usage = store.tokenUsage, usage.fraction >= 0.8 {
                            TokenBanner(usage: usage)
                        }
                    }
                }
                .background {
                    // Messages fade out under the header instead of colliding with it.
                    LinearGradient(stops: [.init(color: Theme.chatBackground, location: 0.7),
                                           .init(color: Theme.chatBackground.opacity(0), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .padding(.bottom, -16)
                        .ignoresSafeArea(edges: .top)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if store.speaker.speakingID != nil {
                        Button("Arrêter la lecture", systemImage: "speaker.slash.fill") { store.speaker.stop() }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .clipShape(.capsule)
                            .transition(.opacity)
                    }
                    if let proposal = store.goalProposals.first, !store.emergencyActive {
                        GoalProposalCard(goal: proposal)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    SlashPalette()
                    ComposerView(focused: $composerFocused)
                }
                .animation(.snappy, value: store.goalProposals)
                .animation(.snappy(duration: 0.2), value: store.slashSuggestions)
                .background {
                    LinearGradient(stops: [.init(color: Theme.chatBackground.opacity(0), location: 0),
                                           .init(color: Theme.chatBackground, location: 0.35)],
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
                        .glass(in: .circle)
                }
                .tint(.primary)
                .accessibilityLabel("Menu")
                Spacer()
                moreMenu
            }
            .padding(.horizontal)
            .padding(.top, 4)

            Menu {
                // This bot, like Grok Bot: another conversation with it, or its card. Other bots are
                // in the side menu.
                Button("Nouvelle conversation", systemImage: "square.and.pencil") {
                    store.newConversation(assistant: store.conversation.assistantID)
                }
                Button(store.mode == nil ? "Tous les bots" : "Fiche du bot", systemImage: "person.crop.circle") {
                    composerFocused = false
                    showAssistants = true
                }
            } label: {
                VStack(spacing: -4) {
                    MarcelAvatar(size: 60, mood: store.modeMood, isThinking: store.isStreaming, cutout: true)
                    VStack(spacing: 0) {
                        // Like Telegram: while Marcel replies, three dots take the name's place.
                        if store.isStreaming {
                            TypingDots()
                                .frame(height: 20)
                        } else {
                            HStack(spacing: 4) {
                                // Always Marcel: a bot is one of the things he takes care of, not someone else.
                                Text("Marcel")
                                    .font(.subheadline.weight(.semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // "en ligne" when idle; while replying, only what a running step does.
                        if let line = store.isStreaming ? store.runningActivity
                            : [store.mode?.name, store.headerStatus?.text].compactMap { $0 }.joined(separator: " · ").nilIfEmpty {
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(store.isStreaming ? Color.accentColor : .secondary)
                                .lineLimit(1)
                        }
                    }
                    // Same size whether it shows the name or the dots.
                    .frame(minWidth: 64, minHeight: 34)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .glass(in: .capsule)
                }
            }
            .tint(.primary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Marcel\(store.mode.map { ", \($0.name)" } ?? "")\(store.headerStatus.map { ", \($0.text)" } ?? "")")
            .accessibilityHint("Nouvelle conversation ou fiche du bot")
            .accessibilityAddTraits(.isHeader)
        }
        .padding(.bottom, 8)
    }

    /// Ideas, missions, assistants and the illustration, behind one button (a dot when something waits).
    private var moreMenu: some View {
        let unseen = store.unseenIdeas, running = store.runningReplies
        return Menu {
            Button {
                composerFocused = false
                showIdeas = true
            } label: {
                Label(unseen > 0 ? "Idées (\(unseen) nouvelle\(unseen > 1 ? "s" : ""))" : "Idées", systemImage: "lightbulb")
            }
            Button {
                composerFocused = false
                showMissions = true
            } label: {
                Label(running > 0 ? "Activité (\(running) en cours)" : "Activité", systemImage: "checklist")
            }
            Button(store.conversation.isPrivate ? "Déjà en privé" : "Conversation privée", systemImage: "lock") {
                composerFocused = false
                store.newPrivateConversation()
            }
            .disabled(store.conversation.isPrivate)
            Button("Assistants", systemImage: "person.2") {
                composerFocused = false
                showAssistants = true
            }
            Divider()
            Menu("Illustration", systemImage: "photo") {
                // A conversation with an assistant shows its mascot: picking one changes the assistant's.
                if let assistant = store.mode {
                    AssistantMoodPicker(assistant: assistant)
                } else {
                    MoodPicker(conversation: store.conversation)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .glass(in: .circle)
                .overlay(alignment: .topTrailing) {
                    if unseen + running > 0 {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 11, height: 11)
                            .offset(x: -2, y: 2)
                    }
                }
        }
        .tint(.primary)
        .accessibilityLabel("Plus" + (unseen > 0 ? ", \(unseen) idée(s)" : "") + (running > 0 ? ", \(running) mission(s) en cours" : ""))
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.conversation.messages.isEmpty {
                        WelcomeView()
                    }
                    ForEach(store.conversation.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if let last = store.conversation.messages.last, last.role == .assistant, last.status == .complete,
                       !store.isStreaming {
                        let questions = Followups.find(in: last.content)
                        if !questions.isEmpty { FollowupsView(questions: questions) }
                    }
                    if let error = store.lastError {
                        ErrorNotice(message: error, action: store.lastErrorAction)
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
            .onChange(of: store.isStreaming) {
                // The follow-ups appear under the reply once it's finished: keep them in sight.
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

/// The last error under the conversation, with the way out when there is one.
private struct ErrorNotice: View {
    @Environment(ChatStore.self) private var store
    let message: String
    let action: ErrorAction?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action.label) { store.perform(action) }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal)
    }
}

/// Server problems, each with the fix one tap away.
private struct ServerStatusBanner: View {
    @Environment(ChatStore.self) private var store
    let status: ServerStatus

    var body: some View {
        if status == .unreachable || status == .unauthorized {
            Button {
                if status == .unauthorized {
                    store.openSettings(.server(store.settings.activeID))
                } else {
                    Task { await store.checkServer() }
                }
            } label: {
                HStack(spacing: 8) {
                    Label(status == .unauthorized
                          ? "Jeton refusé par le serveur."
                          : "Serveur inaccessible : vérifie Tailscale. Les conversations restent consultables.",
                          systemImage: status == .unauthorized ? "key.slash" : "wifi.exclamationmark")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(status == .unauthorized ? "Corriger" : "Réessayer")
                        .fontWeight(.semibold)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(.orange.opacity(0.14), in: .rect(cornerRadius: 14))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.bottom, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Shown once most of the day's token budget is spent.
private struct TokenBanner: View {
    @Environment(ChatStore.self) private var store
    let usage: TokenUsage

    var body: some View {
        let spent = usage.fraction >= 1
        Button {
            store.openSettings(.proactive)
        } label: {
            HStack(spacing: 8) {
                Label(spent ? "Budget de tokens du jour épuisé : reprise à minuit."
                            : "\(Int(usage.fraction * 100)) % du budget de tokens du jour utilisé.",
                      systemImage: "gauge.with.dots.needle.67percent")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Détails").fontWeight(.semibold)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(spent ? Color.red : Color.orange)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background((spent ? Color.red : .orange).opacity(0.14), in: .rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.bottom, 6)
    }
}

#Preview {
    ChatView().environment(ChatStore(settings: ServerSettings()))
}

/// Three dots rising in turn, like a chat app's "typing" bubble.
struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    let wave = (sin(t * 6 - Double(i) * 0.9) + 1) / 2
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * wave)
                        .offset(y: -3 * wave)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
