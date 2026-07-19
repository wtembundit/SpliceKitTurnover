import Foundation

enum TurnoverHeadlessCommand {
    private struct Options {
        var listPresets = false
        var exportTransparent = false
        var sourceXML: String?
        var output: String?
        var presetID: String?
        var presetName: String?
    }

    static func runAndExitIfNeeded() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.contains("--list-burn-in-presets") || args.contains("--burn-in-transparent") else { return }

        Task { @MainActor in
            let code = await run(args: args)
            Foundation.exit(code)
        }
        RunLoop.main.run()
    }

    @MainActor
    private static func run(args: [String]) async -> Int32 {
        do {
            let options = try parse(args: args)
            let model = TurnoverModel()
            if options.listPresets {
                printJSON([
                    "status": "ok",
                    "presets": model.burnInPresetSummariesForHeadless(),
                ])
                return 0
            }
            if options.exportTransparent {
                guard let sourceXML = options.sourceXML, !sourceXML.isEmpty else {
                    throw HeadlessError("Missing --source-xml")
                }
                guard let output = options.output, !output.isEmpty else {
                    throw HeadlessError("Missing --output")
                }
                let result = try await model.exportTransparentBurnInHeadless(
                    source: URL(fileURLWithPath: sourceXML),
                    destination: URL(fileURLWithPath: output),
                    presetID: options.presetID,
                    presetName: options.presetName
                )
                printJSON(result)
                return 0
            }
            throw HeadlessError("No headless command was provided.")
        } catch {
            printJSON([
                "status": "error",
                "message": error.localizedDescription,
            ])
            return 1
        }
    }

    private static func parse(args: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--list-burn-in-presets":
                options.listPresets = true
            case "--burn-in-transparent":
                options.exportTransparent = true
            case "--source-xml":
                index += 1
                options.sourceXML = try value(args, index, for: arg)
            case "--output":
                index += 1
                options.output = try value(args, index, for: arg)
            case "--preset-id":
                index += 1
                options.presetID = try value(args, index, for: arg)
            case "--preset-name":
                index += 1
                options.presetName = try value(args, index, for: arg)
            default:
                throw HeadlessError("Unknown argument: \(arg)")
            }
            index += 1
        }
        return options
    }

    private static func value(_ args: [String], _ index: Int, for flag: String) throws -> String {
        guard index < args.count else { throw HeadlessError("Missing value for \(flag)") }
        return args[index]
    }

    private static func printJSON(_ object: Any) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print("{\"status\":\"error\",\"message\":\"Could not encode JSON output\"}")
        }
    }
}

struct HeadlessError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
