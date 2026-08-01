import SwiftUI

@main
struct NudgyApp: App {
    @StateObject private var session = NudgySession()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(session)
                .task { await session.start() }
        }
    }
}
