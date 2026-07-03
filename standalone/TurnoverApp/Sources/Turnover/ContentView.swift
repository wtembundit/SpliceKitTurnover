import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: TurnoverModel
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
            HStack {
                Spacer(minLength: 0)
                Picker("Tool", selection: $model.selectedTool) {
                    ForEach(TurnoverModel.Tool.allCases) { tool in
                        Text(tool.rawValue).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("SETTINGS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                contextualSettings
                    .fixedSize(horizontal: false, vertical: true)
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
                    Label(model.state == .running ? "Processing..." : "Run \(model.selectedTool.rawValue)", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!model.canRun)

                if model.selectedTool != .vfxPullEDL && model.selectedTool != .vfxShotList {
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

    @ViewBuilder
    private var contextualSettings: some View {
        HStack(spacing: 12) {
            switch model.selectedTool {
            case .conformPrep:
                Text("No additional settings")
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
                Text(model.nodeStatus)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Cache: \(model.cacheSizeText)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Clear Cache") { model.clearCache() }
                    .controlSize(.small)
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
        switch model.state {
        case .idle: "Waiting for FCPXML"
        case .ready: "Ready"
        case .running: "Processing"
        case .succeeded: "Completed"
        case .failed: "Needs attention"
        }
    }
}
