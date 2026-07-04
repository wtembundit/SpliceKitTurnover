import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class TurnoverModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case conformPrep = "Conform Prep"
        case vfxNaming = "VFX Naming"
        case autoMarker = "Auto Marker"
        case vfxPullEDL = "VFX Pull EDL"
        case vfxShotList = "VFX Shot List"
        case vfxTimeline = "VFX Timeline"
        case dataBurnIn = "Data Burn-In"

        var id: String { rawValue }

        var selectorName: String {
            switch self {
            case .vfxNaming: "Naming"
            case .vfxPullEDL: "Pull EDL"
            case .vfxShotList: "Shot List"
            case .vfxTimeline: "Timeline"
            default: rawValue
            }
        }
    }

    enum BurnInPreset: String, CaseIterable, Identifiable, Codable {
        case editorialReview = "Editorial Review"
        case vfxReview = "VFX Review"
        case sourceQC = "Source QC"
        case audioReview = "Audio Review"
        case custom = "Custom"

        var id: String { rawValue }
    }

    enum BurnInAnchor: String, CaseIterable, Identifiable, Codable {
        case topLeft = "Top Left"
        case topCenter = "Top Center"
        case topRight = "Top Right"
        case bottomLeft = "Bottom Left"
        case bottomCenter = "Bottom Center"
        case bottomRight = "Bottom Right"

        var id: String { rawValue }
    }

    enum BurnInTextColor: String, CaseIterable, Identifiable, Codable {
        case white = "White"
        case yellow = "Yellow"
        case cyan = "Cyan"
        case red = "Red"
        case black = "Black"

        var id: String { rawValue }
    }

    struct BurnInField: Identifiable, Codable, Equatable {
        var anchor: BurnInAnchor
        var enabled: Bool
        var template: String
        var fontSize: Double
        var horizontalPadding: Double
        var verticalPadding: Double
        var textColor: BurnInTextColor
        var backgroundOpacity: Double

        var id: BurnInAnchor { anchor }
    }

    enum MarkerKind: String, CaseIterable, Identifiable {
        case standard = "Standard"
        case todo = "To Do"
        case chapter = "Chapter"

        var id: String { rawValue }
        var argument: String { self == .todo ? "todo" : rawValue.lowercased() }
    }

    enum NamingMode: String, CaseIterable, Identifiable {
        case auto = "Auto Number"
        case reset = "Reset to XXXX"

        var id: String { rawValue }
        var argument: String { self == .auto ? "auto" : "reset" }
    }

    enum TimelinePlacement: String, CaseIterable, Identifiable {
        case connected = "Connected"
        case replace = "Replace"
        case audition = "Audition"

        var id: String { rawValue }
        var argument: String { rawValue.lowercased() }
    }

    enum JobState: Equatable {
        case idle
        case ready
        case running
        case succeeded
        case failed(String)
    }

    private struct BurnInManifest: Decodable {
        struct Timeline: Decodable {
            let startSeconds: Double
            let durationSeconds: Double
            let frameDurationSeconds: Double
            let tcFormat: String
            let width: Int?
            let height: Int?
            let colorSpace: String?
            let formatName: String?
        }

        struct VideoSegment: Decodable {
            let timelineStartSeconds: Double
            let timelineEndSeconds: Double
            let sourceFilename: String
            let sourceInSeconds: Double
            let sourceOutSeconds: Double
            let sourceFrameDuration: Double
            let sourceTcFormat: String
        }

        struct VFXTitle: Decodable {
            let timelineStartSeconds: Double
            let timelineEndSeconds: Double
            let vfxNumber: String
            let note: String
        }

        struct AudioRole: Decodable {
            let timelineStartSeconds: Double
            let timelineEndSeconds: Double
            let role: String
        }

        let project: String
        let event: String
        let timeline: Timeline
        let videoSegments: [VideoSegment]
        let vfxTitles: [VFXTitle]
        let audioRoles: [AudioRole]
    }

    private struct SavedBurnInSettings: Codable {
        let fields: [BurnInField]
        let audioRoleFilter: String
        let conditionalText: String
    }

    @Published var sourceURL: URL?
    @Published var outputURL: URL?
    @Published var reportURL: URL?
    @Published var state: JobState = .idle
    @Published var log = "Drop an FCPXML file to begin."
    @Published var openInFinalCut = false
    @Published var selectedTool: Tool = .conformPrep
    @Published var markerKind: MarkerKind = .standard
    @Published var renameMarkers = false
    @Published var handleFrames = 0
    @Published var namingMode: NamingMode = .auto
    @Published var namingStart = 10
    @Published var namingStep = 10
    @Published var deliveryFolderURL: URL?
    @Published var timelineHandleFrames = 0
    @Published var timelineSlateFrames = 0
    @Published var timelinePlacement: TimelinePlacement = .connected
    @Published var referenceMovieURL: URL?
    @Published var cacheSizeText = "0 KB"
    @Published var updateStatus = "Check for Updates"
    @Published var isVFXNamingTemplateInstalled = false
    @Published var templateInstallStatus = ""
    @Published var burnInFields = TurnoverModel.defaultBurnInFields()
    @Published var selectedBurnInAnchor: BurnInAnchor = .topLeft
    @Published var burnInAudioRoleFilter = ""
    @Published var burnInConditionalText = "TEMP AUDIO"
    @Published var burnInPositionSeconds = 0.0
    @Published var burnInDurationSeconds = 0.0
    @Published var burnInPreset: BurnInPreset = .editorialReview
    @Published var burnInVideoURL: URL?

    private var burnInManifest: BurnInManifest?
    private let burnInSettingsKey = "Turnover.DataBurnIn.CustomPreset.v2"

    private let latestReleaseAPI = URL(string: "https://api.github.com/repos/wtembundit/SpliceKitTurnover/releases/latest")!

    init() {
        loadBurnInCustomPreset()
        do {
            try CacheManager.prepareAndClean()
            refreshCacheSize()
            refreshVFXNamingTemplateStatus()
            checkForUpdates(showResult: false)
        } catch {
            log = "Cache cleanup warning: \(error.localizedDescription)"
        }
    }

    func refreshVFXNamingTemplateStatus() {
        isVFXNamingTemplateInstalled = FileManager.default.fileExists(
            atPath: vfxNamingTemplateDestination.appendingPathComponent("VFX NAMING.moti").path
        )
    }

    func installVFXNamingTemplate() {
        guard let source = Bundle.main.resourceURL?
            .appendingPathComponent("Motion Templates.localized", isDirectory: true)
            .appendingPathComponent("Titles.localized", isDirectory: true)
            .appendingPathComponent("VFX", isDirectory: true)
            .appendingPathComponent("VFX Naming", isDirectory: true),
              FileManager.default.fileExists(atPath: source.appendingPathComponent("VFX NAMING.moti").path) else {
            templateInstallStatus = "Bundled template is missing."
            return
        }

        do {
            let destination = vfxNamingTemplateDestination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: vfxNamingTemplateDestination.path) {
                try FileManager.default.removeItem(at: vfxNamingTemplateDestination)
            }
            try FileManager.default.copyItem(at: source, to: vfxNamingTemplateDestination)
            refreshVFXNamingTemplateStatus()
            templateInstallStatus = "Installed. Restart Final Cut Pro to refresh Titles."
        } catch {
            templateInstallStatus = "Install failed: \(error.localizedDescription)"
        }
    }

    private var vfxNamingTemplateDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/Motion Templates.localized/Titles.localized/VFX/VFX Naming", isDirectory: true)
    }

    func checkForUpdates(showResult: Bool = true) {
        updateStatus = "Checking..."
        Task {
            do {
                var request = URLRequest(url: latestReleaseAPI)
                request.timeoutInterval = 10
                request.setValue("Turnover-Standalone", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw NodeRunner.ProcessFailure(message: "GitHub returned an unexpected response.")
                }
                let release = try JSONDecoder().decode(LatestRelease.self, from: data)
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
                let available = compareVersions(current, release.tagName) == .orderedAscending
                updateStatus = available ? "\(release.tagName) Available" : "Up to Date"
                if available || showResult {
                    showUpdateResult(current: current, release: release, available: available)
                }
            } catch {
                updateStatus = "Check Failed"
                if showResult {
                    let alert = NSAlert()
                    alert.messageText = "Update check failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .compare(rhs.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), options: .numeric)
    }

    private func showUpdateResult(current: String, release: LatestRelease, available: Bool) {
        let alert = NSAlert()
        alert.messageText = available ? "Turnover update available" : "Turnover is up to date"
        alert.informativeText = available
            ? "Turnover \(release.tagName) is available. You are using \(current)."
            : "You are using the latest version (\(current))."
        if available { alert.addButton(withTitle: "Open Download Page") }
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn,
           available,
           let url = URL(string: release.htmlURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    var nodeStatus: String {
        if let node = NodeRunner.findNode() {
            return "Node.js: \(node.path)"
        }
        return "Node.js: Not found"
    }

    var canRun: Bool {
        sourceURL != nil
            && state != .running
            && NodeRunner.findNode() != nil
            && (selectedTool != .vfxShotList || referenceMovieURL != nil)
    }

    var burnInTimelineLabel: String {
        guard let manifest = burnInManifest else { return "Build a manifest to preview timeline values." }
        let absolute = manifest.timeline.startSeconds + burnInPositionSeconds
        return "Frame preview: \(formatTimecode(seconds: absolute, frameDuration: manifest.timeline.frameDurationSeconds, tcFormat: manifest.timeline.tcFormat))"
    }

    func burnInPreviewText(for field: BurnInField) -> String {
        guard let manifest = burnInManifest else { return field.template }
        let absolute = manifest.timeline.startSeconds + burnInPositionSeconds
        let segment = manifest.videoSegments
            .filter { absolute >= $0.timelineStartSeconds && absolute < $0.timelineEndSeconds }
            .last
        let title = manifest.vfxTitles
            .filter { absolute >= $0.timelineStartSeconds && absolute < $0.timelineEndSeconds }
            .last
        let roles = manifest.audioRoles
            .filter { absolute >= $0.timelineStartSeconds && absolute < $0.timelineEndSeconds }
            .map(\.role)
        let sourceSeconds: Double? = segment.map {
            let timelineSpan = max($0.timelineEndSeconds - $0.timelineStartSeconds, 0)
            guard timelineSpan > 0 else { return $0.sourceInSeconds }
            let ratio = (absolute - $0.timelineStartSeconds) / timelineSpan
            return $0.sourceInSeconds + (($0.sourceOutSeconds - $0.sourceInSeconds) * ratio)
        }
        let values: [String: String] = [
            "project": manifest.project,
            "event": manifest.event,
            "timeline_tc": formatTimecode(seconds: absolute, frameDuration: manifest.timeline.frameDurationSeconds, tcFormat: manifest.timeline.tcFormat),
            "timeline_frame": String(Int((burnInPositionSeconds / manifest.timeline.frameDurationSeconds).rounded(.down))),
            "source_file": segment?.sourceFilename ?? "",
            "source_tc": sourceSeconds.map { formatTimecode(seconds: $0, frameDuration: segment?.sourceFrameDuration ?? manifest.timeline.frameDurationSeconds, tcFormat: segment?.sourceTcFormat ?? "") } ?? "",
            "vfx_number": title?.vfxNumber ?? "",
            "vfx_note": title?.note ?? "",
            "audio_role": roles.joined(separator: ", "),
            "custom_text": burnInConditionalText,
        ]
        var rendered = field.template
        for (token, value) in values {
            rendered = rendered.replacingOccurrences(of: "{\(token)}", with: value)
        }
        let filter = burnInAudioRoleFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filter.isEmpty && roles.contains(where: { $0.localizedCaseInsensitiveContains(filter) }) {
            rendered += rendered.isEmpty ? burnInConditionalText : "\n\(burnInConditionalText)"
        }
        return rendered
    }

    var selectedBurnInFieldIndex: Int {
        burnInFields.firstIndex(where: { $0.anchor == selectedBurnInAnchor }) ?? 0
    }

    static func defaultBurnInFields() -> [BurnInField] {
        BurnInAnchor.allCases.map { anchor in
            let template: String
            switch anchor {
            case .topLeft: template = "{project}"
            case .topRight: template = "{timeline_tc}"
            case .bottomLeft: template = "{source_file}\n{source_tc}"
            case .bottomRight: template = "{vfx_number}"
            default: template = ""
            }
            return BurnInField(
                anchor: anchor,
                enabled: !template.isEmpty,
                template: template,
                fontSize: 20,
                horizontalPadding: 48,
                verticalPadding: 36,
                textColor: .white,
                backgroundOpacity: 0.35
            )
        }
    }

    var dropTypeIdentifiers: [String] {
        [UTType.fileURL.identifier] + finalCutPasteboardTypes
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose an FCPXML file or bundle"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        // FCPXMLD is a filesystem directory package. AppKit requires directory
        // selection even when the package is presented as a single file.
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        accept(url: url)
    }

    func chooseBurnInVideo() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video to Burn In"
        panel.message = "Choose a reference or master video. Leave this empty to render a transparent ProRes 4444 overlay later."
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        burnInVideoURL = url
    }

    func clearBurnInVideo() {
        burnInVideoURL = nil
    }

    func applyBurnInPreset() {
        burnInFields = Self.defaultBurnInFields()
        switch burnInPreset {
        case .editorialReview:
            burnInAudioRoleFilter = ""
        case .vfxReview:
            setBurnInField(.bottomLeft, template: "{vfx_number}\n{vfx_note}", enabled: true)
            burnInAudioRoleFilter = ""
        case .sourceQC:
            setBurnInField(.bottomLeft, template: "{source_file}\n{source_tc}", enabled: true)
            burnInAudioRoleFilter = ""
        case .audioReview:
            setBurnInField(.topCenter, template: "{audio_role}\n{custom_text}", enabled: true)
            burnInAudioRoleFilter = "Dialogue"
            burnInConditionalText = "TEMP AUDIO"
        case .custom:
            break
        }
    }

    func saveBurnInCustomPreset() {
        burnInPreset = .custom
        let settings = SavedBurnInSettings(
            fields: burnInFields,
            audioRoleFilter: burnInAudioRoleFilter,
            conditionalText: burnInConditionalText
        )
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: burnInSettingsKey)
        }
    }

    private func loadBurnInCustomPreset() {
        guard let data = UserDefaults.standard.data(forKey: burnInSettingsKey),
              let settings = try? JSONDecoder().decode(SavedBurnInSettings.self, from: data) else { return }
        burnInFields = settings.fields
        burnInAudioRoleFilter = settings.audioRoleFilter
        burnInConditionalText = settings.conditionalText
        burnInPreset = .custom
    }

    private func setBurnInField(_ anchor: BurnInAnchor, template: String, enabled: Bool) {
        guard let index = burnInFields.firstIndex(where: { $0.anchor == anchor }) else { return }
        burnInFields[index].template = template
        burnInFields[index].enabled = enabled
    }

    func accept(url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ext == "fcpxml" || ext == "fcpxmld" else {
            state = .failed("Choose a .fcpxml file or .fcpxmld bundle.")
            return
        }
        if ext == "fcpxmld",
           !FileManager.default.fileExists(atPath: url.appendingPathComponent("Info.fcpxml").path) {
            state = .failed("This FCPXML bundle does not contain Info.fcpxml.")
            return
        }
        sourceURL = url
        outputURL = nil
        reportURL = nil
        state = .ready
        log = "Ready to process \(url.lastPathComponent)"
    }

    func acceptDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                Task { @MainActor in
                    if let url {
                        self.accept(url: url)
                    } else if let error {
                        self.state = .failed(error.localizedDescription)
                    }
                }
            }
            return true
        }

        guard let type = finalCutPasteboardTypes.first(where: {
            provider.hasItemConformingToTypeIdentifier($0)
        }) else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
            Task { @MainActor in
                do {
                    if let error { throw error }
                    guard let data, !data.isEmpty else {
                        throw NodeRunner.ProcessFailure(message: "Final Cut Pro returned an empty FCPXML payload.")
                    }
                    let url = try self.storeFinalCutDrop(data)
                    self.accept(url: url)
                    self.log = "Received \(url.lastPathComponent) directly from Final Cut Pro."
                } catch {
                    self.state = .failed("Could not receive the Final Cut Pro project: \(error.localizedDescription)")
                }
            }
        }
        return true
    }

    func runConformPrep() {
        guard let sourceURL else { return }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("Node.js was not found. Install Node.js or configure TURNOVER_NODE_PATH.")
            return
        }
        guard let scriptURL = NodeRunner.conformPrepScript() else {
            state = .failed("The bundled Conform Prep planner is missing.")
            return
        }

        guard let destination = chooseXMLOutputURL(for: sourceURL, suffix: "Turnover") else {
            log = "Conform Prep cancelled: no output location selected."
            return
        }
        let isBundle = sourceURL.pathExtension.lowercased() == "fcpxmld"
        let plannerSource = isBundle ? sourceURL.appendingPathComponent("Info.fcpxml") : sourceURL
        let report = temporaryReportURL(tool: "conform-prep")
        state = .running
        outputURL = nil
        reportURL = nil
        log = "Running Conform Prep..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let result = try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", plannerSource.path,
                            "--output-xml", destination.path,
                            "--report", report.path,
                        ]
                    )
                    try await NodeRunner.prepareForFinalCutImport(executable: nodeURL, xmlURL: destination)
                    if isBundle {
                        let note = "\nstandalone bundle handling:\n- read Info.fcpxml from the source FCPXMLD bundle\n- emitted flat FCPXML; bundle-only sidecars were not copied because flattening can invalidate their clip and timing references\n"
                        let handle = try FileHandle(forWritingTo: report)
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data(note.utf8))
                        try handle.close()
                    }
                    return result
                }.value
                outputURL = destination
                cacheDebugArtifacts(tool: "Conform-Prep", sourceXML: plannerSource, output: destination, report: report)
                try? FileManager.default.removeItem(at: report)
                reportURL = nil
                state = .succeeded
                log = result.isEmpty ? "Conform Prep completed." : result
                if openInFinalCut {
                    openResultInFinalCut()
                }
            } catch {
                try? FileManager.default.removeItem(at: report)
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func runSelectedTool() {
        switch selectedTool {
        case .conformPrep:
            runConformPrep()
        case .autoMarker:
            runAutoMarker()
        case .vfxPullEDL:
            runVFXPullEDL()
        case .vfxNaming:
            runVFXNaming()
        case .vfxTimeline:
            runVFXTimeline()
        case .vfxShotList:
            runVFXShotList()
        case .dataBurnIn:
            runDataBurnIn()
        }
    }

    func runDataBurnIn() {
        guard let sourceURL else { return }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("The bundled Node.js runtime is missing.")
            return
        }
        guard let scriptURL = NodeRunner.dataBurnInManifestScript() else {
            state = .failed("The bundled Data Burn-In manifest planner is missing.")
            return
        }
        guard let destination = chooseBurnInManifestOutputURL(for: sourceURL) else {
            log = "Data Burn-In manifest export cancelled."
            return
        }
        let plannerSource = sourceURL.pathExtension.lowercased() == "fcpxmld"
            ? sourceURL.appendingPathComponent("Info.fcpxml")
            : sourceURL
        let report = temporaryReportURL(tool: "data-burn-in")
        state = .running
        outputURL = nil
        reportURL = nil
        log = "Building frame-resolved Data Burn-In manifest..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", plannerSource.path,
                            "--output-manifest", destination.path,
                            "--report", report.path,
                        ]
                    )
                }.value
                let data = try Data(contentsOf: destination)
                let manifest = try JSONDecoder().decode(BurnInManifest.self, from: data)
                burnInManifest = manifest
                burnInDurationSeconds = max(manifest.timeline.durationSeconds, 0)
                burnInPositionSeconds = 0
                outputURL = destination
                cacheDebugArtifacts(tool: "Data-Burn-In", sourceXML: plannerSource, output: destination, report: report)
                try? FileManager.default.removeItem(at: report)
                state = .succeeded
                log = result.isEmpty ? "Data Burn-In manifest completed." : result
            } catch {
                try? FileManager.default.removeItem(at: report)
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func runVFXShotList() {
        guard let sourceURL else { return }
        guard let referenceMovieURL else {
            log = "Choose a timeline reference movie before running VFX Shot List."
            return
        }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("Node.js was not found. Install Node.js or configure TURNOVER_NODE_PATH.")
            return
        }
        guard let scriptURL = NodeRunner.vfxShotListManifestScript() else {
            state = .failed("The bundled VFX Shot List manifest planner is missing.")
            return
        }
        guard let excelScriptURL = NodeRunner.vfxShotListExcelScript() else {
            state = .failed("The bundled VFX Shot List Excel generator is missing.")
            return
        }
        guard let exportParent = chooseShotListExportDirectory(suggestedBy: sourceURL) else {
            log = "VFX Shot List cancelled: no output location selected."
            return
        }

        let plannerSource = sourceURL.pathExtension.lowercased() == "fcpxmld"
            ? sourceURL.appendingPathComponent("Info.fcpxml")
            : sourceURL
        let jobFolder: URL
        do {
            jobFolder = try createDebugJobDirectory(tool: "VFX-Shot-List")
            try FileManager.default.copyItem(at: plannerSource, to: jobFolder.appendingPathComponent("Source.fcpxml"))
        } catch {
            state = .failed("Could not prepare VFX Shot List: \(error.localizedDescription)")
            return
        }
        let manifest = jobFolder.appendingPathComponent("Manifest.tsv")
        let report = jobFolder.appendingPathComponent("Report.txt")
        state = .running
        outputURL = nil
        reportURL = nil
        log = "Preparing VFX Shot List from user marker anchors..."

        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", plannerSource.path,
                            "--output-manifest", manifest.path,
                            "--report", report.path,
                        ]
                    )
                }.value
                let rows = try Self.shotListManifestRows(at: manifest)
                guard let firstRow = rows.first else {
                    throw NodeRunner.ProcessFailure(message: "The VFX Shot List manifest has no marker rows.")
                }
                let projectName = firstRow["project_name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resultFolder = uniqueShotListResultFolder(
                    in: exportParent,
                    projectName: projectName?.isEmpty == false ? projectName! : sourceURL.deletingPathExtension().lastPathComponent
                )
                let thumbnailFolder = resultFolder.appendingPathComponent("Thumbnail", isDirectory: true)
                let captureFolder = jobFolder.appendingPathComponent("Captures", isDirectory: true)
                try FileManager.default.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: captureFolder, withIntermediateDirectories: true)

                let session = try await ReferenceMovieCapture.Session(movieURL: referenceMovieURL)
                log = "Extracting 0/\(rows.count) marker thumbnails from the reference movie..."
                for (index, row) in rows.enumerated() {
                    guard let movieSecondsText = row["movie_seconds"],
                          let movieSeconds = Double(movieSecondsText) else {
                        throw NodeRunner.ProcessFailure(message: "Shot \(index + 1) has no reference movie time.")
                    }
                    let thumbnailName = row["suggested_thumb_name"]?.isEmpty == false
                        ? row["suggested_thumb_name"]!
                        : String(format: "VFX_%03d.jpg", index + 1)
                    _ = try await session.captureFrame(
                        seconds: movieSeconds,
                        outputURL: thumbnailFolder.appendingPathComponent(thumbnailName),
                        thumbnail: true
                    )
                    let completed = index + 1
                    if completed == rows.count || completed == 1 || completed % 10 == 0 {
                        log = "Extracting \(completed)/\(rows.count) marker thumbnails from the reference movie..."
                    }
                }

                log = "Generating the VFX Shot List Excel workbook..."
                let safeProject = sanitizeFilename(projectName?.isEmpty == false ? projectName! : "Project")
                let workbook = resultFolder.appendingPathComponent("VFX Shot List - \(safeProject).xlsx")
                _ = try await Task.detached(priority: .userInitiated) {
                    try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            excelScriptURL.path,
                            "--manifest", manifest.path,
                            "--captures", captureFolder.path,
                            "--thumbs", thumbnailFolder.path,
                            "--output", workbook.path,
                            "--title", "VFX Shot List - \(projectName ?? "Project")",
                        ]
                    )
                }.value
                guard FileManager.default.fileExists(atPath: workbook.path) else {
                    throw NodeRunner.ProcessFailure(message: "The Excel generator completed without creating a workbook.")
                }
                outputURL = workbook
                state = .succeeded
                try? CacheManager.prepareAndClean()
                refreshCacheSize()
                log = "VFX Shot List complete: \(rows.count) thumbnails and Excel workbook created."
                revealOutput()
            } catch {
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func chooseReferenceMovie() {
        let panel = NSOpenPanel()
        panel.title = "Choose Timeline Reference Movie"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.movie]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            referenceMovieURL = panel.url
        }
    }

    func chooseDeliveryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose VFX Deliveries Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK { deliveryFolderURL = panel.url }
    }

    func runVFXTimeline() {
        guard let sourceURL else { return }
        if deliveryFolderURL == nil { chooseDeliveryFolder() }
        guard let deliveryFolderURL else {
            log = "VFX Timeline cancelled: no delivery folder selected."
            return
        }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("Node.js was not found. Install Node.js or configure TURNOVER_NODE_PATH.")
            return
        }
        guard let scriptURL = NodeRunner.vfxTimelineScript() else {
            state = .failed("The bundled VFX Timeline transformer is missing.")
            return
        }

        let plannerSource = sourceURL.pathExtension.lowercased() == "fcpxmld"
            ? sourceURL.appendingPathComponent("Info.fcpxml")
            : sourceURL
        guard let destination = chooseXMLOutputURL(for: sourceURL, suffix: "VFX Timeline") else {
            log = "VFX Timeline cancelled: no output location selected."
            return
        }
        let report = temporaryReportURL(tool: "vfx-timeline")
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnover-vfx-timeline-\(UUID().uuidString).tsv")
        let handles = max(0, timelineHandleFrames)
        let slate = max(0, timelineSlateFrames)
        let placement = timelinePlacement.argument
        state = .running
        outputURL = nil
        reportURL = nil
        log = "Matching VFX deliveries to naming titles..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let configText = [
                        "status\tok",
                        "delivery_folder\t\(deliveryFolderURL.path)",
                        "delivery_batch_name\t\(deliveryFolderURL.lastPathComponent)",
                        "target_event_name\t📦 Turnover",
                        "handle_frames\t\(handles)",
                        "total_handle_frames\t\(handles)",
                        "slate_frames\t\(slate)",
                        "placement_mode\t\(placement)",
                        "lane\t10",
                        "existing_event_names\t",
                        "existing_project_names\t",
                    ].joined(separator: "\n") + "\n"
                    try configText.write(to: config, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(at: config) }
                    let result = try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", plannerSource.path,
                            "--config", config.path,
                            "--output-xml", destination.path,
                            "--report", report.path,
                        ]
                    )
                    try await NodeRunner.prepareForFinalCutImport(executable: nodeURL, xmlURL: destination)
                    return result
                }.value
                outputURL = destination
                cacheDebugArtifacts(tool: "VFX-Timeline", sourceXML: plannerSource, output: destination, report: report)
                try? FileManager.default.removeItem(at: report)
                reportURL = nil
                state = .succeeded
                log = result.isEmpty ? "VFX Timeline completed." : result
                if openInFinalCut { openResultInFinalCut() }
            } catch {
                try? FileManager.default.removeItem(at: report)
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func runVFXNaming() {
        guard let sourceURL else { return }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("Node.js was not found. Install Node.js or configure TURNOVER_NODE_PATH.")
            return
        }
        guard let scriptURL = NodeRunner.vfxNamingScript() else {
            state = .failed("The bundled VFX Naming transformer is missing.")
            return
        }

        let plannerSource = sourceURL.pathExtension.lowercased() == "fcpxmld"
            ? sourceURL.appendingPathComponent("Info.fcpxml")
            : sourceURL
        let suffix = namingMode == .auto ? "Auto Naming" : "Reset Naming"
        guard let destination = chooseXMLOutputURL(for: sourceURL, suffix: suffix) else {
            log = "VFX Naming cancelled: no output location selected."
            return
        }
        let report = temporaryReportURL(tool: "vfx-naming")
        let mode = namingMode.argument
        let start = max(0, namingStart)
        let step = max(1, namingStep)
        state = .running
        outputURL = nil
        reportURL = nil
        log = namingMode == .auto ? "Numbering VFX naming titles..." : "Resetting VFX naming titles to XXXX..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let result = try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", plannerSource.path,
                            "--output-xml", destination.path,
                            "--report", report.path,
                            "--mode", mode,
                            "--start", String(start),
                            "--step", String(step),
                        ]
                    )
                    try await NodeRunner.prepareForFinalCutImport(executable: nodeURL, xmlURL: destination)
                    return result
                }.value
                outputURL = destination
                cacheDebugArtifacts(tool: "VFX-Naming", sourceXML: plannerSource, output: destination, report: report)
                try? FileManager.default.removeItem(at: report)
                reportURL = nil
                state = .succeeded
                log = result.isEmpty ? "VFX Naming completed." : result
                if openInFinalCut { openResultInFinalCut() }
            } catch {
                try? FileManager.default.removeItem(at: report)
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func runVFXPullEDL() {
        guard let sourceURL else { return }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("Node.js was not found. Install Node.js or configure TURNOVER_NODE_PATH.")
            return
        }
        guard let scriptURL = NodeRunner.vfxPullEDLScript() else {
            state = .failed("The bundled VFX Pull EDL planner is missing.")
            return
        }
        guard let markerScriptURL = NodeRunner.autoMarkerScript() else {
            state = .failed("The bundled marker anchor transformer is missing.")
            return
        }

        let plannerSource = sourceURL.pathExtension.lowercased() == "fcpxmld"
            ? sourceURL.appendingPathComponent("Info.fcpxml")
            : sourceURL
        guard let outputDirectory = chooseVFXPullExportDirectory(suggestedBy: sourceURL) else {
            log = "VFX Pull EDL export cancelled."
            return
        }
        let debugDirectory: URL
        do {
            debugDirectory = try createDebugJobDirectory(tool: "VFX-Pull-EDL")
        } catch {
            state = .failed("Could not prepare the debug cache: \(error.localizedDescription)")
            return
        }
        let debugSource = debugDirectory.appendingPathComponent("Source.fcpxml")
        let anchoredSource = debugDirectory.appendingPathComponent("Marker-Anchored.fcpxml")
        let markerReport = debugDirectory.appendingPathComponent("Auto-Marker.report.txt")
        let report = debugDirectory.appendingPathComponent("VFX-Pull-EDL.report.txt")
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnover-vfx-pull-\(UUID().uuidString).tsv")
        let handles = max(0, handleFrames)
        state = .running
        outputURL = nil
        reportURL = nil
        log = "Building VFX Pull EDL from VFX naming titles..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: plannerSource, to: debugSource)
                    _ = try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            markerScriptURL.path,
                            "--source-xml", debugSource.path,
                            "--output-xml", anchoredSource.path,
                            "--report", markerReport.path,
                            "--marker-kind", "standard",
                            "--rename-markers", "true",
                        ]
                    )
                    try "handle_frames\t\(handles)\n".write(to: config, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(at: config) }
                    return try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", anchoredSource.path,
                            "--config", config.path,
                            "--output-dir", outputDirectory.path,
                            "--report", report.path,
                        ]
                    )
                }.value
                let paths = parsePlannerPaths(result)
                guard let edl = paths.edl, FileManager.default.fileExists(atPath: edl.path) else {
                    throw NodeRunner.ProcessFailure(message: "The planner completed without creating an EDL file.")
                }
                outputURL = edl
                reportURL = nil
                state = .succeeded
                try? CacheManager.prepareAndClean()
                refreshCacheSize()
                log = "VFX Pull EDL completed. Marker anchors were generated privately; the Final Cut timeline was not modified."
            } catch {
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func runAutoMarker() {
        guard let sourceURL else { return }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("Node.js was not found. Install Node.js or configure TURNOVER_NODE_PATH.")
            return
        }
        guard let scriptURL = NodeRunner.autoMarkerScript() else {
            state = .failed("The bundled Auto Marker transformer is missing.")
            return
        }

        let plannerSource = sourceURL.pathExtension.lowercased() == "fcpxmld"
            ? sourceURL.appendingPathComponent("Info.fcpxml")
            : sourceURL
        guard let destination = chooseXMLOutputURL(for: sourceURL, suffix: "Auto Marker") else {
            log = "Auto Marker cancelled: no output location selected."
            return
        }
        let report = temporaryReportURL(tool: "auto-marker")
        let selectedKind = markerKind.argument
        let shouldRename = renameMarkers
        state = .running
        outputURL = nil
        reportURL = nil
        log = "Creating \(markerKind.rawValue) markers..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let result = try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", plannerSource.path,
                            "--output-xml", destination.path,
                            "--report", report.path,
                            "--marker-kind", selectedKind,
                            "--rename-markers", shouldRename ? "true" : "false",
                        ]
                    )
                    try await NodeRunner.prepareForFinalCutImport(executable: nodeURL, xmlURL: destination)
                    return result
                }.value
                outputURL = destination
                cacheDebugArtifacts(tool: "Auto-Marker", sourceXML: plannerSource, output: destination, report: report)
                try? FileManager.default.removeItem(at: report)
                reportURL = nil
                state = .succeeded
                log = result.isEmpty ? "Auto Marker completed." : result
                if openInFinalCut { openResultInFinalCut() }
            } catch {
                try? FileManager.default.removeItem(at: report)
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func openResultInFinalCut() {
        guard let outputURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let finalCutURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FinalCut") {
            NSWorkspace.shared.open(
                [outputURL],
                withApplicationAt: finalCutURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    Task { @MainActor in
                        self.state = .failed("Final Cut Pro could not open the result: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            NSWorkspace.shared.open(outputURL)
        }
    }

    func revealOutput() {
        guard let outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    func openReport() {
        guard let reportURL else { return }
        NSWorkspace.shared.open(reportURL)
    }

    func clearCache() {
        do {
            let clearsCurrentSource = sourceURL.map { $0.path.hasPrefix(CacheManager.inboxURL.path + "/") } ?? false
            try CacheManager.clear()
            if clearsCurrentSource {
                sourceURL = nil
                outputURL = nil
                reportURL = nil
                state = .idle
            }
            refreshCacheSize()
            log = "Turnover cache cleared. User-selected source files and saved outputs were not touched."
        } catch {
            state = .failed("Could not clear the cache: \(error.localizedDescription)")
        }
    }

    private func refreshCacheSize() {
        cacheSizeText = ByteCountFormatter.string(fromByteCount: CacheManager.size(), countStyle: .file)
    }

    private func chooseXMLOutputURL(for source: URL, suffix: String) -> URL? {
        if openInFinalCut {
            guard let folder = try? createDebugJobDirectory(tool: suffix.replacingOccurrences(of: " ", with: "-")) else {
                return nil
            }
            return folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) - \(suffix).fcpxml")
        }

        let panel = NSSavePanel()
        panel.title = "Save \(suffix) FCPXML"
        panel.prompt = "Save"
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml")].compactMap { $0 }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(source.deletingPathExtension().lastPathComponent) - \(suffix).fcpxml"
        panel.directoryURL = source.path.hasPrefix(CacheManager.inboxURL.path + "/")
            ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            : source.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.pathExtension.lowercased() == "fcpxml" ? url : url.appendingPathExtension("fcpxml")
    }

    private func chooseBurnInManifestOutputURL(for source: URL) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Data Burn-In Manifest"
        panel.prompt = "Build Manifest"
        panel.allowedContentTypes = [UTType.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(source.deletingPathExtension().lastPathComponent) - BurnInManifest.json"
        panel.directoryURL = source.path.hasPrefix(CacheManager.inboxURL.path + "/")
            ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            : source.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.pathExtension.lowercased() == "json" ? url : url.appendingPathExtension("json")
    }

    private func formatTimecode(seconds: Double, frameDuration: Double, tcFormat: String) -> String {
        let duration = frameDuration > 0 ? frameDuration : (1.0 / 24.0)
        let fps = max(1, Int((1.0 / duration).rounded()))
        var frames = max(0, Int((seconds / duration + 0.000001).rounded(.down)))
        if tcFormat.uppercased() == "DF", fps == 30 || fps == 60 {
            let dropFrames = Int((Double(fps) * 0.0666666667).rounded())
            let framesPerMinute = (fps * 60) - dropFrames
            let framesPerTenMinutes = (fps * 600) - (dropFrames * 9)
            let tenMinuteChunks = frames / framesPerTenMinutes
            let remainder = frames % framesPerTenMinutes
            frames += (dropFrames * 9 * tenMinuteChunks)
                + (dropFrames * max(0, remainder - dropFrames) / framesPerMinute)
        }
        let ff = frames % fps
        let totalSeconds = frames / fps
        let ss = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let mm = totalMinutes % 60
        let hh = (totalMinutes / 60) % 24
        return String(format: "%02d:%02d:%02d:%02d", hh, mm, ss, ff)
    }

    private func cacheDebugArtifacts(tool: String, sourceXML: URL, output: URL, report: URL) {
        let outputIsCached = output.path.hasPrefix(CacheManager.inboxURL.path + "/")
        let folder: URL
        if outputIsCached {
            folder = output.deletingLastPathComponent()
        } else {
            guard let debugFolder = try? createDebugJobDirectory(tool: tool) else { return }
            folder = debugFolder
        }
        let manager = FileManager.default
        var items = [
            (sourceXML, folder.appendingPathComponent("Source.fcpxml")),
            (report, folder.appendingPathComponent("Report.txt")),
        ]
        if !outputIsCached {
            let outputExtension = output.pathExtension.isEmpty ? "dat" : output.pathExtension
            items.append((output, folder.appendingPathComponent("Output.\(outputExtension)")))
        }
        for (source, destination) in items where manager.fileExists(atPath: source.path) {
            guard source.standardizedFileURL != destination.standardizedFileURL else { continue }
            try? manager.copyItem(at: source, to: destination)
        }
        try? CacheManager.prepareAndClean()
        refreshCacheSize()
    }

    private func temporaryReportURL(tool: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("turnover-\(tool)-\(UUID().uuidString).report.txt")
    }

    private func uniqueSidecarURL(for source: URL, suffix: String, extension ext: String) -> URL {
        uniqueSidecarURL(
            in: source.deletingLastPathComponent(),
            baseName: source.deletingPathExtension().lastPathComponent,
            suffix: suffix,
            extension: ext
        )
    }

    private func uniqueSidecarURL(
        in folder: URL,
        baseName: String,
        suffix: String,
        extension ext: String
    ) -> URL {
        folder.appendingPathComponent("\(baseName) - \(suffix).\(ext)")
    }

    private func createDebugJobDirectory(tool: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = CacheManager.inboxURL
            .appendingPathComponent("Debug", isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: Date()))-\(tool)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func chooseVFXPullExportDirectory(suggestedBy source: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose VFX Pull EDL Export Folder"
        panel.prompt = "Export"
        panel.message = "The EDL, companion TSV, and report will be saved in this folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = source.path.hasPrefix(CacheManager.inboxURL.path + "/")
            ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            : source.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func parsePlannerPaths(_ output: String) -> (edl: URL?, report: URL?) {
        let jsonLine = output.split(separator: "\n").last.map(String.init) ?? output
        guard let data = jsonLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let edl = (object["edl_path"] as? String).map(URL.init(fileURLWithPath:))
        let report = (object["report_path"] as? String).map(URL.init(fileURLWithPath:))
        return (edl, report)
    }

    nonisolated private static func shotListManifestRows(at url: URL) throws -> [[String: String]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \Character.isNewline).map(String.init)
        guard lines.count >= 2 else {
            throw NodeRunner.ProcessFailure(message: "The VFX Shot List manifest has no marker rows.")
        }
        let headers = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return lines.dropFirst().map { line in
            let values = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            var row: [String: String] = [:]
            for (index, header) in headers.enumerated() {
                row[header] = unescapeTSV(index < values.count ? values[index] : "")
            }
            return row
        }
    }

    private func chooseShotListExportDirectory(suggestedBy source: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose VFX Shot List Export Folder"
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = source.path.hasPrefix(CacheManager.inboxURL.path + "/")
            ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            : source.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func uniqueShotListResultFolder(in parent: URL, projectName: String) -> URL {
        let base = "VFX Shot List - \(sanitizeFilename(projectName))"
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    private func sanitizeFilename(_ value: String) -> String {
        let clean = value
            .replacingOccurrences(of: #"[<>:\"/\\|?*]"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Project" : clean
    }

    nonisolated private static func unescapeTSV(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\\\", with: "\u{0000}")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\u{0000}", with: "\\")
    }

    private var finalCutPasteboardTypes: [String] {
        (8...14).reversed().map { "com.apple.finalcutpro.xml.v1-\($0)" }
            + ["com.apple.finalcutpro.xml"]
    }

    private func storeFinalCutDrop(_ data: Data) throws -> URL {
        guard let xml = String(data: data, encoding: .utf8), xml.contains("<fcpxml") else {
            throw NodeRunner.ProcessFailure(message: "The dropped Final Cut Pro payload is not valid UTF-8 FCPXML.")
        }
        let projectName = xml.firstMatch(for: #"<project\b[^>]*\bname="([^"]+)""#) ?? "Final Cut Project"
        let safeName = projectName
            .replacingOccurrences(of: #"[/:]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let inbox = CacheManager.inboxURL
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var destination = inbox.appendingPathComponent("\(safeName).fcpxml")
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = inbox.appendingPathComponent("\(safeName) \(index).fcpxml")
            index += 1
        }
        let normalizedXML = normalizeFinalCutDropText(xml)
        guard let normalizedData = normalizedXML.data(using: .utf8) else {
            throw NodeRunner.ProcessFailure(message: "The normalized Final Cut Pro project is not valid UTF-8.")
        }
        try normalizedData.write(to: destination, options: .atomic)
        refreshCacheSize()
        return destination
    }

    private func normalizeFinalCutDropText(_ xml: String) -> String {
        guard let textStyleExpression = try? NSRegularExpression(
            pattern: #"<text-style\b[^>]*>[\s\S]*?</text-style>"#
        ), let continuationIndent = try? NSRegularExpression(pattern: #"(\r?\n) {8}"#) else {
            return xml
        }

        var normalized = xml
        let matches = textStyleExpression.matches(
            in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized)
        )
        for match in matches.reversed() {
            guard let range = Range(match.range, in: normalized) else { continue }
            let block = String(normalized[range])
            let cleanBlock = continuationIndent.stringByReplacingMatches(
                in: block,
                range: NSRange(block.startIndex..., in: block),
                withTemplate: "$1"
            )
            normalized.replaceSubrange(range, with: cleanBlock)
        }
        return normalized
    }
}

private extension String {
    func firstMatch(for pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
