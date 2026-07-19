import SwiftUI

@MainActor
final class TurnoverAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: TurnoverModel?
    private struct PendingOpen {
        var path: String
        var burnInCustomize: Bool
    }
    private var pendingOpens: [PendingOpen] = []

    func bind(model: TurnoverModel) {
        self.model = model
        queueLaunchBurnInCustomizeRequestIfNeeded()
        let opens = pendingOpens
        pendingOpens.removeAll()
        for open in opens {
            let url = URL(fileURLWithPath: open.path)
            if open.burnInCustomize {
                model.acceptForBurnInCustomize(url: url)
            } else {
                model.accept(url: url)
            }
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let burnInCustomize = URL(fileURLWithPath: filename).lastPathComponent == "Data_Burn_In_Source.fcpxml"
        if let model {
            let url = URL(fileURLWithPath: filename)
            if burnInCustomize {
                model.acceptForBurnInCustomize(url: url)
            } else {
                model.accept(url: url)
            }
        } else {
            pendingOpens.append(PendingOpen(path: filename, burnInCustomize: burnInCustomize))
        }
        return true
    }

    private func queueLaunchBurnInCustomizeRequestIfNeeded() {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--open-burn-in-customize"),
              arguments.indices.contains(arguments.index(after: flagIndex)) else { return }
        let path = arguments[arguments.index(after: flagIndex)]
        guard !pendingOpens.contains(where: { $0.path == path }) else { return }
        pendingOpens.append(PendingOpen(path: path, burnInCustomize: true))
    }
}

@main
struct TurnoverApp: App {
    @NSApplicationDelegateAdaptor(TurnoverAppDelegate.self) private var appDelegate
    @StateObject private var model = TurnoverModel()

    init() {
        TurnoverHeadlessCommand.runAndExitIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    appDelegate.bind(model: model)
                }
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
        WindowGroup("Data Burn-In Customizer", id: "burn-in-customizer") {
            BurnInCustomizerView(model: model)
                .frame(minWidth: 1280, minHeight: 820)
        }
    }
}
