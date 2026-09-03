import SwiftUI

@main
struct NixTermApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(red: 0.157, green: 0.173, blue: 0.204)
                    .ignoresSafeArea()
                TerminalView()
            }
            .preferredColorScheme(.dark)
        }
    }
}
