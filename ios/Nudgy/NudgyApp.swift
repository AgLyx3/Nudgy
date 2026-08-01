import SwiftUI

@main
struct NudgyApp: App {
    @StateObject private var session = NudgySession()

    var body: some Scene {
        WindowGroup {
            ConversationScreen()
                .environmentObject(session)
                .task { await session.start() }
        }
    }
}
