import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import Carbon.HIToolbox

struct SetupStatus {
    let luaInstalled: Bool
    let motionTemplateInstalled: Bool
    let screenRecordingGranted: Bool
    let accessibilityGranted: Bool
    let automationGranted: Bool
    let startAtLoginEnabled: Bool
}

final class WorkerSetupWindowController: NSWindowController {
    private let worker: VFXShotListWorker
    private let summaryLabel = NSTextField(labelWithString: "Install the SpliceKit menu scripts, Motion title, and permissions from one place.")
    private let footerLabel = NSTextField(labelWithString: "")
    private let luaStatusLabel = NSTextField(labelWithString: "")
    private let motionStatusLabel = NSTextField(labelWithString: "")
    private let screenStatusLabel = NSTextField(labelWithString: "")
    private let accessibilityStatusLabel = NSTextField(labelWithString: "")
    private let automationStatusLabel = NSTextField(labelWithString: "")
    private let loginStatusLabel = NSTextField(labelWithString: "")
    private let startAtLoginCheckbox = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)

    init(worker: VFXShotListWorker) {
        self.worker = worker

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SpliceKit Worker"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        buildUI()
        refreshStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSetupWindow() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshStatus(message: String? = nil) {
        let status = worker.currentSetupStatus()
        updateStatus(label: luaStatusLabel, title: "Lua Scripts", isOK: status.luaInstalled, okText: "Installed", missingText: "Not installed")
        updateStatus(label: motionStatusLabel, title: "VFX Naming Title", isOK: status.motionTemplateInstalled, okText: "Installed", missingText: "Not installed")
        updateStatus(label: screenStatusLabel, title: "Screen Recording", isOK: status.screenRecordingGranted, okText: "Allowed", missingText: "Needs permission")
        updateStatus(label: accessibilityStatusLabel, title: "Accessibility", isOK: status.accessibilityGranted, okText: "Allowed", missingText: "Needs permission")
        updateStatus(label: automationStatusLabel, title: "Automation", isOK: status.automationGranted, okText: "Allowed", missingText: "Needs permission")
        updateStatus(label: loginStatusLabel, title: "Login Item", isOK: status.startAtLoginEnabled, okText: "Enabled", missingText: "Disabled")

        startAtLoginCheckbox.state = status.startAtLoginEnabled ? .on : .off
        footerLabel.stringValue = message ?? ""
    }

    private func buildUI() {
        guard let window else { return }

        let visualEffect = NSVisualEffectView(frame: window.contentView?.bounds ?? .zero)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        window.contentView = visualEffect

        let rootStack = NSStackView()
        rootStack.orientation = .horizontal
        rootStack.spacing = 24
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(rootStack)

        let iconImageView = NSImageView()
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.image = bundlePreviewIcon()
        NSLayoutConstraint.activate([
            iconImageView.widthAnchor.constraint(equalToConstant: 140),
            iconImageView.heightAnchor.constraint(equalToConstant: 140),
        ])

        let rightStack = NSStackView()
        rightStack.orientation = .vertical
        rightStack.spacing = 14
        rightStack.alignment = .leading

        let titleLabel = NSTextField(labelWithString: "SpliceKit Worker")
        titleLabel.font = NSFont.systemFont(ofSize: 24, weight: .semibold)

        summaryLabel.font = NSFont.systemFont(ofSize: 13)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.lineBreakMode = .byWordWrapping

        let statusStack = NSStackView()
        statusStack.orientation = .vertical
        statusStack.spacing = 8
        statusStack.alignment = .leading

        [luaStatusLabel, motionStatusLabel, screenStatusLabel, accessibilityStatusLabel, automationStatusLabel, loginStatusLabel].forEach { label in
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            statusStack.addArrangedSubview(label)
        }

        let installAllButton = makeButton(title: "Install All", action: #selector(handleInstallAll))
        let luaButton = makeButton(title: "Install Lua Scripts", action: #selector(handleInstallLua))
        let motionButton = makeButton(title: "Install Motion Template", action: #selector(handleInstallMotion))
        let screenButton = makeButton(title: "Request Screen Recording", action: #selector(handleRequestScreenRecording))
        let accessibilityButton = makeButton(title: "Request Accessibility", action: #selector(handleRequestAccessibility))
        let launchFCPButton = makeButton(title: "Launch Final Cut Pro", action: #selector(handleLaunchFinalCut))
        let refreshButton = makeButton(title: "Refresh Status", action: #selector(handleRefresh))

        startAtLoginCheckbox.target = self
        startAtLoginCheckbox.action = #selector(toggleStartAtLogin)

        let buttonRow1 = NSStackView(views: [installAllButton, luaButton, motionButton])
        buttonRow1.orientation = .horizontal
        buttonRow1.spacing = 12

        let buttonRow2 = NSStackView(views: [screenButton, accessibilityButton, launchFCPButton, refreshButton])
        buttonRow2.orientation = .horizontal
        buttonRow2.spacing = 12

        footerLabel.font = NSFont.systemFont(ofSize: 12)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.maximumNumberOfLines = 0
        footerLabel.lineBreakMode = .byWordWrapping

        rightStack.addArrangedSubview(titleLabel)
        rightStack.addArrangedSubview(summaryLabel)
        rightStack.addArrangedSubview(statusStack)
        rightStack.addArrangedSubview(startAtLoginCheckbox)
        rightStack.addArrangedSubview(buttonRow1)
        rightStack.addArrangedSubview(buttonRow2)
        rightStack.addArrangedSubview(footerLabel)

        rootStack.addArrangedSubview(iconImageView)
        rootStack.addArrangedSubview(rightStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -24),
            rootStack.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 24),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: visualEffect.bottomAnchor, constant: -24),
            rightStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])
    }

    private func bundlePreviewIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "SpliceKitWorkerIconPreview", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: NSImage.applicationIconName)
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func updateStatus(label: NSTextField, title: String, isOK: Bool, okText: String, missingText: String) {
        let marker = isOK ? "●" : "○"
        let text = isOK ? okText : missingText
        label.stringValue = "\(marker) \(title): \(text)"
        label.textColor = isOK ? .labelColor : .secondaryLabelColor
    }

    @objc private func handleInstallAll() {
        worker.performInstallAll()
        refreshStatus(message: "Installed Lua scripts and Motion template, then requested permissions.")
    }

    @objc private func handleInstallLua() {
        let ok = worker.installLuaScripts()
        refreshStatus(message: ok ? "Lua scripts copied into the SpliceKit menu folder." : "Lua script install failed. Check the worker log.")
    }

    @objc private func handleInstallMotion() {
        let ok = worker.installMotionTemplate()
        refreshStatus(message: ok ? "VFX Naming Motion title installed." : "Motion template install failed. Check the worker log.")
    }

    @objc private func handleRequestScreenRecording() {
        worker.requestScreenRecordingPermission()
        refreshStatus(message: "Requested Screen Recording permission.")
    }

    @objc private func handleRequestAccessibility() {
        worker.requestAccessibilityAndAutomationPermission()
        refreshStatus(message: "Requested Accessibility and Automation permissions.")
    }

    @objc private func handleLaunchFinalCut() {
        worker.launchFinalCutPro()
        refreshStatus(message: "Launched Final Cut Pro.")
    }

    @objc private func handleRefresh() {
        refreshStatus(message: "Status refreshed.")
    }

    @objc private func toggleStartAtLogin() {
        let enabled = startAtLoginCheckbox.state == .on
        let ok = worker.setLaunchAtLogin(enabled)
        let message: String
        if ok {
            message = enabled ? "SpliceKit Worker will now open at login." : "SpliceKit Worker will no longer open at login."
        } else {
            message = "Could not change the login item state. macOS may ask for System Events permission."
        }
        refreshStatus(message: message)
    }
}

final class WorkerAppDelegate: NSObject, NSApplicationDelegate {
    private let worker = VFXShotListWorker()
    private var timer: Timer?
    private var windowController: WorkerSetupWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        worker.start()
        let windowController = WorkerSetupWindowController(worker: worker)
        self.windowController = windowController
        worker.performInitialSetupIfNeeded()
        windowController.refreshStatus()
        windowController.showSetupWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.worker.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        worker.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.showSetupWindow()
        return true
    }
}

final class VFXShotListWorker {
    private let fileManager = FileManager.default
    private let homeDir = FileManager.default.homeDirectoryForCurrentUser
    private lazy var desktopDir = homeDir.appendingPathComponent("Desktop", isDirectory: true)
    private lazy var stateDir = homeDir
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("SpliceKit", isDirectory: true)
        .appendingPathComponent("VFXShotList", isDirectory: true)

    private lazy var readyFile = stateDir.appendingPathComponent("VFX_Shot_List_Worker_Ready.flag")
    private lazy var progressFile = stateDir.appendingPathComponent("VFX_Shot_List_Progress.tsv")
    private lazy var doneFile = stateDir.appendingPathComponent("VFX_Shot_List_Done.flag")
    private lazy var manifestFile = stateDir.appendingPathComponent("VFX_Shot_List_Manifest.tsv")
    private lazy var fcpxmlFile = stateDir.appendingPathComponent("VFX_Shot_List.fcpxml")
    private lazy var reportFile = stateDir.appendingPathComponent("VFX_Shot_List_Report.txt")
    private lazy var logFile = stateDir.appendingPathComponent("VFX_Shot_List_Capture_Worker.log")
    private lazy var deliveriesRequestFile = stateDir.appendingPathComponent("VFX_Deliveries_Request.tsv")
    private lazy var deliveriesConfigFile = stateDir.appendingPathComponent("VFX_Deliveries_Config.tsv")
    private lazy var deliveriesJobFile = stateDir.appendingPathComponent("VFX_Deliveries_Job.tsv")
    private lazy var deliveriesResultFile = stateDir.appendingPathComponent("VFX_Deliveries_Result.tsv")
    private lazy var markerRequestFile = stateDir.appendingPathComponent("VFX_Auto_Marker_Request.tsv")
    private lazy var markerResultFile = stateDir.appendingPathComponent("VFX_Auto_Marker_Result.tsv")

    private lazy var rawDir = desktopDir.appendingPathComponent("VFX_Shot_List_Captures_Raw", isDirectory: true)
    private lazy var cropDir = desktopDir.appendingPathComponent("VFX_Shot_List_Captures_16x9", isDirectory: true)
    private lazy var thumbDir = desktopDir.appendingPathComponent("VFX_Shot_List_Captures_Thumb", isDirectory: true)

    private let thumbWidth: CGFloat = 960
    private var lastProcessedLine = 1
    private var currentRunCaptureAttempts = 0
    private var currentRunCaptureSuccesses = 0
    private var currentRunCaptureFailures = 0
    private var abortCurrentRun = false
    private var isHandlingDeliveriesRequest = false
    private var isHandlingDeliveriesJob = false
    private var isHandlingMarkerRequest = false

    private lazy var packageRootURL: URL = {
        let bundleURL = Bundle.main.bundleURL
        return bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    }()

    private lazy var generatorScriptURL = packageRootURL
        .appendingPathComponent("lua", isDirectory: true)
        .appendingPathComponent("scripts", isDirectory: true)
        .appendingPathComponent("generate_vfx_shot_list_excel.mjs")
    private lazy var deliveriesPlannerScriptURL = packageRootURL
        .appendingPathComponent("lua", isDirectory: true)
        .appendingPathComponent("scripts", isDirectory: true)
        .appendingPathComponent("build_vfx_deliveries_fcpxml.mjs")

    private lazy var artifactToolLinkURL = packageRootURL
        .appendingPathComponent("lua", isDirectory: true)
        .appendingPathComponent("scripts", isDirectory: true)
        .appendingPathComponent("node_modules", isDirectory: true)
        .appendingPathComponent("@oai", isDirectory: true)
        .appendingPathComponent("artifact-tool")

    private lazy var codexNodeURL = homeDir
        .appendingPathComponent(".cache", isDirectory: true)
        .appendingPathComponent("codex-runtimes", isDirectory: true)
        .appendingPathComponent("codex-primary-runtime", isDirectory: true)
        .appendingPathComponent("dependencies", isDirectory: true)
        .appendingPathComponent("node", isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("node")

    private lazy var codexArtifactToolURL = homeDir
        .appendingPathComponent(".cache", isDirectory: true)
        .appendingPathComponent("codex-runtimes", isDirectory: true)
        .appendingPathComponent("codex-primary-runtime", isDirectory: true)
        .appendingPathComponent("dependencies", isDirectory: true)
        .appendingPathComponent("node", isDirectory: true)
        .appendingPathComponent("node_modules", isDirectory: true)
        .appendingPathComponent("@oai", isDirectory: true)
        .appendingPathComponent("artifact-tool")

    private lazy var splicekitMenuRootURL = homeDir
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("SpliceKit", isDirectory: true)
        .appendingPathComponent("lua", isDirectory: true)
        .appendingPathComponent("menu", isDirectory: true)

    private lazy var luaSourceRootURL = packageRootURL
        .appendingPathComponent("lua", isDirectory: true)

    private lazy var motionTemplateSourceURL = packageRootURL
        .appendingPathComponent("motion-templates", isDirectory: true)
        .appendingPathComponent("Titles.localized", isDirectory: true)
        .appendingPathComponent("VFX", isDirectory: true)
        .appendingPathComponent("VFX Naming", isDirectory: true)

    private lazy var motionTemplateTargetURL = homeDir
        .appendingPathComponent("Movies", isDirectory: true)
        .appendingPathComponent("Motion Templates.localized", isDirectory: true)
        .appendingPathComponent("Titles.localized", isDirectory: true)
        .appendingPathComponent("VFX", isDirectory: true)
        .appendingPathComponent("VFX Naming", isDirectory: true)

    private let initialSetupDefaultsKey = "SpliceKitWorkerInitialSetupCompleted"
    private lazy var patchedFinalCutURL = homeDir
        .appendingPathComponent("Applications", isDirectory: true)
        .appendingPathComponent("SpliceKit", isDirectory: true)
        .appendingPathComponent("Final Cut Pro.app", isDirectory: true)
    private lazy var stockFinalCutURL = URL(fileURLWithPath: "/Applications/Final Cut Pro.app", isDirectory: true)

    func start() {
        try? fileManager.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? "".write(to: logFile, atomically: true, encoding: .utf8)

        log("SpliceKit Worker.app")
        log("Watching: \(progressFile.path)")
        log("State dir: \(stateDir.path)")
        log("Raw captures (created on demand): \(rawDir.path)")
        log("16x9 captures (created on demand): \(cropDir.path)")
        log("Thumb captures (created on demand): \(thumbDir.path)")
        log("Worker log: \(logFile.path)")
        log("Package root: \(packageRootURL.path)")

        writeReadyFlag()

        if !CGPreflightScreenCaptureAccess() {
            log("Screen Recording permission not granted yet. Requesting access...")
            _ = CGRequestScreenCaptureAccess()
        } else {
            log("Screen Recording permission already granted.")
        }
    }

    func shutdown() {
        try? fileManager.removeItem(at: readyFile)
    }

    func performInitialSetupIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: initialSetupDefaultsKey) else { return }
        performInstallAll()
        UserDefaults.standard.set(true, forKey: initialSetupDefaultsKey)
    }

    func performInstallAll() {
        _ = installLuaScripts()
        _ = installMotionTemplate()
        requestRequiredPermissions()
    }

    func currentSetupStatus() -> SetupStatus {
        SetupStatus(
            luaInstalled: luaScriptsInstalled(),
            motionTemplateInstalled: motionTemplateInstalled(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            accessibilityGranted: AXIsProcessTrusted(),
            automationGranted: automationGranted(),
            startAtLoginEnabled: launchAtLoginEnabled()
        )
    }

    @discardableResult
    func installLuaScripts() -> Bool {
        do {
            try fileManager.createDirectory(at: splicekitMenuRootURL, withIntermediateDirectories: true)
            try syncDirectoryContents(from: luaSourceRootURL, to: splicekitMenuRootURL)
            for legacyName in [
                "VFX Auto Marker - Standard.lua",
                "VFX Auto Marker - To Do.lua",
                "VFX Auto Marker - Chapter.lua",
            ] {
                try? fileManager.removeItem(at: splicekitMenuRootURL.appendingPathComponent(legacyName))
            }
            log("Lua scripts installed to: \(splicekitMenuRootURL.path)")
            return luaScriptsInstalled()
        } catch {
            log("Failed to install Lua scripts: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func installMotionTemplate() -> Bool {
        guard fileManager.fileExists(atPath: motionTemplateSourceURL.path) else {
            log("Missing motion template source: \(motionTemplateSourceURL.path)")
            return false
        }

        do {
            try fileManager.createDirectory(at: motionTemplateTargetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try replaceItem(at: motionTemplateTargetURL, with: motionTemplateSourceURL)
            log("Motion template installed to: \(motionTemplateTargetURL.path)")
            return motionTemplateInstalled()
        } catch {
            log("Failed to install motion template: \(error.localizedDescription)")
            return false
        }
    }

    func requestRequiredPermissions() {
        requestScreenRecordingPermission()
        requestAccessibilityAndAutomationPermission()
    }

    func requestScreenRecordingPermission() {
        if !CGPreflightScreenCaptureAccess() {
            log("Requesting Screen Recording permission.")
            _ = CGRequestScreenCaptureAccess()
        } else {
            log("Screen Recording permission already granted.")
        }
    }

    func requestAccessibilityAndAutomationPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = runAppleScriptAndCapture("""
            tell application "System Events"
                return UI elements enabled
            end tell
            """)
        log("Requested Accessibility and Automation permissions.")
    }

    func launchFinalCutPro() {
        let appURL = fileManager.fileExists(atPath: patchedFinalCutURL.path) ? patchedFinalCutURL : stockFinalCutURL
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                self.log("Failed to launch Final Cut Pro: \(error.localizedDescription)")
            } else {
                self.log("Launched Final Cut Pro from: \(appURL.path)")
            }
        }
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        let appPath = Bundle.main.bundleURL.path
        let command: String
        if enabled {
            command = """
            tell application "System Events"
              delete every login item whose path is "\(appleScriptEscaped(appPath))"
              make login item at end with properties {path:"\(appleScriptEscaped(appPath))", hidden:true}
            end tell
            """
        } else {
            command = """
            tell application "System Events"
              delete every login item whose path is "\(appleScriptEscaped(appPath))"
            end tell
            """
        }
        runAppleScript(command)
        return launchAtLoginEnabled() == enabled
    }

    func tick() {
        if fileManager.fileExists(atPath: markerRequestFile.path), !isHandlingMarkerRequest {
            handleMarkerRequest()
            return
        }
        if fileManager.fileExists(atPath: deliveriesRequestFile.path), !isHandlingDeliveriesRequest {
            handleDeliveriesRequest()
            return
        }
        if fileManager.fileExists(atPath: deliveriesJobFile.path), !isHandlingDeliveriesJob {
            handleDeliveriesJob()
            return
        }

        guard fileManager.fileExists(atPath: progressFile.path) else {
            lastProcessedLine = 1
            return
        }

        guard let text = try? String(contentsOf: progressFile, encoding: .utf8) else { return }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        guard lines.count > lastProcessedLine else { return }

        for line in lines[lastProcessedLine...] {
            handle(line: line)
        }
        lastProcessedLine = lines.count
    }

    private func handle(line: String) {
        let fields = line.components(separatedBy: "\t")
        let status = fields[safe: 0] ?? ""
        let index = fields[safe: 1] ?? ""
        let markerName = fields[safe: 2] ?? ""
        let fullName = fields[safe: 4] ?? ""
        let thumbName = fields[safe: 5] ?? ""

        switch status {
        case "ready":
            if abortCurrentRun {
                return
            }
            if currentRunCaptureAttempts == 0 {
                try? fileManager.removeItem(at: rawDir)
                try? fileManager.removeItem(at: cropDir)
                try? fileManager.removeItem(at: thumbDir)
            }
            ensureCaptureDirs()
            capture(index: index, markerName: markerName, fullName: fullName, thumbName: thumbName)
        case "done":
            finalizeRun()
        default:
            break
        }
    }

    private func handleMarkerRequest() {
        isHandlingMarkerRequest = true
        defer { isHandlingMarkerRequest = false }

        let request = readKeyValueFile(markerRequestFile)
        let defaultMarkerKind = request["default_marker_kind"]?.nilIfEmpty ?? "standard"

        let markerKind = promptForList(
            prompt: "Choose the VFX marker type:",
            options: ["standard", "todo", "chapter"],
            defaultValue: defaultMarkerKind
        )

        if let markerKind, !markerKind.isEmpty {
            writeKeyValueFile(markerResultFile, [
                "status": "ok",
                "marker_kind": markerKind,
            ])
            log("VFX marker choice written: \(markerKind)")
        } else {
            writeKeyValueFile(markerResultFile, [
                "status": "cancelled",
                "message": "Marker selection cancelled by user.",
            ])
            log("VFX marker selection cancelled.")
        }

        try? fileManager.removeItem(at: markerRequestFile)
    }

    private func handleDeliveriesRequest() {
        isHandlingDeliveriesRequest = true
        defer { isHandlingDeliveriesRequest = false }

        let request = readKeyValueFile(deliveriesRequestFile)
        let defaultHandleFrames = request["total_handle_frames"]?.nilIfEmpty ?? "0"
        let defaultSlateFrames = request["slate_frames"]?.nilIfEmpty ?? "0"
        let defaultPlacementMode = request["placement_mode"]?.nilIfEmpty ?? "connected"
        let defaultLane = request["lane"]?.nilIfEmpty ?? "10"
        let defaultTargetEventName = request["target_event_name"]?.nilIfEmpty ?? "VFX Deliveries"
        let existingEventNames = (request["existing_event_names"] ?? "")
            .split(separator: "\u{1F}")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard let deliveryFolder = promptForFolder(prompt: "Choose the VFX deliveries folder") else {
            writeKeyValueFile(deliveriesConfigFile, [
                "status": "cancelled",
                "message": "Folder selection cancelled by user.",
            ])
            try? fileManager.removeItem(at: deliveriesRequestFile)
            return
        }

        let totalHandleFrames = promptForText(
            prompt: "Total handle frames to trim equally from head/tail:",
            defaultValue: defaultHandleFrames
        ) ?? defaultHandleFrames

        let slateFrames = promptForText(
            prompt: "Slate frames to trim from the head:",
            defaultValue: defaultSlateFrames
        ) ?? defaultSlateFrames

        let placementMode = promptForList(
            prompt: """
Choose placement mode:

connected
- Add the incoming render as a new VFX connected clip above the shot

replace or audition
- Work against the earlier VFX version for that shot
- Never replaces the original editorial clip underneath
- If no earlier VFX version exists, it falls back to connected
- replace swaps to the new VFX version
- audition keeps both VFX versions for comparison
""",
            options: ["connected", "replace", "audition"],
            defaultValue: defaultPlacementMode
        ) ?? defaultPlacementMode

        let targetEventName = promptForEventName(
            existingEventNames: existingEventNames,
            defaultValue: defaultTargetEventName
        ) ?? defaultTargetEventName

        writeKeyValueFile(deliveriesConfigFile, [
            "status": "ok",
            "delivery_folder": deliveryFolder,
            "delivery_batch_name": URL(fileURLWithPath: deliveryFolder).lastPathComponent,
            "target_event_name": targetEventName,
            "total_handle_frames": totalHandleFrames,
            "slate_frames": slateFrames,
            "placement_mode": placementMode,
            "lane": defaultLane,
        ])
        log("VFX Deliveries config written: \(deliveriesConfigFile.path)")
        try? fileManager.removeItem(at: deliveriesRequestFile)
    }

    private func handleDeliveriesJob() {
        isHandlingDeliveriesJob = true
        defer { isHandlingDeliveriesJob = false }

        let job = readKeyValueFile(deliveriesJobFile)
        let sourceXMLPath = job["source_xml_path"]?.nilIfEmpty ?? ""
        let configPath = job["config_path"]?.nilIfEmpty ?? deliveriesConfigFile.path
        let outputXMLPath = job["output_xml_path"]?.nilIfEmpty ?? stateDir.appendingPathComponent("VFX_Deliveries_Patched.fcpxml").path
        let reportPath = job["report_path"]?.nilIfEmpty ?? stateDir.appendingPathComponent("VFX_Deliveries_Report.txt").path

        defer { try? fileManager.removeItem(at: deliveriesJobFile) }
        try? fileManager.removeItem(at: deliveriesResultFile)

        guard !sourceXMLPath.isEmpty, fileManager.fileExists(atPath: sourceXMLPath) else {
            writeKeyValueFile(deliveriesResultFile, [
                "status": "error",
                "message": "Missing source FCPXML export.",
            ])
            return
        }

        guard fileManager.fileExists(atPath: deliveriesPlannerScriptURL.path) else {
            writeKeyValueFile(deliveriesResultFile, [
                "status": "error",
                "message": "Missing VFX Deliveries planner script.",
            ])
            return
        }

        guard let nodeURL = resolvedNodeURL() else {
            writeKeyValueFile(deliveriesResultFile, [
                "status": "error",
                "message": "No Node.js runtime found.",
            ])
            return
        }

        do {
            let process = Process()
            process.executableURL = nodeURL
            process.arguments = [
                deliveriesPlannerScriptURL.path,
                "--source-xml", sourceXMLPath,
                "--config", configPath,
                "--output-xml", outputXMLPath,
                "--report", reportPath,
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !output.isEmpty {
                log(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            if process.terminationStatus == 0, fileManager.fileExists(atPath: outputXMLPath) {
                writeKeyValueFile(deliveriesResultFile, [
                    "status": "ok",
                    "patched_xml_path": outputXMLPath,
                    "report_path": reportPath,
                ])
                log("VFX Deliveries plan ready: \(outputXMLPath)")
            } else {
                writeKeyValueFile(deliveriesResultFile, [
                    "status": "error",
                    "message": output.isEmpty ? "Planner exited with failure." : output,
                    "report_path": reportPath,
                ])
            }
        } catch {
            writeKeyValueFile(deliveriesResultFile, [
                "status": "error",
                "message": "Failed to launch planner: \(error.localizedDescription)",
            ])
        }
    }

    private func capture(index: String, markerName: String, fullName: String, thumbName: String) {
        currentRunCaptureAttempts += 1

        let rawPath = rawDir.appendingPathComponent(fullName)
        let cropPath = cropDir.appendingPathComponent(fullName)
        let thumbPath = thumbDir.appendingPathComponent(thumbName)

        log("Capturing [\(index)] \(markerName) -> \(rawPath.path)")

        guard runScreencapture(to: rawPath) else {
            currentRunCaptureFailures += 1
            log("screencapture failed. Screen Recording permission may be missing for Worker.app.")
            abortCurrentRun = true
            sendEscapeToExitFullscreen()
            return
        }

        do {
            guard let image = NSImage(contentsOf: rawPath) else {
                throw NSError(domain: "VFXShotListWorker", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not read raw screenshot"])
            }
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw NSError(domain: "VFXShotListWorker", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not decode screenshot image"])
            }
            let cropImage = cropTo16x9(cgImage) ?? cgImage
            try writePNG(cropImage, to: cropPath)
            try writeJPEGThumbnail(cropImage, to: thumbPath, maxWidth: thumbWidth)
            currentRunCaptureSuccesses += 1
            log("Saved thumb: \(thumbPath.path)")
            try? fileManager.removeItem(at: rawPath)
            try? fileManager.removeItem(at: cropPath)
        } catch {
            currentRunCaptureFailures += 1
            log("Capture pipeline failed: \(error.localizedDescription)")
            abortCurrentRun = true
            sendEscapeToExitFullscreen()
        }
    }

    private func finalizeRun() {
        log("Done signal received.")
        sendEscapeToExitFullscreen()

        guard currentRunCaptureSuccesses > 0 else {
            log("No thumbnails were captured in this run. Excel generation skipped.")
            cleanupRunState(keepLog: true)
            resetRunCounters()
            return
        }

        log("Generating Excel...")
        guard generateExcel() else {
            log("Excel generation failed. Temporary files kept for debugging.")
            resetRunCounters()
            return
        }

        guard let workbookURL = newestWorkbookURL() else {
            log("Excel generation completed but workbook could not be found.")
            resetRunCounters()
            return
        }

        let finalFolderURL = organizeFinalOutputs(workbookURL: workbookURL)
        cleanupRunState(keepLog: false)
        resetRunCounters()

        if let finalFolderURL {
            NSWorkspace.shared.open(finalFolderURL)
        }
    }

    private func resetRunCounters() {
        currentRunCaptureAttempts = 0
        currentRunCaptureSuccesses = 0
        currentRunCaptureFailures = 0
        abortCurrentRun = false
        lastProcessedLine = 1
        writeReadyFlag()
    }

    private func ensureCaptureDirs() {
        try? fileManager.createDirectory(at: rawDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: cropDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: thumbDir, withIntermediateDirectories: true)
    }

    private func writeReadyFlag() {
        try? fileManager.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? ISO8601DateFormatter().string(from: Date()).write(to: readyFile, atomically: true, encoding: .utf8)
        log("Ready flag: \(readyFile.path)")
    }

    private func cleanupRunState(keepLog: Bool) {
        for url in [progressFile, doneFile, manifestFile, fcpxmlFile, reportFile] {
            try? fileManager.removeItem(at: url)
        }
        try? fileManager.removeItem(at: rawDir)
        try? fileManager.removeItem(at: cropDir)

        if !keepLog {
            try? fileManager.removeItem(at: logFile)
        }
    }

    private func sendEscapeToExitFullscreen() {
        activateFinalCutPro()
        for _ in 0..<3 {
            guard let source = CGEventSource(stateID: .combinedSessionState) else {
                log("Could not create CGEventSource for Escape key.")
                return
            }
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: false) else {
                log("Could not create Escape key events.")
                return
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        log("Posted Escape key to exit fullscreen.")
        runAppleScript("""
            tell application "Final Cut Pro" to activate
            tell application "System Events"
                key code 53
            end tell
            """)
    }

    private func activateFinalCutPro() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FinalCut")
        running.first?.activate()
    }

    private func runAppleScript(_ source: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("Failed to run AppleScript escape fallback: \(error.localizedDescription)")
        }
    }

    private func newestWorkbookURL() -> URL? {
        let candidates = (try? fileManager.contentsOfDirectory(at: desktopDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return candidates
            .filter { $0.lastPathComponent.hasPrefix("VFX Shot List") && $0.pathExtension.lowercased() == "xlsx" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
            .first
    }

    private func organizeFinalOutputs(workbookURL: URL) -> URL? {
        let stem = workbookURL.deletingPathExtension().lastPathComponent
        let outputDir = desktopDir.appendingPathComponent(stem, isDirectory: true)
        let finalWorkbookURL = outputDir.appendingPathComponent(workbookURL.lastPathComponent)
        let finalThumbDir = outputDir.appendingPathComponent("Thumbnails", isDirectory: true)

        do {
            try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: finalWorkbookURL)
            try? fileManager.removeItem(at: finalThumbDir)
            try fileManager.moveItem(at: workbookURL, to: finalWorkbookURL)
            if fileManager.fileExists(atPath: thumbDir.path) {
                try fileManager.moveItem(at: thumbDir, to: finalThumbDir)
            } else {
                try fileManager.createDirectory(at: finalThumbDir, withIntermediateDirectories: true)
            }
            log("Final output folder: \(outputDir.path)")
            log("Workbook: \(finalWorkbookURL.path)")
            log("Thumbnails: \(finalThumbDir.path)")
            return outputDir
        } catch {
            log("Failed to organize final outputs: \(error.localizedDescription)")
            return nil
        }
    }

    private func generateExcel() -> Bool {
        guard let nodeURL = resolvedNodeURL() else {
            log("No Node.js runtime found.")
            return false
        }

        let artifactParent = artifactToolLinkURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: artifactParent, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: artifactToolLinkURL.path) {
            guard fileManager.fileExists(atPath: codexArtifactToolURL.path) else {
                log("Missing @oai/artifact-tool runtime package at: \(codexArtifactToolURL.path)")
                return false
            }
            try? fileManager.createSymbolicLink(at: artifactToolLinkURL, withDestinationURL: codexArtifactToolURL)
        }

        let process = Process()
        process.executableURL = nodeURL
        process.arguments = [
            generatorScriptURL.path,
            "--manifest", manifestFile.path,
            "--thumbs", thumbDir.path,
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !output.isEmpty { log(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return process.terminationStatus == 0
        } catch {
            log("Failed to launch Excel generator: \(error.localizedDescription)")
            return false
        }
    }

    private func resolvedNodeURL() -> URL? {
        if fileManager.isExecutableFile(atPath: codexNodeURL.path) {
            return codexNodeURL
        }
        if let nodePath = shellWhich("node") {
            return URL(fileURLWithPath: nodePath)
        }
        return nil
    }

    private func cropTo16x9(_ image: CGImage) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let lhs = width * 9
        let rhs = height * 16
        let diff = abs(lhs - rhs)
        let tol = max(rhs / 100, 4)
        if diff <= tol { return image }

        var targetW = width
        var targetH = floor(width * 9 / 16)
        if targetH > height {
            targetH = height
            targetW = floor(height * 16 / 9)
        }

        let cropX = floor((width - targetW) / 2)
        var safeTop = floor(height / 28)
        safeTop = min(max(safeTop, 24), 80)
        let usableH = height - safeTop
        var cropY: CGFloat
        if usableH < targetH {
            cropY = floor((height - targetH) / 2)
        } else {
            cropY = floor(safeTop + (usableH - targetH) / 2)
        }
        cropY = max(0, min(cropY, height - targetH))

        let rect = CGRect(x: cropX, y: cropY, width: targetW, height: targetH)
        return image.cropping(to: rect.integral)
    }

    private func runScreencapture(to url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !output.isEmpty {
                log(output)
            }
            return process.terminationStatus == 0 && fileManager.fileExists(atPath: url.path)
        } catch {
            log("Failed to launch screencapture: \(error.localizedDescription)")
            return false
        }
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "VFXShotListWorker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PNG destination"])
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw NSError(domain: "VFXShotListWorker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not finalize PNG"])
        }
    }

    private func writeJPEGThumbnail(_ image: CGImage, to url: URL, maxWidth: CGFloat) throws {
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        let scale = min(1.0, maxWidth / max(sourceWidth, 1))
        let destSize = CGSize(width: max(1, floor(sourceWidth * scale)), height: max(1, floor(sourceHeight * scale)))

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(destSize.width),
            pixelsHigh: Int(destSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmapRep = rep else {
            throw NSError(domain: "VFXShotListWorker", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not allocate thumbnail bitmap"])
        }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            NSGraphicsContext.restoreGraphicsState()
            throw NSError(domain: "VFXShotListWorker", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create graphics context"])
        }
        NSGraphicsContext.current = context
        let nsImage = NSImage(cgImage: image, size: NSSize(width: sourceWidth, height: sourceHeight))
        nsImage.draw(in: NSRect(origin: .zero, size: destSize))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw NSError(domain: "VFXShotListWorker", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not encode JPEG thumbnail"])
        }
        try data.write(to: url)
    }

    private func shellWhich(_ executable: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [executable]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func luaScriptsInstalled() -> Bool {
        let requiredPaths = [
            "VFX Auto Marker.lua",
            "VFX Auto Naming.lua",
            "VFX Reset Naming.lua",
            "VFX Shot List.lua",
            "VFX Timeline.lua",
            "scripts/VFX Auto Marker - Standard.lua",
            "scripts/VFX Auto Marker - To Do.lua",
            "scripts/VFX Auto Marker - Chapter.lua",
            "scripts/build_vfx_deliveries_fcpxml.mjs",
            "scripts/generate_vfx_shot_list_excel.mjs",
        ]
        return requiredPaths.allSatisfy { relativePath in
            fileManager.fileExists(atPath: splicekitMenuRootURL.appendingPathComponent(relativePath).path)
        }
    }

    private func motionTemplateInstalled() -> Bool {
        fileManager.fileExists(atPath: motionTemplateTargetURL.appendingPathComponent("VFX NAMING.moti").path)
    }

    private func automationGranted() -> Bool {
        runAppleScriptAndCapture("""
            tell application "System Events"
                return UI elements enabled
            end tell
            """) != nil
    }

    private func launchAtLoginEnabled() -> Bool {
        guard let result = runAppleScriptAndCapture("""
            tell application "System Events"
                set loginPaths to path of every login item
                return loginPaths as string
            end tell
            """) else {
            return false
        }
        return result.contains(Bundle.main.bundleURL.path)
    }

    private func syncDirectoryContents(from sourceURL: URL, to targetURL: URL) throws {
        try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
        let items = try fileManager.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for sourceItem in items {
            let destinationItem = targetURL.appendingPathComponent(sourceItem.lastPathComponent, isDirectory: false)
            try replaceItem(at: destinationItem, with: sourceItem)
        }
    }

    private func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func readKeyValueFile(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 2 {
                map[parts[0]] = parts[1]
            }
        }
        return map
    }

    private func writeKeyValueFile(_ url: URL, _ map: [String: String]) {
        let lines = map
            .sorted { $0.key < $1.key }
            .map { "\($0.key)\t\($0.value)" }
            .joined(separator: "\n") + "\n"
        try? lines.write(to: url, atomically: true, encoding: .utf8)
    }

    private func promptForFolder(prompt: String) -> String? {
        let script = """
        set chosenFolder to choose folder with prompt "\(appleScriptEscaped(prompt))"
        return POSIX path of chosenFolder
        """
        return runAppleScriptAndCapture(script)?.nilIfEmpty
    }

    private func promptForText(prompt: String, defaultValue: String) -> String? {
        let script = """
        set dialogResult to display dialog "\(appleScriptEscaped(prompt))" default answer "\(appleScriptEscaped(defaultValue))" buttons {"Cancel", "OK"} default button "OK"
        return text returned of dialogResult
        """
        return runAppleScriptAndCapture(script)
    }

    private func promptForList(prompt: String, options: [String], defaultValue: String) -> String? {
        let renderedOptions = options
            .map { "\"\(appleScriptEscaped($0))\"" }
            .joined(separator: ", ")
        let script = """
        set picked to choose from list {\(renderedOptions)} with prompt "\(appleScriptEscaped(prompt))" default items {"\(appleScriptEscaped(defaultValue))"}
        if picked is false then
            return ""
        end if
        return item 1 of picked
        """
        let result = runAppleScriptAndCapture(script)
        return result?.isEmpty == true ? nil : result
    }

    private func promptForEventName(existingEventNames: [String], defaultValue: String) -> String? {
        var options = existingEventNames
        if !options.contains(defaultValue) {
            options.insert(defaultValue, at: 0)
        }
        if !options.contains("New Event...") {
            options.append("New Event...")
        }

        let picked = promptForList(
            prompt: """
Choose the browser event for imported VFX media.

Pick an existing event, or choose New Event... to type a new one.
""",
            options: options,
            defaultValue: defaultValue
        )

        guard let picked else { return nil }
        if picked == "New Event..." {
            return promptForText(
                prompt: "Name for the new VFX event:",
                defaultValue: defaultValue
            )?.nilIfEmpty
        }
        return picked
    }

    private func runAppleScriptAndCapture(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "osascript failed"
                log("AppleScript prompt failed: \(error)")
                return nil
            }
            return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            log("Failed to run AppleScript prompt: \(error.localizedDescription)")
            return nil
        }
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func log(_ message: String) {
        let line = "[vfx-shot-list-app] \(message)"
        print(line)
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if fileManager.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
                return
            }
        }
        try? data.write(to: logFile)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

let app = NSApplication.shared
let delegate = WorkerAppDelegate()
app.delegate = delegate
app.run()
