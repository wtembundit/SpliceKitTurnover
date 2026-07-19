import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: TurnoverModel
    @Environment(\.openWindow) private var openWindow
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.10, blue: 0.13), Color(red: 0.12, green: 0.18, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.orange.opacity(0.16))
                .frame(width: 380, height: 380)
                .blur(radius: 80)
                .offset(x: 300, y: -230)

            VStack(alignment: .leading, spacing: 24) {
                header
                dropZone
                controls
                statusPanel
            }
            .padding(32)
        }
        .preferredColorScheme(.dark)
        .onChange(of: model.state) { _, newState in
            if model.selectedTool == .dataBurnIn,
               newState == .succeeded,
               model.shouldOpenBurnInCustomizerAfterBuild {
                model.shouldOpenBurnInCustomizerAfterBuild = false
                openWindow(id: "burn-in-customizer")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("TURNOVER")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .tracking(3)
                .foregroundStyle(.orange)
            Spacer()
            Button(model.updateStatus) { model.checkForUpdates() }
                .buttonStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Version \(appVersion)")
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0"
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: model.sourceURL == nil ? "arrow.down.doc.fill" : "doc.badge.checkmark.fill")
                .font(.system(size: 38))
                .foregroundStyle(dropTargeted ? .orange : .white)
            Text(model.sourceURL?.lastPathComponent ?? "Drop an FCPXML file or bundle here")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .lineLimit(1)
            Text("Bundles are read safely and exported as flat FCPXML. The original is never overwritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Choose File...") { model.chooseSource() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.white.opacity(dropTargeted ? 0.10 : 0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(dropTargeted ? Color.orange : Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [8]))
                )
        )
        .onDrop(of: model.dropTypeIdentifiers, isTargeted: $dropTargeted) { providers in
            model.acceptDrop(providers: providers)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolSelection

            VStack(alignment: .leading, spacing: 9) {
                Text("SETTINGS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                contextualSettings
                    .fixedSize(horizontal: false, vertical: true)

                requirementFooter
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                Button {
                    model.runSelectedTool()
                } label: {
                    Label(
                        model.state == .running
                            ? "Processing..."
                            : (model.selectedTool == .dataBurnIn ? "Build Burn-In Cache" : "Run \(model.selectedTool.rawValue)"),
                        systemImage: "wand.and.stars"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!model.canRun)

                if model.burnInExportProgress != nil {
                    Button {
                        model.cancelBurnInExport()
                    } label: {
                        Label("Stop Current", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .help("Cancel the current Data Burn-In export and continue with the next queued job.")
                }

                if model.selectedTool != .vfxPullEDL
                    && model.selectedTool != .vfxShotList
                    && model.selectedTool != .exportMarkers
                    && model.selectedTool != .dataBurnIn {
                    Toggle("Open result in Final Cut Pro", isOn: $model.openInFinalCut)
                        .toggleStyle(.checkbox)
                }

                Spacer()

                if model.outputURL != nil {
                    Button("Reveal") { model.revealOutput() }
                    if model.selectedTool != .vfxPullEDL {
                        Button("Open in Final Cut") { model.openResultInFinalCut() }
                    }
                }
            }
        }
    }

    private var toolSelection: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Picker("Core Tools", selection: $model.selectedTool) {
                    ForEach([
                        TurnoverModel.Tool.conformPrep,
                        TurnoverModel.Tool.dataBurnIn,
                        .exportMarkers,
                    ]) { tool in
                        Text(tool.selectorName).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text("VFX TOOLS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Picker("VFX Tools", selection: $model.selectedTool) {
                    ForEach([
                        TurnoverModel.Tool.vfxNaming,
                        .autoMarker,
                        .vfxPullEDL,
                        .vfxShotList,
                        .vfxTimeline,
                    ]) { tool in
                        Text(tool.selectorName).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var requirementText: String {
        switch model.selectedTool {
        case .conformPrep:
            "Flattens sync clips and retains supported timeline attributes. Use a duplicate timeline, then detach and delete audio first for clean conform checks."
        case .exportMarkers:
            "Exports existing Final Cut Pro markers only. EDL is the Resolve-friendly default; CSV and TXT are available for review."
        case .vfxNaming:
            "Requires the VFX Naming Motion title template. Auto Number works on VFX naming titles already placed in the timeline."
        case .autoMarker:
            "Requires VFX Naming titles in the timeline. Markers are created at their midpoint; renaming is optional."
        case .vfxPullEDL:
            "Requires numbered VFX Naming titles. Existing markers are not required; private marker anchors are generated automatically."
        case .vfxShotList:
            "Requires numbered VFX Naming titles, user markers for thumbnail frames, and a reference movie with matching timeline timecode."
        case .vfxTimeline:
            "Requires numbered VFX Naming titles and delivery filenames containing the matching VFX shot numbers."
        case .dataBurnIn:
            "Builds a frame-resolved preview cache. Export can render a burned-in reference or a transparent ProRes 4444 overlay."
        }
    }

    private var requiresVFXNamingTemplate: Bool {
        model.selectedTool == .vfxNaming || model.selectedTool == .autoMarker
    }

    private var requirementFooter: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.orange)
            Text(requirementText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if requiresVFXNamingTemplate {
                if model.isVFXNamingTemplateInstalled {
                    Label("Template Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button("Install VFX Naming Template") { model.installVFXNamingTemplate() }
                        .controlSize(.small)
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !model.templateInstallStatus.isEmpty && requiresVFXNamingTemplate {
                Text(model.templateInstallStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .offset(y: 16)
            }
        }
    }

    @ViewBuilder
    private var contextualSettings: some View {
        HStack(spacing: 12) {
            switch model.selectedTool {
            case .exportMarkers:
                HStack(spacing: 10) {
                    Picker("Marker Type", selection: $model.markerExportKind) {
                        ForEach(TurnoverModel.MarkerExportKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .frame(width: 220)
                    Picker("Format", selection: $model.markerExportFormat) {
                        ForEach(TurnoverModel.MarkerExportFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .frame(width: 190)
                }
                Text("Exports markers only. EDL is optimized for DaVinci Resolve.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .conformPrep:
                Text("Flatten sync clips to source media. Recommended preflight: duplicate the timeline, detach audio, and delete audio before running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .autoMarker:
                Picker("Marker", selection: $model.markerKind) {
                    ForEach(TurnoverModel.MarkerKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .frame(width: 170)

                Toggle("Rename and add notes", isOn: $model.renameMarkers)
                    .toggleStyle(.checkbox)
            case .vfxPullEDL:
                Stepper("Handles: \(model.handleFrames) frames per side", value: $model.handleFrames, in: 0...240)
                    .frame(width: 240)
            case .vfxNaming:
                Picker("Mode", selection: $model.namingMode) {
                    ForEach(TurnoverModel.NamingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .frame(width: 180)

                if model.namingMode == .auto {
                    Stepper("Start: \(model.namingStart)", value: $model.namingStart, in: 0...9990, step: 10)
                        .frame(width: 115)
                    Stepper("Step: \(model.namingStep)", value: $model.namingStep, in: 1...1000)
                        .frame(width: 110)
                }
            case .vfxTimeline:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Button("Choose Deliveries Folder...") { model.chooseDeliveryFolder() }
                        Text(model.deliveryFolderURL?.lastPathComponent ?? "No folder selected")
                            .font(.caption)
                            .foregroundStyle(model.deliveryFolderURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 12) {
                        Stepper("Handles: \(model.timelineHandleFrames)", value: $model.timelineHandleFrames, in: 0...240)
                            .frame(width: 135)
                        Stepper("Slate: \(model.timelineSlateFrames)", value: $model.timelineSlateFrames, in: 0...240)
                            .frame(width: 115)
                        Picker("Placement", selection: $model.timelinePlacement) {
                            ForEach(TurnoverModel.TimelinePlacement.allCases) { placement in
                                Text(placement.rawValue).tag(placement)
                            }
                        }
                        .frame(width: 170)
                        Text("Event: 📦 Turnover")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .vfxShotList:
                Button("Choose Reference Movie...") { model.chooseReferenceMovie() }
                Text(model.referenceMovieURL?.lastPathComponent ?? "No movie selected")
                    .font(.caption)
                    .foregroundStyle(model.referenceMovieURL == nil ? .secondary : .primary)
                    .lineLimit(1)
                Text("Uses user markers as thumbnail anchors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .dataBurnIn:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Picker("Preset", selection: $model.selectedBurnInPresetID) {
                            ForEach(model.burnInPresets) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        }
                        .frame(width: 135)
                        .onChange(of: model.selectedBurnInPresetID) { _, _ in model.applySelectedBurnInPreset() }

                        Button("Choose Video...") { model.chooseBurnInVideo() }
                            .fixedSize()
                        Text(model.burnInExportMode == .transparentOverlay ? "Transparent ProRes 4444 overlay" : (model.burnInVideoURL?.lastPathComponent ?? "Choose a video for burned-in export"))
                            .font(.caption)
                            .foregroundStyle(model.burnInExportMode == .transparentOverlay || model.burnInVideoURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if model.burnInVideoURL != nil {
                            Button("Clear") { model.clearBurnInVideo() }
                                .controlSize(.small)
                        }
                        Button("Export Video...") { model.prepareBurnInVideoExport() }
                            .fixedSize()
                            .disabled(model.burnInDurationSeconds <= 0)
                            .help(model.burnInExportEstimateText)
                        if model.burnInExportProgress != nil {
                            Button {
                                model.cancelBurnInExport()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.bordered)
                            .help("Cancel the current export")
                        }
                        Button("Customize...") { openWindow(id: "burn-in-customizer") }
                            .fixedSize()
                    }
                    Text(model.burnInExportEstimateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusIndicator
                Text(statusTitle)
                    .font(.system(.headline, design: .rounded))
                Spacer()
                if model.burnInExportProgress == nil {
                    Text(model.nodeStatus)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("Cache: \(model.cacheSizeText)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Clear Cache") { model.clearCache() }
                    .controlSize(.small)
            }
            if let progress = model.burnInExportProgress {
                HStack(spacing: 10) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 360)
                    Text("\(Int(progress * 100))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                    if model.burnInExportQueueCount > 0 {
                        Text("\(model.burnInExportQueueCount) queued")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        model.cancelBurnInExport()
                    } label: {
                        Label("Stop Current", systemImage: "xmark")
                    }
                    .controlSize(.small)
                    .help("Cancel the current export and continue with the next queued job.")
                    if model.burnInExportQueueCount > 0 {
                        Button {
                            model.cancelAllBurnInExports()
                        } label: {
                            Label("Stop All", systemImage: "xmark.circle")
                        }
                        .controlSize(.small)
                        .help("Cancel the current export and clear all queued exports.")
                    }
                }
                Text([model.burnInExportFilename, model.burnInExportStatus]
                    .filter { !$0.isEmpty }
                    .joined(separator: " - "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !model.burnInQueuedExports.isEmpty {
                    HStack(spacing: 8) {
                        Text("Queued \(model.burnInExportQueueCount):")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                        Text(model.burnInQueueSummary)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Clear Queue") {
                            model.clearQueuedBurnInExports()
                        }
                        .controlSize(.small)
                        .help("Remove queued exports. The current export keeps running.")
                    }
                }
            }
            Text(model.log)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch model.state {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        default:
            Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        if model.burnInExportProgress != nil { return "Exporting Video" }
        return switch model.state {
        case .idle: "Waiting for FCPXML"
        case .ready: "Ready"
        case .running: "Processing"
        case .succeeded: "Completed"
        case .failed: "Needs attention"
        }
    }
}
