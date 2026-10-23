import SwiftUI
import UserNotifications

@main
struct MarcelApp: App {
    @State private var store = ChatStore(settings: ServerSettings())
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Banners while the app is open, and a tap on a clock-in reminder opens the portal.
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environment(store)
                .preferredColorScheme(appearance.colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            // The next background check for ideas and finished replies (when notifications are on).
            if phase == .background { BackgroundRefresh.schedule() }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run()
        }
    }
}
