import SwiftUI

@main
struct PodcastNotesApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1380, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("检查更新") { model.checkForUpdates() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.isUpdating)
            }
        }
    }
}
