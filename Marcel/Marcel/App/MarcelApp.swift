import SwiftUI

@main
struct MarcelApp: App {
    @State private var store = ChatStore(settings: ServerSettings())

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environment(store)
        }
    }
}
