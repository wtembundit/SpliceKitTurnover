import SwiftUI

@main
struct TurnoverApp: App {
    @StateObject private var model = TurnoverModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 940, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open FCPXML...") {
                    model.chooseSource()
                }
                .keyboardShortcut("o")
            }
        }
    }
}
