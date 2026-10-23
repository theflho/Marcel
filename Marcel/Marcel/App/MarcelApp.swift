import SwiftUI

@main
struct MarcelApp: App {
    @State private var store = ChatStore(settings: ServerSettings())
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environment(store)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
