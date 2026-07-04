import Foundation

enum NodeRunner {
    struct ProcessFailure: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    static func findNode() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            Bundle.main.resourceURL?
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("node").path,
            environment["TURNOVER_NODE_PATH"],
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ].compactMap { $0 }

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func conformPrepScript() -> URL? {
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("build_conform_prep_fcpxml.mjs"),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }

        let environment = ProcessInfo.processInfo.environment
        if let override = environment["TURNOVER_CONFORM_PREP_SCRIPT"] {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func autoMarkerScript() -> URL? {
        bundledScript(named: "build_vfx_auto_marker_fcpxml.mjs")
    }

    static func vfxPullEDLScript() -> URL? {
        bundledScript(named: "build_vfx_pull_edl.mjs")
    }

    static func vfxNamingScript() -> URL? {
        bundledScript(named: "build_vfx_naming_fcpxml.mjs")
    }

    static func vfxTimelineScript() -> URL? {
        bundledScript(named: "build_vfx_deliveries_fcpxml.mjs")
    }

    static func vfxShotListManifestScript() -> URL? {
        bundledScript(named: "build_vfx_shot_list_manifest.mjs")
    }

    static func vfxShotListExcelScript() -> URL? {
        bundledScript(named: "generate_vfx_shot_list_excel.mjs")
    }

    static func dataBurnInManifestScript() -> URL? {
        bundledScript(named: "build_data_burn_in_manifest.mjs")
    }

    static func importPreparationScript() -> URL? {
        bundledScript(named: "prepare_turnover_import_fcpxml.mjs")
    }

    static func prepareForFinalCutImport(executable: URL, xmlURL: URL) async throws {
        guard let scriptURL = importPreparationScript() else {
            throw ProcessFailure(message: "The bundled Turnover import preparation script is missing.")
        }
        _ = try await run(
            executable: executable,
            arguments: [
                scriptURL.path,
                "--input-xml", xmlURL.path,
                "--output-xml", xmlURL.path,
            ]
        )
    }

    private static func bundledScript(named name: String) -> URL? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func run(executable: URL, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            ]) { current, _ in current }

            process.terminationHandler = { process in
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
                let outputText = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let errorText = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: outputText)
                } else {
                    let detail = errorText.isEmpty ? outputText : errorText
                    continuation.resume(throwing: ProcessFailure(
                        message: detail.isEmpty
                            ? "Node exited with status \(process.terminationStatus)."
                            : detail
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
